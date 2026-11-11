// ============================================================================
// SecDisplayReceiver —— Windows 端接收与显示
//
// 目标：尽可能短的路径把解码结果送上屏
//   TCP 收包 → AVCC 转 Annex-B → Media Foundation H.264 硬解（D3D11 共享纹理）
//            → VideoProcessorBlt 到交换链后缓冲 → Present(0, ALLOW_TEARING)
//
// 关键实现点（每一条都是踩过的坑）：
//   1. MF 的 MFVideoFormat_H264 输入要求 Annex-B。Mac 发来的是 AVCC，
//      按 4 字节长度前缀切 NAL 再换成起始码，不扫描码流内部。
//   2. 硬解必须注入 IMFDXGIDeviceManager（MFT_MESSAGE_SET_D3D11_MANAGER），
//      否则拿到的是系统内存，无法零拷贝。
//   3. 解码器收到首个 SPS 后会返回 MF_E_TRANSFORM_STREAM_CHANGE，
//      必须重设输出类型再继续，否则永远无输出。
//   4. 呈现必须写交换链后缓冲（GetBuffer(0)），不是自建纹理。
//   5. 交换链 FLIP + ALLOW_TEARING，绕过垂直同步。
//   6. 不支持 tearing 的环境要自动降级，否则 Present 持续失败黑屏。
//
// 编译:
//   cl /EHsc /std:c++17 /O2 SecDisplayReceiver.cpp /link ole32.lib user32.lib
// 运行:
//   SecDisplayReceiver.exe <Mac的IP> <端口> <宽> <高>
// ============================================================================

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _CRT_SECURE_NO_WARNINGS   // fopen/strncpy 等标准函数在 MSVC 下会被警告
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>      // 系统托盘 Shell_NotifyIcon
#include <winsock2.h>
#include <ws2tcpip.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <codecapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfobjects.h>
#include <evr.h>
#include <mferror.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <clocale>
#include <string>
#include <vector>
#include <deque>
#include <algorithm>
#include <unordered_map>
#include <atomic>
#include <thread>
#include <mutex>
#include <chrono>
#include <condition_variable>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "gdi32.lib")   // ApplyCursorImage 的 CreateDIBSection/CreateBitmap/DeleteObject

using Microsoft::WRL::ComPtr;

// ---------------------------------------------------------------------------
// 统计与日志
// ---------------------------------------------------------------------------

struct Stats {
    std::atomic<uint64_t> packets{0};
    std::atomic<uint64_t> bytes{0};
    std::atomic<uint64_t> decoded{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<uint64_t> paced{0};       // --pace 队列溢出时主动丢掉的旧帧
    std::atomic<uint64_t> decodeFail{0};
    std::atomic<uint64_t> lastLatencyUs{0};
    std::atomic<uint64_t> cursor{0};      // 收到的 0x03 光标包
    std::atomic<uint64_t> inputSent{0};   // 发出的 0x04 输入事件
};

static Stats g_stats;

// 可选抖动缓冲：默认关闭。--pace 打开后，呈现线程用一个小队列按自适应节拍上屏，
// 吸收源端偶发的双倍帧间隔；代价是增加约一帧延迟。
static std::atomic<bool>   g_paceEnabled{false};
static std::atomic<double> g_paceTargetMs{0.0};
static int g_refreshHz = 0;   // 当前显示器刷新率，用于把节拍吸附到刷新周期整数倍

// 呈现间隔采样（毫秒）：用来区分「垂直同步量化」与「跟随源帧率」。
// qsvc 下 89Hz 屏 + 53fps 源会落在 11/22ms 两档；免同步则贴近源间隔。
static std::mutex g_presentMtx;
static const int PRESENT_RING = 512;
static double g_presentIntervals[PRESENT_RING];
static int g_presentRingCount = 0;

// 亚毫秒时钟：GetTickCount64 在 Windows 上约 15.6ms 粒度，
// 会把 11/22ms 的 vsync 量化抹成 16/31ms，必须用 QPC。
static double QpcNowMs() {
    static LARGE_INTEGER freq{};
    if (!freq.QuadPart) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (double)c.QuadPart * 1000.0 / (double)freq.QuadPart;
}

static void ResetPresentRing() {
    std::lock_guard<std::mutex> lk(g_presentMtx);
    g_presentRingCount = 0;
}

// 解码到达间隔：与上屏间隔并排，用来判断抖动是源端带来的还是呈现侧引入的。
static std::mutex g_decodeMtx;
static double g_decodeIntervals[PRESENT_RING];
static int g_decodeRingCount = 0;
static double g_lastDecodeMs = 0.0;   // 仅收流线程访问

static void ResetDecodeRing() {
    std::lock_guard<std::mutex> lk(g_decodeMtx);
    g_decodeRingCount = 0;
}

static void PushDecodeInterval(double ms) {
    std::lock_guard<std::mutex> lk(g_decodeMtx);
    if (g_decodeRingCount < PRESENT_RING) g_decodeIntervals[g_decodeRingCount++] = ms;
}

static void TakeDecodeIntervals(std::vector<double>& out) {
    std::lock_guard<std::mutex> lk(g_decodeMtx);
    out.assign(g_decodeIntervals, g_decodeIntervals + g_decodeRingCount);
    g_decodeRingCount = 0;
}

static void PushPresentInterval(double ms) {
    std::lock_guard<std::mutex> lk(g_presentMtx);
    if (g_presentRingCount < PRESENT_RING) g_presentIntervals[g_presentRingCount++] = ms;
}

static void TakePresentIntervals(std::vector<double>& out) {
    std::lock_guard<std::mutex> lk(g_presentMtx);
    out.assign(g_presentIntervals, g_presentIntervals + g_presentRingCount);
    g_presentRingCount = 0;
}

static double PercentileMs(std::vector<double>& v, double p) {
    if (v.empty()) return 0.0;
    size_t k = (size_t)(p * (double)(v.size() - 1));
    std::nth_element(v.begin(), v.begin() + k, v.end());
    return v[k];
}

// 复用预分配缓冲，避免每帧分配
static char g_logBuf[1024];
static std::mutex g_logLock;
static FILE* g_logFile = nullptr;   // 可选：同时写日志文件，方便后台监控时 tail

// UTF-8 转宽字符。Log() 用它把日志经 WriteConsoleW 直写控制台，绕开代码页。
static std::wstring ToWide(const char* utf8, int bytes) {
    if (!utf8 || bytes <= 0) return {};
    int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8, bytes, nullptr, 0);
    if (len <= 0) return {};
    std::wstring out((size_t)len, L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, utf8, bytes, &out[0], len);
    return out;
}

static void Log(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::lock_guard<std::mutex> lk(g_logLock);
    int n = vsnprintf(g_logBuf, sizeof(g_logBuf) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof(g_logBuf) - 2) n = (int)sizeof(g_logBuf) - 2;
    g_logBuf[n] = '\n';

    // 控制台：用 WriteConsoleW 直写宽字符，绕开 CP936/UTF-8 代码页问题。
    // 中文 Windows 默认控制台是 GBK，直接 fwrite UTF-8 字节会显示成乱码。
    // 句柄不是真控制台（重定向到文件/管道）时回退到 fwrite。
    HANDLE hErr = GetStdHandle(STD_ERROR_HANDLE);
    DWORD mode = 0;
    bool wroteConsole = false;
    if (hErr && hErr != INVALID_HANDLE_VALUE && GetConsoleMode(hErr, &mode)) {
        std::wstring w = ToWide(g_logBuf, n + 1);
        DWORD written = 0;
        if (!w.empty() && WriteConsoleW(hErr, w.c_str(), (DWORD)w.size(), &written, nullptr))
            wroteConsole = true;
    }
    if (!wroteConsole) {
        fwrite(g_logBuf, 1, n + 1, stderr);
        fflush(stderr);
    }

    // 日志文件：始终原样写 UTF-8，遥测提取器按 UTF-8 读取，不受控制台改动影响
    if (g_logFile) {
        fwrite(g_logBuf, 1, n + 1, g_logFile);
        fflush(g_logFile);          // 立即落盘，tail 时能实时看到
    }
}

// 宽字符转 UTF-8。不要在同一输出流上混用 printf 和 wprintf，
// 那是未定义行为，MSVC 上可能崩溃或输出丢失。
static std::string ToUtf8(const wchar_t* w) {
    if (!w) return {};
    int len = ::WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string out((size_t)len - 1, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, w, -1, &out[0], len, nullptr, nullptr);
    return out;
}

// Unix 纪元微秒的本地墙钟。FILETIME 是 1601-01-01 起的 100ns 单位，
// 常量 116444736000000000 把它换算到 Unix 纪元。QPC 是开机以来的相对
// 时间，不能与 Mac 端的 Unix 纪元时间戳相减。
static int64_t UnixNowMicros() {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    const int64_t t100ns = ((int64_t)ft.dwHighDateTime << 32) | (int64_t)ft.dwLowDateTime;
    return (t100ns - 116444736000000000LL) / 10;
}

// ---------------------------------------------------------------------------
// 协议常量（必须与 Mac 端一致）
//   帧: [4 字节大端 长度][1 字节 类型][8 字节大端 采集时间戳 us][载荷]
//   长度字段 = 1 + 8 + 载荷长度（不含长度字段自身）
// ---------------------------------------------------------------------------

static const uint8_t TYPE_VIDEO = 0x01;
static const uint8_t TYPE_CURSOR = 0x03;   // 光标位置，与视频帧分离发送
static const uint8_t TYPE_CURSOR_IMAGE = 0x05;  // 真实光标图像 + 热点（BGRA）
static const uint8_t TYPE_KEYFRAME_REQUEST = 0x02;
static const size_t HEADER_BYTES = 9;   // 类型 1 + 时间戳 8
static const size_t MAX_PACKET = 64u * 1024u * 1024u;

// ---------------------------------------------------------------------------
// 光标
//
// 视频只有 40fps 左右，把指针画进画面会让它每 25ms 才动一次，看起来是拖影。
// 发送端改成不带指针出视频，指针位置用独立小包高频送来，这里直接移动系统光标。
// Windows 的光标由硬件合成，延迟接近零。
// ---------------------------------------------------------------------------

// 坐标基准 = Mac 虚拟屏 CGDisplayBounds 的尺寸（e153f2c 起默认对齐物理，
// 随档位变化，如 2880x1800 / 2240x1400）。光标显示和输入回传都以它为准。
// 解码/呈现/全屏窗口用 cfg.width/height（物理像素），两者一致时不冲突。
static std::atomic<int> g_coordW{0};
static std::atomic<int> g_coordH{0};
static std::atomic<double> g_cursorX{-1};
static std::atomic<double> g_cursorY{-1};
// 程序自己调用 SetCursorPos 会引起 WM_MOUSEMOVE；用时间戳把它和用户真实
// 输入区分开，否则每次跟随都会被当成「用户动了」，导致门控反复自锁。
static std::atomic<int64_t> g_lastRemoteCursorMoveMs{ 0 };

// 真实 Mac 光标图像（0x05）。网络线程只把收到的 BGRA 存进缓冲并 post 消息，
// HCURSOR 的创建/替换/销毁统一在 UI 线程做，避免跨线程句柄竞态。
static const UINT WM_APPLY_CURSOR = WM_APP + 2;
// 0x03 远程光标位置：网络线程 post，UI 线程做门控与 SetCursorPos
static const UINT WM_APP_REMOTE_CURSOR = WM_APP + 3;
struct CursorImageBuf {
    std::mutex mtx;
    std::vector<uint8_t> bgra;
    int w = 0, h = 0, hotX = 0, hotY = 0;
    bool pending = false;
};
static CursorImageBuf g_cursorImage;
static HCURSOR g_customCursor = nullptr;   // 仅 UI 线程访问

// 输入回传：把窗口内的鼠标位置和按键状态发给 Mac，由它重放事件。
// 不再用 SetCursorPos 搬本机光标——那会和用户自己的鼠标抢位置，
// 表现就是「点这里，菜单出现在别处」。
static std::atomic<SOCKET> g_sock{ INVALID_SOCKET };
static std::atomic<uint8_t> g_buttons{ 0 };
static std::atomic<int64_t> g_lastLocalInputMs{ 0 };

// 鼠标移动节流：WM_MOUSEMOVE 频率可达每秒数百上千次，逐包发给 Mac 会让
// 对端 CGEvent.mouseMoved 队列堆积，体感「鼠标延迟极高」。UI 线程只记最新位置，
// 由独立 inputThread 每 8ms（约 120Hz，与 Mac 侧 0x03 采样同频）合并发送。
// 按键/滚轮标记 eventPending，inputThread 下一轮（约 4ms 内）立即发，保证点击及时。
// 用独立线程而非 WM_TIMER：WM_TIMER 是低优先级，消息队列不空时长期不触发，节奏不稳。
static std::atomic<bool> g_moveDirty{ false };
static std::atomic<float> g_moveX{ 0.0f };
static std::atomic<float> g_moveY{ 0.0f };
static std::atomic<bool> g_eventPending{ false };
static std::atomic<int16_t> g_pendingWheel{ 0 };
static const uint64_t INPUT_MOVE_INTERVAL_MS = 8;   // 约 120Hz
static const uint64_t INPUT_TICK_MS           = 4;   // 线程轮询粒度

