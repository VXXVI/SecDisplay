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
#include <fstream>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <exception>
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
    std::atomic<uint64_t> presentFail{0};   // 呈现路径静默 return 的次数（取缓冲/建视图/Blt/Present 失败）
    std::atomic<uint64_t> dupFrame{0};      // 与上一帧编码数据完全相同的帧数（源端在重发最后一帧）
    std::atomic<uint64_t> lastLatencyUs{0};
    std::atomic<uint64_t> cursor{0};      // 收到的 0x03 光标包
    std::atomic<uint64_t> inputSent{0};   // 发出的 0x04 输入事件
};

static Stats g_stats;

// 可选抖动缓冲：默认关闭。--pace 打开后，呈现线程用一个小队列按自适应节拍上屏，
// 吸收源端偶发的双倍帧间隔；代价是增加约 1~3 帧延迟（队列上限 3）。
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

static double g_lastPresentMs = 0.0;   // 仅呈现线程写；重连时复位，避免断线时长污染 p95

// 最近一次「成功 Present」的时刻。呈现线程写，看门狗读，所以用原子。
// 看门狗据此判断「连接还在但画面不再更新」，2 秒没有成功上屏就清屏提示。
static std::atomic<double> g_lastGoodPresentMs{ 0.0 };
// 最近一次收到视频包的时刻（收流线程写，看门狗读）。用来区分
// 「有帧在来但上不了屏」和「源端一个包都没发」，后者不能立刻判无信号，
// 否则静止桌面（源端不出帧）会被误清屏。
static std::atomic<double> g_lastVideoPacketMs{ 0.0 };

static void ResetPresentRing() {
    std::lock_guard<std::mutex> lk(g_presentMtx);
    g_presentRingCount = 0;
    g_lastPresentMs = 0.0;
    g_lastGoodPresentMs.store(0.0);   // 新连接从零开始算，避免把上一段连接的时长算进看门狗
    g_lastVideoPacketMs.store(0.0);
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
// 0x06 有两种形态：
//   旧版发送端：9 字节空载荷心跳，只维持 TCP 有数据流动
//   新版发送端：15 字节会话头，附带虚拟屏尺寸，接收端据此自动重建管线
// 载荷（全大端）：[version u8][width u16][height u16][fps u8][reserved u8]，共 7 字节
static const uint8_t TYPE_SESSION = 0x06;
static const size_t SESSION_PAYLOAD_BYTES = 7;
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

// 对端会话头通告的虚拟屏尺寸与采集帧率。
// 旧版发送端不发会话头，这里保持 0，接收端沿用启动参数。
static std::atomic<int> g_sessW{0};
static std::atomic<int> g_sessH{0};
static std::atomic<int> g_sessFps{0};
// 当前解码/呈现管线实际使用的尺寸。会话头与它不同就断开重连并重建管线。
static std::atomic<int> g_displayW{0};
static std::atomic<int> g_displayH{0};
static std::atomic<double> g_cursorX{-1};
static std::atomic<double> g_cursorY{-1};
// 光标是否在副屏范围内。Mac 端把指针移回主屏时会发 visible=0，
// 这里必须真的把 Windows 光标隐藏，否则它会一直停在最后位置。
static std::atomic<bool> g_cursorVisible{true};
// 程序自己调用 SetCursorPos 会引起 WM_MOUSEMOVE；用时间戳把它和用户真实
// 输入区分开，否则每次跟随都会被当成「用户动了」，导致门控反复自锁。
static std::atomic<int64_t> g_lastRemoteCursorMoveMs{ 0 };
// 程序 SetCursorPos 的目标点。只过滤「时间接近且落点等于目标点」的那一次 WM_MOUSEMOVE，
// 不能只看时间窗：Mac 光标高频移动时，真实本地移动会被一直吞掉。
static std::atomic<LONG> g_lastRemoteCursorX{ INT_MIN };
static std::atomic<LONG> g_lastRemoteCursorY{ INT_MIN };

// 真实 Mac 光标图像（0x05）。网络线程只把收到的 BGRA 存进缓冲并 post 消息，
// HCURSOR 的创建/替换/销毁统一在 UI 线程做，避免跨线程句柄竞态。
static const UINT WM_APPLY_CURSOR = WM_APP + 2;
// 0x03 远程光标位置：网络线程 post，UI 线程做门控与 SetCursorPos
static const UINT WM_APP_REMOTE_CURSOR = WM_APP + 3;
// 0x03 的可见性变化：UI 线程据此 SetCursor(cur) 或 SetCursor(nullptr)
static const UINT WM_APP_CURSOR_VIS = WM_APP + 4;
// 老 SDK 的 winuser.h 可能没定义 WM_DPICHANGED（需要 WINVER >= 0x0603）
#ifndef WM_DPICHANGED
#define WM_DPICHANGED 0x02E0
#endif
struct CursorImageBuf {
    std::mutex mtx;
    std::vector<uint8_t> bgra;
    int w = 0, h = 0, hotX = 0, hotY = 0;
    bool pending = false;
};
static CursorImageBuf g_cursorImage;
static HCURSOR g_customCursor = nullptr;   // 仅 UI 线程访问
// 已建好的 HCURSOR 对应的位图指纹与缩放（千分比）。同一张位图、同一缩放不重建，
// 避免重复的 CreateIconIndirect/DestroyCursor 造成光标闪烁和句柄抖动。
static uint64_t g_cursorAppliedFp = 0;     // 仅 UI 线程访问
static int g_cursorAppliedScalePm = 0;     // 仅 UI 线程访问

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

// 控制包发送锁：0x04 输入、0x07 反馈、0x02 关键帧请求共用同一 socket，
// 必须串行写，避免不同线程的 send 交错导致对端解析错位。
static std::mutex g_sendMtx;

// 可选反馈包 0x07：--feedback 打开后，监控线程每 2 秒把接收端健康度回传给 Mac，
// 供 Mac 侧自适应码率环使用。默认关闭，旧 Mac 会把未知字节逐个丢弃，不会误解析。
static std::atomic<bool>     g_feedbackEnabled{ false };
static std::atomic<bool>     g_feedbackPending{ false };
static std::atomic<uint16_t> g_fbPresentP95{ 0 };
static std::atomic<uint16_t> g_fbSourceP95{ 0 };
static std::atomic<uint16_t> g_fbDecodeFps10{ 0 };
static std::atomic<uint16_t> g_fbPresentDrop{ 0 };
static std::atomic<uint16_t> g_fbPacedDrop{ 0 };

static void SendFeedbackPacket() {
    SOCKET s = g_sock.load();
    if (s == INVALID_SOCKET) return;
    uint8_t pkt[13];
    pkt[0] = 0x07;
    auto wr16 = [](uint8_t* q, uint16_t v) {
        q[0] = (uint8_t)(v >> 8); q[1] = (uint8_t)v;
    };
    wr16(pkt + 1,  g_fbPresentP95.load());
    wr16(pkt + 3,  g_fbSourceP95.load());
    wr16(pkt + 5,  g_fbDecodeFps10.load());
    wr16(pkt + 7,  g_fbPresentDrop.load());
    wr16(pkt + 9,  g_fbPacedDrop.load());
    wr16(pkt + 11, 0);
    std::lock_guard<std::mutex> lk(g_sendMtx);
    send(s, (const char*)pkt, sizeof(pkt), 0);
}

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
    {
        std::lock_guard<std::mutex> lk(g_sendMtx);
        send(s, (const char*)pkt, 12, 0);
    }
    g_stats.inputSent++;
}

static HWND g_hwnd = nullptr;   // 主窗口句柄，ClientToVideo 与全屏切换共用

// 全局存活标志。放在靠前位置，因为 RecvAll 等底层函数也要读它来判断退出。
// false 时所有后台线程（收流/光标/监控）应尽快结束。
static std::atomic<bool> g_alive{ true };