static void SendInputPacket(float vx, float vy, uint8_t buttons, int16_t wheel) {
    SOCKET s = g_sock.load();
    if (s == INVALID_SOCKET) return;

    uint8_t pkt[12];
    pkt[0] = 0x04;
    auto wrF = [](uint8_t* q, float f) {
        uint32_t u; memcpy(&u, &f, 4);
        q[0] = (uint8_t)(u >> 24); q[1] = (uint8_t)(u >> 16);
        q[2] = (uint8_t)(u >> 8);  q[3] = (uint8_t)u;
    };
    wrF(pkt + 1, vx);
    wrF(pkt + 5, vy);
    pkt[9] = buttons;
    pkt[10] = (uint8_t)((uint16_t)wheel >> 8);
    pkt[11] = (uint8_t)((uint16_t)wheel & 0xFF);
    send(s, (const char*)pkt, 12, 0);
    g_stats.inputSent++;
}

static HWND g_hwnd = nullptr;   // 主窗口句柄，ClientToVideo 与全屏切换共用

// 全局存活标志。放在靠前位置，因为 RecvAll 等底层函数也要读它来判断退出。
// false 时所有后台线程（收流/光标/监控）应尽快结束。
static std::atomic<bool> g_alive{ true };

// ---------------------------------------------------------------------------
// 系统托盘：全屏置顶无边框窗口没有关闭按钮，唯一退出口是 Esc。
// 加一个托盘小图标，让「退出」永远点得到，不用盲敲命令。
//   - 左键单击托盘图标 = 直接退出
//   - 右键 = 菜单（退出 / 全屏·窗口切换 / 关于）
//   - 全局热键 Ctrl+Alt+Q = 兜底强退（连托盘都被盖住时）
// ---------------------------------------------------------------------------
static const UINT WM_TRAY      = WM_USER + 1;   // Shell_NotifyIcon 回调消息
static const UINT ID_TRAY_EXIT = 1001;
static const UINT ID_TRAY_TOGGLE = 1002;
static const UINT ID_TRAY_ABOUT  = 1003;
static const UINT ID_TRAY_MINIMIZE = 1004;
static const int  HOTKEY_QUIT_ID = 1;
static const int  HOTKEY_HIDE_ID = 2;   // Ctrl+Alt+H：最小化让位/还原，不退出
// 用 W 版托盘结构与宽字符提示：A 版在 CP936 下会把 UTF-8 中文按 GBK 解码，
// 托盘悬浮提示会变乱码。窗口类本身仍是 A 版注册（类名纯 ASCII），不受影响。
static NOTIFYICONDATAW g_nid{};
static bool g_trayAdded = false;

static void RequestQuit() {
    // g_alive 由主循环收尾时统一置 false（见消息循环后），这里不碰它：
    // 该变量在文件后段才定义，提前引用会编译失败。
    // WM_CLOSE -> WndProc 的 PostQuitMessage 会让 GetMessage 返回 0，正常收尾。
    if (g_hwnd) PostMessageA(g_hwnd, WM_CLOSE, 0, 0);
}

// 一键让位：把窗口最小化/还原，用户随时能回到 Windows 桌面而不必退出程序。
// 不碰 g_alive、不 PostQuitMessage，网络与解码线程照常运行，回来即恢复画面。
static void ToggleMinimize() {
    if (!g_hwnd) return;
    if (IsIconic(g_hwnd)) {
        ShowWindow(g_hwnd, SW_RESTORE);
        SetForegroundWindow(g_hwnd);
        Log("已从托盘还原窗口");
    } else {
        ShowWindow(g_hwnd, SW_MINIMIZE);
        Log("已最小化让位，按 Ctrl+Alt+H 或点托盘还原");
    }
}

static void TrayCreate(HWND hwnd) {
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = hwnd;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    // 系统自带应用图标，省去资源文件。图标是数字资源 ID，A/W 版等价、无文本编码问题
    g_nid.hIcon = LoadIconA(nullptr, IDI_APPLICATION);
    // 宽字符悬浮提示：A 版在 CP936 下会把 UTF-8 中文按 GBK 解码成乱码。
    // lstrcpynW 来自 windows.h，保证按缓冲区截断并以 L'\0' 结尾，
    // MinGW / MSVC 都可用，不用 strcpy_s 这类 MSVC 扩展。
    lstrcpynW(g_nid.szTip,
              L"SecDisplay - 左键退出 / 右键菜单 / Ctrl+Alt+Q 强退",
              (int)(sizeof(g_nid.szTip) / sizeof(g_nid.szTip[0])));
    g_trayAdded = Shell_NotifyIconW(NIM_ADD, &g_nid) == TRUE;
    if (!g_trayAdded) Log("托盘图标添加失败（不影响 Esc / 热键退出）");
}

static void TrayRemove() {
    if (g_trayAdded) {
        Shell_NotifyIconW(NIM_DELETE, &g_nid);
        g_trayAdded = false;
    }
}

static void TrayShowMenu(HWND hwnd) {
    POINT pt{};
    GetCursorPos(&pt);
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    // W 版菜单 + 宽字符：绕开 CP936 对 UTF-8 中文的 GBK 误解码
    AppendMenuW(menu, MF_STRING, ID_TRAY_TOGGLE, L"切换全屏 / 窗口  (F11)");
    AppendMenuW(menu, MF_STRING, ID_TRAY_MINIMIZE, L"最小化让位 / 还原  (Ctrl+Alt+H)");
    AppendMenuW(menu, MF_STRING, ID_TRAY_ABOUT,  L"关于 SecDisplay");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | MF_DEFAULT, ID_TRAY_EXIT, L"退出 SecDisplay");
    // 前置，否则菜单可能被置顶窗口盖住
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                   pt.x, pt.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
}

/// 窗口客户区坐标 → 虚拟屏逻辑点坐标（0..coordW, 0..coordH）
static bool ClientToVideo(int cx, int cy, float* vx, float* vy) {
    if (!g_hwnd) return false;
    RECT rc{};
    if (!GetClientRect(g_hwnd, &rc)) return false;
    int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
    int vw = g_coordW.load(), vh = g_coordH.load();
    if (cw <= 0 || ch <= 0 || vw <= 0 || vh <= 0) return false;
    *vx = (float)cx / cw * vw;
    *vy = (float)cy / ch * vh;
    return true;
}

static void OnCursorPacket(const uint8_t* p, size_t payloadLen) {
    if (payloadLen < 9) return;
    // 大端读 4 字节再按位解释成 float
    auto rdFloat = [](const uint8_t* q) -> float {
        uint32_t u = ((uint32_t)q[0] << 24) | ((uint32_t)q[1] << 16)
                   | ((uint32_t)q[2] << 8) | (uint32_t)q[3];
        float f; memcpy(&f, &u, sizeof(f)); return f;
    };
    float rx = rdFloat(p);
    float ry = rdFloat(p + 4);
    uint8_t visible = p[8];
    if (!visible) {
        // 光标离开副屏：清空坐标。留着旧值会让 UI 线程把系统光标拽回
        // 上一次的位置，这正是「鼠标被反复重置」的来源。
        g_cursorX = -1;
        g_cursorY = -1;
        return;
    }

    double oldX = g_cursorX.load(), oldY = g_cursorY.load();
    g_cursorX = rx;
    g_cursorY = ry;
    // 只在位置真的变化时通知 UI。Mac 端静止不发包，这里再挡一层，
    // 避免重复 SetCursorPos。
    if (rx == oldX && ry == oldY) return;
    if (g_hwnd) PostMessageA(g_hwnd, WM_APP_REMOTE_CURSOR, 0, 0);
}

// 0x05 真实光标图像。载荷(全大端):
//   [u16 w][u16 h][u16 hotX][u16 hotY][u32 nBytes][BGRA 像素...]
// 网络线程只存缓冲并 post 消息，HCURSOR 创建在 UI 线程做，避免句柄竞态。
static void OnCursorImagePacket(const uint8_t* p, size_t payloadLen) {
    if (payloadLen < 12) return;
    auto rd16 = [](const uint8_t* q) -> uint16_t {
        return (uint16_t)((q[0] << 8) | q[1]);
    };
    auto rd32 = [](const uint8_t* q) -> uint32_t {
        return ((uint32_t)q[0] << 24) | ((uint32_t)q[1] << 16)
             | ((uint32_t)q[2] << 8) | (uint32_t)q[3];
    };
    int w = rd16(p), h = rd16(p + 2);
    int hotX = rd16(p + 4), hotY = rd16(p + 6);
    uint32_t nBytes = rd32(p + 8);
    if (w <= 0 || h <= 0 || w > 128 || h > 128) return;
    if (nBytes != (uint32_t)(w * h * 4) || payloadLen < 12 + nBytes) return;

    {
        std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
        g_cursorImage.w = w; g_cursorImage.h = h;
        g_cursorImage.hotX = hotX; g_cursorImage.hotY = hotY;
        g_cursorImage.bgra.assign(p + 12, p + 12 + nBytes);
        g_cursorImage.pending = true;
    }
    if (g_hwnd) PostMessageA(g_hwnd, WM_APPLY_CURSOR, 0, 0);
}

// ---------------------------------------------------------------------------
// 网络
// ---------------------------------------------------------------------------

static bool RecvAll(SOCKET s, void* buf, int len) {
    char* p = (char*)buf;
    while (len > 0) {
        int n = recv(s, p, len, 0);
        if (n > 0) { p += n; len -= n; continue; }
        if (n == 0) return false;               // 对端关闭
        // n < 0：区分「超时」与「真错误」。SO_RCVTIMEO 让 recv 每 500ms
        // 醒一次，超时时若 g_alive 仍为 true 就继续等（保活间隔约 80ms，
        // 正常收流不会真的超时）；g_alive=false 时立刻返回，让线程退出。
        int err = WSAGetLastError();
        if (err == WSAETIMEDOUT) {
            if (!g_alive.load()) return false; // 退出信号：结束收流
            continue;                          // 只是超时，继续等下一批数据
        }
        if (err == WSAEINTR) continue;
        return false;                          // 其它错误：连接断了
    }
    return true;
}

// Mac 端时间戳是 CFAbsoluteTime 纪元（2001-01-01）的微秒。
//
// 两台机器的时钟没有同步，所以不能直接相减得到"端到端延迟"。
// 能可靠测的是「排队延迟」：把 (本地接收时刻 - 远端发送时刻) 减去一个窗口内的
// 最小值，得到的就是相对于最快那一帧多出来的等待时间。
// 这个值恒 >= 0，且不随两端时钟漂移而失真（窗口每 3 秒重算一次）。
//
// 之前用首帧建立固定偏移，导致差值恒为负、被钳到 0，日志一直是 0.0 ms。

static int64_t g_winMinDeltaUs = 0;
static int64_t g_winStartUs = 0;

static void ResetTimestampBase() {
    g_winMinDeltaUs = 0;
    g_winStartUs = 0;
}

/// 返回相对于窗口内最快帧的附加延迟（微秒）。明显无效的时间戳返回 -1。
static int64_t EstimateExtraDelayUs(uint64_t macMicros) {
    // Mac 发的是 CFAbsoluteTime 纪元(2001-01-01)微秒，不是 Unix 纪元。
    // 旧代码把 macMicros 当 Unix 微秒、又减去 978307200e6，导致守卫
    // (macMicros < 9.78e14) 对当前约 8.15e14 的值恒成立，直接 return -1，
    // 日志「附加延迟」永远是 0.0 ms。
    // 这里把本地 now 也换算到 CFAbsoluteTime 基准，两边同基准直接相减。
    const int64_t kAppleEpochOffsetUs = 978307200LL * 1000000LL;
    // 只拦截明显无效的输入（为 0 或量级异常），避免无符号下溢
    if (macMicros < 1000000ULL) return -1;
    const int64_t macAppleUs = (int64_t)macMicros;
    const int64_t now = UnixNowMicros() - kAppleEpochOffsetUs;
    const int64_t delta = now - macAppleUs;

    const int64_t WINDOW_US = 3'000'000;         // 3 秒窗口
    if (g_winStartUs == 0 || now - g_winStartUs > WINDOW_US) {
        g_winStartUs = now;
        g_winMinDeltaUs = delta;
    } else if (delta < g_winMinDeltaUs) {
        g_winMinDeltaUs = delta;
    }
    if (delta >= g_winMinDeltaUs) return delta - g_winMinDeltaUs;
    return 0;
}

// ---------------------------------------------------------------------------
// 码流工具：AVCC -> Annex-B
//
// AVCC 是 [4 字节大端长度][NAL] 重复。转 Annex-B 只需把每个长度前缀换成
// 00 00 00 01。按长度前缀切分是可靠的，不要去扫描码流内部找起始码
//（H.264 数据里天然会出现 00 00 00 01）。
// ---------------------------------------------------------------------------

static bool AvccToAnnexB(const uint8_t* data, size_t len, std::vector<uint8_t>& out) {
    out.clear();
    out.reserve(len + 64);
    size_t i = 0;
    while (i + 4 <= len) {
        uint32_t n = ((uint32_t)data[i] << 24) | ((uint32_t)data[i + 1] << 16)
                   | ((uint32_t)data[i + 2] << 8) | (uint32_t)data[i + 3];
        i += 4;
        if (n == 0 || i + n > len) return false;
        out.push_back(0); out.push_back(0); out.push_back(0); out.push_back(1);
        out.insert(out.end(), data + i, data + i + n);
        i += n;
    }
    return !out.empty();
}

/// 从 AVCC 里取出 SPS(7) 与 PPS(8)
static bool ExtractParamSets(const uint8_t* data, size_t len,
                             std::vector<uint8_t>& sps, std::vector<uint8_t>& pps) {
    sps.clear(); pps.clear();
    size_t i = 0;
    while (i + 4 <= len) {
        uint32_t n = ((uint32_t)data[i] << 24) | ((uint32_t)data[i + 1] << 16)
                   | ((uint32_t)data[i + 2] << 8) | (uint32_t)data[i + 3];
        i += 4;
        if (n == 0 || i + n > len) break;
        uint8_t type = data[i] & 0x1F;
        if (type == 7) sps.assign(data + i, data + i + n);
        else if (type == 8) pps.assign(data + i, data + i + n);
        i += n;
    }
    return !sps.empty() && !pps.empty();
}

// ---------------------------------------------------------------------------
// D3D11 设备（解码与呈现共用同一台，才能零拷贝）
// ---------------------------------------------------------------------------

class Graphics {
public:
    bool Init(int width, int height);
    void Shutdown();

    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IMFDXGIDeviceManager> deviceManager;
    UINT resetToken = 0;

private:
    bool CreateDevice();
};

// 这台机器上常驻多个显示适配器：真实核显、远程控制的虚拟屏、其他投屏软件的虚拟屏。
// 直接传 nullptr 让系统挑，选中的未必是真显卡。这里显式枚举，
// 优先选带 VIDEO_SUPPORT 能力、且不是软件/虚拟适配器的那个。
bool Graphics::CreateDevice() {
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;

    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
        Log("CreateDXGIFactory1 失败");
        return false;
    }

    HRESULT hr = E_FAIL;
    ComPtr<IDXGIAdapter1> chosen;

    for (UINT i = 0; ; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;

        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;

        wchar_t nameW[128] = {};
        wcsncpy_s(nameW, desc.Description, _TRUNCATE);

        ComPtr<ID3D11Device> trial;
        HRESULT r = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                      flags, levels, ARRAYSIZE(levels),
                                      D3D11_SDK_VERSION, &trial, nullptr, nullptr);
        if (FAILED(r)) {
            Log("  跳过显示适配器（无法创建设备）: %s", ToUtf8(nameW).c_str());
            continue;
        }

        // 虚拟显示器适配器通常能创建设备，但没有视频解码能力。
        // 必须验证它真的支持 H.264 硬解，否则选了也白选。
        ComPtr<ID3D11VideoDevice> vd;
        if (FAILED(trial.As(&vd)) || vd->GetVideoDecoderProfileCount() == 0) {
            Log("  跳过显示适配器（无视频解码能力）: %s", ToUtf8(nameW).c_str());
            continue;
        }

        device = trial;
        trial->GetImmediateContext(&context);
        Log("  选用显示适配器: %s（%u 个解码 profile）",
            ToUtf8(nameW).c_str(), vd->GetVideoDecoderProfileCount());
        chosen = adapter;
        hr = S_OK;
        break;
    }

    if (FAILED(hr) || !device) {
        // 兜底：枚举失败时退回系统默认
        Log("枚举适配器未成功，退回系统默认设备");
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                               levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                               &device, nullptr, &context);
    }
    if (FAILED(hr) || !device) { Log("D3D11CreateDevice 失败 %08X", hr); return false; }

    // 多线程保护：解码线程与呈现线程共享同一台设备。
    // 注意 SetMultithreadProtected 返回的是「调用前是否已开启」，FALSE 只表示之前没开、
    // 本次已成功开启，不能当失败。真实状态要用 GetMultithreadProtected() 回读。
    ComPtr<ID3D11Multithread> mt;
    if (SUCCEEDED(device.As(&mt)) && mt) {
        mt->SetMultithreadProtected(TRUE);
        if (!mt->GetMultithreadProtected()) {
            Log("警告: 多线程保护未能启用，共享设备可能有竞争");
        } else {
            Log("多线程保护已启用");
        }
    }
    return true;
}

bool Graphics::Init(int, int) {
    if (!CreateDevice()) return false;

    // 为硬件解码创建 D3D 管理器并绑定同一台设备。
    // 不做这一步，硬件 MFT 只会吐系统内存，零拷贝路径不成立。
    HRESULT hr = MFCreateDXGIDeviceManager(&resetToken, &deviceManager);
    if (FAILED(hr)) { Log("MFCreateDXGIDeviceManager 失败 %08X", hr); return false; }
    hr = deviceManager->ResetDevice(device.Get(), resetToken);
    if (FAILED(hr)) { Log("ResetDevice 失败 %08X", hr); return false; }

    Log("D3D11 设备就绪（已绑定 MF 硬件解码管理器）");
    return true;
}

void Graphics::Shutdown() {
    deviceManager.Reset();
    context.Reset();
    device.Reset();
}

// ---------------------------------------------------------------------------
// 解码器
// ---------------------------------------------------------------------------

class Decoder {
public:
    bool Init(Graphics* gfx, int width, int height);
    bool Decode(const uint8_t* avcc, size_t len, IMFSample** outSample);
    void Shutdown();

    // 解码器实际给出的输出尺寸。硬解要求表面按编码尺寸对齐（1800 -> 1808），
    // 所以它可能比请求的大，呈现端要按这个尺寸建输入视图再裁边。
    int outWidth() const { return outWidth_ > 0 ? outWidth_ : width_; }
    int outHeight() const { return outHeight_ > 0 ? outHeight_ : height_; }

private:
    bool SetInputTypeFromParamSets(const std::vector<uint8_t>& sps,
                                   const std::vector<uint8_t>& pps);
    bool SetOutputTypeD3D();
    bool DrainOutput(IMFSample** outSample);
    MFT_OUTPUT_STREAM_INFO GetOutInfo();

    Graphics* gfx_ = nullptr;
    ComPtr<IMFTransform> transform_;
    std::vector<uint8_t> paramSets_;
    std::vector<uint8_t> paramSetsCache_;   // 当前已生效的 SPS+PPS，用于判断是否需要重设
    std::vector<uint8_t> annexB_;
    LONGLONG sampleTime_ = 0;
    int width_ = 0, height_ = 0;
    DWORD outId_ = 0;
    bool ready_ = false;
    bool inputTypeSet_ = false;      // 输入类型没设就谈输出类型只会拿到 MF_E_TRANSFORM_TYPE_NOT_SET
    int outWidth_ = 0, outHeight_ = 0;   // 解码器实际输出尺寸
    ComPtr<IMFVideoSampleAllocatorEx> allocator_;
    bool allocatorReady_ = false;
};

bool Decoder::Init(Graphics* gfx, int width, int height) {
    gfx_ = gfx;
    width_ = width;
    height_ = height;

    MFT_REGISTER_TYPE_INFO inInfo{ MFMediaType_Video, MFVideoFormat_H264 };
    IMFActivate** acts = nullptr;
    UINT32 count = 0;

    // 枚举 H.264 解码器。
    //
    // 关键认知：Windows 的硬解并不是注册成 "hardware MFT"。
    // 微软自带的 MSH264DecoderMFT（msmpeg2vdec.dll）注册为同步 MFT，
    // 只有在收到 MFT_MESSAGE_SET_D3D_MANAGER 且输入输出类型匹配时，
    // 才在内部走 DXVA 硬件加速。
    // 用 MFT_ENUM_FLAG_HARDWARE 单独枚举，反而会把真正能硬解的这个 MFT 过滤掉，
    // 表现就是"找不到硬解"，白白退回慢路径。
    //
    // 所以这里放宽枚举范围，拿全之后再逐个判断-谁接受 D3D 管理器。
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                           MFT_ENUM_FLAG_SYNCMFT |
                           MFT_ENUM_FLAG_ASYNCMFT |
                           MFT_ENUM_FLAG_HARDWARE |
                           MFT_ENUM_FLAG_SORTANDFILTER,
                           &inInfo, nullptr, &acts, &count);
    if (FAILED(hr) || count == 0) {
        // 兜底：不带 SORTANDFILTER 再试一次
        hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                       MFT_ENUM_FLAG_ALL,
                       &inInfo, nullptr, &acts, &count);
    }
    if (FAILED(hr) || count == 0) { Log("MFTEnumEx 失败 %08X", hr); return false; }

    // 打印候选清单，便于排查选错的情况
    Log("找到 %u 个 H.264 解码器候选", count);
    for (UINT32 i = 0; i < count; ++i) {
        LPWSTR name = nullptr;
        UINT32 len = 0;
        if (SUCCEEDED(acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &len))) {
            UINT32 d3dAware = 0;
            acts[i]->GetUINT32(MF_SA_D3D_AWARE, &d3dAware);
            Log("         [%u] %s%s", i, ToUtf8(name).c_str(), d3dAware ? "  (支持 D3D)" : "");
            CoTaskMemFree(name);
        }
    }

    // 依次尝试候选，直到找到接受 D3D 管理器的那个。
    // 只按属性声明去猜不可靠，直接试才是准的。
    bool hardware = false;
    ComPtr<IMFTransform> fallback;   // 第一个能激活但拒绝 D3D 的候选，留作软件兜底

    for (UINT32 i = 0; i < count && !transform_; ++i) {
        ComPtr<IMFTransform> candidate;
        if (FAILED(acts[i]->ActivateObject(IID_PPV_ARGS(&candidate))) || !candidate) continue;

        // 低延迟：不缓冲、不解码后攒帧
        ComPtr<IMFAttributes> a;
        if (SUCCEEDED(candidate->GetAttributes(&a)) && a) {
            // 异步 MFT 不解除锁定，ProcessInput/ProcessOutput 不工作，表现为永远无输出
            a->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
            a->SetUINT32(MF_LOW_LATENCY, TRUE);
        }

        // 试着注入 D3D 管理器，成功即走 DXVA 硬解
        bool accepted = false;
        if (gfx_ && gfx_->deviceManager) {
            HRESULT dr = candidate->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                                   (ULONG_PTR)gfx_->deviceManager.Get());
            accepted = SUCCEEDED(dr);
        }

        if (accepted) {
            transform_ = candidate;
            hardware = true;
            Log("候选 [%u] 接受 D3D 管理器，启用 DXVA 硬件解码", i);
        } else if (!fallback) {
            fallback = candidate;
        }
    }

    // 没有任何候选接受 D3D，退回记录的第一个（软件解码）
    if (!transform_ && fallback) {
        transform_ = fallback;
        Log("没有解码器接受 D3D 管理器，退回软件解码（性能受限）");
    }

    for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
    CoTaskMemFree(acts);
    if (!transform_) { Log("没有可用的解码器"); return false; }

    DWORD inId = 0, outId = 0;
    transform_->GetStreamIDs(1, &inId, 1, &outId);
    outId_ = outId;

    // 注意：这里绝对不能发 MFT_MESSAGE_NOTIFY_BEGIN_STREAMING。
    // 此刻输入/输出类型都还没设，msmpeg2vdec.dll 不返回错误，而是直接访问违例崩溃。
    // 开始流消息统一挪到输出类型设好之后（见 Decode）。

    Log("解码器就绪 %dx%d（%s）", width, height, hardware ? "硬件" : "软件");
    return true;
}

bool Decoder::SetInputTypeFromParamSets(const std::vector<uint8_t>& sps,
                                        const std::vector<uint8_t>& pps) {
    // MF 的 H.264 输入要 Annex-B 形式的 SPS/PPS 拼在序列头里
    std::vector<uint8_t> seq;
    auto push = [&](const std::vector<uint8_t>& n) {
        seq.push_back(0); seq.push_back(0); seq.push_back(0); seq.push_back(1);
        seq.insert(seq.end(), n.begin(), n.end());
    };
    push(sps);
    push(pps);

    ComPtr<IMFMediaType> in;
    HRESULT hr = MFCreateMediaType(&in);
    if (FAILED(hr)) return false;
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    MFSetAttributeSize(in.Get(), MF_MT_FRAME_SIZE, width_, height_);
    in->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    in->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
    in->SetBlob(MF_MT_MPEG_SEQUENCE_HEADER, seq.data(), (UINT32)seq.size());

    hr = transform_->SetInputType(0, in.Get(), 0);
    if (FAILED(hr)) {
        Log("SetInputType 失败 %08X", hr);
        return false;
    }
    paramSets_ = seq;
    inputTypeSet_ = true;
    Log("已注入 SPS(%zu) PPS(%zu)", sps.size(), pps.size());
    return true;
}