// 可中断的等待：退出时不用等满整个重连间隔，避免「点退出没反应」
static void SleepAlive(int ms) {
    while (ms > 0 && g_alive.load()) {
        int step = ms > 100 ? 100 : ms;
        Sleep(step);
        ms -= step;
    }
}

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
static const UINT ID_TRAY_PANEL = 1005;
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
    AppendMenuW(menu, MF_STRING, ID_TRAY_PANEL, L"控制面板");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
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
        // 光标离开副屏：清空坐标并通知 UI 线程隐藏本机光标。
        // 只清坐标不隐藏，会让光标图像一直停在最后位置。
        g_cursorX = -1;
        g_cursorY = -1;
        if (g_cursorVisible.exchange(false) && g_hwnd) {
            PostMessageA(g_hwnd, WM_APP_CURSOR_VIS, 0, 0);
        }
        return;
    }
    if (!g_cursorVisible.exchange(true) && g_hwnd) {
        PostMessageA(g_hwnd, WM_APP_CURSOR_VIS, 0, 0);
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
// 极简 SPS 解析：只为拿到码流里的真实编码宽高
//
// 为什么需要：接收端协商输入类型时用的是 config.ini / 命令行的尺寸（默认
// 2880x1800），而 Mac 侧虚拟屏切档后实际可能是 1600x1000。按错误尺寸声明
// MF_MT_FRAME_SIZE 会让 H.264 解码器的 SetInputType 或输出类型协商反复失败，
// 表现是一直没有输出，而日志里只有一行 SetInputType 失败。
// 这里从 SPS 里解出真实宽高，协商前先纠正 width_/height_。
//
// 只处理常见语法（progressive、无 scaling list）。遇到不支持的语法返回 false，
// 调用方沿用原尺寸，行为与改动前一致，解析失败不会把链路弄坏。
// ---------------------------------------------------------------------------

struct SpsBitReader {
    const uint8_t* p;
    size_t n;          // 字节数
    size_t pos = 0;    // 位偏移
    bool ok = true;

    explicit SpsBitReader(const std::vector<uint8_t>& d) : p(d.data()), n(d.size()) {}

    uint32_t u(int bits) {
        uint32_t v = 0;
        for (int i = 0; i < bits; ++i) {
            if (pos >= n * 8) { ok = false; return 0; }
            v = (v << 1) | (uint32_t)((p[pos >> 3] >> (7 - (pos & 7))) & 1);
            ++pos;
        }
        return v;
    }

    // 无符号指数哥伦布
    uint32_t ue() {
        int zeros = 0;
        while (ok) {
            if (u(1) != 0) break;
            if (++zeros > 31) { ok = false; return 0; }
        }
        if (!ok) return 0;
        if (zeros == 0) return 0;
        return ((1u << zeros) - 1u) + u(zeros);
    }

    // 有符号指数哥伦布
    int32_t se() {
        uint32_t k = ue();
        if (!ok) return 0;
        return (k & 1u) ? (int32_t)((k + 1u) / 2u) : -(int32_t)(k / 2u);
    }
};

/// sps 含 NAL 头字节（0x67）。成功时写回真实宽高。
static bool ParseSpsDimensions(const std::vector<uint8_t>& sps, int& outW, int& outH) {
    if (sps.size() < 4) return false;

    // 去掉防竞争字节（00 00 03 -> 00 00）
    std::vector<uint8_t> rbsp;
    rbsp.reserve(sps.size());
    int zeros = 0;
    for (size_t i = 0; i < sps.size(); ++i) {
        uint8_t b = sps[i];
        if (zeros >= 2 && b == 0x03) { zeros = 0; continue; }
        rbsp.push_back(b);
        zeros = (b == 0) ? zeros + 1 : 0;
    }
    if (rbsp.size() < 4) return false;

    SpsBitReader br(rbsp);
    br.u(8);                 // NAL 头
    uint32_t profile = br.u(8);
    br.u(8);                 // constraint_set 标志 + reserved
    br.u(8);                 // level_idc
    br.ue();                 // seq_parameter_set_id

    uint32_t chroma = 1;     // 非 High profile 隐含 4:2:0
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 ||
        profile == 44 || profile == 83 || profile == 86 || profile == 118 ||
        profile == 128 || profile == 138 || profile == 139 || profile == 134 ||
        profile == 135) {
        chroma = br.ue();
        if (chroma == 3) br.u(1);   // separate_colour_plane_flag
        br.ue();                    // bit_depth_luma_minus8
        br.ue();                    // bit_depth_chroma_minus8
        br.u(1);                    // qpprime_y_zero_transform_bypass_flag
        if (br.u(1)) return false;  // seq_scaling_matrix_present_flag：不解析
    }
    if (!br.ok) return false;

    br.ue();                        // log2_max_frame_num_minus4
    uint32_t pocType = br.ue();
    if (pocType == 0) {
        br.ue();                    // log2_max_pic_order_cnt_lsb_minus4
    } else if (pocType == 1) {
        br.u(1);                    // delta_pic_order_always_zero_flag
        br.se();                    // offset_for_non_ref_pic
        br.se();                    // offset_for_top_to_bottom_field
        uint32_t cycle = br.ue();
        if (!br.ok || cycle > 255) return false;
        for (uint32_t i = 0; i < cycle; ++i) br.se();
    } else if (pocType != 2) {
        return false;
    }
    br.ue();                        // max_num_ref_frames
    br.u(1);                        // gaps_in_frame_num_value_allowed_flag

    uint32_t wMbs = br.ue() + 1;        // pic_width_in_mbs_minus1
    uint32_t hMapUnits = br.ue() + 1;   // pic_height_in_map_units_minus1
    uint32_t frameMbsOnly = br.u(1);
    if (!frameMbsOnly) br.u(1);     // mb_adaptive_frame_field_flag
    br.u(1);                        // direct_8x8_inference_flag
    uint32_t cropL = 0, cropR = 0, cropT = 0, cropB = 0;
    if (br.u(1)) {                  // frame_cropping_flag
        cropL = br.ue(); cropR = br.ue(); cropT = br.ue(); cropB = br.ue();
    }
    if (!br.ok) return false;

    // 裁剪单位按色度格式取，4:2:0 是 2x2，其它见 H.264 7.4.2.1.1
    int cropUnitX = 1;
    int cropUnitY = (int)(2 - frameMbsOnly);
    if (chroma == 1) {
        cropUnitX = 2;
        cropUnitY = 2 * (int)(2 - frameMbsOnly);
    } else if (chroma == 2) {
        cropUnitX = 2;
    } else if (chroma != 0 && chroma != 3) {
        return false;
    }

    int w = (int)wMbs * 16 - cropUnitX * (int)(cropL + cropR);
    int h = (int)(2 - frameMbsOnly) * (int)hMapUnits * 16 - cropUnitY * (int)(cropT + cropB);
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return false;
    outW = w;
    outH = h;
    return true;
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
    auto releaseEvents = [&] {
        if (buffer.pEvents) { buffer.pEvents->Release(); buffer.pEvents = nullptr; }
    };

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
            if (!SetOutputTypeD3D()) { releaseEvents(); return false; }
            Log("输出类型已重建，继续解码");
        }
        releaseEvents();
        return false;
    }
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
        if (buffer.pSample && buffer.pSample != ourSample.Get()) buffer.pSample->Release();
        releaseEvents();
        return false;
    }
    if (FAILED(hr)) {
        if (buffer.pSample && buffer.pSample != ourSample.Get()) buffer.pSample->Release();
        releaseEvents();
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
    releaseEvents();
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
            // 先用 SPS 里的真实编码尺寸协商，再退回启动参数。
            // Mac 切档后虚拟屏可能是 1600x1000，而接收端启动参数还是 2880x1800，
            // 按错尺寸声明 MF_MT_FRAME_SIZE 会让 SetInputType 反复失败、一直无输出。
            const int prevW = width_, prevH = height_;
            int spsW = 0, spsH = 0;
            const bool haveSps = ParseSpsDimensions(sps, spsW, spsH);
            if (haveSps) { width_ = spsW; height_ = spsH; }

            bool applied = SetInputTypeFromParamSets(sps, pps);
            if (!applied && haveSps && (spsW != prevW || spsH != prevH)) {
                // SPS 尺寸被拒（少见）：退回原尺寸再试一次，保证不比改动前更差
                Log("按 SPS 尺寸 %dx%d 设输入类型失败，退回 %dx%d 重试",
                    spsW, spsH, prevW, prevH);
                width_ = prevW; height_ = prevH;
                applied = SetInputTypeFromParamSets(sps, pps);
            }
            if (applied) {
                paramSetsCache_ = merged;
                transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
                ready_ = false;
                if (haveSps && (spsW != prevW || spsH != prevH)) {
                    Log("按 SPS 更新编码尺寸: %dx%d（启动参数 %dx%d）",
                        spsW, spsH, prevW, prevH);
                }
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
        // 关键：重送仍失败时，pending 是「更早」的旧帧，绝不能当成新解出的帧
        // 交回调用方。原来这里 return pending != nullptr，调用方会把旧帧计进
        // decoded、再交给呈现线程重复上屏，外部表现就是
        // 「连接正常、每 2 秒都有帧、画面却永远不动」且没有任何错误日志。
        if (pending) { pending->Release(); pending = nullptr; }
        static double lastLogMs = 0.0;
        double nowMs = QpcNowMs();
        if (lastLogMs == 0.0 || nowMs - lastLogMs > 2000.0) {
            lastLogMs = nowMs;
            Log("送帧失败 %08X（解码器拒绝输入），丢弃这一帧", (unsigned)hr);
        }
        return false;
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
    // 返回是否真的把一帧送上了屏。中间任何一步失败都返回 false 并计数，
    // 调用方据此跑看门狗：静默失败会让 FLIP 交换链永久停在旧帧上。
    bool PresentSample(IMFSample* sample);
    void Shutdown();
    bool tearingSupported() const { return tearing_; }
    void setUseVsync(bool v) { useVsync_ = v; }

    // 断线时把后缓冲清成深色并 Present 一次。
    // FLIP 交换链停止 Present 后 DWM 会一直显示最后一个后缓冲，窗口就永久停在
    // 最后一帧，看起来像「显示的是别的屏」。断线必须主动清掉。
    void ClearToIdle();

    // 解码器实际输出尺寸可能与显示尺寸不同（硬解按宏块对齐，1800 -> 1808）。
    // 变了就重建视频处理器，并按显示尺寸裁边。
    bool SetSourceSize(int w, int h);

    // 对端会话头切换分辨率时重建交换链。调用时机必须在呈现线程退出之后，
    // 否则 ResizeBuffers 会因后缓冲仍被引用而失败。
    bool Resize(int width, int height);

private:
    bool CreateProcessor();

    Graphics* gfx_ = nullptr;
    ComPtr<IDXGISwapChain1> swap_;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoCtx_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11VideoProcessorEnumerator> enum_;
    int width_ = 0, height_ = 0;      // 交换链尺寸，恒等于窗口客户区物理像素
    int srcW_ = 0, srcH_ = 0;         // 解码器实际输出尺寸
    // 视频处理器视图按纹理指针缓存：每帧新建在 45fps 下是每秒 90 次 Create*View
    std::unordered_map<uint64_t, ComPtr<ID3D11VideoProcessorInputView>> inViewCache_;
    std::unordered_map<void*, ComPtr<ID3D11VideoProcessorOutputView>> outViewCache_;
    // 黑边靠每帧清后缓冲实现，RTV 同样按纹理指针缓存
    std::unordered_map<void*, ComPtr<ID3D11RenderTargetView>> rtvCache_;
    // 交换链与三张缓存表会被呈现线程和 UI/网络线程同时碰：
    // 以前只有会话切档会改尺寸，窗口一拖 WM_SIZE 就频繁触发，必须串起来。
    std::mutex mtx_;
    bool tearing_ = false;
    bool useVsync_ = true;
    // 连续失败计数与限流日志：45fps 下每帧打日志会淹掉文件，
    // 只打第一次和之后每 2 秒一次，既能定位又不会刷屏。
    uint64_t failStreak_ = 0;
    double lastFailLogMs_ = 0.0;
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

/// 把 sw×sh 等比装进 dw×dh，居中，返回目标矩形。
/// 整数取整后可能差一两个像素，全部夹在输出范围内。
static RECT FitRect(int sw, int sh, int dw, int dh) {
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return RECT{ 0, 0, dw, dh };
    const double sx = (double)dw / sw;
    const double sy = (double)dh / sh;
    const double s = sx < sy ? sx : sy;
    int w = (int)(sw * s + 0.5);
    int h = (int)(sh * s + 0.5);
    if (w > dw) w = dw;
    if (h > dh) h = dh;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    const int x = (dw - w) / 2;
    const int y = (dh - h) / 2;
    return RECT{ x, y, x + w, y + h };
}

bool Presenter::CreateProcessor() {
    processor_.Reset();
    enum_.Reset();
    // 输入/输出视图都持有创建时那个 enum_ 的引用，重建时必须一起失效，
    // 否则分辨率切换后复用按旧枚举器创建的视图，VideoProcessorBlt 会持续
    // 返回 E_INVALIDARG（上屏静默失败，画面永久停在旧帧）。
    // 原来只清了 inViewCache_，输出视图仍按旧 enum_ 命中缓存，是个漏点。
    inViewCache_.clear();
    outViewCache_.clear();

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

    // 输入永远取整帧：硬解按宏块对齐多出的行(如 1808 vs 1800)交给输出矩形去处理，
    // 不再从源上裁，否则缩放基准会跟着错。
    RECT src{ 0, 0, srcW_, srcH_ };
    videoCtx_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);

    // 输出按等比装进交换链，装不满的地方留黑边。
    // 交换链尺寸现在恒等于窗口客户区，所以这里缩完就是最终像素，
    // DWM 不会再拉第二次。之前交换链按流尺寸建、客户区又是另一个尺寸，
    // 等于被 VideoProcessor 和 DWM 各双线性一次，文字就是这么糊掉的。
    RECT dst = FitRect(srcW_, srcH_, width_, height_);
    const bool letterbox = dst.left > 0 || dst.top > 0 ||
                           dst.right < width_ || dst.bottom < height_;
    if (letterbox) {
        videoCtx_->VideoProcessorSetOutputTargetRect(processor_.Get(), TRUE, &dst);
    } else {
        videoCtx_->VideoProcessorSetOutputTargetRect(processor_.Get(), FALSE, nullptr);
    }
    Log("呈现器: 输入 %dx%d → 输出 %dx%d，画面矩形 %d,%d - %d,%d%s",
        srcW_, srcH_, width_, height_,
        (int)dst.left, (int)dst.top, (int)dst.right, (int)dst.bottom,
        letterbox ? "（留黑边）" : "（满幅）");
    return true;
}

bool Presenter::SetSourceSize(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    if (w == srcW_ && h == srcH_) return true;
    srcW_ = w;
    srcH_ = h;
    return CreateProcessor();
}

bool Presenter::Resize(int width, int height) {
    if (width <= 0 || height <= 0) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    if (width == width_ && height == height_) return true;
    if (!swap_) { width_ = width; height_ = height; return true; }

    // 输入/输出视图都缓存了后缓冲指针，改尺寸后必须全部失效
    inViewCache_.clear();
    outViewCache_.clear();
    rtvCache_.clear();

    UINT flags = tearing_ ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;
    HRESULT hr = swap_->ResizeBuffers(0, (UINT)width, (UINT)height,
                                      DXGI_FORMAT_UNKNOWN, flags);
    if (FAILED(hr)) {
        Log("交换链改尺寸失败 %08X（保持 %dx%d）", hr, width_, height_);
        return false;
    }
    width_ = width;
    height_ = height;
    if (!CreateProcessor()) return false;
    Log("呈现器已切换到 %dx%d", width_, height_);
    return true;
}

bool Presenter::PresentSample(IMFSample* sample) {
    // 所有失败都从这里走：计数 + 限流日志。
    // 原来这里 8 个静默 return，设备移除、交换链失效、VideoProcessorBlt 失败时
    // 画面会永久停在旧帧，日志里一行线索都没有，看起来就像「连着却显示别的屏」。
    auto fail = [&](const char* what, HRESULT hr) -> bool {
        ++failStreak_;
        g_stats.presentFail++;
        double nowMs = QpcNowMs();
        if (failStreak_ == 1 || nowMs - lastFailLogMs_ > 2000.0) {
            lastFailLogMs_ = nowMs;
            Log("上屏失败（连续 %llu 次）: %s  hr=%08X",
                (unsigned long long)failStreak_, what, (unsigned)hr);
        }
        return false;
    };

    std::lock_guard<std::mutex> lk(mtx_);

    if (!sample) return fail("空样本", E_POINTER);
    if (!swap_) return fail("交换链为空", E_UNEXPECTED);
    if (!processor_) return fail("视频处理器未就绪", E_UNEXPECTED);

    // FLIP 模型下交换链有多个物理缓冲随 Present 轮转，且每次 GetBuffer 拿到的
    // 可能是不同的表面。必须每帧重新获取，缓存指针会画到错误或不可写的缓冲上，
    // 表现为隔帧黑屏或花屏。
    ComPtr<ID3D11Texture2D> backTex;
    HRESULT hr = swap_->GetBuffer(0, IID_PPV_ARGS(&backTex));
    if (FAILED(hr)) return fail("交换链 GetBuffer(0)", hr);
    if (!backTex) return fail("交换链 GetBuffer(0) 返回空纹理", E_POINTER);

    // 黑边每帧都要重画：FLIP 交换链的后缓冲内容在 Present 之后即失效，
    // 上一帧留下的黑边不会自己保留。这里只清一次全屏，代价远低于一次缩放。
    {
        ComPtr<ID3D11RenderTargetView> rtv;
        void* rtvKey = (void*)backTex.Get();
        auto itRtv = rtvCache_.find(rtvKey);
        if (itRtv != rtvCache_.end()) {
            rtv = itRtv->second;
        } else {
            if (rtvCache_.size() > 8) rtvCache_.clear();
            if (SUCCEEDED(gfx_->device->CreateRenderTargetView(backTex.Get(), nullptr, &rtv)) && rtv)
                rtvCache_[rtvKey] = rtv;
        }
        if (rtv) {
            const float bg[4] = { 0.0f, 0.0f, 0.0f, 1.0f };
            gfx_->context->ClearRenderTargetView(rtv.Get(), bg);
        }
    }

    // 取解码输出的纹理
    ComPtr<IMFMediaBuffer> buf;
    hr = sample->GetBufferByIndex(0, &buf);
    if (FAILED(hr)) return fail("样本 GetBufferByIndex(0)", hr);
    if (!buf) return fail("样本没有缓冲区", E_POINTER);

    ComPtr<IMFDXGIBuffer> dxgiBuf;
    ComPtr<ID3D11Texture2D> inputTex;
    UINT subIdx = 0;

    if (SUCCEEDED(buf.As(&dxgiBuf))) {
        hr = dxgiBuf->GetResource(IID_PPV_ARGS(&inputTex));
        if (FAILED(hr)) return fail("IMFDXGIBuffer::GetResource", hr);
        dxgiBuf->GetSubresourceIndex(&subIdx);
    } else {
        // 解码器给的是系统内存：需要上传到纹理
        ComPtr<IMF2DBuffer> twoD;
        BYTE* scan0 = nullptr;
        LONG pitch = 0;
        hr = buf.As(&twoD);
        if (FAILED(hr) || !twoD) return fail("样本不支持 IMF2DBuffer", hr);
        hr = twoD->Lock2D(&scan0, &pitch);
        if (FAILED(hr) || !scan0) return fail("Lock2D", hr);

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
        hr = gfx_->device->CreateTexture2D(&td, nullptr, &tex);
        if (FAILED(hr) || !tex) { twoD->Unlock2D(); return fail("创建 NV12 上传纹理", hr); }

        D3D11_BOX box{ 0, 0, 0, (UINT)srcW_, (UINT)srcH_, 1 };
        gfx_->context->UpdateSubresource(tex.Get(), 0, &box, scan0, (UINT)pitch, 0);
        twoD->Unlock2D();
        inputTex = tex;
        subIdx = 0;
    }
    if (!inputTex) return fail("输入纹理为空", E_POINTER);

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
        hr = videoDevice_->CreateVideoProcessorInputView(inputTex.Get(), enum_.Get(),
                                                         &ivd, &inView);
        if (FAILED(hr) || !inView) return fail("创建输入视图", hr);
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
        hr = videoDevice_->CreateVideoProcessorOutputView(backTex.Get(), enum_.Get(),
                                                          &ovd, &outView);
        if (FAILED(hr) || !outView) return fail("创建输出视图", hr);
        outViewCache_[outKey] = outView;
    }

    D3D11_VIDEO_PROCESSOR_STREAM stream{};
    stream.Enable = TRUE;
    stream.pInputSurface = inView.Get();
    hr = videoCtx_->VideoProcessorBlt(processor_.Get(), outView.Get(), 0, 1, &stream);
    if (FAILED(hr)) return fail("VideoProcessorBlt", hr);

    // 呈现方式：
    //   垂直同步（默认）—— 帧对齐到刷新周期，画面均匀。显示器 89Hz 而输出 43fps 时，
    //     每帧占约 2 个刷新周期，节奏稳定；免同步会让这个比例在 2~3 之间跳，看起来就是卡。
    //   免同步 —— 延迟最低，但刷新节奏不均时会有抖动的观感。
    HRESULT phr = S_OK;
    if (tearing_ && !useVsync_) {
        phr = swap_->Present(0, DXGI_PRESENT_ALLOW_TEARING);
        if (FAILED(phr)) phr = swap_->Present(1, 0);
    } else {
        phr = swap_->Present(1, 0);
    }
    if (FAILED(phr)) return fail("Present", phr);

    // 走到这里才算真的上了屏。看门狗只看这个时刻，不看解码计数。
    failStreak_ = 0;
    double nowMs = QpcNowMs();
    g_lastGoodPresentMs.store(nowMs);
    // 记录两次上屏的间隔：vsync 会把节奏拉成刷新周期的整数倍，
    // 免同步则贴近源帧间隔。统计行打印 p50/p95 便于客观判断。
    if (g_lastPresentMs > 0.0) PushPresentInterval(nowMs - g_lastPresentMs);
    g_lastPresentMs = nowMs;
    g_stats.presented++;
    return true;
}