bool Decoder::SetOutputTypeD3D() {
    // 输入类型还没设就调这里，解码器只会回 MF_E_TRANSFORM_TYPE_NOT_SET（C00D6D60）
    if (!inputTypeSet_) {
        static bool told = false;
        if (!told) { told = true; Log("等 SPS/PPS 到了再协商输出类型"); }
        return false;
    }

    ComPtr<IMFMediaType> out;
    HRESULT hr = MFCreateMediaType(&out);
    if (FAILED(hr)) return false;
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(out.Get(), MF_MT_FRAME_SIZE, width_, height_);
    out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

    hr = transform_->SetOutputType(0, out.Get(), 0);
    if (FAILED(hr)) {
        // 硬解要求输出表面按编码尺寸对齐：1800 不是 16 的倍数，实际得给 1808，
        // 直接要 1800 会被判 MF_E_INVALIDMEDIATYPE（C00D36B4）。
        // 与其猜尺寸，不如直接问解码器它接受哪些 NV12 类型。
        Log("按 %dx%d 设输出类型失败 %08X，改向解码器查询可用类型", width_, height_, hr);
        ComPtr<IMFMediaType> picked;
        for (DWORD i = 0; i < 32; ++i) {
            ComPtr<IMFMediaType> avail;
            HRESULT ar = transform_->GetOutputAvailableType(0, i, &avail);
            if (ar == MF_E_NO_MORE_TYPES) break;
            if (FAILED(ar)) { Log("GetOutputAvailableType(%u) 失败 %08X", i, ar); break; }
            GUID sub{};
            avail->GetGUID(MF_MT_SUBTYPE, &sub);
            UINT32 w = 0, h = 0;
            MFGetAttributeSize(avail.Get(), MF_MT_FRAME_SIZE, &w, &h);
            Log("  可用输出[%u] 子类型 %08X 尺寸 %ux%u", i, (unsigned)sub.Data1, w, h);
            if (sub != MFVideoFormat_NV12) continue;
            bool exact = (w == (UINT32)width_ && h == (UINT32)height_);
            if (!picked || exact) picked = avail;
            if (exact) break;
        }
        if (!picked) { Log("解码器没有可用的 NV12 输出类型"); return false; }
        UINT32 w = 0, h = 0;
        MFGetAttributeSize(picked.Get(), MF_MT_FRAME_SIZE, &w, &h);
        hr = transform_->SetOutputType(0, picked.Get(), 0);
        if (FAILED(hr)) { Log("按 %ux%u 设输出类型仍失败 %08X", w, h, hr); return false; }
        if (w != (UINT32)width_ || h != (UINT32)height_) {
            Log("解码器按 %ux%u 输出（比请求的 %dx%d 高），呈现时裁掉多余行",
                w, h, width_, height_);
        }
    }

    // 记录实际输出尺寸，呈现端要按这个尺寸建输入视图
    ComPtr<IMFMediaType> cur;
    if (SUCCEEDED(transform_->GetOutputCurrentType(0, &cur)) && cur) {
        UINT32 w = 0, h = 0;
        if (SUCCEEDED(MFGetAttributeSize(cur.Get(), MF_MT_FRAME_SIZE, &w, &h))) {
            outWidth_ = (int)w;
            outHeight_ = (int)h;
        }
    }

    // 输出类型变了，样本分配器需要按新类型重建
    allocator_.Reset();
    allocatorReady_ = false;
    ready_ = true;
    return true;
}

MFT_OUTPUT_STREAM_INFO Decoder::GetOutInfo() {
    MFT_OUTPUT_STREAM_INFO info{};
    transform_->GetOutputStreamInfo(0, &info);
    return info;
}

bool Decoder::DrainOutput(IMFSample** outSample) {
    *outSample = nullptr;
    MFT_OUTPUT_STREAM_INFO info = GetOutInfo();
    bool provideSample = !(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES);

    MFT_OUTPUT_DATA_BUFFER buffer{};
    buffer.dwStreamID = outId_;

    ComPtr<IMFSample> ourSample;
    if (provideSample) {
        // 软件解码器要求调用方提供输出缓冲。必须用能提供 2D 布局
        //（IMF2DBuffer）的缓冲，否则呈现端拿不到行跨度，无法上传纹理。
        if (!allocator_) {
            HRESULT ar = MFCreateVideoSampleAllocatorEx(IID_PPV_ARGS(&allocator_));
            if (FAILED(ar)) { Log("创建样本分配器失败 %08X", ar); return false; }
            // 注：IMFVideoSampleAllocatorEx 没有 GetAttributes 方法（它只继承
            // IMFVideoSampleAllocator，不含 IMFAttributes），所以无法在对象上设属性。
            // 「预分配、避免每帧分配」由下面 InitializeSampleAllocatorEx 的
            // cInitialSamples / cMaximumSamples 两个参数完成。
        }
        if (!allocatorReady_) {
            ComPtr<IMFMediaType> ot;
            if (SUCCEEDED(transform_->GetOutputCurrentType(0, &ot)) && ot) {
                if (FAILED(allocator_->InitializeSampleAllocatorEx(2, 4, nullptr, ot.Get()))) {
                    Log("初始化样本分配器失败");
                    return false;
                }
                allocatorReady_ = true;
            }
        }
        if (!allocatorReady_) return false;
        if (FAILED(allocator_->AllocateSample(&ourSample))) return false;
        buffer.pSample = ourSample.Get();
    }

    DWORD status = 0;
    HRESULT hr = transform_->ProcessOutput(0, 1, &buffer, &status);

    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        // 解码器要求重设输出类型。常见于收到首个 SPS 之后。
        if (buffer.pSample && provideSample == false) buffer.pSample->Release();
        if (status & MFT_OUTPUT_DATA_BUFFER_FORMAT_CHANGE) {
            if (!SetOutputTypeD3D()) return false;
            Log("输出类型已重建，继续解码");
        }
        return false;
    }
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        if (buffer.pSample && buffer.pSample != ourSample.Get()) buffer.pSample->Release();
        return false;
    }
    if (FAILED(hr)) {
        if (buffer.pSample && buffer.pSample != ourSample.Get()) buffer.pSample->Release();
        return false;
    }

    if (buffer.pSample) {
        if (buffer.pSample != ourSample.Get()) {
            *outSample = buffer.pSample;   // 解码器自己给的样本，调用方负责 Release
        } else {
            ourSample.Detach();
            *outSample = buffer.pSample;
        }
    }
    if (buffer.pEvents) buffer.pEvents->Release();
    return *outSample != nullptr;
}

bool Decoder::Decode(const uint8_t* avcc, size_t len, IMFSample** outSample) {
    *outSample = nullptr;
    if (!transform_) return false;

    // 收到带参数集的关键帧就刷新输入类型
    std::vector<uint8_t> sps, pps;
    if (ExtractParamSets(avcc, len, sps, pps)) {
        std::vector<uint8_t> merged;
        merged.insert(merged.end(), sps.begin(), sps.end());
        merged.insert(merged.end(), pps.begin(), pps.end());
        if (merged != paramSetsCache_) {
            if (SetInputTypeFromParamSets(sps, pps)) {
                paramSetsCache_ = merged;
                transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
                ready_ = false;
            }
        }
    }
    if (!ready_) {
        if (!SetOutputTypeD3D()) return false;
        // 输入类型 + 输出类型都设好之后，才能通知解码器开始流。
        // 顺序颠倒（先 BEGIN_STREAMING 再设类型）会让 msmpeg2vdec 直接访问违例。
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    }

    // AVCC -> Annex-B
    if (!AvccToAnnexB(avcc, len, annexB_)) return false;

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateMemoryBuffer((DWORD)annexB_.size(), &buffer))) return false;
    BYTE* dst = nullptr;
    if (FAILED(buffer->Lock(&dst, nullptr, nullptr))) return false;
    memcpy(dst, annexB_.data(), annexB_.size());
    buffer->Unlock();
    buffer->SetCurrentLength((DWORD)annexB_.size());

    ComPtr<IMFSample> sample;
    if (FAILED(MFCreateSample(&sample))) return false;
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(sampleTime_);
    sample->SetSampleDuration(166666);
    sampleTime_ += 166666;

    // 解码器可能攒着上一帧的输出（MF_E_NOTACCEPTING）。这里先把旧输出抽出来，
    // 再送新帧。中间产生的样本统一在函数末尾处置，避免覆盖 *outSample 造成泄漏。
    IMFSample* pending = nullptr;

    HRESULT hr = transform_->ProcessInput(0, sample.Get(), 0);
    if (hr == MF_E_NOTACCEPTING) {
        DrainOutput(&pending);              // 返回 false 时 pending 仍可能非空
        hr = transform_->ProcessInput(0, sample.Get(), 0);
    }

    if (FAILED(hr)) {
        g_stats.decodeFail++;
        // 送不进去，但手上可能已有解好的帧，交给调用方，别丢
        *outSample = pending;
        return pending != nullptr;
    }

    IMFSample* out = nullptr;
    if (DrainOutput(&out) && out) {
        if (pending) pending->Release();
        *outSample = out;
        return true;
    }

    *outSample = pending;
    return pending != nullptr;
}

void Decoder::Shutdown() {
    if (transform_) {
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        transform_.Reset();
    }
}

// ---------------------------------------------------------------------------
// 呈现
// ---------------------------------------------------------------------------

class Presenter {
public:
    bool Init(Graphics* gfx, HWND hwnd, int width, int height);
    void PresentSample(IMFSample* sample);
    void Shutdown();
    bool tearingSupported() const { return tearing_; }
    void setUseVsync(bool v) { useVsync_ = v; }

    // 解码器实际输出尺寸可能与显示尺寸不同（硬解按宏块对齐，1800 -> 1808）。
    // 变了就重建视频处理器，并按显示尺寸裁边。
    bool SetSourceSize(int w, int h);

private:
    bool CreateProcessor();

    Graphics* gfx_ = nullptr;
    ComPtr<IDXGISwapChain1> swap_;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoCtx_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11VideoProcessorEnumerator> enum_;
    int width_ = 0, height_ = 0;      // 显示尺寸（= 交换链尺寸）
    int srcW_ = 0, srcH_ = 0;         // 解码器实际输出尺寸
    // 视频处理器视图按纹理指针缓存：每帧新建在 45fps 下是每秒 90 次 Create*View
    std::unordered_map<uint64_t, ComPtr<ID3D11VideoProcessorInputView>> inViewCache_;
    std::unordered_map<void*, ComPtr<ID3D11VideoProcessorOutputView>> outViewCache_;
    bool tearing_ = false;
    bool useVsync_ = true;
};

bool Presenter::Init(Graphics* gfx, HWND hwnd, int width, int height) {
    gfx_ = gfx;
    width_ = width;
    height_ = height;

    ComPtr<IDXGIDevice> dxgiDev;
    gfx->device.As(&dxgiDev);
    ComPtr<IDXGIAdapter> adapter;
    dxgiDev->GetAdapter(&adapter);
    ComPtr<IDXGIFactory2> factory;
    adapter->GetParent(IID_PPV_ARGS(&factory));

    // 查询是否支持免垂直同步呈现
    {
        ComPtr<IDXGIFactory5> f5;
        if (SUCCEEDED(factory.As(&f5))) {
            BOOL allow = FALSE;
            if (SUCCEEDED(f5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING,
                                                  &allow, sizeof(allow)))) {
                tearing_ = allow == TRUE;
            }
        }
    }
    Log("免垂直同步能力: %s", tearing_ ? "支持" : "不支持");

    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = width;
    desc.Height = height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.Stereo = FALSE;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    desc.Flags = tearing_ ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;

    HRESULT hr = factory->CreateSwapChainForHwnd(gfx->device.Get(), hwnd, &desc,
                                                 nullptr, nullptr, &swap_);
    if (FAILED(hr)) { Log("交换链创建失败 %08X", hr); return false; }

    gfx->device.As(&videoDevice_);
    gfx->context.As(&videoCtx_);

    srcW_ = width;
    srcH_ = height;
    if (!CreateProcessor()) return false;

    Log("呈现器就绪");
    return true;
}