void Presenter::ClearToIdle() {
    if (!swap_ || !gfx_) return;
    std::lock_guard<std::mutex> lk(mtx_);
    ComPtr<ID3D11Texture2D> back;
    if (FAILED(swap_->GetBuffer(0, IID_PPV_ARGS(&back))) || !back) return;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(gfx_->device->CreateRenderTargetView(back.Get(), nullptr, &rtv)) || !rtv) return;
    const float c[4] = { 0.06f, 0.06f, 0.07f, 1.0f };
    gfx_->context->ClearRenderTargetView(rtv.Get(), c);
    gfx_->context->Flush();
    swap_->Present(0, 0);
}

void Presenter::Shutdown() {
    std::lock_guard<std::mutex> lk(mtx_);
    inViewCache_.clear();
    outViewCache_.clear();
    rtvCache_.clear();
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
static const wchar_t* kDefaultHint =
    L"F11 或 Esc 返回窗口      Ctrl+Alt+H 最小化让位      再按一次 Esc 退出";
static const wchar_t* g_hintText = kDefaultHint;
static const UINT     WM_APP_HIDE_HINT = WM_APP + 1;
static const UINT     WM_APP_SHOW_STATUS = WM_APP + 5;
static const wchar_t* g_pendingStatus = nullptr;
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

/// 断线/重连状态提示，复用同一条提示条
static void ShowStatusHint(const wchar_t* text) {
    g_hintText = text;
    ShowFullscreenHint();
}

/// 从网络线程请求 UI 线程显示状态提示（提示窗只能在 UI 线程碰）
static void ShowStatusHintAsync(const wchar_t* text) {
    g_pendingStatus = text;
    if (g_hwnd) PostMessageW(g_hwnd, WM_APP_SHOW_STATUS, 0, 0);
}

static void RestoreDefaultHint() {
    g_hintText = kDefaultHint;
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

// ---------------------------------------------------------------------------
// 控制面板
//
// 独立于投屏窗口的轻量设置页：托盘菜单打开，关闭只隐藏，不影响投屏。
// 状态直接读 g_stats，不额外开线程；开关即时生效，不写回配置文件。
// ---------------------------------------------------------------------------

static HWND g_panel = nullptr;
static Presenter* g_presenter = nullptr;
static std::atomic<bool> g_vsyncEnabled{true};
static std::string g_peerHost = "10.10.10.1";
static int g_peerPort = 9922;
static std::string g_logPath;

// 客户区尺寸变化的防抖同步：拖窗口时会连发 WM_SIZE，
// 每次 ResizeBuffers 都可能撞上呈现线程占着后缓冲，攒到停手再改一次最稳。
static int  g_pendingClientW = 0;
static int  g_pendingClientH = 0;
static int  g_syncSwapRetry = 0;
static const UINT_PTR TIMER_SYNC_SWAP = 4;

static const int IDC_PANEL_STATUS   = 2001;
static const int IDC_PANEL_PEER     = 2002;
static const int IDC_PANEL_SIZE     = 2003;
static const int IDC_PANEL_FPS      = 2004;
static const int IDC_PANEL_MBPS     = 2005;
static const int IDC_PANEL_FAIL     = 2006;
static const int IDC_PANEL_FULL     = 2010;
static const int IDC_PANEL_RECONN   = 2011;
static const int IDC_PANEL_LOG      = 2012;
static const int IDC_PANEL_EXIT     = 2013;
static const int IDC_PANEL_VSYNC    = 2020;
static const int IDC_PANEL_PACE     = 2021;
static const int IDC_PANEL_FEEDBACK = 2022;

static int DpiScale(int v) {
    static int dpi = 0;
    if (dpi == 0) {
        typedef UINT (WINAPI *GetDpiForSystemFn)(void);
        auto fn = (GetDpiForSystemFn)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForSystem");
        dpi = fn ? (int)fn() : 96;
        if (dpi <= 0) dpi = 96;
    }
    return MulDiv(v, dpi, 96);
}

static HFONT PanelFont() {
    static HFONT font = nullptr;
    if (!font) {
        NONCLIENTMETRICSW ncm{};
        ncm.cbSize = sizeof(ncm);
        if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0)) {
            font = CreateFontIndirectW(&ncm.lfMessageFont);
        }
        if (!font) font = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
    }
    return font;
}

static void UpdateControlPanel() {
    if (!g_panel) return;

    static uint64_t lastDecoded = 0, lastBytes = 0;
    static ULONGLONG lastTick = 0;
    ULONGLONG now = GetTickCount64();
    double dt = lastTick ? (double)(now - lastTick) / 1000.0 : 1.0;
    uint64_t decoded = g_stats.decoded.load();
    uint64_t bytes = g_stats.bytes.load();
    double fps = dt > 0.0 ? (double)(decoded - lastDecoded) / dt : 0.0;
    double mbps = dt > 0.0 ? (double)(bytes - lastBytes) * 8.0 / dt / 1e6 : 0.0;
    lastDecoded = decoded;
    lastBytes = bytes;
    lastTick = now;

    bool connected = g_sock.load() != INVALID_SOCKET;
    bool receiving = connected && g_stats.packets.load() > 0;

    wchar_t buf[256];
    swprintf(buf, 256, L"状态: %s",
             receiving ? L"已连接，正在接收" : (connected ? L"已连接，等待画面" : L"未连接，等待重连"));
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_STATUS), buf);

    std::wstring host = ToWide(g_peerHost.c_str(), (int)g_peerHost.size());
    swprintf(buf, 256, L"对端: %s:%d", host.c_str(), g_peerPort);
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_PEER), buf);

    int dw = g_displayW.load(), dh = g_displayH.load();
    if (dw <= 0 || dh <= 0) { dw = g_sessW.load(); dh = g_sessH.load(); }
    swprintf(buf, 256, L"分辨率: %dx%d", dw, dh);
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_SIZE), buf);

    swprintf(buf, 256, L"帧率: %.1f fps", fps);
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_FPS), buf);

    swprintf(buf, 256, L"码率: %.1f Mbps", mbps);
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_MBPS), buf);

    swprintf(buf, 256, L"解码失败: %llu", (unsigned long long)g_stats.decodeFail.load());
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_FAIL), buf);

    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_FULL),
                   g_isFullscreen ? L"回到窗口" : L"全屏");
}

static LRESULT CALLBACK PanelWndProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CREATE: {
        HFONT font = PanelFont();
        auto mk = [&](const wchar_t* cls, const wchar_t* text, DWORD style,
                      int x, int y, int cw, int ch, int id) -> HWND {
            HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style,
                                     DpiScale(x), DpiScale(y), DpiScale(cw), DpiScale(ch),
                                     h, (HMENU)(INT_PTR)id, GetModuleHandleW(nullptr), nullptr);
            if (c && font) SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
            return c;
        };

        mk(L"STATIC", L"连接状态", SS_LEFT, 20, 16, 200, 24, 0);
        mk(L"STATIC", L"状态: --", SS_LEFT, 20, 48, 420, 24, IDC_PANEL_STATUS);
        mk(L"STATIC", L"对端: --", SS_LEFT, 20, 80, 420, 24, IDC_PANEL_PEER);
        mk(L"STATIC", L"分辨率: --", SS_LEFT, 20, 112, 420, 24, IDC_PANEL_SIZE);
        mk(L"STATIC", L"帧率: --", SS_LEFT, 20, 144, 420, 24, IDC_PANEL_FPS);
        mk(L"STATIC", L"码率: --", SS_LEFT, 20, 176, 420, 24, IDC_PANEL_MBPS);
        mk(L"STATIC", L"解码失败: --", SS_LEFT, 20, 208, 420, 24, IDC_PANEL_FAIL);

        mk(L"BUTTON", L"全屏", BS_PUSHBUTTON, 20, 252, 130, 36, IDC_PANEL_FULL);
        mk(L"BUTTON", L"重新连接", BS_PUSHBUTTON, 165, 252, 130, 36, IDC_PANEL_RECONN);
        mk(L"BUTTON", L"打开日志", BS_PUSHBUTTON, 310, 252, 130, 36, IDC_PANEL_LOG);
        mk(L"BUTTON", L"退出 SecDisplay", BS_PUSHBUTTON, 20, 300, 130, 36, IDC_PANEL_EXIT);

        HWND vs = mk(L"BUTTON", L"垂直同步", BS_AUTOCHECKBOX, 20, 360, 220, 28, IDC_PANEL_VSYNC);
        HWND pc = mk(L"BUTTON", L"抖动缓冲", BS_AUTOCHECKBOX, 20, 396, 220, 28, IDC_PANEL_PACE);
        HWND fb = mk(L"BUTTON", L"反馈", BS_AUTOCHECKBOX, 20, 432, 220, 28, IDC_PANEL_FEEDBACK);
        if (vs) SendMessageW(vs, BM_SETCHECK, g_vsyncEnabled.load() ? BST_CHECKED : BST_UNCHECKED, 0);
        if (pc) SendMessageW(pc, BM_SETCHECK, g_paceEnabled.load() ? BST_CHECKED : BST_UNCHECKED, 0);
        if (fb) SendMessageW(fb, BM_SETCHECK, g_feedbackEnabled.load() ? BST_CHECKED : BST_UNCHECKED, 0);

        mk(L"STATIC", L"Esc 退出    Ctrl+Alt+H 让位    F11 全屏", SS_LEFT, 20, 490, 420, 24, 0);
        SetTimer(h, 1, 1000, nullptr);
        return 0;
    }
    case WM_TIMER:
        if (w == 1) UpdateControlPanel();
        return 0;
    case WM_CTLCOLORSTATIC:
        // 静态文本默认用 COLOR_BTNFACE 画背景，会显示成一块块灰底；
        // 改成透明背景加窗口底色，和面板融为一体
        SetBkMode((HDC)w, TRANSPARENT);
        SetTextColor((HDC)w, GetSysColor(COLOR_WINDOWTEXT));
        return (LRESULT)GetSysColorBrush(COLOR_WINDOW);
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case IDC_PANEL_FULL:
            if (g_hwnd) PostMessageW(g_hwnd, WM_COMMAND, ID_TRAY_TOGGLE, 0);
            return 0;
        case IDC_PANEL_RECONN: {
            SOCKET s = g_sock.load();
            if (s != INVALID_SOCKET) {
                Log("控制面板请求重新连接");
                shutdown(s, SD_BOTH);
            }
            return 0;
        }
        case IDC_PANEL_LOG:
            if (!g_logPath.empty()) {
                std::wstring path = ToWide(g_logPath.c_str(), (int)g_logPath.size());
                ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            } else {
                MessageBoxW(h, L"当前没有配置日志文件（--log）", L"SecDisplay",
                            MB_OK | MB_ICONINFORMATION);
            }
            return 0;
        case IDC_PANEL_EXIT:
            if (g_hwnd) PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
            return 0;
        case IDC_PANEL_VSYNC:
            g_vsyncEnabled = (SendMessageW((HWND)l, BM_GETCHECK, 0, 0) == BST_CHECKED);
            if (g_presenter) g_presenter->setUseVsync(g_vsyncEnabled.load());
            Log("控制面板: 垂直同步 %s", g_vsyncEnabled.load() ? "开" : "关");
            return 0;
        case IDC_PANEL_PACE:
            g_paceEnabled = (SendMessageW((HWND)l, BM_GETCHECK, 0, 0) == BST_CHECKED);
            Log("控制面板: 抖动缓冲 %s", g_paceEnabled.load() ? "开" : "关");
            return 0;
        case IDC_PANEL_FEEDBACK:
            g_feedbackEnabled = (SendMessageW((HWND)l, BM_GETCHECK, 0, 0) == BST_CHECKED);
            Log("控制面板: 反馈 %s", g_feedbackEnabled.load() ? "开" : "关");
            return 0;
        }
        return 0;
    case WM_CLOSE:
        // 只隐藏，不销毁：投屏继续跑，下次从托盘再打开
        ShowWindow(h, SW_HIDE);
        return 0;
    case WM_DESTROY:
        KillTimer(h, 1);
        return 0;
    }
    return DefWindowProcW(h, msg, w, l);
}