bool Presenter::CreateProcessor() {
    processor_.Reset();
    enum_.Reset();

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = srcW_;
    cd.InputHeight = srcH_;
    cd.OutputWidth = width_;
    cd.OutputHeight = height_;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

    HRESULT hr = videoDevice_->CreateVideoProcessorEnumerator(&cd, &enum_);
    if (FAILED(hr)) { Log("视频处理器枚举失败（输入 %dx%d） %08X", srcW_, srcH_, hr); return false; }
    hr = videoDevice_->CreateVideoProcessor(enum_.Get(), 0, &processor_);
    if (FAILED(hr)) { Log("视频处理器创建失败 %08X", hr); return false; }
    videoCtx_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0,
                                                  D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);

    // 裁边/缩放：VideoProcessorBlt 默认把整个输入表面映射到输出，
    // 这里只在需要时覆盖 StreamSourceRect，且右下角绝不越出输入纹理。
    //   src >= dst：硬解按宏块对齐多出几行(如 1808 vs 1800)，取 dst 大小裁掉多余行。
    //   src <  dst：Mac 切到低分辨率档位(如 smooth 2240x1408 对命令行 2880x1800)，
    //               取整个 src，让 VideoProcessor 缩放到输出，不能按 dst 取(会越界)。
    //   src == dst：不设，走默认整面映射。
    if (srcW_ != width_ || srcH_ != height_) {
        RECT src{};
        if (srcW_ >= width_ && srcH_ >= height_) {
            src = RECT{ 0, 0, width_, height_ };          // 裁掉对齐多出的行/列
            Log("呈现器: 输入 %dx%d，裁到 %dx%d（去掉宏块对齐余量）",
                srcW_, srcH_, width_, height_);
        } else {
            src = RECT{ 0, 0, srcW_, srcH_ };             // 取整个源，缩放到输出
            Log("呈现器: 输入 %dx%d，小于显示 %dx%d，缩放铺满（不裁边）",
                srcW_, srcH_, width_, height_);
        }
        videoCtx_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);
    }
    return true;
}

bool Presenter::SetSourceSize(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    if (w == srcW_ && h == srcH_) return true;
    srcW_ = w;
    srcH_ = h;
    return CreateProcessor();
}

void Presenter::PresentSample(IMFSample* sample) {
    if (!sample) return;

    // FLIP 模型下交换链有多个物理缓冲随 Present 轮转，且每次 GetBuffer 拿到的
    // 可能是不同的表面。必须每帧重新获取，缓存指针会画到错误或不可写的缓冲上，
    // 表现为隔帧黑屏或花屏。
    ComPtr<ID3D11Texture2D> backTex;
    if (FAILED(swap_->GetBuffer(0, IID_PPV_ARGS(&backTex))) || !backTex) return;

    // 取解码输出的纹理
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(sample->GetBufferByIndex(0, &buf))) return;

    ComPtr<IMFDXGIBuffer> dxgiBuf;
    ComPtr<ID3D11Texture2D> inputTex;
    UINT subIdx = 0;

    if (SUCCEEDED(buf.As(&dxgiBuf))) {
        if (FAILED(dxgiBuf->GetResource(IID_PPV_ARGS(&inputTex)))) return;
        dxgiBuf->GetSubresourceIndex(&subIdx);
    } else {
        // 解码器给的是系统内存：需要上传到纹理
        ComPtr<IMF2DBuffer> twoD;
        BYTE* scan0 = nullptr;
        LONG pitch = 0;
        if (FAILED(buf.As(&twoD)) || FAILED(twoD->Lock2D(&scan0, &pitch))) return;

        D3D11_TEXTURE2D_DESC td{};
        td.Width = srcW_;
        td.Height = srcH_;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_NV12;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_DECODER;
        ComPtr<ID3D11Texture2D> tex;
        if (FAILED(gfx_->device->CreateTexture2D(&td, nullptr, &tex))) { twoD->Unlock2D(); return; }

        D3D11_BOX box{ 0, 0, 0, (UINT)srcW_, (UINT)srcH_, 1 };
        gfx_->context->UpdateSubresource(tex.Get(), 0, &box, scan0, (UINT)pitch, 0);
        twoD->Unlock2D();
        inputTex = tex;
        subIdx = 0;
    }
    if (!inputTex) return;

    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
    ivd.FourCC = 0;
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ivd.Texture2D.ArraySlice = subIdx;

    ComPtr<ID3D11VideoProcessorInputView> inView;
    uint64_t inKey = ((uint64_t)(uintptr_t)inputTex.Get() << 8) | (uint64_t)(subIdx & 0xFF);
    auto itIn = inViewCache_.find(inKey);
    if (itIn != inViewCache_.end()) {
        inView = itIn->second;
    } else {
        if (inViewCache_.size() > 32) inViewCache_.clear();
        if (FAILED(videoDevice_->CreateVideoProcessorInputView(inputTex.Get(), enum_.Get(),
                                                               &ivd, &inView))) return;
        inViewCache_[inKey] = inView;
    }

    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;

    ComPtr<ID3D11VideoProcessorOutputView> outView;
    void* outKey = (void*)backTex.Get();
    auto itOut = outViewCache_.find(outKey);
    if (itOut != outViewCache_.end()) {
        outView = itOut->second;
    } else {
        if (outViewCache_.size() > 8) outViewCache_.clear();
        if (FAILED(videoDevice_->CreateVideoProcessorOutputView(backTex.Get(), enum_.Get(),
                                                                &ovd, &outView))) return;
        outViewCache_[outKey] = outView;
    }

    D3D11_VIDEO_PROCESSOR_STREAM stream{};
    stream.Enable = TRUE;
    stream.pInputSurface = inView.Get();
    if (FAILED(videoCtx_->VideoProcessorBlt(processor_.Get(), outView.Get(), 0, 1, &stream))) return;

    // 呈现方式：
    //   垂直同步（默认）—— 帧对齐到刷新周期，画面均匀。显示器 89Hz 而输出 43fps 时，
    //     每帧占约 2 个刷新周期，节奏稳定；免同步会让这个比例在 2~3 之间跳，看起来就是卡。
    //   免同步 —— 延迟最低，但刷新节奏不均时会有抖动的观感。
    if (tearing_ && !useVsync_) {
        HRESULT hr = swap_->Present(0, DXGI_PRESENT_ALLOW_TEARING);
        if (FAILED(hr)) swap_->Present(1, 0);
    } else {
        swap_->Present(1, 0);
    }
    // 记录两次上屏的间隔：vsync 会把节奏拉成刷新周期的整数倍，
    // 免同步则贴近源帧间隔。统计行打印 p50/p95 便于客观判断。
    static double s_lastPresentMs = 0.0;   // 仅呈现线程调用
    double nowMs = QpcNowMs();
    if (s_lastPresentMs > 0.0) PushPresentInterval(nowMs - s_lastPresentMs);
    s_lastPresentMs = nowMs;
    g_stats.presented++;
}

void Presenter::Shutdown() {
    inViewCache_.clear();
    outViewCache_.clear();
    processor_.Reset();
    enum_.Reset();
    videoCtx_.Reset();
    videoDevice_.Reset();
    swap_.Reset();
}

// ---------------------------------------------------------------------------
// 窗口
// ---------------------------------------------------------------------------

// --- 全屏切换 ---
static bool g_isFullscreen = false;      // 由 main 按 cfg.fullscreen 同步
static LONG_PTR g_savedStyle = 0;
static LONG_PTR g_savedExStyle = 0;
static RECT g_savedRect{};

// --- 全屏提示 ---
// 进入全屏时短暂显示「怎么返回」，避免用户找不到出口把程序直接关掉。
// 用独立的分层弹出窗：FLIP 交换链会盖住子窗口，子控件画在视频上不可见。
static HWND    g_hintHwnd = nullptr;
static HBRUSH  g_hintBrush = nullptr;
static HFONT   g_hintFont = nullptr;
static const wchar_t* g_hintText =
    L"F11 或 Esc 返回窗口      Ctrl+Alt+H 最小化让位      再按一次 Esc 退出";
static const UINT     WM_APP_HIDE_HINT = WM_APP + 1;
static const UINT_PTR TIMER_HINT_HIDE  = 3;

static LRESULT CALLBACK HintWndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        FillRect(dc, &rc, g_hintBrush ? g_hintBrush : (HBRUSH)GetStockObject(BLACK_BRUSH));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        HFONT old = (HFONT)SelectObject(dc, g_hintFont ? g_hintFont : GetStockObject(DEFAULT_GUI_FONT));
        RECT tr = rc; tr.left += 18; tr.right -= 18;
        DrawTextW(dc, g_hintText, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        SelectObject(dc, old);
        EndPaint(h, &ps);
        return 0;
    }
    if (m == WM_ERASEBKGND) return 1;
    return DefWindowProcW(h, m, w, l);
}

static void HideFullscreenHint() {
    if (g_hintHwnd) ShowWindow(g_hintHwnd, SW_HIDE);
}

static void ShowFullscreenHint() {
    if (!g_hwnd) return;
    if (!g_hintHwnd) {
        g_hintBrush = CreateSolidBrush(RGB(18, 18, 18));
        g_hintFont = CreateFontW(-26, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Microsoft YaHei");
        static bool clsReg = false;
        if (!clsReg) {
            WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc);
            wc.lpfnWndProc = HintWndProc;
            wc.hInstance = (HINSTANCE)GetWindowLongPtrW(g_hwnd, GWLP_HINSTANCE);
            wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
            wc.lpszClassName = L"SecDisplayHint";
            RegisterClassExW(&wc);
            clsReg = true;
        }
        HINSTANCE inst = (HINSTANCE)GetWindowLongPtrW(g_hwnd, GWLP_HINSTANCE);
        g_hintHwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE,
            L"SecDisplayHint", L"",
            WS_POPUP,
            0, 0, 920, 60, g_hwnd, nullptr, inst, nullptr);
        if (g_hintHwnd)
            SetLayeredWindowAttributes(g_hintHwnd, 0, 235, LWA_ALPHA);
    }
    if (!g_hintHwnd) return;
    HMONITOR mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{}; mi.cbSize = sizeof(mi);
    int px = 16, py = 16;
    if (GetMonitorInfoW(mon, &mi)) { px = mi.rcMonitor.left + 16; py = mi.rcMonitor.top + 16; }
    SetWindowPos(g_hintHwnd, HWND_TOP, px, py, 920, 60, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    SetTimer(g_hwnd, TIMER_HINT_HIDE, 5000, nullptr);   // 5 秒后自动隐藏
}

/// 在当前所在的显示器上铺满。配合 per-monitor DPI 感知，
/// 窗口客户区就是显示器的物理像素，交换链 1:1 不做缩放。
static void EnterFullscreen() {
    if (!g_hwnd || g_isFullscreen) return;
    g_savedStyle = GetWindowLongPtr(g_hwnd, GWL_STYLE);
    g_savedExStyle = GetWindowLongPtr(g_hwnd, GWL_EXSTYLE);
    GetWindowRect(g_hwnd, &g_savedRect);

    HMONITOR mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfo(mon, &mi)) return;

    // 切换后仍是普通应用窗口：保留 WS_MINIMIZEBOX/WS_SYSMENU，EXSTYLE 保持
    // WS_EX_APPWINDOW（进任务栏、可 Alt-Tab），不设 TOPMOST/TOOLWINDOW。
    SetWindowLongPtr(g_hwnd, GWL_STYLE,
                     WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE);
    SetWindowPos(g_hwnd, HWND_NOTOPMOST,
                 mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    g_isFullscreen = true;
    Log("已切换到全屏");
    ShowFullscreenHint();
}