static void ShowControlPanel() {
    if (g_panel) {
        ShowWindow(g_panel, SW_SHOW);
        SetForegroundWindow(g_panel);
        UpdateControlPanel();
        return;
    }

    Log("打开控制面板");
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = PanelWndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
        wc.lpszClassName = L"SecDisplayControl";
        wc.hIcon = LoadIconW(nullptr, (LPCWSTR)IDI_APPLICATION);
        RegisterClassExW(&wc);
        registered = true;
    }

    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT rc{ 0, 0, DpiScale(470), DpiScale(540) };
    AdjustWindowRect(&rc, style, FALSE);
    int w = rc.right - rc.left;
    int hgt = rc.bottom - rc.top;
    int x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
    int y = (GetSystemMetrics(SM_CYSCREEN) - hgt) / 2;
    g_panel = CreateWindowExW(WS_EX_APPWINDOW, L"SecDisplayControl", L"SecDisplay 控制面板",
                              style, x, y, w, hgt,
                              nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (g_panel) {
        Log("控制面板已创建 hwnd=%p", (void*)g_panel);
        ShowWindow(g_panel, SW_SHOW);
        SetForegroundWindow(g_panel);
        UpdateControlPanel();
    } else {
        Log("控制面板创建失败 %lu", GetLastError());
    }
}

// 光标要按「屏幕物理像素」绘制：本窗口所在显示器的 DPI 缩放（96 DPI = 1.0）。
// 用 GetDpiForWindow 而不是 GetDpiForSystem：多屏不同缩放时后者只反映系统/主屏。
// 两者都用 GetProcAddress 取，保持与 DpiScale 相同的旧系统兼容路径。
static double WindowDpiScale(HWND hwnd) {
    typedef UINT (WINAPI *GetDpiForWindowFn)(HWND);
    typedef UINT (WINAPI *GetDpiForSystemFn)(void);
    HMODULE u32 = GetModuleHandleA("user32.dll");
    UINT dpi = 0;
    if (u32 && hwnd) {
        auto fn = (GetDpiForWindowFn)GetProcAddress(u32, "GetDpiForWindow");
        if (fn) dpi = fn(hwnd);
    }
    if (dpi == 0 && u32) {
        auto fn = (GetDpiForSystemFn)GetProcAddress(u32, "GetDpiForSystem");
        if (fn) dpi = fn();
    }
    if (dpi == 0) dpi = 96;
    double s = (double)dpi / 96.0;
    if (s < 1.0) s = 1.0;   // 低于 96 DPI 也不缩小，光标只能因为高 DPI 变大
    if (s > 4.0) s = 4.0;   // 上限保护，避免 4x 屏上出现超大指针
    return s;
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
    const int rawW = w, rawH = h, rawHotX = hotX, rawHotY = hotY;   // 原始参数，仅供日志

    // 位图指纹：尺寸 + 热点 + 全像素。同一张位图且缩放没变就不用重建 HCURSOR。
    // 放在缩放之前算，指纹只跟网络收到的原始数据相关，跨 DPI 变化也能复用。
    uint64_t fp = 1469598103934665603ull;
    {
        int key[4] = { w, h, hotX, hotY };
        const uint8_t* kp = (const uint8_t*)key;
        for (size_t i = 0; i < sizeof(key); ++i) { fp ^= kp[i]; fp *= 1099511628211ull; }
        const uint8_t* bp = bgra.data();
        size_t n = (size_t)w * h * 4;
        for (size_t i = 0; i < n; ++i) { fp ^= bp[i]; fp *= 1099511628211ull; }
    }

    // 缩放基准：Mac 送来的位图是 1x 逻辑点（CursorImageTracker 用 NSCursor.size 归一化），
    // 客户区坐标却是物理像素（PER_MONITOR_AWARE_V2）。
    // 旧做法按「客户区 / 流尺寸」缩放是错的：窗口模式客户区固定取屏幕宽度的一半
    // （见窗口创建处的 sw/2），系数恒为 0.5，箭头只剩一半尺寸，肉眼几乎看不见；
    // 全屏时系数恒为 1，又完全不补偿 DPI，在高 DPI 屏上同样偏小。
    // 指针是给用户直接看的，按屏幕物理像素绘制，只乘本显示器的 DPI 缩放。
    // 1600x1000 客户区铺满 1600x1000 流、DPI 100% 时系数正好是 1。
    const double scale = WindowDpiScale(g_hwnd);
    const int scalePm = (int)(scale * 1000.0 + 0.5);
    if (g_customCursor && fp == g_cursorAppliedFp && scalePm == g_cursorAppliedScalePm) {
        return;   // 同一张图同一缩放，沿用现有 HCURSOR
    }

    int w2 = (int)(w * scale + 0.5);
    int h2 = (int)(h * scale + 0.5);
    if (w2 < 1) w2 = 1;
    if (h2 < 1) h2 = 1;
    if (w2 > 256) w2 = 256;
    if (h2 > 256) h2 = 256;
    if (w2 != w || h2 != h) {
        std::vector<uint8_t> dst((size_t)w2 * h2 * 4);
        for (int yy = 0; yy < h2; ++yy) {
            int sy0 = (int)((long long)yy * h / h2);
            if (sy0 >= h) sy0 = h - 1;
            for (int xx = 0; xx < w2; ++xx) {
                int sx0 = (int)((long long)xx * w / w2);
                if (sx0 >= w) sx0 = w - 1;
                memcpy(&dst[((size_t)yy * w2 + xx) * 4],
                       &bgra[((size_t)sy0 * w + sx0) * 4], 4);
            }
        }
        // 热点跟着位图同比例缩放，否则指针尖和实际点击点会错位
        hotX = (int)((double)hotX * (double)w2 / (double)w + 0.5);
        hotY = (int)((double)hotY * (double)h2 / (double)h + 0.5);
        bgra.swap(dst);
        w = w2;
        h = h2;
    }
    // 热点必须落在位图内，越界会让 CreateIconIndirect 造出的指针跑偏或直接不可见
    if (hotX < 0) hotX = 0;
    if (hotY < 0) hotY = 0;
    if (hotX > w - 1) hotX = w - 1;
    if (hotY > h - 1) hotY = h - 1;

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
    if (!cur) return;   // 不更新指纹，下一包重试

    Log("光标位图 %dx%d hot=(%d,%d) 缩放 %.2fx → 实际 %dx%d hot=(%d,%d)",
        rawW, rawH, rawHotX, rawHotY, scale, w, h, hotX, hotY);

    // 先挂上新的再销毁旧的：反过来的话，销毁到 SetCursor 之间系统光标句柄是悬空的
    HCURSOR old = g_customCursor;
    g_customCursor = cur;
    g_cursorAppliedFp = fp;
    g_cursorAppliedScalePm = scalePm;
    if (g_cursorVisible.load()) SetCursor(cur);
    if (old) DestroyCursor(old);
}

// 查询窗口所在显示器的当前刷新率。启动、显示模式变化、窗口跨屏移动时都用它。
static int QueryRefreshHz(HWND hwnd) {
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
    return hz;
}

static void UpdateRefreshHz() {
    int hz = QueryRefreshHz(g_hwnd);
    if (hz > 0 && hz != g_refreshHz) {
        g_refreshHz = hz;
        Log("显示器刷新率变化，更新为 %d Hz", hz);
    }
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_QUERYENDSESSION:
        Log("收到 WM_QUERYENDSESSION（系统注销/关机）");
        return TRUE;
    case WM_ENDSESSION:
        Log("收到 WM_ENDSESSION（会话结束）");
        return 0;
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
    case WM_SIZE:
        // 客户区变了就把交换链跟过去。不跟的话 DWM 会把按流尺寸建的交换链
        // 双线性拉伸到窗口大小，文字边缘就是这么糊的。
        // 拖动时 WM_SIZE 连发，攒 120ms 只改一次，避免和呈现线程抢后缓冲。
        if (w != SIZE_MINIMIZED) {
            g_pendingClientW = LOWORD(l);
            g_pendingClientH = HIWORD(l);
            g_syncSwapRetry = 0;
            SetTimer(h, TIMER_SYNC_SWAP, 120, nullptr);
        }
        return 0;
    case WM_TIMER:
        if (w == TIMER_HINT_HIDE) {
            KillTimer(g_hwnd, TIMER_HINT_HIDE);
            HideFullscreenHint();
            return 0;
        }
        if (w == TIMER_SYNC_SWAP) {
            KillTimer(h, TIMER_SYNC_SWAP);
            if (g_presenter && g_pendingClientW > 0 && g_pendingClientH > 0) {
                if (!g_presenter->Resize(g_pendingClientW, g_pendingClientH)) {
                    // 后缓冲还被呈现线程占着，隔一轮再试，最多 8 次
                    if (++g_syncSwapRetry < 8) {
                        SetTimer(h, TIMER_SYNC_SWAP, 150, nullptr);
                    } else {
                        Log("交换链同步放弃: 目标 %dx%d 连续失败", g_pendingClientW, g_pendingClientH);
                        g_syncSwapRetry = 0;
                    }
                }
            }
            return 0;
        }
        break;
    case WM_APP_HIDE_HINT:
        HideFullscreenHint();
        return 0;
    case WM_APP_SHOW_STATUS:
        if (g_pendingStatus) ShowStatusHint(g_pendingStatus);
        return 0;
    case WM_APPLY_CURSOR:
        // 网络线程收到 0x05 后 post 到这里，HCURSOR 创建/销毁统一在 UI 线程
        ApplyCursorImage();
        return 0;
    case WM_APP_CURSOR_VIS:
        // 0x03 的可见性变化：离开副屏就隐藏，回来就恢复自定义光标
        if (g_cursorVisible.load()) {
            SetCursor(g_customCursor ? g_customCursor : LoadCursor(nullptr, IDC_ARROW));
        } else {
            SetCursor(nullptr);
        }
        return 0;
    case WM_DISPLAYCHANGE:
    case WM_EXITSIZEMOVE:
        // 显示模式变化或窗口跨屏移动后，刷新率可能变了，--pace 的节拍要跟着更新
        UpdateRefreshHz();
        return 0;
    case WM_DPICHANGED:
        // 窗口被拖到另一块缩放不同的显示器：按新 DPI 重建光标位图。
        // 原始位图仍留在 g_cursorImage.bgra，只是 pending 已被清掉，这里重新置位。
        {
            std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
            if (!g_cursorImage.bgra.empty()) g_cursorImage.pending = true;
        }
        ApplyCursorImage();
        break;   // 窗口位置/尺寸仍交给 DefWindowProc
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
        // 标记这次移动是程序发起的，随后的 WM_MOUSEMOVE 只在落点等于目标点时才忽略
        int sx = tl.x + (int)(cx / vw * cw);
        int sy = tl.y + (int)(cy / vh * ch);
        g_lastRemoteCursorX = sx;
        g_lastRemoteCursorY = sy;
        g_lastRemoteCursorMoveMs = GetTickCount64();
        SetCursorPos(sx, sy);
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
        case ID_TRAY_PANEL:  ShowControlPanel(); return 0;
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
        // 只过滤程序自己 SetCursorPos 产生的那一次移动：时间接近且落点等于目标点。
        // 不能只看时间窗，否则 Mac 光标高频移动时，真实本地移动会被一直吞掉，
        // g_lastLocalInputMs 永不刷新，本地鼠标无法在 250ms 后抢回控制权。
        POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        ClientToScreen(h, &pt);
        if (GetTickCount64() - (uint64_t)g_lastRemoteCursorMoveMs.load() < 50 &&
            pt.x == g_lastRemoteCursorX.load() && pt.y == g_lastRemoteCursorY.load()) {
            return 0;
        }
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
            // 两次滚轮落在同一个 4ms 窗口时累加，避免高精度滚轮丢格
            int acc = (int)g_pendingWheel.load() - delta;
            if (acc > 32767) acc = 32767;
            if (acc < -32768) acc = -32768;
            g_pendingWheel = (int16_t)acc;
            g_eventPending = true;   // 滚轮事件由 inputThread 立即发
        }
        return 0;
    }
    case WM_SETCURSOR:
        // 光标已离开副屏（Mac 发过 visible=0）时不画任何光标
        if (!g_cursorVisible.load()) {
            SetCursor(nullptr);
            return TRUE;
        }
        // 有 Mac 真实光标就用它，否则退回标准箭头
        SetCursor(g_customCursor ? g_customCursor : LoadCursor(nullptr, IDC_ARROW));
        return TRUE;
    case WM_SYSCOMMAND:
        // 窗口模式的「最大化」按钮 / Win+↑ 都接到整屏放大（EnterFullscreen）。
        // 交换链尺寸由 WM_SIZE 的防抖同步跟上，不再固定在流尺寸上硬拉伸。
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
    bool pace = false;        // --pace：1~3 帧抖动缓冲，按自适应节拍上屏，抹平源端小抖动
    bool feedback = false;    // --feedback：每 2 秒向 Mac 回传 0x07 健康度，供自适应码率环使用
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
        } else if (a == "--feedback") {
            cfg.feedback = true;
        } else if ((a == "--log" || a == "-l") && i + 1 < argc) {
            cfg.logFile = argv[++i];
        } else if (a == "--config" && i + 1 < argc) {
            ++i;   // 配置文件已在 main 里读过，这里只跳过它的值
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

// ---------------------------------------------------------------------------
// 配置文件与免参数启动
//
// exe 同目录的 config.ini，键值形如 key=value，# 或 ; 开头为注释。
// 命令行参数优先级高于配置文件，便于临时覆盖。
// ---------------------------------------------------------------------------

static std::string TrimStr(const std::string& s) {
    size_t b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return "";
    size_t e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

static std::string ExeDir() {
    char buf[MAX_PATH] = {};
    DWORD n = GetModuleFileNameA(nullptr, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return ".";
    std::string p(buf, n);
    size_t pos = p.find_last_of("\\/");
    return pos == std::string::npos ? "." : p.substr(0, pos);
}

static bool Truthy(const std::string& v) {
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

static void LoadConfigFile(RunConfig& cfg, const std::string& path) {
    std::ifstream f(path);
    if (!f) return;
    std::string line;
    int applied = 0;
    while (std::getline(f, line)) {
        // 记事本保存的 UTF-8 可能带 BOM，不去掉会让第一个键名匹配失败
        if (line.size() >= 3 &&
            (unsigned char)line[0] == 0xEF &&
            (unsigned char)line[1] == 0xBB &&
            (unsigned char)line[2] == 0xBF) {
            line.erase(0, 3);
        }
        line = TrimStr(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = TrimStr(line.substr(0, eq));
        std::string val = TrimStr(line.substr(eq + 1));
        std::transform(key.begin(), key.end(), key.begin(),
                       [](unsigned char c) { return (char)std::tolower(c); });
        if (key == "host") cfg.host = val;
        else if (key == "port") cfg.port = atoi(val.c_str());
        else if (key == "width") cfg.width = atoi(val.c_str());
        else if (key == "height") cfg.height = atoi(val.c_str());
        else if (key == "log") cfg.logFile = val;
        else if (key == "fullscreen") cfg.fullscreen = Truthy(val);
        else if (key == "vsync") cfg.vsync = Truthy(val);
        else if (key == "pace") cfg.pace = Truthy(val);
        else if (key == "feedback") cfg.feedback = Truthy(val);
        else if (key == "coordw") cfg.coordW = atoi(val.c_str());
        else if (key == "coordh") cfg.coordH = atoi(val.c_str());
        else continue;
        ++applied;
    }
    Log("已读取配置 %s（%d 项）", path.c_str(), applied);
}

// ---------------------------------------------------------------------------
// 会话头与分辨率自适应
// ---------------------------------------------------------------------------

// 0x06 会话头：尺寸与当前管线不同就断开当前连接，让 NetworkLoop 在下一轮
// 用新尺寸重建解码器、交换链与窗口。不在这里直接重建，是因为此刻解码与
// 呈现线程都还在跑，ResizeBuffers 会因后缓冲被引用而失败。
static void OnSessionPacket(const uint8_t* p, size_t n) {
    if (n < SESSION_PAYLOAD_BYTES) return;   // 旧版空载荷心跳
    uint8_t ver = p[0];
    int w = (int)((p[1] << 8) | p[2]);
    int h = (int)((p[3] << 8) | p[4]);
    int fps = (int)p[5];
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return;
    if (g_sessW.load() == w && g_sessH.load() == h && g_sessFps.load() == fps) return;

    g_sessW = w; g_sessH = h; g_sessFps = fps;
    Log("会话头: 协议 v%u  虚拟屏 %dx%d @ %d fps", ver, w, h, fps);

    int dw = g_displayW.load(), dh = g_displayH.load();
    if (w != dw || h != dh) {
        Log("与当前管线 %dx%d 不一致，断开重连后按新尺寸重建", dw, dh);
        SOCKET s = g_sock.load();
        if (s != INVALID_SOCKET) shutdown(s, SD_BOTH);
    }
}

// 窗口模式下把客户区直接设成流的尺寸，做到 1:1 上屏。
// 放不下时按比例缩到工作区的 90%，此时交给 VideoProcessor 做一次等比缩放。
static void ResizeWindowForVideo(int w, int h) {
    if (!g_hwnd || g_isFullscreen || w <= 0 || h <= 0) return;

    int maxW = w, maxH = h;
    HMONITOR mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{}; mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, &mi)) {
        maxW = (mi.rcWork.right - mi.rcWork.left) * 9 / 10;
        maxH = (mi.rcWork.bottom - mi.rcWork.top) * 9 / 10;
    }

    int cw = w, ch = h;
    if (cw > maxW || ch > maxH) {
        const double s = std::min((double)maxW / w, (double)maxH / h);
        cw = (int)(w * s + 0.5);
        ch = (int)(h * s + 0.5);
    }
    if (cw < 160) cw = 160;
    if (ch < 100) ch = 100;

    RECT wr{ 0, 0, cw, ch };
    AdjustWindowRect(&wr, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX, FALSE);
    int winW = wr.right - wr.left, winH = wr.bottom - wr.top;
    RECT cur{};
    GetWindowRect(g_hwnd, &cur);
    SetWindowPos(g_hwnd, nullptr, cur.left, cur.top, winW, winH, SWP_NOZORDER | SWP_NOACTIVATE);
    Log("窗口按流尺寸调整: 客户区 %dx%d（流 %dx%d）", cw, ch, w, h);
}

static void NetworkLoop(RunConfig cfg, Graphics* gfx, Presenter* presenter) {
    // 还没连上时先给一个明确的等待状态，避免全屏黑屏被当成卡死
    presenter->ClearToIdle();
    ShowStatusHintAsync(L"等待 Mac 发送端…");
    // 交换链改尺寸失败过的尺寸，避免每次重连都反复尝试同一个值
    int failedW = 0, failedH = 0;
    while (g_alive) {
        // 会话头切档：尺寸与当前管线不同就重建解码器、交换链与窗口
        int sw = g_sessW.load(), sh = g_sessH.load();
        if (sw > 0 && sh > 0 && (sw != cfg.width || sh != cfg.height) &&
            !(sw == failedW && sh == failedH)) {
            if (presenter->Resize(sw, sh)) {
                cfg.width = sw; cfg.height = sh;
                g_displayW = sw; g_displayH = sh;
                if (cfg.coordW <= 0) { g_coordW = sw; g_coordH = sh; }
                ResizeWindowForVideo(sw, sh);
                Log("按会话头切换管线尺寸: %dx%d", sw, sh);
            } else {
                failedW = sw; failedH = sh;
            }
        }

        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) {
            Log("socket 失败 %d，2 秒后重试", WSAGetLastError());
            SleepAlive(2000);
            continue;
        }

        int nodelay = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
        int rcvbuf = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (const char*)&rcvbuf, sizeof(rcvbuf));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((u_short)cfg.port);
        // inet_pton 失败时 sin_addr 会留在 0.0.0.0，Windows 上等于连本机，
        // 会连到本机 9922 上任意监听者，看起来就像「显示的是别的屏」。必须检查返回值。
        if (inet_pton(AF_INET, cfg.host.c_str(), &addr.sin_addr) != 1) {
            Log("主机名无法解析为 IPv4: %s（请直接填 IP）", cfg.host.c_str());
            closesocket(sock);
            if (!cfg.reconnect) break;
            SleepAlive(2000);
            continue;
        }

        Log("连接 %s:%d ...", cfg.host.c_str(), cfg.port);
        // 非阻塞 connect + 2 秒超时：Mac 没开机时 IP 不可达，阻塞 connect 会卡十几秒，
        // 退出时 net.join 也跟着等，表现成「点了退出没反应」。
        u_long nb = 1;
        ioctlsocket(sock, FIONBIO, &nb);
        int rc = connect(sock, (sockaddr*)&addr, sizeof(addr));
        bool connected = (rc == 0);
        if (!connected) {
            int err = WSAGetLastError();
            if (err == WSAEWOULDBLOCK) {
                fd_set wf;
                FD_ZERO(&wf);
                FD_SET(sock, &wf);
                timeval tv{ 2, 0 };
                int sel = select(0, nullptr, &wf, nullptr, &tv);
                if (sel > 0) {
                    int soErr = 0, soLen = (int)sizeof(soErr);
                    getsockopt(sock, SOL_SOCKET, SO_ERROR, (char*)&soErr, &soLen);
                    connected = (soErr == 0);
                    if (!connected) Log("连接失败 %d", soErr);
                } else if (sel == 0) {
                    Log("连接超时（2 秒）");
                } else {
                    Log("连接失败 %d", WSAGetLastError());
                }
            } else {
                Log("连接失败 %d", err);
            }
        }
        if (!connected) {
            closesocket(sock);
            if (!cfg.reconnect) break;
            ShowStatusHintAsync(L"等待 Mac 发送端…");
            SleepAlive(2000);
            continue;
        }
        nb = 0;
        ioctlsocket(sock, FIONBIO, &nb);
        Log("已连接，目标 %dx%d", cfg.width, cfg.height);
        g_sock = sock;
        RestoreDefaultHint();
        HideFullscreenHint();

        // 给 recv 设超时，退出时即便漏了 shutdown，阻塞的 recv 也会在
        // 500ms 内返回，让收流线程能轮询 g_alive 后退出（避免 net.join 卡死）。
        DWORD recvTimeoutMs = 500;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                   (const char*)&recvTimeoutMs, sizeof(recvTimeoutMs));
        // 发送也要有超时。半开连接或对端不读时，阻塞 send 会卡住 inputThread，
        // 退出时 join 永久等待，表现成「点退出没反应」。
        DWORD sendTimeoutMs = 500;
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
                   (const char*)&sendTimeoutMs, sizeof(sendTimeoutMs));

        // 复位统计，重连后从头计数
        g_stats.packets = 0; g_stats.bytes = 0; g_stats.decoded = 0;
        g_stats.presented = 0; g_stats.dropped = 0; g_stats.paced = 0; g_stats.decodeFail = 0;
        g_stats.presentFail = 0; g_stats.dupFrame = 0;
        ResetPresentRing();
        ResetDecodeRing();
        g_lastDecodeMs = 0.0;
        g_stats.lastLatencyUs = 0;
        ResetTimestampBase();

        // 立刻请求关键帧，否则解码器拿不到 SPS/PPS，黑屏
        {
            uint8_t req = TYPE_KEYFRAME_REQUEST;
            int sent = 0;
            {
                std::lock_guard<std::mutex> lk(g_sendMtx);
                sent = send(sock, (const char*)&req, 1, 0);
            }
            if (sent == 1) Log("已请求关键帧（0x02）");
        }

        Decoder decoder;
        if (!decoder.Init(gfx, cfg.width, cfg.height)) {
            Log("解码器初始化失败，断开重试");
            if (g_sock.load() == sock) g_sock = INVALID_SOCKET;
            closesocket(sock);
            if (!cfg.reconnect) break;
            SleepAlive(2000);
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
        // 同帧重复诊断：Mac 静止时不重编，而是把最后一帧原样重发（保活）。
        // 字节完全相同说明源端没有新画面，接收端再怎么解码上屏也只是同一张旧图。
        size_t lastPayloadLen = 0;
        uint64_t lastPayloadHash = 0;

        // 收流 + 解码线程
        std::thread recv([&] {
            while (g_alive && connAlive) {
                uint32_t len = 0;
                if (!RecvAll(sock, &len, 4)) {
                    Log("收流结束：读包头失败 err=%d", WSAGetLastError());
                    break;
                }
                len = ntohl(len);
                if (len < HEADER_BYTES || len > MAX_PACKET) {
                    Log("包长度异常 %u，断开", len);
                    break;
                }
                packet.resize(len);
                if (!RecvAll(sock, packet.data(), (int)len)) {
                    Log("收流结束：读载荷失败 err=%d len=%u", WSAGetLastError(), len);
                    break;
                }

                if (packet[0] == TYPE_CURSOR) {
                    g_stats.cursor++;
                    OnCursorPacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_CURSOR_IMAGE) {
                    OnCursorImagePacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_SESSION) {
                    OnSessionPacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                // 其它未知类型：忽略即可，TCP 已有数据流动
                if (packet[0] != TYPE_VIDEO) continue;

                uint64_t ts = 0;
                for (int i = 0; i < 8; ++i) ts = (ts << 8) | packet[1 + i];

                g_stats.packets++;
                g_stats.bytes += len;
                g_lastVideoPacketMs.store(QpcNowMs());

                // 同帧重复诊断：哈希编码载荷（不含包头时间戳），和上一帧比对。
                // Mac 的保活会原样重发最后一帧，时间戳是新的、字节完全一样，
                // 这条计数能在日志里把「有帧但画面不动」和「真的没帧」区分开。
                {
                    const uint8_t* pb = packet.data() + HEADER_BYTES;
                    size_t pn = len - HEADER_BYTES;
                    uint64_t h = 14695981039346656037ull;   // FNV-1a 64 偏移基
                    for (size_t i = 0; i < pn; ++i) { h ^= pb[i]; h *= 1099511628211ull; }
                    if (pn == lastPayloadLen && h == lastPayloadHash) g_stats.dupFrame++;
                    lastPayloadLen = pn;
                    lastPayloadHash = h;
                }

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
                    if (old) {
                        // pace 模式下 latest 被新帧取代属于节拍主动丢帧，不计入拥塞丢帧，
                        // 否则 Mac 的 dropLoad 会把节拍代价误判成网络拥塞。
                        if (g_paceEnabled.load()) g_stats.paced++;
                        else g_stats.dropped++;
                        old->Release();
                    }
                    latestCv.notify_one();
                }
            }
            connAlive = false;
            latestCv.notify_all();
        });

        // 呈现线程：默认只上屏最新帧。慢于解码时中间帧被丢，不影响解码参考链。
        // --pace 时改为「1~3 帧缓冲 + 自适应节拍」：先预填一帧，再按源端平均帧间隔
        // 定期上屏，把偶发的双倍间隔吸收掉。代价是增加约 1~3 帧延迟。
        std::thread present([&] {
            struct PendingFrame { IMFSample* smp; int w; int h; };
            std::deque<PendingFrame> pending;
            double lastPresentMs = 0.0;
            bool primed = false;
            // 看门狗状态：连接起点用于「一帧都没上过」的初始宽限；
            // idleCleared 保证清屏和提示只做一次，恢复后再复位。
            const double connStartMs = QpcNowMs();
            const double kNoPresentLimitMs = 2000.0;
            bool idleCleared = false;

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
                        // 必须带超时：完全没有新帧时（源端停发、只发心跳）也要定期
                        // 醒来看门狗，否则这一等就是永久，画面永远停在旧帧上。
                        double blockMs = timed ? waitMs : 200.0;
                        if (blockMs < 20.0) blockMs = 20.0;
                        latestCv.wait_for(lk, std::chrono::duration<double, std::milli>(blockMs),
                                          [&] { return hasLatest || !connAlive || !g_alive; });
                    }
                    if (hasLatest) {
                        pending.push_back({ latest.smp, latest.srcW, latest.srcH });
                        latest.smp = nullptr; hasLatest = false;
                    }
                }
                if (!g_alive || !connAlive) break;

                // 看门狗：连接还在、包也还在来，但连续 2 秒没有一次成功 Present，
                // 说明卡在呈现路径（交换链失效、设备移除、Blt 持续失败）。
                // FLIP 交换链不 Present 就永远显示最后一个后缓冲，必须主动清屏，
                // 否则用户看到的是很久以前的旧帧，还会误判成「显示的是别的屏」。
                {
                    double nowMs = QpcNowMs();
                    double good = g_lastGoodPresentMs.load();
                    double pkt = g_lastVideoPacketMs.load();
                    double sinceGood = (good > 0.0) ? (nowMs - good) : (nowMs - connStartMs);
                    double sincePkt = (pkt > 0.0) ? (nowMs - pkt) : (nowMs - connStartMs);
                    // 有视频包在来但 2 秒上不了屏：卡在呈现路径。
                    // 一个包都没有：给 8 秒宽限，避免源端静止桌面（本来就不出帧）被误判。
                    const bool lost = (sincePkt <= 1500.0 && sinceGood >= kNoPresentLimitMs) ||
                                      sinceGood >= 8000.0;
                    if (!idleCleared && lost) {
                        idleCleared = true;
                        Log("看门狗: %.1f 秒没有成功上屏（%.1f 秒无视频包），清屏并提示无信号",
                            sinceGood / 1000.0, sincePkt / 1000.0);
                        presenter->ClearToIdle();
                        ShowStatusHint(L"无信号，等待画面…");
                    }
                }

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
                const bool shown = presenter->PresentSample(f.smp);
                f.smp->Release();
                if (shown && idleCleared) {
                    idleCleared = false;
                    RestoreDefaultHint();
                    HideFullscreenHint();
                    Log("看门狗: 画面已恢复");
                }
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
            uint64_t lastDup = 0;
            int dupWarnCount = 0;
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
                uint64_t dropDelta = dr - lastDropped;
                uint64_t pacedDelta = pc - lastPaced;
                uint64_t dup = g_stats.dupFrame;
                uint64_t dupDelta = dup - lastDup;
                lastDup = dup;
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
                    "  %.1f Mbps  附加延迟 %.1f ms  解码失败 %llu  上屏失败 %llu"
                    "  同帧重复 +%llu  光标+%llu  输入 %llu",
                    (unsigned long long)g_stats.packets,
                    (unsigned long long)d,
                    (unsigned long long)(d - lastDecoded),
                    curFps,
                    peakFps,
                    (unsigned long long)(p - lastPresented),
                    (unsigned long long)dropDelta,
                    d50, d95,
                    p50, p95,
                    g_paceTargetMs.load(),
                    (unsigned long long)pacedDelta,
                    mbps,
                    g_stats.lastLatencyUs / 1000.0,
                    (unsigned long long)g_stats.decodeFail,
                    (unsigned long long)g_stats.presentFail,
                    (unsigned long long)dupDelta,
                    (unsigned long long)(curPkts - lastCursor),
                    (unsigned long long)g_stats.inputSent.load());
                // 连续收到字节完全相同的编码帧：源端在重发最后一帧，画面不会更新。
                // 每 5 个窗口（约 10 秒）提示一次，避免刷屏。
                if (dupDelta >= 3 && (d - lastDecoded) > 0 && (++dupWarnCount % 5) == 1) {
                    Log("注意: 本窗口 %llu 帧与上一帧编码数据完全相同，"
                        "源端在重发最后一帧（画面不会更新）", (unsigned long long)dupDelta);
                }
                lastCursor = curPkts;
                lastPresented = p;
                lastDropped = dr;
                lastPaced = pc;

                // 可选：把接收端健康度回传给 Mac，供自适应码率环使用。
                // 只回传本窗口的统计，不做判断；由 Mac 侧决定是否调码率。
                if (g_feedbackEnabled.load()) {
                    auto clamp16 = [](double v) -> uint16_t {
                        if (v < 0.0) v = 0.0;
                        if (v > 65535.0) v = 65535.0;
                        return (uint16_t)(v + 0.5);
                    };
                    auto clamp16u = [](uint64_t v) -> uint16_t {
                        return (uint16_t)(v > 65535 ? 65535 : v);
                    };
                    g_fbPresentP95.store(clamp16(p95));
                    g_fbSourceP95.store(clamp16(d95));
                    g_fbDecodeFps10.store(clamp16(curFps * 10.0));
                    g_fbPresentDrop.store(clamp16u(dropDelta));
                    g_fbPacedDrop.store(clamp16u(pacedDelta));
                    g_feedbackPending.store(true);
                }

                if (d == lastDecoded) {
                    ++stallRounds;
                    // 静止桌面不要每 2 秒都请求 IDR：Mac 的补帧逻辑会真的编一帧，
                    // 造成周期性码率尖峰。第一次立即请求，之后每 5 轮（约 10 秒）一次。
                    if (stallRounds == 1 || stallRounds % 5 == 0) {
                        uint8_t req = TYPE_KEYFRAME_REQUEST;
                        int sent = 0;
                        {
                            std::lock_guard<std::mutex> lk(g_sendMtx);
                            sent = send(sock, (const char*)&req, 1, 0);
                        }
                        if (sent == 1) {
                            Log("无新帧 %d 轮，重新请求关键帧（0x02）", stallRounds);
                        }
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

        // 断线必须把画面清掉并给出提示。否则 FLIP 交换链会一直显示最后一帧，
        // 用户看到的是几分钟前的旧画面，容易误判成「显示的是别的屏」。
        presenter->ClearToIdle();
        if (g_alive) ShowStatusHint(L"连接已断开，2 秒后重连…");

        decoder.Shutdown();
        if (g_sock.load() == sock) g_sock = INVALID_SOCKET;
        shutdown(sock, SD_BOTH);
        closesocket(sock);

        if (!g_alive) break;
        Log("连接结束");
        if (!cfg.reconnect) break;
        Log("2 秒后重连");
        SleepAlive(2000);
    }
    Log("网络循环退出");
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

// 未处理异常/terminate 时尽量留一行日志，便于区分崩溃与外部终止。
static LONG WINAPI CrashFilter(EXCEPTION_POINTERS* ep) {
    if (ep && ep->ExceptionRecord) {
        Log("未处理异常: code=%08X addr=%p",
            ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress);
    } else {
        Log("未处理异常: 无异常记录");
    }
    return EXCEPTION_EXECUTE_HANDLER;
}

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
    // 免参数启动：先读 exe 同目录 config.ini，再让命令行覆盖。
    // --config 指定别的文件，--no-config 跳过配置文件。
    std::string cfgPath = ExeDir() + "\\config.ini";
    bool useConfigFile = true;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--config" && i + 1 < argc) cfgPath = argv[++i];
        else if (a == "--no-config") useConfigFile = false;
    }
    if (useConfigFile) LoadConfigFile(cfg, cfgPath);
    ParseArgs(argc, argv, cfg);

    // 单实例。旧实例被新实例踢掉后收流线程退出、交换链停止 Present，
    // 窗口会永久停在最后一帧，看起来就像「显示的是别的屏」。
    // 这里直接拒绝第二个实例，并把已有窗口提到前台。
    {
        HANDLE instMutex = CreateMutexW(nullptr, TRUE, L"Global\\SecDisplayReceiver");
        if (instMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
            HWND existing = FindWindowA("SecDisplayReceiver", nullptr);
            if (existing) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
            Log("已有接收端实例在运行，本次启动退出（避免两个实例互踢留下冻结窗口）");
            return 0;
        }
    }

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

    SetUnhandledExceptionFilter(CrashFilter);
    std::set_terminate([] {
        Log("std::terminate 被调用");
        std::abort();
    });

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
        // 窗口模式：客户区直接取流尺寸，1:1 上屏。放不下就按比例缩到工作区的 90%，
        // 这时由 VideoProcessor 做一次等比缩放，比让 DWM 拉伸清楚得多。
        int maxW = GetSystemMetrics(SM_CXSCREEN) * 9 / 10;
        int maxH = GetSystemMetrics(SM_CYSCREEN) * 9 / 10;
        int ww = cfg.width, wh = cfg.height;
        if (ww > maxW || wh > maxH) {
            const double s = std::min((double)maxW / ww, (double)maxH / wh);
            ww = (int)(ww * s + 0.5);
            wh = (int)(wh * s + 0.5);
        }
        RECT rc{ 0, 0, ww, wh };
        AdjustWindowRect(&rc, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX, FALSE);
        int winW = rc.right - rc.left;
        int winH = rc.bottom - rc.top;
        hwnd = CreateWindowExA(WS_EX_APPWINDOW, "SecDisplayReceiver", "SecDisplay",
                               WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_VISIBLE,
                               (GetSystemMetrics(SM_CXSCREEN) - winW) / 2,
                               (GetSystemMetrics(SM_CYSCREEN) - winH) / 2,
                               winW, winH,
                               nullptr, nullptr, wc.hInstance, nullptr);
    }
    if (!hwnd) { Log("窗口创建失败"); return 3; }
    g_hwnd = hwnd;
    g_isFullscreen = cfg.fullscreen;   // 与启动模式对齐，F11 首次切换才正确

    // 记录显示器刷新率：判断源帧率与刷新率是否成整数比，是 vsync 顿挫的前提。
    {
        int hz = QueryRefreshHz(hwnd);
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
    {
        // 交换链按客户区物理像素建，和窗口一一对应，DWM 不再二次拉伸。
        RECT crc{};
        GetClientRect(hwnd, &crc);
        int cw = crc.right - crc.left;
        int ch = crc.bottom - crc.top;
        if (cw <= 0 || ch <= 0) { cw = cfg.width; ch = cfg.height; }
        if (!presenter.Init(&gfx, hwnd, cw, ch)) return 4;
        // 解码尺寸单独告诉呈现器，输入输出从此解耦
        if (!presenter.SetSourceSize(cfg.width, cfg.height)) {
            Log("呈现器设置解码尺寸失败 %dx%d", cfg.width, cfg.height);
            return 4;
        }
    }
    presenter.setUseVsync(cfg.vsync);
    g_presenter = &presenter;
    g_vsyncEnabled = cfg.vsync;
    g_peerHost = cfg.host;
    g_peerPort = cfg.port;
    g_logPath = cfg.logFile;
    Log("呈现方式: %s", cfg.vsync ? "垂直同步（均匀）" : "免同步（低延迟）");
    g_paceEnabled = cfg.pace;
    Log("抖动缓冲: %s", cfg.pace ? "开（1~3 帧缓冲，自适应节拍，增加约 1~3 帧延迟）" : "关（即时上屏，延迟最低）");
    g_feedbackEnabled = cfg.feedback;
    Log("反馈包: %s", cfg.feedback ? "开（0x07 健康度，每 2 秒，供 Mac 自适应码率）" : "关");

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
    // 记录当前管线尺寸，供会话头比较；不一致时 NetworkLoop 会重建
    g_displayW = cfg.width;
    g_displayH = cfg.height;
    Log("坐标基准: 逻辑 %dx%d（物理 %dx%d%s）",
        g_coordW.load(), g_coordH.load(), cfg.width, cfg.height,
        cfg.coordW > 0 ? "，命令行指定" : "，默认对齐物理");

    // 光标跟随已改为事件驱动（见 WM_APP_REMOTE_CURSOR）。
    //
    // 历史：早期这里起过一个 4ms 轮询线程，把 0x03 远程坐标换算到窗口客户区后
    // SetCursorPos。因为 g_lastLocalInputMs 只在副屏内刷新，鼠标回主屏 1 秒后
    // 会被拽回。该线程已移除，不要再加回轮询版。
    //
    // 现在的实现：0x03 位置变化时 PostMessage(WM_APP_REMOTE_CURSOR)，UI 线程在
    // 「窗口在前台 + 本机鼠标 250ms 内没动」两个门控都通过时才 SetCursorPos；
    // g_lastRemoteCursorMoveMs 用来区分程序移动与用户移动，避免门控自锁。
    // 0x05 图像仍由 ApplyCursorImage + WM_SETCURSOR 本地绘制。

    // 输入回传线程：每 4ms 轮询，鼠标移动按 8ms 合并发（约 120Hz），
    // 按键/滚轮事件在下一轮立即发。单线程发送，避免与 UI 线程并发 send 同一 socket。
    std::thread inputThread([] {
        uint64_t lastMoveMs = 0;
        while (g_alive) {
            Sleep((DWORD)INPUT_TICK_MS);
            if (!g_alive) break;
            if (g_sock.load() == INVALID_SOCKET) continue;
            if (g_feedbackEnabled.load() && g_feedbackPending.exchange(false)) {
                SendFeedbackPacket();
            }
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
    if (g_panel) { DestroyWindow(g_panel); g_panel = nullptr; }
    g_presenter = nullptr;
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

    Log("主循环退出，进程结束");
    if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
    return 0;
}