static void ExitFullscreen() {
    if (!g_hwnd || !g_isFullscreen) return;
    SetWindowLongPtr(g_hwnd, GWL_STYLE, g_savedStyle);
    SetWindowLongPtr(g_hwnd, GWL_EXSTYLE, g_savedExStyle);
    SetWindowPos(g_hwnd, HWND_NOTOPMOST,
                 g_savedRect.left, g_savedRect.top,
                 g_savedRect.right - g_savedRect.left,
                 g_savedRect.bottom - g_savedRect.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    g_isFullscreen = false;
    Log("已切换到窗口");
    KillTimer(g_hwnd, TIMER_HINT_HIDE);
    HideFullscreenHint();
}

// 用收到的 BGRA 像素造一个 32bpp 带 alpha 的 HCURSOR。
// 仅在 UI 线程(WM_APPLY_CURSOR)调用；旧 cursor 在此销毁，无跨线程句柄竞态。
static void ApplyCursorImage() {
    // 只拷需要的字段；CursorImageBuf 含 mutex，不可整体值拷贝。
    std::vector<uint8_t> bgra;
    int w, h, hotX, hotY;
    {
        std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
        if (!g_cursorImage.pending) return;
        w = g_cursorImage.w; h = g_cursorImage.h;
        hotX = g_cursorImage.hotX; hotY = g_cursorImage.hotY;
        bgra = g_cursorImage.bgra;
        g_cursorImage.pending = false;
    }
    if (w <= 0 || h <= 0 || (int)bgra.size() < w * h * 4) return;

    // color DIB：自底向上，32bpp BGRA
    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = w;
    bi.bV5Height = -h;                  // 负值 = 自顶向下，匹配 Mac 送来的行序
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_RGB;
    void* bits = nullptr;
    HDC hdc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(hdc, (BITMAPINFO*)&bi, DIB_RGB_COLORS,
                                     &bits, nullptr, 0);
    if (hdc) ReleaseDC(nullptr, hdc);
    if (!color || !bits) { if (color) DeleteObject(color); return; }
    memcpy(bits, bgra.data(), (size_t)w * h * 4);

    // mask：全 0（32bpp alpha 光标不需要 1bpp AND 掩码，但 ICONINFO 要求提供）
    HBITMAP mask = CreateBitmap(w, h, 1, 1, nullptr);
    if (!mask) { DeleteObject(color); return; }

    ICONINFO ii{};
    ii.fIcon = FALSE;
    ii.xHotspot = (DWORD)hotX;
    ii.yHotspot = (DWORD)hotY;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HCURSOR cur = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    if (!cur) return;

    if (g_customCursor) DestroyCursor(g_customCursor);
    g_customCursor = cur;
    SetCursor(cur);
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_CLOSE:
        // Esc / 托盘「退出」/ 全局热键都汇到这里
        Log("收到 WM_CLOSE，准备退出");
        TrayRemove();
        PostQuitMessage(0);
        return 0;
    case WM_DESTROY:
        Log("收到 WM_DESTROY");
        TrayRemove();
        PostQuitMessage(0);
        return 0;
    case WM_TIMER:
        if (w == TIMER_HINT_HIDE) {
            KillTimer(g_hwnd, TIMER_HINT_HIDE);
            HideFullscreenHint();
            return 0;
        }
        break;
    case WM_APP_HIDE_HINT:
        HideFullscreenHint();
        return 0;
    case WM_APPLY_CURSOR:
        // 网络线程收到 0x05 后 post 到这里，HCURSOR 创建/销毁统一在 UI 线程
        ApplyCursorImage();
        return 0;
    case WM_APP_REMOTE_CURSOR: {
        // 事件驱动：只有收到新的远程位置才搬一次光标，不再 4ms 轮询。
        // Mac 端静止时本来就不发包，所以不会出现「停下 1 秒就被拽回」。
        // 两个门控都通过才动：
        //   1. 副屏窗口在前台，用户在别的程序里操作时不抢
        //   2. 本机鼠标最近 250ms 没动，本地输入优先
        if (GetForegroundWindow() != g_hwnd) return 0;
        if (GetTickCount64() - (uint64_t)g_lastLocalInputMs.load() < 250) return 0;
        double cx = g_cursorX.load(), cy = g_cursorY.load();
        if (cx < 0 || cy < 0) return 0;
        int vw = g_coordW.load(), vh = g_coordH.load();
        if (vw <= 0 || vh <= 0) return 0;
        RECT rc{};
        if (!GetClientRect(g_hwnd, &rc)) return 0;
        int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
        if (cw <= 0 || ch <= 0) return 0;
        POINT tl{ rc.left, rc.top };
        ClientToScreen(g_hwnd, &tl);
        // 标记这次移动是程序发起的，随后的 WM_MOUSEMOVE 不要污染本地输入时间戳
        g_lastRemoteCursorMoveMs = GetTickCount64();
        SetCursorPos(tl.x + (int)(cx / vw * cw), tl.y + (int)(cy / vh * ch));
        return 0;
    }
    case WM_TRAY:
        // 托盘图标的鼠标事件（lParam = 具体消息）
        if (LOWORD(l) == WM_LBUTTONUP) {
            RequestQuit();                 // 左键：直接退出
        } else if (LOWORD(l) == WM_RBUTTONUP) {
            TrayShowMenu(h);               // 右键：菜单
        }
        return 0;
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case ID_TRAY_EXIT:   RequestQuit(); return 0;
        case ID_TRAY_TOGGLE:
            if (g_isFullscreen) ExitFullscreen(); else EnterFullscreen();
            return 0;
        case ID_TRAY_MINIMIZE: ToggleMinimize(); return 0;
        case ID_TRAY_ABOUT:
            MessageBoxW(h,
                L"SecDisplay\n"
                L"左键托盘图标 或 Ctrl+Alt+Q 退出\n"
                L"Ctrl+Alt+H 最小化让位 / 还原（不退出）\n"
                L"F11 切换全屏 / 窗口\n"
                L"Esc 也可退出",
                L"关于 SecDisplay", MB_OK | MB_ICONINFORMATION);
            return 0;
        }
        return 0;
    case WM_HOTKEY:
        if (w == HOTKEY_QUIT_ID) RequestQuit();
        else if (w == HOTKEY_HIDE_ID) ToggleMinimize();
        return 0;
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) {
            // 全屏时 Esc 先回到窗口，避免想退出放大却直接把程序关掉；
            // 已经在窗口模式时 Esc 才退出程序。
            if (g_isFullscreen) ExitFullscreen(); else RequestQuit();
            return 0;
        }
        // F11 或 F 切换全屏，方便窗口模式下按一下变全屏
        if (w == VK_F11 || w == 'F') {
            if (g_isFullscreen) ExitFullscreen(); else EnterFullscreen();
            return 0;
        }
        return 0;
    case WM_MOUSEMOVE: {
        // 程序自己 SetCursorPos 引起的移动不算用户输入，否则远程跟随
        // 每动一次就把本地时间戳刷新，门控随即自锁，光标一顿一顿。
        if (GetTickCount64() - (uint64_t)g_lastRemoteCursorMoveMs.load() < 50) return 0;
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            g_lastLocalInputMs = GetTickCount64();
            // 只记最新位置，由 inputThread 8ms 合并发送，避免逐消息刷包
            g_moveX = vx;
            g_moveY = vy;
            g_moveDirty = true;
        }
        return 0;
    }
    case WM_LBUTTONDOWN: case WM_LBUTTONUP:
    case WM_RBUTTONDOWN: case WM_RBUTTONUP:
    case WM_MBUTTONDOWN: case WM_MBUTTONUP: {
        uint8_t b = g_buttons.load();
        bool down = (m == WM_LBUTTONDOWN || m == WM_RBUTTONDOWN || m == WM_MBUTTONDOWN);
        uint8_t bit = (m == WM_LBUTTONDOWN || m == WM_LBUTTONUP) ? 0x1
                    : (m == WM_RBUTTONDOWN || m == WM_RBUTTONUP) ? 0x2 : 0x4;
        if (down) b |= bit; else b &= (uint8_t)~bit;
        g_buttons = b;
        g_lastLocalInputMs = GetTickCount64();
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            // 更新位置并标记事件，inputThread 下一轮（约 4ms 内）立即发，保证点击落点准
            g_moveX = vx;
            g_moveY = vy;
            g_eventPending = true;
        }
        return 0;
    }
    case WM_MOUSEWHEEL: {
        POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        ScreenToClient(h, &pt);
        float vx, vy;
        if (ClientToVideo(pt.x, pt.y, &vx, &vy)) {
            int delta = GET_WHEEL_DELTA_WPARAM(w);
            g_lastLocalInputMs = GetTickCount64();
            g_moveX = vx;
            g_moveY = vy;
            g_pendingWheel = (int16_t)(-delta);
            g_eventPending = true;   // 滚轮事件由 inputThread 立即发
        }
        return 0;
    }
    case WM_SETCURSOR:
        // 有 Mac 真实光标就用它，否则退回标准箭头
        SetCursor(g_customCursor ? g_customCursor : LoadCursor(nullptr, IDC_ARROW));
        return TRUE;
    case WM_SYSCOMMAND:
        // 窗口模式的「最大化」按钮 / Win+↑ 都接到整屏放大（EnterFullscreen），
        // 走的是改窗口样式与位置，不动交换链尺寸，避免 ResizeBuffers 引发的黑屏风险。
        if ((w & 0xFFF0) == SC_MAXIMIZE) {
            if (!g_isFullscreen) EnterFullscreen();
            return 0;
        }
        break;
    case WM_LBUTTONDBLCLK:      // 双击也切换
        if (g_isFullscreen) ExitFullscreen(); else EnterFullscreen();
        return 0;
    }
    return DefWindowProc(h, m, w, l);
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 运行配置
// ---------------------------------------------------------------------------

struct RunConfig {
    std::string host = "10.10.10.1";
    int port = 9922;
    int width = 2880;         // 物理像素：解码 / 呈现 / 全屏窗口
    int height = 1800;
    int coordW = -1;          // 坐标基准尺寸；<0 表示默认取物理尺寸（与 Mac CGDisplayBounds 对齐）
    int coordH = -1;
    bool fullscreen = false;  // 默认窗口化：开启软件后桌面仍可正常使用，不盖屏、可 Alt-Tab、可最小化。
                              // 需要铺满时用 --fullscreen 或 F11，且全屏也不置顶、不进不了任务栏。
    bool reconnect = true;    // 断线自动重连
    bool vsync = true;        // true=垂直同步（画面均匀），false=免同步（延迟最低但可能抖）
    bool pace = false;        // --pace：一帧抖动缓冲，按自适应节拍上屏，抹平源端小抖动
    std::string logFile;      // 非空则同时写日志文件
};

// g_alive 已前移到文件顶部全局区（供 RecvAll 等底层函数使用）。

static void ParseArgs(int argc, char** argv, RunConfig& cfg) {
    int positional = 0;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--windowed" || a == "-w") {
            cfg.fullscreen = false;
        } else if (a == "--fullscreen" || a == "-f") {
            cfg.fullscreen = true;
        } else if (a == "--no-reconnect") {
            cfg.reconnect = false;
        } else if (a == "--vsync") {
            cfg.vsync = true;
        } else if (a == "--tearing") {
            cfg.vsync = false;
        } else if (a == "--pace") {
            cfg.pace = true;
        } else if ((a == "--log" || a == "-l") && i + 1 < argc) {
            cfg.logFile = argv[++i];
        } else if (a == "--coord" && i + 2 < argc) {
            // 显式指定坐标基准尺寸（如 --coord 2880 1800）。
            // 用于 Mac 端 CGDisplayBounds 尺寸与物理值不符时现场纠正，无需重编译。
            cfg.coordW = atoi(argv[++i]);
            cfg.coordH = atoi(argv[++i]);
        } else if (a.rfind("--", 0) == 0) {
            // 未知选项，忽略
        } else {
            switch (positional++) {
            case 0: cfg.host = a; break;
            case 1: cfg.port = atoi(a.c_str()); break;
            case 2: cfg.width = atoi(a.c_str()); break;
            case 3: cfg.height = atoi(a.c_str()); break;
            }
        }
    }
    if (cfg.width <= 0) cfg.width = 2880;
    if (cfg.height <= 0) cfg.height = 1800;
    if (cfg.port <= 0 || cfg.port > 65535) cfg.port = 9922;
}

// ---------------------------------------------------------------------------
// 网络主循环：连接 → 收流 → 断线重连
//
// 解码器每条连接重建一次：对端重启后参数集会变，沿用旧实例会解不出来。
// ---------------------------------------------------------------------------

static void NetworkLoop(const RunConfig& cfg, Graphics* gfx, Presenter* presenter) {
    while (g_alive) {
        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) {
            Log("socket 失败 %d，2 秒后重试", WSAGetLastError());
            Sleep(2000);
            continue;
        }

        int nodelay = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
        int rcvbuf = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (const char*)&rcvbuf, sizeof(rcvbuf));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((u_short)cfg.port);
        inet_pton(AF_INET, cfg.host.c_str(), &addr.sin_addr);

        Log("连接 %s:%d ...", cfg.host.c_str(), cfg.port);
        if (connect(sock, (sockaddr*)&addr, sizeof(addr)) != 0) {
            Log("连接失败 %d", WSAGetLastError());
            closesocket(sock);
            if (!cfg.reconnect) break;
            Sleep(2000);
            continue;
        }
        Log("已连接，目标 %dx%d", cfg.width, cfg.height);
        g_sock = sock;

        // 给 recv 设超时，退出时即便漏了 shutdown，阻塞的 recv 也会在
        // 500ms 内返回，让收流线程能轮询 g_alive 后退出（避免 net.join 卡死）。
        DWORD recvTimeoutMs = 500;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                   (const char*)&recvTimeoutMs, sizeof(recvTimeoutMs));

        // 复位统计，重连后从头计数
        g_stats.packets = 0; g_stats.bytes = 0; g_stats.decoded = 0;
        g_stats.presented = 0; g_stats.dropped = 0; g_stats.paced = 0; g_stats.decodeFail = 0;
        ResetPresentRing();
        ResetDecodeRing();
        g_lastDecodeMs = 0.0;
        g_stats.lastLatencyUs = 0;
        ResetTimestampBase();

        // 立刻请求关键帧，否则解码器拿不到 SPS/PPS，黑屏
        {
            uint8_t req = TYPE_KEYFRAME_REQUEST;
            if (send(sock, (const char*)&req, 1, 0) == 1) Log("已请求关键帧（0x02）");
        }

        Decoder decoder;
        if (!decoder.Init(gfx, cfg.width, cfg.height)) {
            Log("解码器初始化失败，断开重试");
            closesocket(sock);
            if (!cfg.reconnect) break;
            Sleep(2000);
            continue;
        }

        std::atomic<bool> connAlive{ true };
        std::vector<uint8_t> packet;

        // 解码只保留最新一帧：收流线程持续解码以维持 H.264 参考链（直接丢编码包会花屏），
        // 呈现线程只取最新帧上屏。这样呈现被垂直同步阻塞时，旧帧不会在队列里堆积，
        // 操作延迟被压到「解码 + 一次呈现」的量级。
        struct LatestFrame { IMFSample* smp = nullptr; int srcW = 0; int srcH = 0; };
        std::mutex latestMtx;
        std::condition_variable latestCv;
        LatestFrame latest;
        bool hasLatest = false;

        // 收流 + 解码线程
        std::thread recv([&] {
            while (g_alive && connAlive) {
                uint32_t len = 0;
                if (!RecvAll(sock, &len, 4)) break;
                len = ntohl(len);
                if (len < HEADER_BYTES || len > MAX_PACKET) {
                    Log("包长度异常 %u，断开", len);
                    break;
                }
                packet.resize(len);
                if (!RecvAll(sock, packet.data(), (int)len)) break;

                if (packet[0] == TYPE_CURSOR) {
                    g_stats.cursor++;
                    OnCursorPacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_CURSOR_IMAGE) {
                    OnCursorImagePacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                // 0x06 心跳 / 其它未知类型：忽略即可，TCP 已有数据流动
                if (packet[0] != TYPE_VIDEO) continue;

                uint64_t ts = 0;
                for (int i = 0; i < 8; ++i) ts = (ts << 8) | packet[1 + i];

                g_stats.packets++;
                g_stats.bytes += len;

                IMFSample* smp = nullptr;
                if (decoder.Decode(packet.data() + HEADER_BYTES, len - HEADER_BYTES, &smp) && smp) {
                    g_stats.decoded++;
                    double dn = QpcNowMs();
                    if (g_lastDecodeMs > 0.0) PushDecodeInterval(dn - g_lastDecodeMs);
                    g_lastDecodeMs = dn;
                    int64_t extra = EstimateExtraDelayUs(ts);
                    if (extra >= 0) g_stats.lastLatencyUs = (uint64_t)extra;
                    // 解码器实际输出可能比显示尺寸高（硬解按宏块对齐），随帧带给呈现器裁边。
                    int ow = decoder.outWidth(), oh = decoder.outHeight();
                    IMFSample* old = nullptr;
                    {
                        std::lock_guard<std::mutex> lk(latestMtx);
                        old = latest.smp;
                        latest.smp = smp; latest.srcW = ow; latest.srcH = oh;
                        hasLatest = true;
                    }
                    if (old) { g_stats.dropped++; old->Release(); }   // 旧帧还没上屏就被新帧取代，记一次呈现丢帧
                    latestCv.notify_one();
                }
            }
            connAlive = false;
            latestCv.notify_all();
        });

        // 呈现线程：默认只上屏最新帧。慢于解码时中间帧被丢，不影响解码参考链。
        // --pace 时改为「一帧缓冲 + 自适应节拍」：先预填一帧，再按源端平均帧间隔
        // 定期上屏，把偶发的双倍间隔吸收掉。代价是增加约一帧延迟。
        std::thread present([&] {
            struct PendingFrame { IMFSample* smp; int w; int h; };
            std::deque<PendingFrame> pending;
            double lastPresentMs = 0.0;
            bool primed = false;

            auto dropOldest = [&] {
                if (!pending.empty()) {
                    pending.front().smp->Release();
                    pending.pop_front();
                    g_stats.paced++;
                }
            };

            while (g_alive && connAlive) {
                double target = g_paceTargetMs.load();
                const bool pace = g_paceEnabled.load() && target > 1.0;

                // 节拍模式下等到下一个上屏点；否则有新帧就上。
                bool timed = false;
                double waitMs = 0.0;
                if (pace && primed && lastPresentMs > 0.0) {
                    double due = lastPresentMs + target;
                    double now = QpcNowMs();
                    if (now + 0.5 < due) { timed = true; waitMs = due - now; }
                }

                {
                    std::unique_lock<std::mutex> lk(latestMtx);
                    if (!hasLatest) {
                        if (timed) {
                            latestCv.wait_for(lk, std::chrono::duration<double, std::milli>(waitMs),
                                              [&] { return hasLatest || !connAlive || !g_alive; });
                        } else {
                            latestCv.wait(lk, [&] { return hasLatest || !connAlive || !g_alive; });
                        }
                    }
                    if (hasLatest) {
                        pending.push_back({ latest.smp, latest.srcW, latest.srcH });
                        latest.smp = nullptr; hasLatest = false;
                    }
                }
                if (!g_alive || !connAlive) break;

                // 源快于节拍时丢最旧保实时，队列最多留 3 帧
                while (pending.size() > 3) dropOldest();

                if (pace) {
                    if (!primed) {
                        if (pending.size() < 2) continue;   // 预填一帧，避免起步就空
                        primed = true;
                        lastPresentMs = 0.0;
                    }
                    if (lastPresentMs > 0.0) {
                        double due = lastPresentMs + target;
                        if (QpcNowMs() + 0.5 < due) continue;   // 还没到上屏点
                    }
                }

                if (pending.empty()) continue;
                PendingFrame f = pending.front();
                pending.pop_front();
                presenter->SetSourceSize(f.w, f.h);
                lastPresentMs = QpcNowMs();   // 以本次上屏开始时刻为节拍基准，避免把 Present 阻塞时长叠加进节拍
                presenter->PresentSample(f.smp);
                f.smp->Release();
            }

            // 清理退出前尚未上屏的样本
            for (auto& f : pending) f.smp->Release();
            pending.clear();
            IMFSample* rest = nullptr;
            {
                std::lock_guard<std::mutex> lk(latestMtx);
                rest = latest.smp; latest.smp = nullptr; hasLatest = false;
            }
            if (rest) rest->Release();
        });

        // 监控线程：打印状态；长时间无新帧就补请求关键帧
        std::thread watch([&] {
            uint64_t lastBytes = 0, lastDecoded = 0, lastCursor = 0;
            uint64_t lastPresented = 0, lastDropped = 0, lastPaced = 0;
            double recentFps[5] = { 0, 0, 0, 0, 0 };   // 近 10 秒的每秒解码帧数
            int fpsIdx = 0;
            int stallRounds = 0;
            std::vector<double> ivs, divs;
            while (g_alive && connAlive) {
                for (int i = 0; i < 20 && g_alive && connAlive; ++i) Sleep(100);
                if (!g_alive || !connAlive) break;

                uint64_t b = g_stats.bytes, d = g_stats.decoded;
                uint64_t p = g_stats.presented, dr = g_stats.dropped;
                uint64_t pc = g_stats.paced;
                double mbps = (b - lastBytes) * 8 / 2.0 / 1e6;

                // 当前帧率 = 本 2 秒窗口的实时解码速率；峰值 = 近 5 个窗口（约 10 秒）最大值。
                // 静止桌面 SCK 变化驱动，当前值本来就低；峰值用来判断「有动静时能跑多快」。
                double curFps = (double)(d - lastDecoded) / 2.0;
                recentFps[fpsIdx] = curFps;
                fpsIdx = (fpsIdx + 1) % 5;
                double peakFps = 0;
                for (double v : recentFps) if (v > peakFps) peakFps = v;

                TakePresentIntervals(ivs);
                double p50 = PercentileMs(ivs, 0.50);
                double p95 = PercentileMs(ivs, 0.95);
                TakeDecodeIntervals(divs);
                double d50 = PercentileMs(divs, 0.50);
                double d95 = PercentileMs(divs, 0.95);

                // 节拍目标吸附到刷新周期整数倍，避免垂直同步再量化一次。
                // 只在源帧率稳定落在刷新率 25%~60% 区间时启用；
                // 低帧率、静止、或帧率大幅波动时自动关闭，退回即时上屏。
                if (g_paceEnabled.load()) {
                    double targetMs = 0.0;
                    bool inRange = g_refreshHz > 0 &&
                                   curFps >= g_refreshHz * 0.30 &&
                                   curFps <  g_refreshHz * 0.60;
                    if (inRange) {
                        double mn = curFps, mx = curFps;
                        for (double v : recentFps) {
                            if (v > 0.0) { if (v < mn) mn = v; if (v > mx) mx = v; }
                        }
                        bool stable = (mx <= 0.0) || ((mx - mn) <= mx * 0.5);
                        if (stable && d50 > 0.0 && d50 < 80.0) {
                            double vs = 1000.0 / (double)g_refreshHz;
                            double meanMs = 1000.0 / curFps;
                            double n = std::ceil(meanMs / vs - 0.02);
                            if (n < 1.0) n = 1.0;
                            if (n > 6.0) n = 6.0;
                            targetMs = n * vs;
                        }
                    }
                    g_paceTargetMs.store(targetMs);
                }

                uint64_t curPkts = g_stats.cursor.load();
                Log("包 %llu  解码 %llu(+%llu)  当前 %.1f fps  峰值 %.1f fps"
                    "  上屏 +%llu  呈现丢帧 +%llu  源间隔 p50 %.1f p95 %.1f ms"
                    "  上屏间隔 p50 %.1f p95 %.1f ms  节拍 %.1f ms  节拍丢帧 +%llu"
                    "  %.1f Mbps  附加延迟 %.1f ms  解码失败 %llu  光标+%llu  输入 %llu",
                    (unsigned long long)g_stats.packets,
                    (unsigned long long)d,
                    (unsigned long long)(d - lastDecoded),
                    curFps,
                    peakFps,
                    (unsigned long long)(p - lastPresented),
                    (unsigned long long)(dr - lastDropped),
                    d50, d95,
                    p50, p95,
                    g_paceTargetMs.load(),
                    (unsigned long long)(pc - lastPaced),
                    mbps,
                    g_stats.lastLatencyUs / 1000.0,
                    (unsigned long long)g_stats.decodeFail,
                    (unsigned long long)(curPkts - lastCursor),
                    (unsigned long long)g_stats.inputSent.load());
                lastCursor = curPkts;
                lastPresented = p;
                lastDropped = dr;
                lastPaced = pc;

                if (d == lastDecoded) {
                    ++stallRounds;
                    uint8_t req = TYPE_KEYFRAME_REQUEST;
                    if (send(sock, (const char*)&req, 1, 0) == 1) {
                        Log("无新帧 %d 轮，重新请求关键帧（0x02）", stallRounds);
                    }
                    // 连续 5 轮（约 10 秒）没新帧：多半是 Mac 那边画面完全静止。
                    // ScreenCaptureKit 是变化驱动的，静止就不出帧，请求关键帧也没用。
                    if (stallRounds == 5) {
                        Log("提示: 已 10 秒没有任何新帧。若 Mac 端画面静止，"
                            "ScreenCaptureKit 不会出帧——移动窗口或鼠标即可恢复。");
                    }
                } else {
                    stallRounds = 0;
                }
                lastBytes = b;
                lastDecoded = d;
            }
        });

        recv.join();
        connAlive = false;
        latestCv.notify_all();
        present.join();
        watch.join();

        decoder.Shutdown();
        if (g_sock.load() == sock) g_sock = INVALID_SOCKET;
        shutdown(sock, SD_BOTH);
        closesocket(sock);

        if (!g_alive) break;
        Log("连接结束");
        if (!cfg.reconnect) break;
        Log("2 秒后重连");
        Sleep(2000);
    }
    Log("网络循环退出");
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    setvbuf(stderr, nullptr, _IONBF, 0);

    // 控制台输出用 UTF-8。Log() 把 UTF-8 字节直接 fwrite 到 stderr，
    // 而中文 Windows 控制台默认是 CP936(GBK)，UTF-8 字节被当 GBK 显示，
    // 就是截图里「附加延迟」变「闃勫姩浠樻儏縺」那种乱码。
    // 设成 CP_UTF8 后控制台按 UTF-8 解释这些字节。
    // 只影响控制台显示；写日志文件仍保持 UTF-8 原样，遥测提取器不受影响。
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
    // 用 UTF-8 locale，保证 CRT 不做多余的窄字符转换
    setlocale(LC_ALL, ".UTF-8");

    // 每显示器 DPI 感知。不做这步，200% 缩放的系统里全屏窗口只有逻辑尺寸，
    // 交换链会被系统再缩一次，画面变糊。
    // 用动态解析避免不同 SDK / MinGW 的头文件差异。
    if (HMODULE u32 = GetModuleHandleA("user32.dll")) {
        typedef BOOL (WINAPI *SetCtxFn)(HANDLE);
        auto fn = (SetCtxFn)GetProcAddress(u32, "SetProcessDpiAwarenessContext");
        if (fn) fn((HANDLE)-4);   // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    }

    RunConfig cfg;
    ParseArgs(argc, argv, cfg);

    if (!cfg.logFile.empty()) {
        // 追加模式，保留历史便于回看崩溃前的日志。
        // 用标准 fopen 而不是 fopen_s：后者是 MSVC 扩展，MinGW 构建会不通过。
        g_logFile = fopen(cfg.logFile.c_str(), "a");
        if (!g_logFile) fprintf(stderr, "无法打开日志文件 %s\n", cfg.logFile.c_str());
    }

    Log("================ SecDisplay 接收端 ================");
    Log("目标 %s:%d  分辨率 %dx%d  %s  重连 %s",
        cfg.host.c_str(), cfg.port, cfg.width, cfg.height,
        cfg.fullscreen ? "全屏" : "窗口",
        cfg.reconnect ? "开" : "关");
    if (!cfg.logFile.empty()) Log("日志文件: %s", cfg.logFile.c_str());

    HRESULT coInit = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(coInit) && coInit != RPC_E_CHANGED_MODE) {
        Log("CoInitializeEx 失败 %08X", coInit);
        return 1;
    }
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
        Log("MFStartup 失败");
        return 1;
    }

    Graphics gfx;
    if (!gfx.Init(cfg.width, cfg.height)) return 2;

    WNDCLASSA wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "SecDisplayReceiver";
    RegisterClassA(&wc);

    HWND hwnd = nullptr;
    if (cfg.fullscreen) {
        // 用 EnumDisplaySettings 拿物理分辨率，而不是 GetSystemMetrics。
        // 系统若启用了 DPI 虚拟化，SM_CXSCREEN 会返回逻辑尺寸（200% 缩放下只有一半），
        // 窗口就盖不满屏。
        int sw = 0, sh = 0;
        DEVMODEW dm{};
        dm.dmSize = sizeof(dm);
        if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm) && dm.dmPelsWidth > 0) {
            sw = (int)dm.dmPelsWidth;
            sh = (int)dm.dmPelsHeight;
        }
        if (sw <= 0 || sh <= 0) {
            sw = GetSystemMetrics(SM_CXSCREEN);
            sh = GetSystemMetrics(SM_CYSCREEN);
        }
        Log("全屏目标尺寸 %dx%d（显示器物理分辨率）", sw, sh);

        // 不盖屏约束：不用 WS_EX_TOPMOST（否则压住任务栏与所有窗口），
        // 不用 WS_EX_TOOLWINDOW（否则被 pin 到所有虚拟桌面、不进任务栏/Alt-Tab，
        // 用户 Win+Tab 新建桌面也会被盖住）。改 WS_EX_APPWINDOW 让窗口正常进任务栏，
        // 补 WS_SYSMENU|WS_MINIMIZEBOX 让最小化按钮与 Win+M 可用。
        // 客户区仍是整屏物理分辨率，投屏 1:1 不变。
        hwnd = CreateWindowExA(WS_EX_APPWINDOW,
                               "SecDisplayReceiver", "SecDisplay",
                               WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX | WS_VISIBLE,
                               0, 0, sw, sh,
                               nullptr, nullptr, wc.hInstance, nullptr);
    } else {
        // 窗口模式：占屏幕中间一块，不置顶，方便远程调试时还能操作桌面
        int sw = GetSystemMetrics(SM_CXSCREEN);
        int sh = GetSystemMetrics(SM_CYSCREEN);
        int ww = sw / 2;
        int wh = (int)((double)ww * cfg.height / cfg.width);
        if (wh > sh * 2 / 3) { wh = sh * 2 / 3; ww = (int)((double)wh * cfg.width / cfg.height); }
        RECT rc{ 0, 0, ww, wh };
        AdjustWindowRect(&rc, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX, FALSE);
        int winW = rc.right - rc.left;
        int winH = rc.bottom - rc.top;
        hwnd = CreateWindowExA(WS_EX_APPWINDOW, "SecDisplayReceiver", "SecDisplay",
                               WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_VISIBLE,
                               (sw - winW) / 2, (sh - winH) / 2,
                               winW, winH,
                               nullptr, nullptr, wc.hInstance, nullptr);
    }
    if (!hwnd) { Log("窗口创建失败"); return 3; }
    g_hwnd = hwnd;
    g_isFullscreen = cfg.fullscreen;   // 与启动模式对齐，F11 首次切换才正确

    // 记录显示器刷新率：判断源帧率与刷新率是否成整数比，是 vsync 顿挫的前提。
    {
        int hz = 0;
        MONITORINFOEXW mi{}; mi.cbSize = sizeof(mi);
        DEVMODEW dmr{}; dmr.dmSize = sizeof(dmr);
        if (GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi) &&
            EnumDisplaySettingsW(mi.szDevice, ENUM_CURRENT_SETTINGS, &dmr)) {
            hz = (int)dmr.dmDisplayFrequency;
        }
        if (hz <= 0) {
            DEVMODEW dm2{}; dm2.dmSize = sizeof(dm2);
            if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm2))
                hz = (int)dm2.dmDisplayFrequency;
        }
        if (hz > 0) { g_refreshHz = hz; Log("显示器刷新率 %d Hz", hz); }
    }

    // 窗口模式标题含中文，用 W 版单独设，绕开 A 版在 CP936 下的 GBK 误解码。
    // 全屏标题 "SecDisplay" 是纯 ASCII，保持 CreateWindowExA 传入的值即可。
    if (!cfg.fullscreen) {
        SetWindowTextW(hwnd, L"SecDisplay - 按标题栏最大化或 F11 全屏放大 / Ctrl+Alt+H 让位 / Esc 退出");
    }

    // 系统托盘小图标 + 全局热键
    TrayCreate(hwnd);
    // Ctrl+Alt+Q 兜底强退；注册失败也不影响托盘和 Esc
    if (!RegisterHotKey(hwnd, HOTKEY_QUIT_ID, MOD_CONTROL | MOD_ALT, 'Q')) {
        Log("全局热键 Ctrl+Alt+Q 注册失败（可能已被占用）");
    }
    // Ctrl+Alt+H 一键最小化让位/还原，焦点无关，随时能回 Windows 桌面且不退出程序
    if (!RegisterHotKey(hwnd, HOTKEY_HIDE_ID, MOD_CONTROL | MOD_ALT, 'H')) {
        Log("全局热键 Ctrl+Alt+H 注册失败（可能已被占用）");
    }
    Log("退出方式: 窗口模式按 Esc / 左键托盘图标 / 右键菜单 / Ctrl+Alt+Q；全屏时 Esc 先回窗口");
    Log("让位方式: Ctrl+Alt+H 最小化/还原，或托盘菜单；窗口可 Alt-Tab、可 Win+M 最小化");
    Log("放大方式: 点标题栏最大化按钮 / F11 / Win+向上键，均切换整屏放大；不置顶、可随时让位");
    Log("输入回传: 鼠标移动约 120Hz 合并发送，按键/滚轮即时");
    Log("遥测口径: 当前=本2秒解码帧率 峰值=近10秒最大 源间隔=相邻解码帧到达间隔"
        " 上屏间隔=相邻Present间隔 呈现丢帧=上屏前被新帧取代"
        " 节拍=目标上屏间隔 节拍丢帧=缓冲队列溢出主动丢弃");

    if (cfg.fullscreen) {
        // 绝对定位兜底，确保铺满显示器；不再置顶（HWND_NOTOPMOST），
        // 让任务栏与其它窗口能正常显示在它之上，用户可随时切回桌面。
        RECT wr{};
        GetWindowRect(hwnd, &wr);
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0,
                     wr.right - wr.left, wr.bottom - wr.top,
                     SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    }

    {
        RECT rc{};
        GetClientRect(hwnd, &rc);
        RECT wr{};
        GetWindowRect(hwnd, &wr);
        Log("窗口客户区 %dx%d  窗口矩形 %dx%d",
            rc.right - rc.left, rc.bottom - rc.top,
            wr.right - wr.left, wr.bottom - wr.top);
    }

    Presenter presenter;
    if (!presenter.Init(&gfx, hwnd, cfg.width, cfg.height)) return 4;
    presenter.setUseVsync(cfg.vsync);
    Log("呈现方式: %s", cfg.vsync ? "垂直同步（均匀）" : "免同步（低延迟）");
    g_paceEnabled = cfg.pace;
    Log("抖动缓冲: %s", cfg.pace ? "开（一帧缓冲，自适应节拍，增加约一帧延迟）" : "关（即时上屏，延迟最低）");

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { Log("WSAStartup 失败"); return 5; }

    // 坐标基准必须等于 Mac 端 CGDisplayBounds 的尺寸。
    // 实测（2026-11-10，macOS 27.2 / M1 Pro）：hiDPI 虚拟屏的 CGDisplayBounds
    // 返回物理像素尺寸 2880x1800，而非逻辑点 1440x900；CursorTracker 发的
    // rx/ry = CGEvent.location - bounds.minX，范围就是 0..2880 / 0..1800，
    // InputInjector 也把收到的值当同一坐标注入。
    // 因此默认取物理尺寸，与 Mac 对齐。早期按「逻辑点=物理/2」的假设会
    // 让光标显示偏移一半、点击回传放大一倍。
    // 若换到 CGDisplayBounds 返回逻辑点的系统，用 --coord W H 现场纠正。
    g_coordW = cfg.coordW > 0 ? cfg.coordW : cfg.width;
    g_coordH = cfg.coordH > 0 ? cfg.coordH : cfg.height;
    Log("坐标基准: 逻辑 %dx%d（物理 %dx%d%s）",
        g_coordW.load(), g_coordH.load(), cfg.width, cfg.height,
        cfg.coordW > 0 ? "，命令行指定" : "，默认对齐物理");

    // 光标跟随已停用（止血）。
    //
    // 旧实现在这里起了一个 4ms 轮询的线程，把 0x03 收到的远程坐标换算到
    // 窗口客户区后 SetCursorPos，直接搬系统光标。问题是 g_lastLocalInputMs
    // 只在鼠标位于副屏客户区内时才刷新（WM_MOUSEMOVE + ClientToVideo 成功），
    // 用户把鼠标移回主屏后时间戳不再更新，满 1 秒就被判定「本机没动」，
    // 光标被拽回副屏旧坐标；SetCursorPos 又触发一次 WM_MOUSEMOVE 刷新时间戳，
    // 于是形成每 1 秒一次的周期性抢光标。
    //
    // 现在窗口光标由 0x05 图像 + ApplyCursorImage + WM_SETCURSOR 本地绘制，
    // 位置完全交给系统光标，两边互不抢占。若将来要做「远程驱动副屏光标」，
    // 应改为在视频画面上绘制，而不是 SetCursorPos 搬系统光标。

    // 输入回传线程：每 4ms 轮询，鼠标移动按 8ms 合并发（约 120Hz），
    // 按键/滚轮事件在下一轮立即发。单线程发送，避免与 UI 线程并发 send 同一 socket。
    std::thread inputThread([] {
        uint64_t lastMoveMs = 0;
        while (g_alive) {
            Sleep((DWORD)INPUT_TICK_MS);
            if (!g_alive) break;
            if (g_sock.load() == INVALID_SOCKET) continue;
            if (g_eventPending.exchange(false)) {
                SendInputPacket(g_moveX.load(), g_moveY.load(), g_buttons.load(),
                                g_pendingWheel.exchange(0));
                lastMoveMs = GetTickCount64();
                g_moveDirty = false;   // 事件包已带最新位置
                continue;
            }
            if (g_moveDirty.load()) {
                uint64_t now = GetTickCount64();
                if (now - lastMoveMs >= INPUT_MOVE_INTERVAL_MS) {
                    if (g_moveDirty.exchange(false)) {
                        SendInputPacket(g_moveX.load(), g_moveY.load(), g_buttons.load(), 0);
                    }
                    lastMoveMs = now;
                }
            }
        }
    });

    std::thread net(NetworkLoop, cfg, &gfx, &presenter);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    // 退出清理：托盘图标和热键必须在进程结束前移除，否则托盘会留残影
    TrayRemove();
    UnregisterHotKey(hwnd, HOTKEY_QUIT_ID);
    UnregisterHotKey(hwnd, HOTKEY_HIDE_ID);
    if (g_customCursor) { DestroyCursor(g_customCursor); g_customCursor = nullptr; }
    if (g_hintFont)  { DeleteObject(g_hintFont);  g_hintFont = nullptr; }
    if (g_hintBrush) { DeleteObject(g_hintBrush); g_hintBrush = nullptr; }
    if (g_hintHwnd)  { DestroyWindow(g_hintHwnd); g_hintHwnd = nullptr; }
    g_alive = false;
    // 关键：先掐断 socket，让阻塞在 recv 的收流线程立即返回。
    // 否则「已连上 Mac 正常收流」时按退出，net.join() 会一直等那个
    // 无超时的 recv，进程卡在退出途中，看起来像「点了退出没反应」。
    // 配合 RecvAll 的 SO_RCVTIMEO(500ms) 双保险。
    {
        SOCKET s = g_sock.load();
        if (s != INVALID_SOCKET) shutdown(s, SD_BOTH);
    }
    if (net.joinable()) net.join();
    // cursorThread 已随「停用 SetCursorPos 抢光标」一起移除，勿再 join。
    if (inputThread.joinable()) inputThread.join();

    WSACleanup();
    presenter.Shutdown();
    gfx.Shutdown();
    MFShutdown();
    CoUninitialize();

    if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
    return 0;
}
