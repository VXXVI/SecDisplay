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

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _CRT_SECURE_NO_WARNINGS   // fopen/strncpy 等标准函数在 MSVC 下会被警告
#include <windows.h>
#include <windowsx.h>
#include <mmsystem.h>      // timeBeginPeriod(1) 高精度动画定时器
#include <shellapi.h>      // 系统托盘 Shell_NotifyIcon
#include <psapi.h>         // GetProcessMemoryInfo（控制面板显示进程内存）
#include <winsock2.h>
#include <ws2tcpip.h>
#include <commdlg.h>
#include <shlobj.h>
#include <objidl.h>
#include <gdiplus.h>
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
#include <memory>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "gdi32.lib")   // ApplyCursorImage 的 CreateDIBSection/CreateBitmap/DeleteObject

#ifdef _MSC_VER
// 默认以 Windows GUI 子系统运行，消除后台 cmd 黑框；若从已有终端启动则在 main() 开头附着输出
#pragma comment(linker, "/SUBSYSTEM:WINDOWS /ENTRY:mainCRTStartup")
#endif

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

// 解码器描述（硬件/软件 + 友好名），由 Decoder::Init 写入，控制面板读取。
// 放在 Decoder 定义之前，因为 Init 里要写它。
static std::mutex g_decoderInfoMtx;
static std::wstring g_decoderInfo = L"--";

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
    // C++11 magic static 保证多线程首次调用时的初始化安全
    static const double invFreqMs = []() {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return (f.QuadPart > 0) ? (1000.0 / (double)f.QuadPart) : 0.0;
    }();
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return (double)c.QuadPart * invFreqMs;
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
static std::deque<std::wstring> g_recentLogs;
static const size_t kRecentLogCap = 80;

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

    // 环形缓冲供控制面板内嵌「运行日志」实时展示（无需 cmd 黑框）
    {
        std::wstring wline = ToWide(g_logBuf, n);
        if (!wline.empty()) {
            SYSTEMTIME st{};
            GetLocalTime(&st);
            wchar_t ts[20];
            swprintf(ts, 20, L"[%02d:%02d:%02d] ", st.wHour, st.wMinute, st.wSecond);
            g_recentLogs.push_back(std::wstring(ts) + wline);
            while (g_recentLogs.size() > kRecentLogCap) g_recentLogs.pop_front();
        }
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

#include "WinHostSender.hpp"
static secdisplay::WinHostSender g_winHost;

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
// 0x09 键盘事件（接收端 → Mac）。
// 载荷（全大端，6 字节）：[vk u16][scan u16][down u8][flags u8]
//   vk    : Windows 虚拟键码
//   scan  : 硬件扫描码（lParam bits 16-23），扩展键时区分左右 Ctrl/Alt
//   down  : 1=按下 0=抬起
//   flags : bit0 扩展键；bit1 系统键（Alt 组合）
static const uint8_t TYPE_KEY = 0x09;
static const uint8_t TYPE_KVM_MOUSE = 0x0A;
static const uint8_t TYPE_KVM_KEY   = 0x0B;
static const uint8_t TYPE_KVM_STATE = 0x0C;
static const uint8_t TYPE_ROLE_HELLO    = 0x7E;
static const uint8_t TYPE_ROLE_CONFLICT = 0x7F;
static const size_t KEY_PAYLOAD_BYTES = 6;
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
static std::atomic<int> g_sessScaleTenths{0};
// 当前解码/呈现管线实际使用的尺寸。会话头与它不同就断开重连并重建管线。
static std::atomic<int> g_displayW{0};
static std::atomic<int> g_displayH{0};
static std::atomic<double> g_cursorX{-1};
static std::atomic<double> g_cursorY{-1};
// 光标是否在副屏范围内。Mac 端把指针移回主屏时会发 visible=0，
// 这里必须真的把 Windows 光标隐藏，否则它会一直停在最后位置。
static std::atomic<bool> g_cursorVisible{true};
// Mac 光标从「离开副屏」重新回到副屏时置位：下一次 0x03 允许把 Windows 光标拉回画面内，
// 否则用户把指针滑到主屏后就再也收不回来了（远程位置只对画面内生效）。
static std::atomic<bool> g_pullCursorIn{false};
// 程序自己调用 SetCursorPos 会引起 WM_MOUSEMOVE；用时间戳把它和用户真实
// 输入区分开，否则每次跟随都会被当成「用户动了」，导致门控反复自锁。
static std::atomic<int64_t> g_lastRemoteCursorMoveMs{ 0 };
// 程序 SetCursorPos 的目标点与 16 槽位历史环形缓冲，配合 WM_INPUT 硬件鼠标记时，
// 彻底过滤连发覆盖 / 边界舍入 / 异步投递产生的 WM_MOUSEMOVE 回声。
static std::atomic<LONG> g_lastRemoteCursorX{ INT_MIN };
static std::atomic<LONG> g_lastRemoteCursorY{ INT_MIN };
static std::atomic<bool> g_cursorMsgPending{ false };
static std::atomic<uint64_t> g_lastHardwareMouseMs{ 0 };
static bool g_coordUserSpecified = false;

struct RemoteTargetSample { LONG x = 0; LONG y = 0; uint64_t ms = 0; };
static const int kRemoteTargetCap = 16;
static RemoteTargetSample g_remoteTargets[kRemoteTargetCap];
static int g_remoteTargetHead = 0;

static void RecordRemoteTarget(LONG x, LONG y, uint64_t ms) {
    g_remoteTargets[g_remoteTargetHead] = RemoteTargetSample{ x, y, ms };
    g_remoteTargetHead = (g_remoteTargetHead + 1) % kRemoteTargetCap;
}

static bool IsRemoteCursorEcho(LONG x, LONG y, uint64_t nowMs) {
    // 判定「程序自己 SetCursorPos 引起的 WM_MOUSEMOVE」。
    // 窗口必须收得很紧（40ms / 2px），否则远程 60~90Hz 调 SetCursorPos 时，
    // 「用户慢速小幅移动」会被整片吞掉，Mac 端光标不动、点击落在旧位置（体感「点不进去」）。
    // 完全没有硬件鼠标输入时（远程/虚拟输入设备不产生 WM_INPUT），
    // 队列积压可能让回声迟到几十毫秒，这时放宽到 400ms，避免回声被当成真实移动反复回传。
    const bool hwRecent = (nowMs - (uint64_t)g_lastHardwareMouseMs.load() < 300);
    const uint64_t win = hwRecent ? 40u : 400u;
    for (int i = 0; i < kRemoteTargetCap; ++i) {
        const RemoteTargetSample& s = g_remoteTargets[i];
        if (s.ms == 0 || nowMs - s.ms > win) continue;
        if (std::abs(x - s.x) <= 2 && std::abs(y - s.y) <= 2) return true;
    }
    return false;
}

// 真实 Mac 光标图像（0x05）。网络线程只把收到的 BGRA 存进缓冲并 post 消息，
// HCURSOR 的创建/替换/销毁统一在 UI 线程做，避免跨线程句柄竞态。
static const UINT WM_APPLY_CURSOR = WM_APP + 2;
// 0x03 远程光标位置：网络线程 post，UI 线程做门控与 SetCursorPos
static const UINT WM_APP_REMOTE_CURSOR = WM_APP + 3;
// 0x03 的可见性变化：UI 线程据此 SetCursor(cur) 或 SetCursor(nullptr)
static const UINT WM_APP_CURSOR_VIS = WM_APP + 4;
// 投屏状态/最小化/开关变化：UI 线程据此更新 SetThreadExecutionState 防熄屏锁
static const UINT WM_APP_UPDATE_POWER = WM_APP + 6;
// 保持屏幕常亮（防止投屏期间因无 Windows 本地输入而自动熄屏）
static std::atomic<bool> g_keepScreenOn{true};
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
// 1x1 全透明光标：需要「完全不画指针」时用它替代 SetCursor(nullptr)。
// SetCursor(nullptr) 只是隐藏到下一次光标更新，任何 WM_SETCURSOR/系统刷新都会把箭头
// 重新画出来，于是自绘放大光标和系统箭头会同时出现在屏幕上（用户看到的「两个指针」）。
static HCURSOR g_hiddenCursor = nullptr;

// ---- 晃动放大叠加层 ----
// 放大期间不再重建更大的 HCURSOR：一旦超过硬件光标上限，DWM 会退化成软件光标，
// 在 D3D 交换链上拖出残影甚至同时显示两个指针。改为用一个 click-through 的分层窗
// 自己绘制放大后的光标，系统光标在此期间用 1x1 透明光标隐藏，硬件光标始终合规。
static HWND g_zoomOverlay = nullptr;
static bool g_zoomOverlayShown = false;
static int g_zoomOverlayW = 0, g_zoomOverlayH = 0;
static HDC  g_zoomOverlayDC = nullptr;
static HBITMAP g_zoomOverlayBmp = nullptr;
static void* g_zoomOverlayBits = nullptr;

// 最近一次收到的光标精灵（原生分辨率、未缩放），供放大动画从高分辨率源重采样。
static std::mutex g_spriteMtx;
static std::vector<uint8_t> g_nativeSprite;
static int g_nativeW = 0, g_nativeH = 0, g_nativeHotX = 0, g_nativeHotY = 0;
// 稳态「原生像素 → 屏幕物理像素」的实际比例（已含 hwMax 钳位），供放大叠加层作为基准。
static double g_steadySpriteK = 0.0;

// 已建好的 HCURSOR 对应的位图指纹与缩放（千分比）。同一张位图、同一缩放不重建，
// 避免重复的 CreateIconIndirect/DestroyCursor 造成光标闪烁和句柄抖动。
static uint64_t g_cursorAppliedFp = 0;     // 仅 UI 线程访问
static int g_cursorAppliedScalePm = 0;     // 仅 UI 线程访问
static int g_cursorAppliedCap = 0;         // 仅 UI 线程访问
struct CachedCursor { uint64_t fp = 0; int scalePm = 0; int maxSideCap = 0; HCURSOR cur = nullptr; };
static const int kCursorCacheCap = 16;
static CachedCursor g_cursorCache[kCursorCacheCap];
static int g_cursorCacheNext = 0;

static bool IsInCursorCache(HCURSOR c) {
    if (!c) return false;
    for (int i = 0; i < kCursorCacheCap; ++i) {
        if (g_cursorCache[i].cur == c) return true;
    }
    return false;
}

// ---- 快速晃动放大光标（模仿 macOS 的「晃动找光标」）----
// 在副屏上快速左右/上下晃动光标时，Mac 那边看不到你自己的手，容易找不到指针。
// 这里在接收端本地检测晃动：把最近一小段时间的远程光标轨迹存进环形缓冲，
// 统计方向反转次数与横向摆幅，达到阈值就把光标放大若干倍，停下后自动恢复。
// 全部在 UI 线程（WM_APP_REMOTE_CURSOR / WM_TIMER）里做，不额外开线程。
//
// 时序对齐系统行为（参考 Accessibility → 指针 → 「晃动鼠标指针以定位」）：
// 放大是立刻的，停下后保留约 1 秒再收缩，收缩本身是连续的缓动而不是瞬切。
// 原来的实现是硬切，且只靠 120ms 定时器轮询判断结束，实际要 1 秒多才突然变小，
// 观感上就是「变小很慢、还很突兀」。
static const int kShakeWinMs = 600;      // 观察窗口
static const int kShakeMinReversals = 5; // 至少 5 次方向反转才算主动晃动，避免正常鼠标往返误触发放大
static const int kShakeMinSpanPx = 150;  // 横向/纵向累计摆幅下限，防止细微抖动误触
// 曲线对齐 macOS「晃动鼠标指针以定位」：起势快、带轻微过冲，保持后缓入缓出回落。
static const double kShakeCursorZoom = 2.2;  // 目标放大倍数（绘制在叠加层，不受硬件光标上限限制）
static const double kShakeGrowMs = 180.0;    // 起势时长（EaseOutBack，末端轻微过冲）
static const double kShakeHoldMs = 500.0;    // 最后一次指针移动后的保持时长
static const double kShakeShrinkMs = 280.0;  // 回落时长（EaseInOutCubic）
static const double kShakeOvershootC1 = 1.2;  // EaseOutBack 过冲系数（≈3% 峰值过冲）
static const int kShakeTickMs = 16;          // ~60Hz 动画刷新
static const UINT_PTR kShakeTimer = 4004;
struct ShakeSample { int64_t t; int x; int y; };
// 环容量按「发送侧最高 240Hz × 700ms ≈ 170 个样本」留足余量，
// 否则高刷新率下窗口会被截短，慢一点的晃动就检测不到。
static const int kShakeCap = 256;
static ShakeSample g_shakeBuf[kShakeCap];
static int g_shakeCount = 0;
static int g_shakeHead = 0;
enum ShakePhase { SHAKE_IDLE = 0, SHAKE_GROW = 1, SHAKE_HOLD = 2, SHAKE_SHRINK = 3 };
static ShakePhase g_shakePhase = SHAKE_IDLE;
static bool g_shakeActive = false;
// 晃动找光标总开关（可在控制面板关闭）
static std::atomic<bool> g_shakeEnabled{true};
static double g_shakeZoom = 1.0;
static double g_shakeAnimStartMs = 0.0;
static double g_shakeAnimFromZoom = 1.0;
// 最后一次指针位置真正变化的 QPC 时刻（亚毫秒，不受 GetTickCount64 15.6ms 跳变影响）。
// 晃动触发后的 HOLD 以它为起点：指针还在移动就延长保持期，连续静止 kShakeHoldMs 后才收缩。
static double g_shakeLastPointerQpcMs = 0.0;
static double g_shakeLastRefreshQpcMs = 0.0;
static bool g_shakeTimePeriodOn = false;

// 立即结束晃动放大（失焦、改窗口几何、关闭开关等场景）。定义在后面，控制面板需要先用。
static void AbortShake();

static void SetShakeTimePeriod(bool enable) {
    if (enable && !g_shakeTimePeriodOn) {
        if (timeBeginPeriod(1) == TIMERR_NOERROR) g_shakeTimePeriodOn = true;
    } else if (!enable && g_shakeTimePeriodOn) {
        timeEndPeriod(1);
        g_shakeTimePeriodOn = false;
    }
}

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
struct InputEvent {
    float x = 0.0f, y = 0.0f;
    uint8_t buttons = 0;
    int16_t wheel = 0;
};
static std::mutex g_inputQmtx;
static std::deque<InputEvent> g_inputQ;

// 按键/滚轮必须逐条排队发送。旧实现用一个 eventPending 布尔量合并，
// 快速点击的 down/up 落在同一个 4ms tick 时只会发出最终状态（up），
// Mac 端收不到按下，表现就是「点击概率失灵」。
static void QueueInputEvent(float x, float y, uint8_t buttons, int16_t wheel) {
    std::lock_guard<std::mutex> lk(g_inputQmtx);
    if (g_inputQ.size() > 128) g_inputQ.pop_front();
    InputEvent e;
    e.x = x; e.y = y; e.buttons = buttons; e.wheel = wheel;
    g_inputQ.push_back(e);
}

// 键盘事件独立队列：和鼠标事件分开，避免鼠标高频移动把按键挤掉。
struct KeyEvent {
    uint16_t vk = 0;
    uint16_t scan = 0;
    uint8_t down = 0;
    uint8_t flags = 0;
};
static std::mutex g_keyQmtx;
static std::deque<KeyEvent> g_keyQ;

static void QueueKeyEvent(uint16_t vk, uint16_t scan, uint8_t down, uint8_t flags) {
    std::lock_guard<std::mutex> lk(g_keyQmtx);
    if (g_keyQ.size() > 256) g_keyQ.pop_front();
    KeyEvent e;
    e.vk = vk; e.scan = scan; e.down = down; e.flags = flags;
    g_keyQ.push_back(e);
}
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

static bool SendCtrlAllUnderLock(SOCKET s, const uint8_t* p, int len) {
    int sent = 0;
    while (sent < len) {
        int r = send(s, (const char*)(p + sent), len - sent, 0);
        if (r > 0) {
            sent += r;
        } else {
            // 部分写入失败会破坏无前缀控制流边界，立即断开重连防止对端误判
            shutdown(s, SD_BOTH);
            return false;
        }
    }
    return true;
}

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
    SendCtrlAllUnderLock(s, pkt, sizeof(pkt));
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
        SendCtrlAllUnderLock(s, pkt, 12);
    }
    g_stats.inputSent++;
}

static void SendKeyPacket(uint16_t vk, uint16_t scan, uint8_t down, uint8_t flags) {
    SOCKET s = g_sock.load();
    if (s == INVALID_SOCKET) return;
    uint8_t pkt[7];
    pkt[0] = TYPE_KEY;
    pkt[1] = (uint8_t)(vk >> 8);
    pkt[2] = (uint8_t)(vk & 0xFF);
    pkt[3] = (uint8_t)(scan >> 8);
    pkt[4] = (uint8_t)(scan & 0xFF);
    pkt[5] = down ? 1 : 0;
    pkt[6] = flags;
    {
        std::lock_guard<std::mutex> lk(g_sendMtx);
        SendCtrlAllUnderLock(s, pkt, 7);
    }
    g_stats.inputSent++;
}

static std::atomic<bool> g_rxKvmActive{false};
static std::mutex g_rxKvmMtx;
static uint8_t g_rxKvmButtons = 0;
struct RxKvmHeldKey { uint16_t vk; uint16_t scan; uint8_t flags; };
static std::unordered_map<uint64_t, RxKvmHeldKey> g_rxKvmHeldKeys;

static void ReleaseRxKvmInputs() {
    std::vector<INPUT> inputs;
    {
        std::lock_guard<std::mutex> lk(g_rxKvmMtx);
        if (g_rxKvmButtons & 0x01) { INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_LEFTUP; inputs.push_back(bi); }
        if (g_rxKvmButtons & 0x02) { INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_RIGHTUP; inputs.push_back(bi); }
        if (g_rxKvmButtons & 0x04) { INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_MIDDLEUP; inputs.push_back(bi); }
        g_rxKvmButtons = 0;
        for (const auto& kv : g_rxKvmHeldKeys) {
            const RxKvmHeldKey& e = kv.second;
            INPUT in{};
            in.type = INPUT_KEYBOARD;
            DWORD dw = KEYEVENTF_KEYUP;
            if (e.vk == 0) {
                in.ki.wScan = e.scan;
                dw |= KEYEVENTF_SCANCODE;
            } else {
                in.ki.wVk = e.vk;
                in.ki.wScan = e.scan ? e.scan : (uint16_t)MapVirtualKeyW(e.vk, MAPVK_VK_TO_VSC);
            }
            if (e.flags & 0x01) dw |= KEYEVENTF_EXTENDEDKEY;
            in.ki.dwFlags = dw;
            inputs.push_back(in);
        }
        g_rxKvmHeldKeys.clear();
    }
    if (!inputs.empty()) SendInput((UINT)inputs.size(), inputs.data(), sizeof(INPUT));
}

static void OnKvmMousePacket(const uint8_t* p, size_t len) {
    if (!p || len < 7) return;
    int16_t dx = (int16_t)(((uint16_t)p[0] << 8) | p[1]);
    int16_t dy = (int16_t)(((uint16_t)p[2] << 8) | p[3]);
    uint8_t btns = p[4];
    int16_t wheel = (int16_t)(((uint16_t)p[5] << 8) | p[6]);

    std::vector<INPUT> inputs;
    if (dx != 0 || dy != 0) {
        INPUT mv{};
        mv.type = INPUT_MOUSE;
        mv.mi.dx = (LONG)dx;
        mv.mi.dy = (LONG)dy;
        mv.mi.dwFlags = MOUSEEVENTF_MOVE;
        inputs.push_back(mv);
    }
    {
        std::lock_guard<std::mutex> lk(g_rxKvmMtx);
        auto addBtn = [&](uint8_t mask, DWORD downFlag, DWORD upFlag) {
            bool was = (g_rxKvmButtons & mask) != 0;
            bool now = (btns & mask) != 0;
            if (was == now) return;
            INPUT bi{};
            bi.type = INPUT_MOUSE;
            bi.mi.dwFlags = now ? downFlag : upFlag;
            inputs.push_back(bi);
        };
        addBtn(0x01, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
        addBtn(0x02, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);
        addBtn(0x04, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP);
        g_rxKvmButtons = btns;
    }
    if (wheel != 0) {
        INPUT wi{};
        wi.type = INPUT_MOUSE;
        wi.mi.dwFlags = MOUSEEVENTF_WHEEL;
        wi.mi.mouseData = (DWORD)(int)wheel;
        inputs.push_back(wi);
    }
    if (!inputs.empty()) SendInput((UINT)inputs.size(), inputs.data(), sizeof(INPUT));
}

static void OnKvmKeyPacket(const uint8_t* p, size_t len) {
    if (!p || len < 6) return;
    uint16_t vk = (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
    uint16_t scan = (uint16_t)(((uint16_t)p[2] << 8) | p[3]);
    bool down = p[4] != 0;
    uint8_t flags = p[5];
    if (vk == 0 && scan == 0) return;

    INPUT in{};
    in.type = INPUT_KEYBOARD;
    DWORD dw = 0;
    if (vk == 0) {
        in.ki.wScan = scan;
        dw |= KEYEVENTF_SCANCODE;
    } else {
        in.ki.wVk = vk;
        in.ki.wScan = scan ? scan : (uint16_t)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    }
    if (flags & 0x01) dw |= KEYEVENTF_EXTENDEDKEY;
    if (!down) dw |= KEYEVENTF_KEYUP;
    in.ki.dwFlags = dw;

    {
        std::lock_guard<std::mutex> lk(g_rxKvmMtx);
        uint64_t k = (vk != 0)
            ? (uint64_t)vk
            : (0x8000000000000000ULL | ((uint64_t)(flags & 0x01) << 32) | (uint64_t)scan);
        if (down) g_rxKvmHeldKeys[k] = RxKvmHeldKey{ vk, scan, flags };
        else g_rxKvmHeldKeys.erase(k);
    }
    SendInput(1, &in, sizeof(INPUT));
}

static void OnKvmStatePacket(const uint8_t* p, size_t len) {
    if (!p || len < 1) return;
    bool active = (p[0] != 0);
    g_rxKvmActive = active;
    if (!active) ReleaseRxKvmInputs();
    Log(active ? "KVM: Mac 主控端已开启键鼠穿透 (正在远程操作本机)" : "KVM: Mac 主控端已退出键鼠穿透");
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
static const UINT ID_TRAY_DROPBOX = 1006;
static const UINT ID_TRAY_MODE = 1007;
static const UINT ID_TRAY_KVM  = 1008;
static const int  HOTKEY_QUIT_ID = 1;
static const int  HOTKEY_HIDE_ID = 2;   // Ctrl+Alt+H：最小化让位/还原，不退出
static const int  HOTKEY_DROPBOX_ID = 3; // Ctrl+Alt+B：一键呼出/隐藏文件投递盒
static const int  HOTKEY_KVM_ID = 4;     // Ctrl+Alt+K：主机模式切换 KVM 键鼠穿透到 Mac
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
    // 优先用 exe 内嵌的 1 号图标；取不到再退回系统默认图标。
    g_nid.hIcon = LoadIconA(GetModuleHandleA(nullptr), MAKEINTRESOURCEA(1));
    if (!g_nid.hIcon) g_nid.hIcon = LoadIconA(nullptr, IDI_APPLICATION);
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

static std::atomic<bool> g_hostMode{ false };
static std::atomic<bool> g_switchRoleRequested{ false };
static std::atomic<bool> g_switchRoleToHost{ false };
static HANDLE g_instMutex = nullptr;
static std::string g_activeCfgPath;
static bool g_useConfigFile = true;
static std::vector<std::string> g_preservedArgs;

// 前向声明：主控模式切换与托盘菜单联动
static void SwitchAppMode(bool toHostMode);

static void TrayShowMenu(HWND hwnd) {
    POINT pt{};
    GetCursorPos(&pt);
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    // W 版菜单 + 宽字符：绕开 CP936 对 UTF-8 中文的 GBK 误解码
    AppendMenuW(menu, MF_STRING, ID_TRAY_PANEL, L"控制面板");
    AppendMenuW(menu, MF_STRING, ID_TRAY_DROPBOX, L"文件投递盒（悬浮窗）  (Ctrl+Alt+B)");
    AppendMenuW(menu, MF_STRING, ID_TRAY_MODE,
                g_hostMode.load() ? L"切到副屏模式 (接收 Mac 画面)" : L"切到主控模式 (Mac 当 Windows 副屏)");
    if (g_hostMode.load()) {
        AppendMenuW(menu, MF_STRING, ID_TRAY_KVM,
                    g_winHost.IsKvmActive() ? L"退出键鼠穿透 Mac  (Ctrl+Alt+K)" : L"键鼠穿透控制 Mac  (Ctrl+Alt+K)");
    } else {
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, ID_TRAY_TOGGLE, L"切换全屏 / 窗口  (F11)");
        AppendMenuW(menu, MF_STRING, ID_TRAY_MINIMIZE, L"最小化让位 / 还原  (Ctrl+Alt+H)");
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, ID_TRAY_ABOUT,  L"关于 SecDisplay");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | MF_DEFAULT, ID_TRAY_EXIT, L"退出 SecDisplay");
    // 前置，否则菜单可能被置顶窗口盖住
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
                   pt.x, pt.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
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

static RECT VideoRectInClient(int cw, int ch) {
    int dw = g_displayW.load(), dh = g_displayH.load();
    if (dw <= 0 || dh <= 0) { dw = g_coordW.load(); dh = g_coordH.load(); }
    if (dw <= 0 || dh <= 0) return RECT{ 0, 0, cw, ch };
    return FitRect(dw, dh, cw, ch);
}

/// 窗口客户区坐标 → 虚拟屏逻辑点坐标（0..coordW, 0..coordH），按实际留黑边后的有效画面矩形换算
static bool ClientToVideo(int cx, int cy, float* vx, float* vy) {
    if (!g_hwnd) return false;
    RECT rc{};
    if (!GetClientRect(g_hwnd, &rc)) return false;
    int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
    int vw = g_coordW.load(), vh = g_coordH.load();
    if (cw <= 0 || ch <= 0 || vw <= 0 || vh <= 0) return false;
    RECT vr = VideoRectInClient(cw, ch);
    int rw = vr.right - vr.left, rh = vr.bottom - vr.top;
    if (rw <= 0 || rh <= 0) return false;
    int rx = cx - vr.left;
    int ry = cy - vr.top;
    if (rx < 0) rx = 0;
    if (rx > rw) rx = rw;
    if (ry < 0) ry = 0;
    if (ry > rh) ry = rh;
    *vx = (float)rx / rw * vw;
    *vy = (float)ry / rh * vh;
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
        g_pullCursorIn.store(true);
    }

    double oldX = g_cursorX.load(), oldY = g_cursorY.load();
    g_cursorX = rx;
    g_cursorY = ry;
    // 只在位置真的变化时通知 UI；并用 g_cursorMsgPending 合并连发包，
    // 防止消息队列积压多条 WM_APP_REMOTE_CURSOR 后连续 SetCursorPos 引发回声震荡。
    if (rx == oldX && ry == oldY) return;
    if (g_hwnd && !g_cursorMsgPending.exchange(true)) {
        if (!PostMessageA(g_hwnd, WM_APP_REMOTE_CURSOR, 0, 0)) {
            g_cursorMsgPending.store(false);
        }
    }
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
    // 上限与 Mac 端 CursorImageTracker.maxDim（256 原生像素）保持一致：
    // 之前这里是 128，Mac 放大指针后整包会被静默丢弃，副屏光标直接停止更新。
    if (w <= 0 || h <= 0 || w > 256 || h > 256) {
        static uint64_t s_lastDropLog = 0;
        const uint64_t nowMs = GetTickCount64();
        if (nowMs - s_lastDropLog > 5000) {
            s_lastDropLog = nowMs;
            Log("警告: 丢弃超尺寸光标位图 %dx%d（上限 256）", w, h);
        }
        return;
    }
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
    if (FAILED(hr) || count == 0) {
        Log("MFTEnumEx 失败 %08X", hr);
        // 写面板：这是最可能出现的失败形态（系统缺解码器），
        // 不写的话面板会一直显示上一次重连成功的解码器名。
        std::lock_guard<std::mutex> lk(g_decoderInfoMtx);
        g_decoderInfo = L"无可用解码器（枚举失败）";
        return false;
    }

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
    std::wstring chosenName;         // 选中的解码器友好名，供控制面板显示

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
            LPWSTR nm = nullptr; UINT32 nl = 0;
            if (SUCCEEDED(acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &nm, &nl)) && nm) {
                chosenName = nm;
                CoTaskMemFree(nm);
            }
            Log("候选 [%u] 接受 D3D 管理器，启用 DXVA 硬件解码", i);
        } else if (!fallback) {
            fallback = candidate;
            LPWSTR nm = nullptr; UINT32 nl = 0;
            if (SUCCEEDED(acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &nm, &nl)) && nm) {
                chosenName = nm;
                CoTaskMemFree(nm);
            }
        }
    }

    // 没有任何候选接受 D3D，退回记录的第一个（软件解码）
    if (!transform_ && fallback) {
        transform_ = fallback;
        Log("没有解码器接受 D3D 管理器，退回软件解码（性能受限）");
    }

    for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
    CoTaskMemFree(acts);
    if (!transform_) {
        Log("没有可用的解码器");
        // 失败也要写面板：否则面板会一直显示上一次重连成功的解码器名，
        // 与实际管线不符，排障时误导。
        std::lock_guard<std::mutex> lk(g_decoderInfoMtx);
        g_decoderInfo = L"无可用解码器";
        return false;
    }

    // 记录给控制面板看：硬件/软件 + 友好名
    {
        std::lock_guard<std::mutex> lk(g_decoderInfoMtx);
        g_decoderInfo = (hardware ? L"硬件 · " : L"软件 · ");
        g_decoderInfo += chosenName.empty() ? L"未知" : chosenName;
    }

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

    // 原子更新输出尺寸、源尺寸与逻辑显示尺寸，避免分步更新回滚不一致或同尺寸漏重建处理器
    bool Configure(int outW, int outH, int srcW, int srcH, int dispW, int dispH);

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
    int dispW_ = 0, dispH_ = 0;       // 当前流逻辑显示尺寸（用于裁剪 H.264 宏块对齐边缘）
    // 视频处理器视图按纹理指针缓存：每帧新建在 45fps 下是每秒 90 次 Create*View
    std::unordered_map<uint64_t, ComPtr<ID3D11VideoProcessorInputView>> inViewCache_;
    std::unordered_map<void*, ComPtr<ID3D11VideoProcessorOutputView>> outViewCache_;
    // 交换链与视图缓存表会被呈现线程和 UI/网络线程同时碰：
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

    // 视频设备/上下文拿不到时 CreateProcessor 会对空指针解引用直接崩溃，
    // 这里先判空，让 Init 返回 false（main 里是直接退出并返回退出码 4，
    // 不是重试），至少留下明确日志而不是闪退。
    hr = gfx->device.As(&videoDevice_);
    if (FAILED(hr) || !videoDevice_) {
        Log("D3D11 视频设备接口不可用 %08X", hr);
        return false;
    }
    hr = gfx->context.As(&videoCtx_);
    if (FAILED(hr) || !videoCtx_) {
        Log("D3D11 视频上下文接口不可用 %08X", hr);
        return false;
    }

    srcW_ = width;
    srcH_ = height;
    dispW_ = g_displayW.load();
    dispH_ = g_displayH.load();
    if (!CreateProcessor()) return false;

    Log("呈现器就绪");
    return true;
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

    // 显式锚定 BT.709 色彩空间：Mac 端 420v 采集设了 ITU-R 709（VideoRange 16-235），
    // 编码器已写入 709 VUI。不设这两项时驱动可能按 BT.601 默认矩阵解 NV12，
    // 输出侧 Nominal_Range 默认也是 16-235，导致偏色或黑位发灰。
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE inCs{};
    inCs.Usage = 0;
    inCs.RGB_Range = 0;
    inCs.YCbCr_Matrix = 1;  // 1 = ITU-R BT.709
    inCs.YCbCr_xvYCC = 0;
    inCs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    videoCtx_->VideoProcessorSetStreamColorSpace(processor_.Get(), 0, &inCs);

    D3D11_VIDEO_PROCESSOR_COLOR_SPACE outCs{};
    outCs.Usage = 0;
    outCs.RGB_Range = 0;    // 0 = full range (0-255) RGB 输出给桌面交换链
    outCs.YCbCr_Matrix = 1;
    outCs.YCbCr_xvYCC = 0;
    outCs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_0_255;
    videoCtx_->VideoProcessorSetOutputColorSpace(processor_.Get(), &outCs);

    // 裁掉 H.264 宏块对齐多出的边缘(如 2880x1808 里的底端 8 行)，否则会被当成有效画面
    // 参与等比缩放，原本能 1:1 满幅的 2880x1800 被迫缩到 2867x1800。
    int cropW = srcW_, cropH = srcH_;
    const int dispW = (dispW_ > 0) ? dispW_ : g_displayW.load();
    const int dispH = (dispH_ > 0) ? dispH_ : g_displayH.load();
    if (dispW > 0 && dispH > 0 &&
        srcW_ >= dispW && srcH_ >= dispH &&
        srcW_ - dispW <= 16 && srcH_ - dispH <= 16) {
        cropW = dispW;
        cropH = dispH;
    }
    RECT src{ 0, 0, cropW, cropH };
    videoCtx_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);

    // 用 VideoProcessor 原生背景色画黑边，不再每帧在 3D 管线调 ClearRenderTargetView
    // 去和 VideoProcessorBlt 混写同一个 FLIP 后缓冲。
    D3D11_VIDEO_COLOR bgColor{};
    bgColor.RGBA.R = 0.0f; bgColor.RGBA.G = 0.0f; bgColor.RGBA.B = 0.0f; bgColor.RGBA.A = 1.0f;
    videoCtx_->VideoProcessorSetOutputBackgroundColor(processor_.Get(), FALSE, &bgColor);

    // 始终让 OutputTargetRect 覆盖整张交换链后缓冲（传 FALSE），
    // 只用 StreamDestRect 限定有效画面区域，确保留黑边区域也被背景色清黑不残留旧帧。
    RECT dst = FitRect(cropW, cropH, width_, height_);
    videoCtx_->VideoProcessorSetStreamDestRect(processor_.Get(), 0, TRUE, &dst);
    videoCtx_->VideoProcessorSetOutputTargetRect(processor_.Get(), FALSE, nullptr);
    const bool letterbox = dst.left > 0 || dst.top > 0 ||
                           dst.right < width_ || dst.bottom < height_;
    Log("呈现器: 输入 %dx%d(裁 %dx%d) → 输出 %dx%d，画面矩形 %d,%d - %d,%d%s",
        srcW_, srcH_, cropW, cropH, width_, height_,
        (int)dst.left, (int)dst.top, (int)dst.right, (int)dst.bottom,
        letterbox ? "（留黑边）" : "（满幅）");
    return true;
}

bool Presenter::SetSourceSize(int w, int h) {
    if (w <= 0 || h <= 0) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    const int curDispW = g_displayW.load(), curDispH = g_displayH.load();
    if (w == srcW_ && h == srcH_ && curDispW == dispW_ && curDispH == dispH_) return true;
    const int prevW = srcW_, prevH = srcH_, prevDW = dispW_, prevDH = dispH_;
    srcW_ = w;
    srcH_ = h;
    dispW_ = curDispW;
    dispH_ = curDispH;
    if (!CreateProcessor()) {
        srcW_ = prevW;
        srcH_ = prevH;
        dispW_ = prevDW;
        dispH_ = prevDH;
        return false;
    }
    return true;
}

bool Presenter::Configure(int outW, int outH, int srcW, int srcH, int dispW, int dispH) {
    if (outW <= 0 || outH <= 0 || srcW <= 0 || srcH <= 0) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    const int prevOutW = width_, prevOutH = height_;
    const int prevSrcW = srcW_, prevSrcH = srcH_;
    const int prevDispW = dispW_, prevDispH = dispH_;

    const bool needSwapResize = (outW != width_ || outH != height_);
    const bool needProcRebuild = needSwapResize || (srcW != srcW_ || srcH != srcH_ || dispW != dispW_ || dispH != dispH_);
    if (!needProcRebuild) return true;

    if (needSwapResize && swap_) {
        inViewCache_.clear();
        outViewCache_.clear();
        UINT flags = tearing_ ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;
        HRESULT hr = swap_->ResizeBuffers(0, (UINT)outW, (UINT)outH, DXGI_FORMAT_UNKNOWN, flags);
        if (FAILED(hr)) {
            Log("交换链改尺寸失败 %08X（保持 %dx%d）", hr, prevOutW, prevOutH);
            return false;
        }
    }

    width_ = outW;
    height_ = outH;
    srcW_ = srcW;
    srcH_ = srcH;
    dispW_ = dispW;
    dispH_ = dispH;
    if (!swap_) return true;

    if (!CreateProcessor()) {
        if (needSwapResize) {
            UINT flags = tearing_ ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;
            if (FAILED(swap_->ResizeBuffers(0, (UINT)prevOutW, (UINT)prevOutH, DXGI_FORMAT_UNKNOWN, flags))) {
                Log("交换链回滚到 %dx%d 失败，保留新尺寸 %dx%d", prevOutW, prevOutH, outW, outH);
                return false;
            }
        }
        width_ = prevOutW;
        height_ = prevOutH;
        srcW_ = prevSrcW;
        srcH_ = prevSrcH;
        dispW_ = prevDispW;
        dispH_ = prevDispH;
        return false;
    }
    Log("呈现器已切换到 %dx%d（源 %dx%d）", width_, height_, srcW_, srcH_);
    return true;
}

bool Presenter::Resize(int width, int height) {
    if (width <= 0 || height <= 0) return false;
    std::lock_guard<std::mutex> lk(mtx_);
    if (width == width_ && height == height_) return true;
    if (!swap_) { width_ = width; height_ = height; return true; }

    const int prevW = width_, prevH = height_;

    // 输入/输出视图都缓存了后缓冲指针，改尺寸后必须全部失效
    inViewCache_.clear();
    outViewCache_.clear();

    UINT flags = tearing_ ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;
    HRESULT hr = swap_->ResizeBuffers(0, (UINT)width, (UINT)height,
                                      DXGI_FORMAT_UNKNOWN, flags);
    if (FAILED(hr)) {
        Log("交换链改尺寸失败 %08X（保持 %dx%d）", hr, prevW, prevH);
        return false;
    }
    width_ = width;
    height_ = height;
    if (!CreateProcessor()) {
        // 同上：处理器重建失败时把交换链尺寸也回滚，
        // 否则下次 Resize 会因「尺寸相同」早退，永久不再重建。
        if (FAILED(swap_->ResizeBuffers(0, (UINT)prevW, (UINT)prevH,
                                        DXGI_FORMAT_UNKNOWN, flags))) {
            // 回滚交换链失败：真实尺寸仍是 width×height。
            // 此时不能把 width_/height_ 改回旧值，否则记账与后缓冲不一致，
            // 自愈分支会按错误尺寸重建处理器，VideoProcessorBlt 持续失败。
            // 保留新尺寸，让 PresentSample 按真实尺寸重建。
            Log("交换链回滚到 %dx%d 失败，保留新尺寸 %dx%d", prevW, prevH, width, height);
            return false;
        }
        width_ = prevW;
        height_ = prevH;
        return false;
    }
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
    if (!processor_) {
        // 处理器缺失说明之前 CreateProcessor 失败过（设备繁忙/内存抖动）。
        // 这里限流重试，避免呈现器永久残废：每帧都重建会拖垮主循环，
        // 2 秒一次足够自愈，又不会刷屏。
        static double lastRetryMs = 0.0;
        const double nowMs = QpcNowMs();
        if (nowMs - lastRetryMs > 2000.0) {
            lastRetryMs = nowMs;
            Log("视频处理器缺失，尝试重建（输入 %dx%d 输出 %dx%d）", srcW_, srcH_, width_, height_);
            if (!CreateProcessor()) {
                Log("视频处理器重建仍失败，2 秒后再试");
            }
        }
        if (!processor_) return fail("视频处理器未就绪", E_UNEXPECTED);
    }

    // FLIP 模型下交换链有多个物理缓冲随 Present 轮转，且每次 GetBuffer 拿到的
    // 可能是不同的表面。必须每帧重新获取，缓存指针会画到错误或不可写的缓冲上，
    // 表现为隔帧黑屏或花屏。
    ComPtr<ID3D11Texture2D> backTex;
    HRESULT hr = swap_->GetBuffer(0, IID_PPV_ARGS(&backTex));
    if (FAILED(hr)) return fail("交换链 GetBuffer(0)", hr);
    if (!backTex) return fail("交换链 GetBuffer(0) 返回空纹理", E_POINTER);

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
static std::atomic<bool> g_isFullscreen{false};      // 由 main 按 cfg.fullscreen 同步
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
    // 以 --fullscreen / config fullscreen=1 直接全屏启动时，没走过 EnterFullscreen()，
    // g_savedStyle / g_savedRect 可能是 0；退回合理的默认窗口矩形，避免缩成 2x2 黑窗。
    if (g_savedStyle == 0 || (g_savedRect.right - g_savedRect.left) < 160 ||
        (g_savedRect.bottom - g_savedRect.top) < 100) {
        g_savedStyle = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_VISIBLE;
        g_savedExStyle = WS_EX_APPWINDOW;
        HMONITOR mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
        MONITORINFO mi{}; mi.cbSize = sizeof(mi);
        int ww = 1280, wh = 800;
        int mx = 0, my = 0;
        if (GetMonitorInfoW(mon, &mi)) {
            ww = (mi.rcWork.right - mi.rcWork.left) * 3 / 4;
            wh = (mi.rcWork.bottom - mi.rcWork.top) * 3 / 4;
            mx = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - ww) / 2;
            my = mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - wh) / 2;
        }
        g_savedRect = RECT{ mx, my, mx + ww, my + wh };
    }
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

static std::atomic<HWND> g_panel{nullptr};
static std::atomic<HWND> g_dropBox{nullptr};
static std::atomic<bool> g_dropBoxPinned{true};
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
static const UINT_PTR TIMER_RESUME_HOST = 5;
static const UINT_PTR TIMER_SLEEP_WATCHDOG = 6;
static int g_resumeRetryCount = 0;

#ifndef PBT_APMRESUMECRITICAL
#define PBT_APMRESUMECRITICAL 0x0006
#endif
#ifndef PBT_APMRESUMESTANDBY
#define PBT_APMRESUMESTANDBY 0x0008
#endif

static const int IDC_PANEL_FULL     = 2010;
static const int IDC_PANEL_RECONN   = 2011;
static const int IDC_PANEL_LOG      = 2012;
static const int IDC_PANEL_EXIT     = 2013;
static const int IDC_PANEL_VSYNC    = 2020;
static const int IDC_PANEL_PACE     = 2021;
static const int IDC_PANEL_FEEDBACK = 2022;
static const int IDC_PANEL_TOP      = 2017;
static const int IDC_PANEL_KEY      = 2018;
static const int IDC_PANEL_CFG      = 2019;
static const int IDC_PANEL_COPY     = 2023;
static const int IDC_PANEL_SHAKE    = 2028;
static const int IDC_PANEL_KEEPON   = 2029;
static const int IDC_PANEL_SENDFILE = 2030;
static const int IDC_PANEL_OPENXFER = 2031;
static const int IDC_PANEL_DROPBOX  = 2032;
static const int IDC_PANEL_PASTEXFER = 2033;
static const int IDC_PANEL_MODE      = 2034;
static const int IDC_PANEL_RES_2880  = 2035;
static const int IDC_PANEL_RES_2560  = 2036;
static const int IDC_PANEL_RES_1920  = 2037;
static const int IDC_PANEL_MBPS_30   = 2038;
static const int IDC_PANEL_MBPS_50   = 2039;
static const int IDC_PANEL_MBPS_80   = 2040;
static const int IDC_PANEL_VDD_RETRY = 2041;
static const int IDC_PANEL_KVM       = 2042;

static std::atomic<int> g_hostReqW{2880};
static std::atomic<int> g_hostReqH{1800};
static std::atomic<int> g_hostReqFps{60};
static std::atomic<int> g_hostReqMbps{50};
static std::atomic<int> g_hostReqDpi{0};

static ULONG_PTR g_gdipToken = 0;

static const UINT WM_APP_XFER_UI = WM_APP + 10;
static const UINT WM_APP_SET_CLIP_TEXT = WM_APP + 11;

// ---- 雷电双向文件中转站（独立 TCP 端口 port+1 = 9923）----
static const uint8_t XFER_BEGIN = 0x10;
static const uint8_t XFER_CHUNK = 0x11;
static const uint8_t XFER_END   = 0x12;
static const uint8_t XFER_ACK   = 0x13;
static const uint8_t XFER_PING  = 0x14;
static const uint8_t XFER_TEXT  = 0x15;
static const size_t kXferMaxTextBytes = 1024 * 1024 - 4;

struct XferOutItem {
    bool isText = false;
    std::wstring path;
    bool deleteAfterSend = false;
    std::string textUtf8;
    std::wstring preview;
};
struct PendingClipText {
    uint32_t id = 0;
    std::wstring text;
    std::wstring preview;
    size_t utf8Bytes = 0;
};
static std::mutex g_clipTextMtx;
static std::deque<PendingClipText> g_clipTextQ;
static std::atomic<bool> g_xferConnected{false};
static std::atomic<SOCKET> g_xferSock{INVALID_SOCKET};
static std::mutex g_xferMtx;
static std::condition_variable g_xferCv;
static std::deque<XferOutItem> g_xferOutQ;
static std::wstring g_xferStatus = L"等待中转站连接 (端口 9923)…";
static int g_xferPct = -1;
static std::wstring g_xferSpeed;
static std::wstring g_xferLastRecvPath;
static std::wstring g_xferLastRecvName;
static int g_xferFbKind = 0;         // 0=无 1=成功 -1=失败
static std::wstring g_xferFbTitle;
static std::wstring g_xferFbDetail;
static ULONGLONG g_xferFbExpireTick = 0;
static uint32_t g_xferNextId = 1;
static const UINT_PTR kDropBoxFbTimer = 2;

static std::wstring GetTransferInboxDir() {
    static std::wstring cached;
    static std::mutex dirMtx;
    std::lock_guard<std::mutex> lk(dirMtx);
    if (!cached.empty()) return cached;

    wchar_t desk[MAX_PATH] = {};
    std::wstring base;
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_DESKTOPDIRECTORY, nullptr, SHGFP_TYPE_CURRENT, desk)) && desk[0]) {
        base = desk;
    } else {
        wchar_t exe[MAX_PATH] = {};
        DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
        if (n > 0 && n < MAX_PATH) {
            std::wstring p(exe, n);
            size_t pos = p.find_last_of(L"\\/");
            base = (pos != std::wstring::npos) ? p.substr(0, pos) : L".";
        } else {
            base = L".";
        }
    }
    cached = base + L"\\SecDisplay-Transfer";
    CreateDirectoryW(cached.c_str(), nullptr);
    return cached;
}

static std::wstring FormatBytesW(uint64_t n) {
    wchar_t buf[64];
    if (n >= 1073741824ull) { swprintf(buf, 64, L"%.2f GB", (double)n / 1073741824.0); }
    else if (n >= 1048576ull) { swprintf(buf, 64, L"%.1f MB", (double)n / 1048576.0); }
    else if (n >= 1024ull) { swprintf(buf, 64, L"%.0f KB", (double)n / 1024.0); }
    else { swprintf(buf, 64, L"%llu B", (unsigned long long)n); }
    return buf;
}

static void SetTransferStatus(const std::wstring& s, int pct = -1, const std::wstring& speed = L"") {
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        g_xferStatus = s;
        g_xferPct = pct;
        g_xferSpeed = speed;
        if (pct >= 0) {
            g_xferFbKind = 0;
            g_xferFbTitle.clear();
            g_xferFbDetail.clear();
            g_xferFbExpireTick = 0;
        }
    }
    HWND hp = g_panel.load();
    if (hp && g_alive) PostMessageW(hp, WM_APP_XFER_UI, 0, 0);
    HWND db = g_dropBox.load();
    if (db && g_alive) PostMessageW(db, WM_APP_XFER_UI, 0, 0);
}

static void SetTransferFeedback(int kind, const std::wstring& title, const std::wstring& detail = L"") {
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        g_xferFbKind = kind;
        g_xferFbTitle = title;
        g_xferFbDetail = detail;
        g_xferFbExpireTick = (kind != 0) ? (GetTickCount64() + 2200) : 0;
    }
    HWND hp = g_panel.load();
    if (hp && g_alive) PostMessageW(hp, WM_APP_XFER_UI, 0, 0);
    HWND db = g_dropBox.load();
    if (db && g_alive) PostMessageW(db, WM_APP_XFER_UI, 0, 0);
}

static std::wstring ToWideStrict(const char* utf8, int bytes) {
    if (!utf8 || bytes <= 0) return {};
    int len = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, bytes, nullptr, 0);
    if (len <= 0) return {};
    std::wstring out((size_t)len, L'\0');
    if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, bytes, &out[0], len) <= 0) return {};
    return out;
}

static std::string WideToUtf8N(const wchar_t* w, int chars) {
    if (!w || chars <= 0) return {};
    int len = ::WideCharToMultiByte(CP_UTF8, 0, w, chars, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string out((size_t)len, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, w, chars, &out[0], len, nullptr, nullptr);
    return out;
}

static std::wstring MakeTextPreviewW(const std::wstring& s) {
    std::wstring one;
    one.reserve(32);
    bool started = false;
    size_t cpCount = 0;
    for (size_t i = 0; i < s.size(); ++i) {
        wchar_t ch = s[i];
        if (ch == L'\r' || ch == L'\n' || ch == L'\t') ch = L' ';
        if (!started && ch == L' ') continue;
        started = true;
        if (cpCount >= 22) {
            one += L"…";
            break;
        }
        one.push_back(ch);
        if (ch >= 0xD800 && ch <= 0xDBFF && i + 1 < s.size()) {
            one.push_back(s[++i]);
        }
        ++cpCount;
    }
    return one.empty() ? L"空白文本" : one;
}

static void EnqueueTextTransfer(const std::string& utf8, const std::wstring& preview) {
    if (utf8.empty()) return;
    if (utf8.size() > kXferMaxTextBytes) {
        SetTransferStatus(L"文本超过 1MB，请保存为文件发送");
        SetTransferFeedback(-1, L"文本过大 (>1MB)", L"请改用文件发送");
        Log("中转站拒绝过大文本 (%zu B)", utf8.size());
        return;
    }
    bool conn = g_xferConnected.load();
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        g_xferOutQ.push_back(XferOutItem{ true, L"", false, utf8, preview });
        g_xferStatus = conn ? (L"待发送文本: " + preview) : L"已排队文本（等待连接）";
    }
    g_xferCv.notify_all();
    HWND hp = g_panel.load();
    if (hp && g_alive) PostMessageW(hp, WM_APP_XFER_UI, 0, 0);
    HWND db = g_dropBox.load();
    if (db && g_alive) PostMessageW(db, WM_APP_XFER_UI, 0, 0);
    Log("中转站加入文本发送队列 (%zu B)", utf8.size());
}

static void EnqueueFileTransfer(const std::wstring& path, bool deleteAfterSend = false) {
    DWORD attr = GetFileAttributesW(path.c_str());
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY)) {
        if (deleteAfterSend) DeleteFileW(path.c_str());
        return;
    }
    size_t qSize = 0;
    bool conn = g_xferConnected.load();
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        g_xferOutQ.push_back(XferOutItem{ false, path, deleteAfterSend, {}, {} });
        qSize = g_xferOutQ.size();
        wchar_t buf[128];
        swprintf(buf, 128, conn ? L"已加入发送队列 (%zu 个文件)…" : L"已排队 %zu 个文件（等待连接）", qSize);
        g_xferStatus = buf;
    }
    g_xferCv.notify_all();
    HWND hp = g_panel.load();
    if (hp && g_alive) PostMessageW(hp, WM_APP_XFER_UI, 0, 0);
    HWND db = g_dropBox.load();
    if (db && g_alive) PostMessageW(db, WM_APP_XFER_UI, 0, 0);
    Log("中转站加入发送队列: %s", ToUtf8(path.c_str()).c_str());
}

static bool GetPngEncoderClsid(CLSID* outClsid) {
    UINT num = 0, size = 0;
    Gdiplus::GetImageEncodersSize(&num, &size);
    if (size == 0) return false;
    std::vector<uint8_t> buf(size);
    auto* pInfo = (Gdiplus::ImageCodecInfo*)buf.data();
    if (Gdiplus::GetImageEncoders(num, size, pInfo) != Gdiplus::Ok) return false;
    for (UINT i = 0; i < num; ++i) {
        if (wcscmp(pInfo[i].MimeType, L"image/png") == 0) {
            *outClsid = pInfo[i].Clsid;
            return true;
        }
    }
    return false;
}

static void PasteClipboardToTransfer(HWND owner) {
    if (!OpenClipboard(owner)) {
        SetTransferStatus(L"无法读取剪贴板");
        SetTransferFeedback(-1, L"剪贴板占用", L"请稍后重试");
        return;
    }
    std::vector<std::wstring> files;
    std::wstring tempPngPath;
    std::string clipTextUtf8;
    std::wstring clipPreview;

    if (HANDLE hd = GetClipboardData(CF_HDROP)) {
        HDROP drop = (HDROP)GlobalLock(hd);
        if (drop) {
            UINT cnt = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
            for (UINT i = 0; i < cnt; ++i) {
                UINT len = DragQueryFileW(drop, i, nullptr, 0);
                if (len > 0 && len < 4096) {
                    std::wstring path(len + 1, L'\0');
                    if (DragQueryFileW(drop, i, &path[0], len + 1) > 0) {
                        path.resize(wcslen(path.c_str()));
                        files.push_back(path);
                    }
                }
            }
            GlobalUnlock(hd);
        }
    } else {
        auto makeTmpPngPath = []() -> std::wstring {
            wchar_t tmpDir[MAX_PATH] = {};
            if (GetTempPathW(MAX_PATH, tmpDir) == 0) return {};
            SYSTEMTIME st{};
            GetLocalTime(&st);
            wchar_t fname[96];
            swprintf(fname, 96, L"Screenshot_%04d%02d%02d_%02d%02d%02d_%03d.png",
                     st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
            return std::wstring(tmpDir) + fname;
        };

        // 1. 优先读取截图软件直写的原始 "PNG" / "image/png" 格式（Snipaste / PixPin / Win+Shift+S / 微信等）
        static const UINT fmtPng = RegisterClipboardFormatW(L"PNG");
        static const UINT fmtMimePng = RegisterClipboardFormatW(L"image/png");
        UINT pngFmts[2] = { fmtPng, fmtMimePng };
        for (UINT pf : pngFmts) {
            if (!pf) continue;
            if (HANDLE hp = GetClipboardData(pf)) {
                SIZE_T cb = GlobalSize(hp);
                if (cb >= 8) {
                    if (const uint8_t* ptr = (const uint8_t*)GlobalLock(hp)) {
                        static const uint8_t kPngSig[8] = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
                        if (memcmp(ptr, kPngSig, 8) == 0) {
                            std::wstring cand = makeTmpPngPath();
                            if (!cand.empty()) {
                                HANDLE hf = CreateFileW(cand.c_str(), GENERIC_WRITE, 0, nullptr,
                                                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                                if (hf != INVALID_HANDLE_VALUE) {
                                    DWORD wr = 0;
                                    if (WriteFile(hf, ptr, (DWORD)cb, &wr, nullptr) && wr == (DWORD)cb) {
                                        tempPngPath = cand;
                                    } else {
                                        CloseHandle(hf);
                                        DeleteFileW(cand.c_str());
                                        hf = INVALID_HANDLE_VALUE;
                                    }
                                    if (hf != INVALID_HANDLE_VALUE) CloseHandle(hf);
                                }
                            }
                        }
                        GlobalUnlock(hp);
                    }
                }
                if (!tempPngPath.empty()) break;
            }
        }

        // 2. 若无原始 PNG，优先按 CF_DIB / CF_DIBV5 读取（避开 FromHBITMAP 对 32bpp 透明位图的兼容坑）
        if (tempPngPath.empty()) {
            std::unique_ptr<Gdiplus::Bitmap> bmp;
            UINT dibFmts[2] = { CF_DIB, CF_DIBV5 };
            for (UINT df : dibFmts) {
                if (HANDLE hdib = GetClipboardData(df)) {
                    SIZE_T cb = GlobalSize(hdib);
                    if (cb >= sizeof(BITMAPINFOHEADER)) {
                        if (void* ptr = GlobalLock(hdib)) {
                            const BITMAPINFO* bmi = (const BITMAPINFO*)ptr;
                            DWORD hdrSize = bmi->bmiHeader.biSize;
                            if (hdrSize >= sizeof(BITMAPINFOHEADER) && hdrSize <= cb) {
                                size_t palBytes = 0;
                                // 仅标准 40 字节 BITMAPINFOHEADER 在结构体外附加 3 个 DWORD 掩码；V4/V5 已内嵌
                                if (hdrSize == sizeof(BITMAPINFOHEADER) && bmi->bmiHeader.biCompression == BI_BITFIELDS) {
                                    palBytes += 3 * sizeof(DWORD);
                                }
                                if (bmi->bmiHeader.biBitCount <= 8) {
                                    DWORD nCol = bmi->bmiHeader.biClrUsed ? bmi->bmiHeader.biClrUsed : (1u << bmi->bmiHeader.biBitCount);
                                    palBytes += (size_t)nCol * sizeof(RGBQUAD);
                                } else if (bmi->bmiHeader.biClrUsed > 0) {
                                    palBytes += (size_t)bmi->bmiHeader.biClrUsed * sizeof(RGBQUAD);
                                }
                                if ((size_t)hdrSize + palBytes < cb) {
                                    const void* bits = (const uint8_t*)ptr + hdrSize + palBytes;
                                    std::unique_ptr<Gdiplus::Bitmap> candBmp(Gdiplus::Bitmap::FromBITMAPINFO(bmi, (void*)bits));
                                    if (candBmp && candBmp->GetLastStatus() == Gdiplus::Ok) {
                                        bmp = std::move(candBmp);
                                    }
                                }
                            }
                            GlobalUnlock(hdib);
                        }
                    }
                    if (bmp) break;
                }
            }
            if (!bmp) {
                if (HBITMAP hbm = (HBITMAP)GetClipboardData(CF_BITMAP)) {
                    std::unique_ptr<Gdiplus::Bitmap> candBmp(Gdiplus::Bitmap::FromHBITMAP(hbm, nullptr));
                    if (candBmp && candBmp->GetLastStatus() == Gdiplus::Ok) {
                        bmp = std::move(candBmp);
                    }
                }
            }
            CLSID pngClsid{};
            if (bmp && bmp->GetLastStatus() == Gdiplus::Ok && GetPngEncoderClsid(&pngClsid)) {
                std::wstring candidate = makeTmpPngPath();
                if (!candidate.empty() && bmp->Save(candidate.c_str(), &pngClsid, nullptr) == Gdiplus::Ok) {
                    tempPngPath = candidate;
                }
            }
        }
    }
    if (files.empty() && tempPngPath.empty()) {
        if (HANDLE ht = GetClipboardData(CF_UNICODETEXT)) {
            SIZE_T cb = GlobalSize(ht);
            if (const wchar_t* ws = (const wchar_t*)GlobalLock(ht)) {
                size_t maxChars = cb / sizeof(wchar_t);
                size_t len = wcsnlen(ws, maxChars);
                if (len > 0) {
                    clipTextUtf8 = WideToUtf8N(ws, (int)len);
                    clipPreview = MakeTextPreviewW(std::wstring(ws, len));
                }
                GlobalUnlock(ht);
            }
        } else if (HANDLE ha = GetClipboardData(CF_TEXT)) {
            SIZE_T cb = GlobalSize(ha);
            if (const char* as = (const char*)GlobalLock(ha)) {
                size_t len = strnlen(as, cb);
                if (len > 0) {
                    int wlen = ::MultiByteToWideChar(CP_ACP, 0, as, (int)len, nullptr, 0);
                    if (wlen > 0) {
                        std::wstring ws((size_t)wlen, L'\0');
                        ::MultiByteToWideChar(CP_ACP, 0, as, (int)len, &ws[0], wlen);
                        clipTextUtf8 = WideToUtf8N(ws.data(), wlen);
                        clipPreview = MakeTextPreviewW(ws);
                    }
                }
                GlobalUnlock(ha);
            }
        }
    }
    if (files.empty() && tempPngPath.empty() && clipTextUtf8.empty()) {
        std::string fmts;
        UINT f = 0;
        while ((f = EnumClipboardFormats(f)) != 0) {
            if (!fmts.empty()) fmts += ",";
            wchar_t fn[64] = {};
            if (GetClipboardFormatNameW(f, fn, 64) > 0) fmts += ToUtf8(fn);
            else fmts += std::to_string(f);
            if (fmts.size() > 180) break;
        }
        Log("剪贴板粘贴无可用内容，当前格式: [%s]", fmts.c_str());
    }
    CloseClipboard();

    if (!files.empty()) {
        for (const auto& f : files) EnqueueFileTransfer(f, false);
    } else if (!tempPngPath.empty()) {
        EnqueueFileTransfer(tempPngPath, true);
        Log("剪贴板截图已编码入队: %s", ToUtf8(tempPngPath.c_str()).c_str());
    } else if (!clipTextUtf8.empty()) {
        EnqueueTextTransfer(clipTextUtf8, clipPreview);
    } else {
        SetTransferStatus(L"剪贴板中没有文件、截图或文字");
        SetTransferFeedback(-1, L"剪贴板无内容", L"请先复制文件、截图或文字");
    }
}

static void PickAndSendFiles(HWND owner) {
    std::vector<wchar_t> buf(65536, 0);
    OPENFILENAMEW ofn{};
    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = owner;
    ofn.lpstrFilter = L"所有文件 (*.*)\0*.*\0";
    ofn.lpstrFile = buf.data();
    ofn.nMaxFile = (DWORD)buf.size();
    ofn.lpstrTitle = L"选择要通过雷电线发送到 Mac 的文件";
    ofn.Flags = OFN_EXPLORER | OFN_ALLOWMULTISELECT | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return;

    const wchar_t* p = buf.data();
    std::wstring first = p;
    p += first.size() + 1;
    if (*p == 0) {
        EnqueueFileTransfer(first);
    } else {
        while (*p) {
            std::wstring name = p;
            EnqueueFileTransfer(first + L"\\" + name);
            p += name.size() + 1;
        }
    }
}

// 前向声明：面板要能立即把放大的光标收回，以及呼出/切换悬浮投递盒
static void RefreshCursorScale();
static void ShowDropBoxWindow();
static void ToggleDropBoxWindow();

static std::atomic<bool> g_panelTopmost{false};
static std::atomic<ULONGLONG> g_connStartTick{0};
static std::atomic<double> g_srcP50{0.0}, g_srcP95{0.0}, g_presP50{0.0}, g_presP95{0.0};
static std::atomic<double> g_uiFps{0.0}, g_uiMbps{0.0};

// 主 Graphics 对象，控制面板查 GPU 显存用
static Graphics* g_gfx = nullptr;

// 防熄屏：Windows 在投屏期间收不到本地键鼠输入，默认 10 分钟（插电）/ 3 分钟（电池）
// 无操作就会自动息屏。必须在 UI 主线程调用 SetThreadExecutionState 声明保持常亮，
// 并在断连、最小化或取消勾选时由同一线程释放。
static void UpdateExecutionState() {
    const bool active = g_keepScreenOn.load() &&
                        g_sock.load() != INVALID_SOCKET &&
                        g_hwnd && !IsIconic(g_hwnd);
    static bool applied = false;
    if (active) {
        SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
        if (!applied) {
            applied = true;
            Log("防熄屏: 已声明显示保持常亮（投屏中）");
        }
    } else {
        if (applied) {
            SetThreadExecutionState(ES_CONTINUOUS);
            applied = false;
            Log("防熄屏: 已释放显示常亮声明");
        }
    }
}

// 实时读取窗口所在显示器的 DPI，不再静态永久缓存（跨屏拖动可正确重排）
static int PanelWindowDpi(HWND h) {
    HMODULE u32 = GetModuleHandleA("user32.dll");
    typedef UINT (WINAPI *GetDpiForWindowFn)(HWND);
    typedef UINT (WINAPI *GetDpiForSystemFn)(void);
    auto fw = (GetDpiForWindowFn)GetProcAddress(u32, "GetDpiForWindow");
    auto fs = (GetDpiForSystemFn)GetProcAddress(u32, "GetDpiForSystem");
    int dpi = 0;
    if (fw && h) dpi = (int)fw(h);
    if (dpi <= 0 && fw && g_hwnd) dpi = (int)fw(g_hwnd);
    if (dpi <= 0 && fs) dpi = (int)fs();
    return dpi > 0 ? dpi : 96;
}

static int DpiPx(int logicalPx, int dpi) {
    return MulDiv(logicalPx, dpi, 96);
}

static void AdjustRectDpi(RECT* rc, DWORD style, DWORD exStyle, int dpi) {
    HMODULE u32 = GetModuleHandleA("user32.dll");
    typedef BOOL (WINAPI *AdjustDpiFn)(LPRECT, DWORD, BOOL, DWORD, UINT);
    auto fn = (AdjustDpiFn)GetProcAddress(u32, "AdjustWindowRectExForDpi");
    if (fn) {
        fn(rc, style, FALSE, exStyle, (UINT)dpi);
    } else {
        AdjustWindowRectEx(rc, style, FALSE, exStyle);
    }
}

// 面板主题与字体资源：按 DPI 分组缓存，避免跨屏混合 DPI 下切换绘制时删除另一窗口仍在使用的 HFONT
struct PanelTheme {
    struct FontSet {
        HFONT title = nullptr;
        HFONT section = nullptr;
        HFONT body = nullptr;
        HFONT value = nullptr;
        HFONT smallFont = nullptr;
        HFONT mono = nullptr;
    };
    int dpi = 0;
    HFONT fontTitle = nullptr;
    HFONT fontSection = nullptr;
    HFONT fontBody = nullptr;
    HFONT fontValue = nullptr;
    HFONT fontSmall = nullptr;
    HFONT fontMono = nullptr;
    HBRUSH canvasBrush = nullptr;
    HBRUSH cardBrush = nullptr;
    std::unordered_map<int, FontSet> sets;

    static HFONT MakeFont(int pt, int weight, int targetDpi, const wchar_t* face = L"Microsoft YaHei UI") {
        return CreateFontW(
            -MulDiv(pt, targetDpi, 72), 0, 0, 0, weight, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, face);
    }

    void Ensure(int targetDpi) {
        if (!canvasBrush) canvasBrush = CreateSolidBrush(RGB(243, 245, 249));
        if (!cardBrush)   cardBrush   = CreateSolidBrush(RGB(255, 255, 255));
        if (dpi == targetDpi && fontBody) return;
        auto it = sets.find(targetDpi);
        if (it == sets.end()) {
            FontSet fs;
            fs.title     = MakeFont(12, FW_SEMIBOLD, targetDpi);
            fs.section   = MakeFont(9,  FW_SEMIBOLD, targetDpi);
            fs.body      = MakeFont(9,  FW_NORMAL,   targetDpi);
            fs.value     = MakeFont(9,  FW_SEMIBOLD, targetDpi);
            fs.smallFont = MakeFont(8,  FW_NORMAL,   targetDpi);
            fs.mono      = MakeFont(8,  FW_NORMAL,   targetDpi, L"Consolas");
            it = sets.emplace(targetDpi, fs).first;
        }
        dpi         = targetDpi;
        fontTitle   = it->second.title;
        fontSection = it->second.section;
        fontBody    = it->second.body;
        fontValue   = it->second.value;
        fontSmall   = it->second.smallFont;
        fontMono    = it->second.mono;
    }

    void ReleaseFonts() {
        for (auto& kv : sets) {
            if (kv.second.title)     DeleteObject(kv.second.title);
            if (kv.second.section)   DeleteObject(kv.second.section);
            if (kv.second.body)      DeleteObject(kv.second.body);
            if (kv.second.value)     DeleteObject(kv.second.value);
            if (kv.second.smallFont) DeleteObject(kv.second.smallFont);
            if (kv.second.mono)      DeleteObject(kv.second.mono);
        }
        sets.clear();
        fontTitle = fontSection = fontBody = fontValue = fontSmall = fontMono = nullptr;
        dpi = 0;
    }

    void ReleaseAll() {
        ReleaseFonts();
        if (canvasBrush) { DeleteObject(canvasBrush); canvasBrush = nullptr; }
        if (cardBrush)   { DeleteObject(cardBrush);   cardBrush = nullptr; }
    }
};

static PanelTheme g_theme;

// 面板展示指标快照（由 UpdateControlPanel 刷新，PaintControlPanel 双缓冲绘制）
struct PanelSnapshot {
    int state = 0;  // 0=未连接 1=已连接等待 2=正在接收
    std::wstring statusText = L"未连接，等待重连";
    std::wstring peerText = L"--";
    std::wstring sizeText = L"--";
    std::wstring uptimeText = L"00:00:00";
    std::wstring fpsText = L"0.0 fps";
    std::wstring mbpsText = L"0.0 Mbps";

    std::wstring srcLatText = L"p50 0.0 / p95 0.0 ms";
    std::wstring presLatText = L"p50 0.0 / p95 0.0 ms";
    std::wstring decFailText = L"0";
    std::wstring presFailText = L"0";
    std::wstring dupText = L"0";
    std::wstring dropText = L"0";
    bool decFailWarn = false;
    bool presFailWarn = false;
    bool dropWarn = false;

    std::wstring decoderText = L"--";
    std::wstring procMemText = L"--";
    std::wstring cpuText = L"--";
    std::wstring gpuMemText = L"--";
    std::wstring keepOnText = L"已开启 (防熄屏)";
    bool keepOnActive = true;
    bool xferConnected = false;
    std::wstring xferStatusText = L"等待中转站连接…";
    std::vector<std::wstring> recentLogs;
};

static PanelSnapshot g_panelData;
static HWND g_hoverBtn = nullptr;
static WNDPROC g_origBtnProc = nullptr;

static LRESULT CALLBACK PanelBtnSubclassProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_MOUSEMOVE) {
        if (g_hoverBtn != h) {
            HWND prev = g_hoverBtn;
            g_hoverBtn = h;
            if (prev) InvalidateRect(prev, nullptr, FALSE);
            TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, h, 0 };
            TrackMouseEvent(&tme);
            InvalidateRect(h, nullptr, FALSE);
        }
    } else if (msg == WM_MOUSELEAVE) {
        if (g_hoverBtn == h) {
            g_hoverBtn = nullptr;
            InvalidateRect(h, nullptr, FALSE);
        }
    } else if (msg == WM_NCDESTROY) {
        if (g_hoverBtn == h) g_hoverBtn = nullptr;
    }
    return CallWindowProcW(g_origBtnProc, h, msg, w, l);
}

static void RequestKeyframe() {
    if (g_hostMode.load()) {
        g_winHost.RequestKeyframe();
        Log("控制面板: 已触发发送端关键帧");
        return;
    }
    SOCKET s = g_sock.load();
    if (s == INVALID_SOCKET) {
        Log("控制面板: 请求关键帧失败，当前未连接");
        return;
    }
    uint8_t req = TYPE_KEYFRAME_REQUEST;
    int sent = 0;
    {
        std::lock_guard<std::mutex> lk(g_sendMtx);
        sent = send(s, (const char*)&req, 1, 0);
    }
    Log(sent == 1 ? "控制面板: 已请求关键帧（0x02）" : "控制面板: 请求关键帧失败");
}

static void OpenConfigFile() {
    char exe[MAX_PATH] = {};
    DWORD n = GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string dir = ".";
    if (n > 0 && n < MAX_PATH) {
        std::string p(exe, n);
        size_t pos = p.find_last_of("\\/");
        if (pos != std::string::npos) dir = p.substr(0, pos);
    }
    std::string cfg = dir + "\\config.ini";
    std::wstring target = ToWide(cfg.c_str(), (int)cfg.size());
    if (GetFileAttributesA(cfg.c_str()) == INVALID_FILE_ATTRIBUTES) {
        std::wstring wd = ToWide(dir.c_str(), (int)dir.size());
        ShellExecuteW(nullptr, L"open", wd.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        return;
    }
    ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

static void CopyDiagnostics() {
    char exe[MAX_PATH] = {};
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    int dw = g_displayW.load(), dh = g_displayH.load();
    if (dw <= 0 || dh <= 0) { dw = g_sessW.load(); dh = g_sessH.load(); }
    ULONGLONG start = g_connStartTick.load();
    unsigned long long up = start ? (GetTickCount64() - start) / 1000 : 0;
    // 硬件与资源：排障时这几项和延迟数据一样关键
    wchar_t decoderBuf[256] = L"--";
    {
        std::lock_guard<std::mutex> lk(g_decoderInfoMtx);
        wcsncpy(decoderBuf, g_decoderInfo.c_str(), 255);
    }
    double wsMb = 0, privMb = 0;
    {
        PROCESS_MEMORY_COUNTERS_EX pmc{};
        pmc.cb = sizeof(pmc);
        if (GetProcessMemoryInfo(GetCurrentProcess(),
                                 (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc))) {
            wsMb = pmc.WorkingSetSize / 1048576.0;
            privMb = pmc.PrivateUsage / 1048576.0;
        }
    }
    wchar_t buf[2048];
    if (g_hostMode.load()) {
        auto& hs = g_winHost.Stats();
        std::string peerStr;
        std::wstring encName;
        {
            std::lock_guard<std::mutex> lk(hs.infoMtx);
            peerStr = hs.peerAddr;
            encName = hs.encoderName;
        }
        ULONGLONG hStart = hs.connStartTick.load();
        unsigned long long hUp = (hs.clientConnected.load() && hStart) ? (GetTickCount64() - hStart) / 1000 : 0;
        bool vddOk = g_winHost.VddActive();
        std::string hostErr;
        {
            std::lock_guard<std::mutex> lk(hs.infoMtx);
            hostErr = hs.lastError;
        }
        swprintf(buf, 2048,
            L"SecDisplay 诊断（主控发送端 Win→Mac）\r\n"
            L"状态: %s\r\n"
            L"虚拟屏(VDD): %s%hs%s%hs\r\n"
            L"Mac 副屏: %hs\r\n"
            L"虚拟屏分辨率: %dx%d @ %dHz\r\n"
            L"连接时长: %llu 秒\r\n"
            L"帧率: %.1f fps  码率: %.1f Mbps (当前 %d / 目标 %d Mbps)\r\n"
            L"编码耗时: %.2f ms  失败: %llu  围栏超时: %llu  丢弃: %llu\r\n"
            L"光标发送: %llu  收到输入: %llu\r\n"
            L"编码器: %s\r\n"
            L"进程内存: 工作集 %.0f MB / 私有 %.0f MB\r\n"
            L"日志: %hs\r\n"
            L"程序: %hs",
            hs.clientConnected.load() ? L"已连接" : L"尝试连接 Mac 副屏",
            vddOk ? L"已挂载" : L"未就绪",
            hostErr.empty() ? "" : " (",
            hostErr.empty() ? L"" : ToWide(hostErr.c_str(), (int)hostErr.size()).c_str(),
            hostErr.empty() ? "" : ")",
            peerStr.c_str(),
            hs.width.load(), hs.height.load(), hs.fps.load(), hUp,
            g_uiFps.load(), g_uiMbps.load(), hs.bitrateMbps.load(), hs.targetBitrateMbps.load(),
            hs.lastEncMs.load(),
            (unsigned long long)hs.encodeFail.load(),
            (unsigned long long)hs.fenceTimeouts.load(),
            (unsigned long long)hs.framesDropped.load(),
            (unsigned long long)hs.cursorSent.load(),
            (unsigned long long)hs.inputRecv.load(),
            encName.c_str(), wsMb, privMb,
            g_logPath.c_str(), exe);
    } else {
        swprintf(buf, 2048,
            L"SecDisplay 诊断\r\n"
            L"状态: %s\r\n"
            L"对端: %hs:%d\r\n"
            L"分辨率: %dx%d\r\n"
            L"连接时长: %llu 秒\r\n"
            L"帧率: %.1f fps  码率: %.1f Mbps\r\n"
            L"源延迟: p50 %.1f / p95 %.1f ms\r\n"
            L"呈现延迟: p50 %.1f / p95 %.1f ms\r\n"
            L"解码失败: %llu  呈现失败: %llu\r\n"
            L"同帧重复: %llu  丢弃: %llu\r\n"
            L"解码器: %s\r\n"
            L"进程内存: 工作集 %.0f MB / 私有 %.0f MB\r\n"
            L"屏幕常亮: %s\r\n"
            L"日志: %hs\r\n"
            L"程序: %hs",
            g_sock.load() != INVALID_SOCKET ? L"已连接" : L"未连接",
            g_peerHost.c_str(), g_peerPort,
            dw, dh, up,
            g_uiFps.load(), g_uiMbps.load(),
            g_srcP50.load(), g_srcP95.load(),
            g_presP50.load(), g_presP95.load(),
            (unsigned long long)g_stats.decodeFail.load(),
            (unsigned long long)g_stats.presentFail.load(),
            (unsigned long long)g_stats.dupFrame.load(),
            (unsigned long long)g_stats.dropped.load(),
            decoderBuf, wsMb, privMb,
            g_keepScreenOn.load() ? L"开启（防熄屏）" : L"关闭",
            g_logPath.c_str(), exe);
    }
    if (OpenClipboard(g_panel)) {
        EmptyClipboard();
        size_t bytes = (wcslen(buf) + 1) * sizeof(wchar_t);
        HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if (h) {
            void* dst = GlobalLock(h);
            if (dst) {
                memcpy(dst, buf, bytes);
                GlobalUnlock(h);
                SetClipboardData(CF_UNICODETEXT, h);
            }
        }
        CloseClipboard();
    }
    Log("控制面板: 诊断信息已复制到剪贴板");
}

static void UpdateControlPanel() {
    if (!g_panel) return;

    const bool hostMode = g_hostMode.load();
    if (hostMode) {
        auto& hs = g_winHost.Stats();
        static uint64_t lastSentFrames = 0, lastSentBytes = 0;
        static ULONGLONG lastHostTick = 0;
        ULONGLONG now = GetTickCount64();
        uint64_t sentF = hs.framesSent.load();
        uint64_t sentB = hs.bytesSent.load();
        double fps = g_uiFps.load();
        double mbps = g_uiMbps.load();
        if (lastHostTick == 0 || sentF < lastSentFrames || sentB < lastSentBytes) {
            lastSentFrames = sentF;
            lastSentBytes = sentB;
            lastHostTick = now;
            fps = 0.0;
            mbps = 0.0;
        } else {
            double dt = (double)(now - lastHostTick) / 1000.0;
            if (dt >= 5.0) {
                lastSentFrames = sentF;
                lastSentBytes = sentB;
                lastHostTick = now;
            } else if (dt >= 0.2) {
                fps = (double)(sentF - lastSentFrames) / dt;
                mbps = (double)(sentB - lastSentBytes) * 8.0 / dt / 1e6;
                lastSentFrames = sentF;
                lastSentBytes = sentB;
                lastHostTick = now;
            }
        }
        g_uiFps.store(fps);
        g_uiMbps.store(mbps);

        bool connected = hs.clientConnected.load();
        bool vddOk = g_winHost.VddActive();
        bool kvmOn = hs.kvmActive.load();
        ULONGLONG lastTx = hs.lastSentTick.load();
        bool staticIdle = connected && sentF > 0 && lastTx > 0 && (GetTickCount64() - lastTx > 1500ULL);
        bool streaming = connected && sentF > 0;
        if (!vddOk) {
            g_panelData.state = 3;
            g_panelData.statusText = L"虚拟屏异常 · 请检查 Parsec VDD 或点击重挂";
        } else if (kvmOn) {
            g_panelData.state = 2;
            g_panelData.statusText = L"KVM 穿透中 · 键鼠正控制 Mac (Ctrl+Alt+K 退出)";
        } else if (streaming) {
            g_panelData.state = 2;
            g_panelData.statusText = staticIdle ? L"主控在线 · 桌面静止省流中" : L"主控发送中 · Mac 副屏在线";
        } else if (connected) {
            g_panelData.state = 1;
            g_panelData.statusText = L"Mac 已连接 · 准备推流";
        } else {
            g_panelData.state = 0;
            wchar_t waitBuf[128];
            swprintf(waitBuf, 128, L"主控待命 · 连接 Mac 副屏 (%d)", g_peerPort);
            g_panelData.statusText = waitBuf;
        }

        wchar_t buf[256];
        std::wstring encNameCopy;
        std::string errCopy;
        {
            std::lock_guard<std::mutex> lk(hs.infoMtx);
            std::wstring wp = ToWide(hs.peerAddr.c_str(), (int)hs.peerAddr.size());
            g_panelData.peerText = wp.empty() ? L"--" : wp;
            encNameCopy = hs.encoderName;
            g_panelData.decoderText = encNameCopy.empty() ? L"--" : encNameCopy;
            errCopy = hs.lastError;
        }
        if (vddOk && !connected && !errCopy.empty()) {
            g_panelData.state = 4;
            g_panelData.statusText = ToWide(errCopy.c_str(), (int)errCopy.size());
        }
        swprintf(buf, 256, L"%d × %d @ %dHz", hs.width.load(), hs.height.load(), hs.fps.load());
        g_panelData.sizeText = buf;

        ULONGLONG start = hs.connStartTick.load();
        unsigned long long up = (connected && start) ? (GetTickCount64() - start) / 1000 : 0;
        swprintf(buf, 256, L"%02llu:%02llu:%02llu", up / 3600, (up / 60) % 60, up % 60);
        g_panelData.uptimeText = buf;

        swprintf(buf, 256, L"%.1f fps", fps);
        g_panelData.fpsText = buf;
        swprintf(buf, 256, L"%.1f Mbps (%d/%dM)", mbps, hs.bitrateMbps.load(), hs.targetBitrateMbps.load());
        g_panelData.mbpsText = buf;

        swprintf(buf, 256, L"%.2f ms", hs.lastEncMs.load());
        g_panelData.srcLatText = buf;
        swprintf(buf, 256, L"光标 %llu / 输入 %llu",
                 (unsigned long long)hs.cursorSent.load(),
                 (unsigned long long)hs.inputRecv.load());
        g_panelData.presLatText = buf;

        uint64_t encFail = hs.encodeFail.load();
        uint64_t fenceTo = hs.fenceTimeouts.load();
        uint64_t drop = hs.framesDropped.load();
        if (fenceTo > 0) {
            swprintf(buf, 256, L"%llu (围栏 %llu)", (unsigned long long)encFail, (unsigned long long)fenceTo);
        } else {
            swprintf(buf, 256, L"%llu", (unsigned long long)encFail);
        }
        g_panelData.decFailText = buf;
        g_panelData.decFailWarn = (encFail > 0 || fenceTo > 0);
        swprintf(buf, 256, L"%llu", (unsigned long long)hs.framesSent.load());
        g_panelData.presFailText = buf;
        g_panelData.presFailWarn = false;
        swprintf(buf, 256, L"%llu", (unsigned long long)hs.inputRecv.load());
        g_panelData.dupText = buf;
        swprintf(buf, 256, L"%llu", (unsigned long long)drop);
        g_panelData.dropText = buf;
        g_panelData.dropWarn = drop > 0;

        PROCESS_MEMORY_COUNTERS_EX pmc{};
        pmc.cb = sizeof(pmc);
        if (GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc))) {
            swprintf(buf, 256, L"工作集 %.0f / 私有 %.0f MB",
                     pmc.WorkingSetSize / 1048576.0, pmc.PrivateUsage / 1048576.0);
            g_panelData.procMemText = buf;
        }
        if (encNameCopy.find(L"(硬件)") != std::wstring::npos) {
            g_panelData.cpuText = L"硬件编码加速";
        } else if (encNameCopy.find(L"(软件)") != std::wstring::npos) {
            g_panelData.cpuText = L"软件编码兜底";
        } else {
            g_panelData.cpuText = L"--";
        }
        g_panelData.gpuMemText = vddOk ? L"Parsec VDD 已挂载" : L"Parsec VDD 未挂载";
        g_panelData.keepOnActive = vddOk;
        g_panelData.keepOnText = vddOk ? L"虚拟屏运行中" : L"虚拟屏未就绪";
        g_panelData.xferConnected = g_xferConnected.load();
        {
            std::lock_guard<std::mutex> lk(g_xferMtx);
            g_panelData.xferStatusText = g_xferStatus;
        }
        {
            std::lock_guard<std::mutex> lk(g_logLock);
            g_panelData.recentLogs.clear();
            size_t total = g_recentLogs.size();
            size_t startIdx = (total > 4) ? (total - 4) : 0;
            for (size_t i = startIdx; i < total; ++i) g_panelData.recentLogs.push_back(g_recentLogs[i]);
        }
        SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_MODE), L"切回副屏模式");
        SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_FULL), L"显示设置");
        SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_RECONN), L"断开重连");
        SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_KVM),
                       hs.kvmActive.load() ? L"退出穿透 (Ctrl+Alt+K)" : L"键鼠控 Mac (Ctrl+Alt+K)");
        InvalidateRect(g_panel, nullptr, FALSE);
        return;
    }

    static uint64_t lastDecoded = 0, lastBytes = 0;
    static ULONGLONG lastTick = 0;
    ULONGLONG now = GetTickCount64();
    uint64_t decoded = g_stats.decoded.load();
    uint64_t bytes = g_stats.bytes.load();
    // 沿用上一次算出的值：面板显示时可能连续调用，dt 接近 0 时
    // 不能把帧率写成 0 并污染「复制诊断」。
    double fps = g_uiFps.load();
    double mbps = g_uiMbps.load();
    if (lastTick == 0) {
        lastDecoded = decoded;
        lastBytes = bytes;
        lastTick = now;
    } else if (decoded < lastDecoded || bytes < lastBytes) {
        lastDecoded = decoded;
        lastBytes = bytes;
        lastTick = now;
        fps = 0.0;
        mbps = 0.0;
    } else {
        double dt = (double)(now - lastTick) / 1000.0;
        if (dt >= 5.0) {
            lastDecoded = decoded;
            lastBytes = bytes;
            lastTick = now;
        } else if (dt >= 0.2) {
            fps = (double)(decoded - lastDecoded) / dt;
            mbps = (double)(bytes - lastBytes) * 8.0 / dt / 1e6;
            lastDecoded = decoded;
            lastBytes = bytes;
            lastTick = now;
        }
    }
    g_uiFps.store(fps);
    g_uiMbps.store(mbps);

    bool connected = g_sock.load() != INVALID_SOCKET;
    bool receiving = connected && g_stats.packets.load() > 0;
    g_panelData.state = receiving ? 2 : (connected ? 1 : 0);
    g_panelData.statusText = receiving ? L"已连接 · 正在接收"
                         : (connected ? L"已连接 · 等待画面" : L"未连接 · 等待重连");

    wchar_t buf[256];
    std::wstring host = ToWide(g_peerHost.c_str(), (int)g_peerHost.size());
    swprintf(buf, 256, L"%s:%d", host.c_str(), g_peerPort);
    g_panelData.peerText = buf;

    int dw = g_displayW.load(), dh = g_displayH.load();
    if (dw <= 0 || dh <= 0) { dw = g_sessW.load(); dh = g_sessH.load(); }
    swprintf(buf, 256, L"%d × %d", dw, dh);
    g_panelData.sizeText = buf;

    ULONGLONG start = g_connStartTick.load();
    unsigned long long up = start ? (GetTickCount64() - start) / 1000 : 0;
    swprintf(buf, 256, L"%02llu:%02llu:%02llu", up / 3600, (up / 60) % 60, up % 60);
    g_panelData.uptimeText = buf;

    swprintf(buf, 256, L"%.1f fps", fps);
    g_panelData.fpsText = buf;
    swprintf(buf, 256, L"%.1f Mbps", mbps);
    g_panelData.mbpsText = buf;

    swprintf(buf, 256, L"p50 %.1f / p95 %.1f ms", g_srcP50.load(), g_srcP95.load());
    g_panelData.srcLatText = buf;
    swprintf(buf, 256, L"p50 %.1f / p95 %.1f ms", g_presP50.load(), g_presP95.load());
    g_panelData.presLatText = buf;

    uint64_t decFail = g_stats.decodeFail.load();
    uint64_t presFail = g_stats.presentFail.load();
    uint64_t dup = g_stats.dupFrame.load();
    uint64_t drop = g_stats.dropped.load();
    swprintf(buf, 256, L"%llu", (unsigned long long)decFail);
    g_panelData.decFailText = buf;
    g_panelData.decFailWarn = decFail > 0;
    swprintf(buf, 256, L"%llu", (unsigned long long)presFail);
    g_panelData.presFailText = buf;
    g_panelData.presFailWarn = presFail > 0;
    swprintf(buf, 256, L"%llu", (unsigned long long)dup);
    g_panelData.dupText = buf;
    swprintf(buf, 256, L"%llu", (unsigned long long)drop);
    g_panelData.dropText = buf;
    g_panelData.dropWarn = drop > 0;

    {
        std::lock_guard<std::mutex> lk(g_decoderInfoMtx);
        g_panelData.decoderText = g_decoderInfo.empty() ? L"--" : g_decoderInfo;
    }

    {
        PROCESS_MEMORY_COUNTERS_EX pmc{};
        pmc.cb = sizeof(pmc);
        if (GetProcessMemoryInfo(GetCurrentProcess(),
                                 (PROCESS_MEMORY_COUNTERS*)&pmc, sizeof(pmc))) {
            swprintf(buf, 256, L"工作集 %.0f / 私有 %.0f MB",
                     pmc.WorkingSetSize / 1048576.0, pmc.PrivateUsage / 1048576.0);
            g_panelData.procMemText = buf;
        }
    }

    {
        static ULONGLONG lastCpuTick = 0;
        static ULONGLONG lastKernel = 0, lastUser = 0;
        FILETIME ct, et, kt, ut;
        if (GetProcessTimes(GetCurrentProcess(), &ct, &et, &kt, &ut)) {
            ULONGLONG k = ((ULONGLONG)kt.dwHighDateTime << 32) | kt.dwLowDateTime;
            ULONGLONG u = ((ULONGLONG)ut.dwHighDateTime << 32) | ut.dwLowDateTime;
            static double cpuPct = 0.0;
            if (lastCpuTick != 0) {
                double dtMs = (double)(now - lastCpuTick);
                if (dtMs > 100.0) {
                    double busyMs = (double)((k - lastKernel) + (u - lastUser)) / 10000.0;
                    cpuPct = busyMs / dtMs * 100.0;
                }
            }
            lastCpuTick = now;
            lastKernel = k;
            lastUser = u;
            SYSTEM_INFO si{};
            GetSystemInfo(&si);
            int cores = si.dwNumberOfProcessors > 0 ? (int)si.dwNumberOfProcessors : 1;
            swprintf(buf, 256, L"%.1f%% (单核 %.1f%%)", cpuPct / cores, cpuPct);
            g_panelData.cpuText = buf;
        }
    }

    {
        static IDXGIAdapter3* adapter3 = nullptr;
        static bool probed = false;
        if (!probed) {
            if (g_gfx && g_gfx->device) {
                ComPtr<IDXGIDevice> dxgiDev;
                if (SUCCEEDED(g_gfx->device.As(&dxgiDev)) && dxgiDev) {
                    ComPtr<IDXGIAdapter> ad;
                    if (SUCCEEDED(dxgiDev->GetAdapter(&ad)) && ad) {
                        ComPtr<IDXGIAdapter3> a3;
                        if (SUCCEEDED(ad.As(&a3))) {
                            adapter3 = a3.Detach();
                            probed = true;
                        }
                    }
                }
            }
        }
        if (adapter3) {
            DXGI_QUERY_VIDEO_MEMORY_INFO info{};
            if (SUCCEEDED(adapter3->QueryVideoMemoryInfo(0, DXGI_MEMORY_SEGMENT_GROUP_LOCAL, &info))) {
                swprintf(buf, 256, L"%.0f / 预算 %.0f MB",
                         info.CurrentUsage / 1048576.0, info.Budget / 1048576.0);
                g_panelData.gpuMemText = buf;
            }
        }
    }

    const bool keepActive = g_keepScreenOn.load() && connected && g_hwnd && !IsIconic(g_hwnd);
    g_panelData.keepOnActive = keepActive;
    g_panelData.keepOnText = !g_keepScreenOn.load() ? L"已关闭"
                           : (keepActive ? L"常亮生效中" : L"待命（未投屏）");

    g_panelData.xferConnected = g_xferConnected.load();
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        g_panelData.xferStatusText = g_xferStatus;
    }
    {
        std::lock_guard<std::mutex> lk(g_logLock);
        g_panelData.recentLogs.clear();
        size_t total = g_recentLogs.size();
        size_t startIdx = (total > 4) ? (total - 4) : 0;
        for (size_t i = startIdx; i < total; ++i) {
            g_panelData.recentLogs.push_back(g_recentLogs[i]);
        }
    }

    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_MODE), L"切到主控(Mac当副屏)");
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_FULL),
                   g_isFullscreen ? L"回到窗口" : L"全屏显示");
    SetWindowTextW(GetDlgItem(g_panel, IDC_PANEL_TOP),
                   g_panelTopmost.load() ? L"取消置顶" : L"窗口置顶");

    // 触发双缓冲重绘（背景已由 WM_PAINT 全包，传 FALSE 零闪烁）
    InvalidateRect(g_panel, nullptr, FALSE);
}

// GDI+ 抗锯齿圆角矩形路径（同时支持仅上圆角/全圆角）
static void AddRoundRectPath(Gdiplus::GraphicsPath& path, float x, float y, float w, float h,
                             float rTL, float rTR, float rBR, float rBL) {
    path.Reset();
    auto clampR = [&](float r) { return std::max(0.0f, std::min(r, std::min(w, h) * 0.5f)); };
    rTL = clampR(rTL); rTR = clampR(rTR); rBR = clampR(rBR); rBL = clampR(rBL);
    if (rTL > 0) path.AddArc(x, y, rTL * 2, rTL * 2, 180, 90); else path.AddLine(x, y, x, y);
    if (rTR > 0) path.AddArc(x + w - rTR * 2, y, rTR * 2, rTR * 2, 270, 90); else path.AddLine(x + w, y, x + w, y);
    if (rBR > 0) path.AddArc(x + w - rBR * 2, y + h - rBR * 2, rBR * 2, rBR * 2, 0, 90); else path.AddLine(x + w, y + h, x + w, y + h);
    if (rBL > 0) path.AddArc(x, y + h - rBL * 2, rBL * 2, rBL * 2, 90, 90); else path.AddLine(x, y + h, x, y + h);
    path.CloseFigure();
}

static Gdiplus::Color ToGpColor(COLORREF c, BYTE a = 255) {
    return Gdiplus::Color(a, GetRValue(c), GetGValue(c), GetBValue(c));
}

// 绘制抗锯齿圆角卡片（GDI+ 双缓冲使用）
static void DrawPanelCard(HDC hdc, int x, int y, int w, int h, int radius,
                          COLORREF fill, COLORREF border) {
    Gdiplus::Graphics g(hdc);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
    Gdiplus::GraphicsPath path;
    AddRoundRectPath(path, (float)x, (float)y, (float)w, (float)h,
                     (float)radius, (float)radius, (float)radius, (float)radius);
    Gdiplus::SolidBrush br(ToGpColor(fill));
    g.FillPath(&br, &path);
    Gdiplus::Pen pen(ToGpColor(border), 1.0f);
    g.DrawPath(&pen, &path);
}

static void DrawKVRow(HDC hdc, int x, int y, int w, int rowH,
                      const wchar_t* label, const wchar_t* value,
                      COLORREF valColor = RGB(15, 23, 42)) {
    RECT rL{ x, y, x + w / 2, y + rowH };
    RECT rV{ x + w / 3, y, x + w, y + rowH };
    SelectObject(hdc, g_theme.fontBody);
    SetTextColor(hdc, RGB(100, 116, 139));
    DrawTextW(hdc, label, -1, &rL, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    SelectObject(hdc, g_theme.fontValue);
    SetTextColor(hdc, valColor);
    DrawTextW(hdc, value, -1, &rV, DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
}

static void PaintControlPanel(HWND h) {
    PAINTSTRUCT ps{};
    HDC screenDc = BeginPaint(h, &ps);
    RECT cli{};
    GetClientRect(h, &cli);
    const int cw = cli.right - cli.left;
    const int ch = cli.bottom - cli.top;
    if (cw <= 0 || ch <= 0) { EndPaint(h, &ps); return; }

    const int dpi = PanelWindowDpi(h);
    g_theme.Ensure(dpi);
    auto S = [&](int v) { return DpiPx(v, dpi); };

    HDC hdc = CreateCompatibleDC(screenDc);
    HBITMAP bmp = CreateCompatibleBitmap(screenDc, cw, ch);
    HGDIOBJ oldBmp = SelectObject(hdc, bmp);
    SetBkMode(hdc, TRANSPARENT);

    // 画布底色
    FillRect(hdc, &cli, g_theme.canvasBrush);

    const COLORREF cardFill   = RGB(255, 255, 255);
    const COLORREF cardBorder = RGB(224, 230, 239);
    const COLORREF sepColor   = RGB(238, 241, 246);
    const COLORREF titleCol   = RGB(30, 41, 59);
    const COLORREF mutedCol   = RGB(100, 116, 139);
    const COLORREF valCol     = RGB(15, 23, 42);
    const COLORREF okCol      = RGB(22, 163, 74);
    const COLORREF warnCol    = RGB(217, 119, 6);
    const COLORREF errCol     = RGB(220, 38, 38);

    // 1. 顶部状态横幅 (20, 12, 920, 44)
    DrawPanelCard(hdc, S(20), S(12), S(920), S(44), S(8), cardFill, cardBorder);
    COLORREF dotCol = g_panelData.state == 2 ? okCol
                    : (g_panelData.state == 1 ? warnCol
                    : ((g_panelData.state == 3 || g_panelData.state == 4) ? errCol : RGB(148, 163, 184)));
    {
        int d = S(10), dx = S(38), dy = S(12) + (S(44) - d) / 2;
        HPEN dp = CreatePen(PS_SOLID, 1, dotCol);
        HBRUSH db = CreateSolidBrush(dotCol);
        HGDIOBJ op = SelectObject(hdc, dp), ob = SelectObject(hdc, db);
        Ellipse(hdc, dx, dy, dx + d, dy + d);
        SelectObject(hdc, ob); SelectObject(hdc, op);
        DeleteObject(db); DeleteObject(dp);
    }
    {
        RECT rt{ S(58), S(12), S(455), S(56) };
        SelectObject(hdc, g_theme.fontTitle);
        SetTextColor(hdc, titleCol);
        DrawTextW(hdc, g_panelData.statusText.c_str(), -1, &rt,
                  DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    }
    {
        std::wstring summary = g_panelData.peerText + L"   ·   " +
                               g_panelData.sizeText + L"   ·   " +
                               g_panelData.uptimeText;
        RECT rs{ S(455), S(12), S(752), S(56) };
        SelectObject(hdc, g_theme.fontBody);
        SetTextColor(hdc, mutedCol);
        DrawTextW(hdc, summary.c_str(), -1, &rs,
                  DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    }

    // 2. 中部三张信息卡片 (y=66, h=228)
    auto drawSectionHeader = [&](int x, int y, int w, const wchar_t* title) {
        RECT rt{ x + S(16), y + S(9), x + w - S(16), y + S(32) };
        SelectObject(hdc, g_theme.fontSection);
        SetTextColor(hdc, titleCol);
        DrawTextW(hdc, title, -1, &rt, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        HPEN sp = CreatePen(PS_SOLID, 1, sepColor);
        HGDIOBJ op = SelectObject(hdc, sp);
        MoveToEx(hdc, x + S(16), y + S(36), nullptr);
        LineTo(hdc, x + w - S(16), y + S(36));
        SelectObject(hdc, op);
        DeleteObject(sp);
    };

    // 卡片 1：连接与速率 (20, 66, 286, 228)
    const int c1x = S(20), c1w = S(286), cy = S(66), chCard = S(228);
    DrawPanelCard(hdc, c1x, cy, c1w, chCard, S(8), cardFill, cardBorder);
    drawSectionHeader(c1x, cy, c1w, L"连接与速率");
    {
        int px = c1x + S(16), pw = c1w - S(32), rowY = cy + S(44), step = S(29), rh = S(25);
        const bool hm = g_hostMode.load();
        const wchar_t* shortSt = g_panelData.state == 2 ? (hm ? L"主控推送中" : L"正在接收")
                               : (g_panelData.state == 1 ? (hm ? L"准备推流" : L"等待首帧")
                               : (g_panelData.state == 4 ? L"角色/协议冲突"
                               : (g_panelData.state == 3 ? L"虚拟屏异常"
                                                         : (hm ? L"主控待命" : L"等待重连"))));
        DrawKVRow(hdc, px, rowY, pw, rh, L"连接状态", shortSt, dotCol);
        DrawKVRow(hdc, px, rowY + step * 1, pw, rh, L"对端地址", g_panelData.peerText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 2, pw, rh, L"分辨率",   g_panelData.sizeText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 3, pw, rh, L"连接时长", g_panelData.uptimeText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 4, pw, rh, L"当前帧率", g_panelData.fpsText.c_str(), RGB(37, 99, 235));
        DrawKVRow(hdc, px, rowY + step * 5, pw, rh, L"实时码率", g_panelData.mbpsText.c_str(), valCol);
    }

    // 卡片 2：延迟与质量 (320, 66, 292, 228)
    const int c2x = S(320), c2w = S(292);
    DrawPanelCard(hdc, c2x, cy, c2w, chCard, S(8), cardFill, cardBorder);
    drawSectionHeader(c2x, cy, c2w, g_hostMode.load() ? L"编码与输入" : L"延迟与质量");
    {
        int px = c2x + S(16), pw = c2w - S(32), rowY = cy + S(44), step = S(29), rh = S(25);
        const bool hm = g_hostMode.load();
        DrawKVRow(hdc, px, rowY, pw, rh, hm ? L"编码耗时" : L"源端延迟", g_panelData.srcLatText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 1, pw, rh, hm ? L"光标与输入" : L"呈现延迟", g_panelData.presLatText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 2, pw, rh, hm ? L"编码失败" : L"解码失败", g_panelData.decFailText.c_str(),
                  g_panelData.decFailWarn ? errCol : valCol);
        DrawKVRow(hdc, px, rowY + step * 3, pw, rh, hm ? L"累计发送" : L"上屏失败", g_panelData.presFailText.c_str(),
                  g_panelData.presFailWarn ? errCol : valCol);
        DrawKVRow(hdc, px, rowY + step * 4, pw, rh, hm ? L"收到输入" : L"同帧重复", g_panelData.dupText.c_str(), valCol);
        DrawKVRow(hdc, px, rowY + step * 5, pw, rh, L"丢弃帧数", g_panelData.dropText.c_str(),
                  g_panelData.dropWarn ? warnCol : valCol);
    }

    // 卡片 3：硬件与资源 (626, 66, 314, 228)
    const int c3x = S(626), c3w = S(314);
    DrawPanelCard(hdc, c3x, cy, c3w, chCard, S(8), cardFill, cardBorder);
    drawSectionHeader(c3x, cy, c3w, L"硬件与资源");
    {
        int px = c3x + S(16), pw = c3w - S(32), rowY = cy + S(44), rh = S(25);
        // 解码器/编码器名往往较长，给 42dp 双行空间不截断
        RECT rDecL{ px, rowY, px + S(72), rowY + rh };
        SelectObject(hdc, g_theme.fontBody);
        SetTextColor(hdc, mutedCol);
        DrawTextW(hdc, g_hostMode.load() ? L"编码器" : L"解码器", -1, &rDecL, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        RECT rDecV{ px + S(66), rowY + S(2), px + pw, rowY + S(42) };
        SelectObject(hdc, g_theme.fontValue);
        SetTextColor(hdc, valCol);
        DrawTextW(hdc, g_panelData.decoderText.c_str(), -1, &rDecV,
                  DT_RIGHT | DT_WORDBREAK | DT_END_ELLIPSIS);

        const bool hm = g_hostMode.load();
        int r2 = rowY + S(46), step = S(31);
        DrawKVRow(hdc, px, r2,            pw, rh, L"进程内存", g_panelData.procMemText.c_str(), valCol);
        DrawKVRow(hdc, px, r2 + step * 1, pw, rh, hm ? L"编码管线" : L"CPU 占用", g_panelData.cpuText.c_str(), valCol);
        DrawKVRow(hdc, px, r2 + step * 2, pw, rh, hm ? L"虚拟副屏" : L"GPU 显存", g_panelData.gpuMemText.c_str(), valCol);
        DrawKVRow(hdc, px, r2 + step * 3, pw, rh, hm ? L"挂载状态" : L"屏幕常亮", g_panelData.keepOnText.c_str(),
                  g_panelData.keepOnActive ? okCol : warnCol);
    }

    // 3. 雷电双向文件中转站卡片 (20, 304, 920, 64)
    DrawPanelCard(hdc, S(20), S(304), S(920), S(64), S(8), cardFill, cardBorder);
    {
        COLORREF xCol = g_panelData.xferConnected ? okCol : RGB(148, 163, 184);
        int xd = S(8), xdx = S(36), xdy = S(316) + (S(20) - xd) / 2;
        HPEN xpen = CreatePen(PS_SOLID, 1, xCol);
        HBRUSH xbr = CreateSolidBrush(xCol);
        HGDIOBJ op = SelectObject(hdc, xpen), ob = SelectObject(hdc, xbr);
        Ellipse(hdc, xdx, xdy, xdx + xd, xdy + xd);
        SelectObject(hdc, ob); SelectObject(hdc, op);
        DeleteObject(xbr); DeleteObject(xpen);

        RECT rxt{ S(52), S(312), S(490), S(336) };
        SelectObject(hdc, g_theme.fontSection);
        SetTextColor(hdc, titleCol);
        DrawTextW(hdc, g_panelData.xferConnected
                  ? L"雷电文件中转站 · 已连接 (9923)"
                  : L"雷电文件中转站 · 等待连接 (9923)",
                  -1, &rxt, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        RECT rxs{ S(36), S(337), S(495), S(362) };
        SelectObject(hdc, g_theme.fontBody);
        SetTextColor(hdc, mutedCol);
        DrawTextW(hdc, g_panelData.xferStatusText.c_str(), -1, &rxs,
                  DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    }

    // 4. 控制区卡片 (20, 378, 920, 156)
    DrawPanelCard(hdc, S(20), S(378), S(920), S(156), S(8), cardFill, cardBorder);
    {
        HPEN sp = CreatePen(PS_SOLID, 1, sepColor);
        HGDIOBJ op = SelectObject(hdc, sp);
        MoveToEx(hdc, S(38), S(482), nullptr);
        LineTo(hdc, S(922), S(482));
        SelectObject(hdc, op);
        DeleteObject(sp);
    }

    // 5. 内嵌实时运行日志卡片 (20, 544, 920, 104) —— 替代后台 cmd 黑框
    DrawPanelCard(hdc, S(20), S(544), S(920), S(104), S(8), cardFill, cardBorder);
    {
        RECT rlh{ S(36), S(551), S(240), S(573) };
        SelectObject(hdc, g_theme.fontSection);
        SetTextColor(hdc, titleCol);
        DrawTextW(hdc, L"运行日志（实时）", -1, &rlh, DT_LEFT | DT_VCENTER | DT_SINGLELINE);

        if (!g_logPath.empty()) {
            std::wstring wp = ToWide(g_logPath.c_str(), (int)g_logPath.size());
            RECT rlp{ S(240), S(551), S(924), S(573) };
            SelectObject(hdc, g_theme.fontSmall);
            SetTextColor(hdc, mutedCol);
            DrawTextW(hdc, wp.c_str(), -1, &rlp, DT_RIGHT | DT_VCENTER | DT_SINGLELINE | DT_PATH_ELLIPSIS);
        }

        HPEN sp = CreatePen(PS_SOLID, 1, sepColor);
        HGDIOBJ op = SelectObject(hdc, sp);
        MoveToEx(hdc, S(36), S(576), nullptr);
        LineTo(hdc, S(924), S(576));
        SelectObject(hdc, op);
        DeleteObject(sp);

        SelectObject(hdc, g_theme.fontMono ? g_theme.fontMono : g_theme.fontSmall);
        SetTextColor(hdc, RGB(51, 65, 85));
        if (g_panelData.recentLogs.empty()) {
            RECT rle{ S(36), S(582), S(924), S(640) };
            DrawTextW(hdc, L"暂无日志输出", -1, &rle, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        } else {
            for (size_t i = 0; i < g_panelData.recentLogs.size() && i < 4; ++i) {
                int ly = S(581) + (int)i * S(15);
                RECT rl{ S(36), ly, S(924), ly + S(15) };
                DrawTextW(hdc, g_panelData.recentLogs[i].c_str(), -1, &rl,
                          DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
            }
        }
    }

    // 6. 最底部快捷键提示 (20, 654, 920, 22)
    {
        RECT rf{ S(20), S(654), S(940), S(676) };
        SelectObject(hdc, g_theme.fontSmall);
        SetTextColor(hdc, mutedCol);
        DrawTextW(hdc, L"Esc 退出投屏   ·   Ctrl+Alt+H 让位   ·   Ctrl+Alt+B 文件投递盒   ·   F11 切换全屏   ·   拖入文件直传 Mac",
                  -1, &rf, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }

    BitBlt(screenDc, 0, 0, cw, ch, hdc, 0, 0, SRCCOPY);
    SelectObject(hdc, oldBmp);
    DeleteObject(bmp);
    DeleteDC(hdc);
    EndPaint(h, &ps);
}

// 自绘现代圆角按钮
static void DrawPanelButton(const DRAWITEMSTRUCT* dis, int dpi) {
    if (!dis) return;
    HDC hdc = dis->hDC;
    RECT rc = dis->rcItem;
    const int id = (int)dis->CtlID;
    const bool pressed = (dis->itemState & ODS_SELECTED) != 0;
    const bool hovered = (dis->hwndItem == g_hoverBtn);
    const bool isExit = (id == IDC_PANEL_EXIT);
    const bool isPrimary = (id == IDC_PANEL_FULL);

    // 先用白卡底色填充四周死角，避免圆角外露出黑边
    FillRect(hdc, &rc, g_theme.cardBrush);

    COLORREF bg = RGB(248, 250, 252);
    COLORREF bd = RGB(214, 221, 232);
    COLORREF fg = RGB(30, 41, 59);
    if (isExit) {
        bg = pressed ? RGB(254, 202, 202) : (hovered ? RGB(254, 226, 226) : RGB(254, 242, 242));
        bd = RGB(252, 165, 165);
        fg = RGB(185, 28, 28);
    } else if (isPrimary) {
        bg = pressed ? RGB(29, 78, 216) : (hovered ? RGB(37, 99, 235) : RGB(59, 130, 246));
        bd = bg;
        fg = RGB(255, 255, 255);
    } else {
        if (pressed)      { bg = RGB(226, 232, 240); bd = RGB(148, 163, 184); }
        else if (hovered) { bg = RGB(241, 245, 249); bd = RGB(180, 190, 206); }
    }

    int rad = DpiPx(6, dpi);
    Gdiplus::Graphics g(hdc);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
    Gdiplus::GraphicsPath path;
    AddRoundRectPath(path, (float)rc.left + 0.5f, (float)rc.top + 0.5f,
                     (float)(rc.right - rc.left) - 1.0f, (float)(rc.bottom - rc.top) - 1.0f,
                     (float)rad, (float)rad, (float)rad, (float)rad);
    Gdiplus::SolidBrush br(ToGpColor(bg));
    g.FillPath(&br, &path);
    Gdiplus::Pen pen(ToGpColor(bd), 1.0f);
    g.DrawPath(&pen, &path);

    wchar_t text[128] = {};
    GetWindowTextW(dis->hwndItem, text, 128);
    SetBkMode(hdc, TRANSPARENT);
    SelectObject(hdc, g_theme.fontValue);
    SetTextColor(hdc, fg);
    DrawTextW(hdc, text, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

static void LayoutPanelControls(HWND h) {
    const int dpi = PanelWindowDpi(h);
    g_theme.Ensure(dpi);
    auto S = [&](int v) { return DpiPx(v, dpi); };

    auto mv = [&](int id, int x, int y, int w, int ch) {
        HWND c = GetDlgItem(h, id);
        if (!c) return;
        SendMessageW(c, WM_SETFONT, (WPARAM)g_theme.fontBody, FALSE);
        MoveWindow(c, S(x), S(y), S(w), S(ch), TRUE);
    };

    // 顶部横幅右侧角色切换按钮
    mv(IDC_PANEL_MODE,       762, 18,  166, 32);

    // 中转站右侧按钮（发送文件 / 粘贴截图 / 悬浮盒 / 打开目录）
    mv(IDC_PANEL_SENDFILE,   504, 319, 108, 34);
    mv(IDC_PANEL_PASTEXFER,  620, 319, 102, 34);
    mv(IDC_PANEL_DROPBOX,    730, 319, 94,  34);
    mv(IDC_PANEL_OPENXFER,   832, 319, 90,  34);

    // 两行 4 列按钮：卡片宽 920 (20..940)，内边距 18 -> 38..922 (宽 884)，
    // 4 * 210 + 3 * 14 = 882，左右居中
    const int bx[4] = { 39, 263, 487, 711 };
    const int bw = 210, bh = 36;
    mv(IDC_PANEL_FULL,   bx[0], 392, bw, bh);
    mv(IDC_PANEL_TOP,    bx[1], 392, bw, bh);
    mv(IDC_PANEL_KEY,    bx[2], 392, bw, bh);
    mv(IDC_PANEL_RECONN, bx[3], 392, bw, bh);
    mv(IDC_PANEL_LOG,    bx[0], 436, bw, bh);
    mv(IDC_PANEL_CFG,    bx[1], 436, bw, bh);
    mv(IDC_PANEL_COPY,   bx[2], 436, bw, bh);
    mv(IDC_PANEL_EXIT,   bx[3], 436, bw, bh);

    // 5 个选项开关均匀排在分隔线下方（主控发送模式下隐藏接收端开关，改为展示主控虚拟屏/码率控制）
    const int chkShow = g_hostMode.load() ? SW_HIDE : SW_SHOW;
    const int hostShow = g_hostMode.load() ? SW_SHOW : SW_HIDE;
    auto mvChk = [&](int id, int x, int y, int w, int ch) {
        mv(id, x, y, w, ch);
        if (HWND c = GetDlgItem(h, id)) ShowWindow(c, chkShow);
    };
    auto mvHost = [&](int id, int x, int y, int w, int ch) {
        mv(id, x, y, w, ch);
        if (HWND c = GetDlgItem(h, id)) ShowWindow(c, hostShow);
    };
    mvChk(IDC_PANEL_VSYNC,    39,  494, 130, 28);
    mvChk(IDC_PANEL_PACE,     185, 494, 130, 28);
    mvChk(IDC_PANEL_FEEDBACK, 331, 494, 130, 28);
    mvChk(IDC_PANEL_SHAKE,    477, 494, 165, 28);
    mvChk(IDC_PANEL_KEEPON,   658, 494, 250, 28);

    mvHost(IDC_PANEL_RES_2880,  39,  491, 96,  32);
    mvHost(IDC_PANEL_RES_2560,  143, 491, 96,  32);
    mvHost(IDC_PANEL_RES_1920,  247, 491, 96,  32);
    mvHost(IDC_PANEL_MBPS_30,   355, 491, 68,  32);
    mvHost(IDC_PANEL_MBPS_50,   431, 491, 68,  32);
    mvHost(IDC_PANEL_MBPS_80,   507, 491, 68,  32);
    mvHost(IDC_PANEL_VDD_RETRY, 587, 491, 134, 32);
    mvHost(IDC_PANEL_KVM,       731, 491, 190, 32);
}

static LRESULT CALLBACK PanelWndProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CREATE: {
        const int dpi = PanelWindowDpi(h);
        g_theme.Ensure(dpi);

        auto mkBtn = [&](const wchar_t* text, int id) -> HWND {
            HWND c = CreateWindowExW(0, L"BUTTON", text,
                                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                     0, 0, 10, 10, h, (HMENU)(INT_PTR)id,
                                     GetModuleHandleW(nullptr), nullptr);
            if (c) {
                if (!g_origBtnProc) {
                    g_origBtnProc = (WNDPROC)GetWindowLongPtrW(c, GWLP_WNDPROC);
                }
                SetWindowLongPtrW(c, GWLP_WNDPROC, (LONG_PTR)PanelBtnSubclassProc);
            }
            return c;
        };
        auto mkChk = [&](const wchar_t* text, int id, bool checked) -> HWND {
            HWND c = CreateWindowExW(0, L"BUTTON", text,
                                     WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                                     0, 0, 10, 10, h, (HMENU)(INT_PTR)id,
                                     GetModuleHandleW(nullptr), nullptr);
            if (c) SendMessageW(c, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
            return c;
        };

        mkBtn(g_hostMode.load() ? L"切回副屏模式" : L"切到主控(Mac当副屏)", IDC_PANEL_MODE);
        mkBtn(L"发送文件", IDC_PANEL_SENDFILE);
        mkBtn(L"粘贴发送", IDC_PANEL_PASTEXFER);
        mkBtn(L"悬浮盒", IDC_PANEL_DROPBOX);
        mkBtn(L"打开目录", IDC_PANEL_OPENXFER);
        mkBtn(L"全屏显示", IDC_PANEL_FULL);
        mkBtn(L"窗口置顶", IDC_PANEL_TOP);
        mkBtn(L"强制关键帧", IDC_PANEL_KEY);
        mkBtn(L"重新连接", IDC_PANEL_RECONN);
        mkBtn(L"打开日志", IDC_PANEL_LOG);
        mkBtn(L"打开配置", IDC_PANEL_CFG);
        mkBtn(L"复制诊断", IDC_PANEL_COPY);
        mkBtn(L"退出 SecDisplay", IDC_PANEL_EXIT);

        mkChk(L"垂直同步", IDC_PANEL_VSYNC, g_vsyncEnabled.load());
        mkChk(L"抖动缓冲", IDC_PANEL_PACE, g_paceEnabled.load());
        mkChk(L"状态反馈", IDC_PANEL_FEEDBACK, g_feedbackEnabled.load());
        mkChk(L"晃动找光标", IDC_PANEL_SHAKE, g_shakeEnabled.load());
        mkChk(L"保持屏幕常亮 (防熄屏)", IDC_PANEL_KEEPON, g_keepScreenOn.load());

        mkBtn(L"2880×1800", IDC_PANEL_RES_2880);
        mkBtn(L"2560×1600", IDC_PANEL_RES_2560);
        mkBtn(L"1920×1200", IDC_PANEL_RES_1920);
        mkBtn(L"码率 30M",  IDC_PANEL_MBPS_30);
        mkBtn(L"码率 50M",  IDC_PANEL_MBPS_50);
        mkBtn(L"码率 80M",  IDC_PANEL_MBPS_80);
        mkBtn(L"重挂虚拟屏", IDC_PANEL_VDD_RETRY);
        mkBtn(L"键鼠控 Mac (Ctrl+Alt+K)", IDC_PANEL_KVM);

        DragAcceptFiles(h, TRUE);
        LayoutPanelControls(h);
        SetTimer(h, 1, 1000, nullptr);
        return 0;
    }
    case WM_DROPFILES: {
        HDROP drop = (HDROP)w;
        UINT cnt = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < cnt; ++i) {
            UINT len = DragQueryFileW(drop, i, nullptr, 0);
            if (len > 0 && len < 4096) {
                std::wstring path(len + 1, L'\0');
                if (DragQueryFileW(drop, i, &path[0], len + 1) > 0) {
                    path.resize(wcslen(path.c_str()));
                    EnqueueFileTransfer(path);
                }
            }
        }
        DragFinish(drop);
        return 0;
    }
    case WM_APP_XFER_UI:
        UpdateControlPanel();
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT:
        PaintControlPanel(h);
        return 0;
    case WM_DRAWITEM:
        if (l) {
            DrawPanelButton((const DRAWITEMSTRUCT*)l, PanelWindowDpi(h));
            return TRUE;
        }
        return FALSE;
    case WM_DPICHANGED: {
        const RECT* suggested = (const RECT*)l;
        if (suggested) {
            SetWindowPos(h, nullptr, suggested->left, suggested->top,
                         suggested->right - suggested->left,
                         suggested->bottom - suggested->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
        }
        LayoutPanelControls(h);
        InvalidateRect(h, nullptr, FALSE);
        return 0;
    }
    case WM_TIMER:
        if (w == 1) UpdateControlPanel();
        return 0;
    case WM_SHOWWINDOW:
        // 面板只隐藏不销毁，WM_CREATE 里那个 SetTimer 在 WM_CLOSE 之后已经停掉。
        // 重新显示时必须把它装回去，否则面板上所有数字会冻在关闭那一刻。
        if (w) {
            SetTimer(h, 1, 1000, nullptr);
            UpdateControlPanel();
        } else {
            KillTimer(h, 1);
        }
        return 0;
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
        // 复选框放在底部白卡片内，用卡片纯白画刷统一底色，避免灰块
        SetBkMode((HDC)w, OPAQUE);
        SetBkColor((HDC)w, RGB(255, 255, 255));
        SetTextColor((HDC)w, RGB(30, 41, 59));
        g_theme.Ensure(PanelWindowDpi(h));
        return (LRESULT)g_theme.cardBrush;
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case IDC_PANEL_SENDFILE:
            PickAndSendFiles(h);
            return 0;
        case IDC_PANEL_PASTEXFER:
            PasteClipboardToTransfer(h);
            return 0;
        case IDC_PANEL_DROPBOX:
            ShowDropBoxWindow();
            return 0;
        case IDC_PANEL_OPENXFER: {
            std::wstring dir = GetTransferInboxDir();
            ShellExecuteW(nullptr, L"open", dir.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            return 0;
        }
        case IDC_PANEL_MODE:
            SwitchAppMode(!g_hostMode.load());
            return 0;
        case IDC_PANEL_FULL:
            if (g_hostMode.load()) {
                ShellExecuteW(nullptr, L"open", L"ms-settings:display", nullptr, nullptr, SW_SHOWNORMAL);
            } else if (g_hwnd) {
                PostMessageW(g_hwnd, WM_COMMAND, ID_TRAY_TOGGLE, 0);
            }
            return 0;
        case IDC_PANEL_RECONN: {
            if (g_hostMode.load()) {
                Log("控制面板: 请求快速重连（保留虚拟屏）");
                g_winHost.RestartConnection();
                SOCKET xs = g_xferSock.load();
                if (xs != INVALID_SOCKET) shutdown(xs, SD_BOTH);
                return 0;
            }
            SOCKET s = g_sock.load();
            if (s != INVALID_SOCKET) {
                Log("控制面板: 控制面板请求重新连接");
                shutdown(s, SD_BOTH);
            }
            return 0;
        }
        case IDC_PANEL_RES_2880:
            if (g_hostMode.load()) {
                g_hostReqW = 2880; g_hostReqH = 1800;
                g_winHost.SetResolution(2880, 1800, g_hostReqFps.load());
            }
            return 0;
        case IDC_PANEL_RES_2560:
            if (g_hostMode.load()) {
                g_hostReqW = 2560; g_hostReqH = 1600;
                g_winHost.SetResolution(2560, 1600, g_hostReqFps.load());
            }
            return 0;
        case IDC_PANEL_RES_1920:
            if (g_hostMode.load()) {
                g_hostReqW = 1920; g_hostReqH = 1200;
                g_winHost.SetResolution(1920, 1200, g_hostReqFps.load());
            }
            return 0;
        case IDC_PANEL_MBPS_30:
            if (g_hostMode.load()) {
                g_hostReqMbps = 30;
                g_winHost.SetTargetMbps(30);
                Log("控制面板: 调整主控目标码率 -> 30 Mbps");
            }
            return 0;
        case IDC_PANEL_MBPS_50:
            if (g_hostMode.load()) {
                g_hostReqMbps = 50;
                g_winHost.SetTargetMbps(50);
                Log("控制面板: 调整主控目标码率 -> 50 Mbps");
            }
            return 0;
        case IDC_PANEL_MBPS_80:
            if (g_hostMode.load()) {
                g_hostReqMbps = 80;
                g_winHost.SetTargetMbps(80);
                Log("控制面板: 调整主控目标码率 -> 80 Mbps");
            }
            return 0;
        case IDC_PANEL_VDD_RETRY:
            if (g_hostMode.load()) {
                Log("控制面板: 请求重挂 Parsec 虚拟屏并重启主控推送");
                if (!g_winHost.Start(g_peerHost, g_hostReqW.load(), g_hostReqH.load(),
                                     g_hostReqFps.load(), g_hostReqMbps.load(),
                                     (uint16_t)g_peerPort, [](const char* s) { Log("%s", s); },
                                     g_hostReqDpi.load())) {
                    Log("警告: 重挂 Parsec 虚拟屏仍失败，请检查驱动是否安装");
                }
            }
            return 0;
        case IDC_PANEL_KVM:
            if (g_hostMode.load()) {
                g_winHost.ToggleKvm();
                UpdateControlPanel();
            }
            return 0;
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
        case IDC_PANEL_TOP: {
            bool top = !g_panelTopmost.load();
            g_panelTopmost = top;
            SetWindowPos(h, top ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE);
            SetWindowTextW(GetDlgItem(h, IDC_PANEL_TOP), top ? L"取消置顶" : L"窗口置顶");
            Log("控制面板: 置顶 %s", top ? "开" : "关");
            return 0;
        }
        case IDC_PANEL_KEY:
            RequestKeyframe();
            return 0;
        case IDC_PANEL_CFG:
            OpenConfigFile();
            return 0;
        case IDC_PANEL_COPY:
            CopyDiagnostics();
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
        case IDC_PANEL_SHAKE: {
            bool on = (SendMessageW((HWND)l, BM_GETCHECK, 0, 0) == BST_CHECKED);
            g_shakeEnabled = on;
            if (!on) {
                // 关掉时立刻收起放大叠加层并复位动画：
                // 只杀定时器不复位叠加层会留下一张冻结的放大光标，同时系统光标仍是隐藏句柄。
                AbortShake();
            }
            Log("控制面板: 晃动找光标 %s", on ? "开" : "关");
            return 0;
        }
        case IDC_PANEL_KEEPON: {
            bool on = (SendMessageW((HWND)l, BM_GETCHECK, 0, 0) == BST_CHECKED);
            g_keepScreenOn = on;
            if (g_hwnd) PostMessageW(g_hwnd, WM_APP_UPDATE_POWER, 0, 0);
            UpdateControlPanel();
            Log("控制面板: 保持屏幕常亮 %s", on ? "开" : "关");
            return 0;
        }
        }
        return 0;
    case WM_CLOSE:
        KillTimer(h, 1);
        ShowWindow(h, SW_HIDE);
        return 0;
    case WM_DESTROY:
        KillTimer(h, 1);
        g_hoverBtn = nullptr;
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
        wc.hbrBackground = nullptr;   // 由 WM_PAINT 双缓冲全量绘制
        wc.lpszClassName = L"SecDisplayControl";
        wc.hIcon = LoadIconW(wc.hInstance, MAKEINTRESOURCEW(1));
        if (!wc.hIcon) wc.hIcon = LoadIconW(nullptr, (LPCWSTR)IDI_APPLICATION);
        RegisterClassExW(&wc);
        registered = true;
    }

    const int dpi = PanelWindowDpi(nullptr);
    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_CLIPCHILDREN;
    RECT rc{ 0, 0, DpiPx(960, dpi), DpiPx(680, dpi) };
    AdjustRectDpi(&rc, style, WS_EX_APPWINDOW, dpi);
    int w = rc.right - rc.left;
    int hgt = rc.bottom - rc.top;
    RECT wa{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = (wa.right > wa.left) ? (wa.left + (wa.right - wa.left - w) / 2) : ((GetSystemMetrics(SM_CXSCREEN) - w) / 2);
    int y = (wa.bottom > wa.top) ? std::max((int)wa.top, (int)(wa.top + (wa.bottom - wa.top - hgt) / 2)) : ((GetSystemMetrics(SM_CYSCREEN) - hgt) / 2);
    g_panel = CreateWindowExW(WS_EX_APPWINDOW, L"SecDisplayControl", L"SecDisplay 控制面板",
                              style, x, y, w, hgt,
                              nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (g_panel) {
        // 创建后校准一次真实所在屏幕 DPI，避免多屏 DPI 不同时窗口外框与内绘比例错配
        const int realDpi = PanelWindowDpi(g_panel);
        if (realDpi != dpi) {
            RECT r2{ 0, 0, DpiPx(960, realDpi), DpiPx(680, realDpi) };
            AdjustRectDpi(&r2, style, WS_EX_APPWINDOW, realDpi);
            SetWindowPos(g_panel, nullptr, 0, 0, r2.right - r2.left, r2.bottom - r2.top,
                         SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            LayoutPanelControls(g_panel);
        }
        Log("控制面板已创建 hwnd=%p", (void*)g_panel.load());
        ShowWindow(g_panel, SW_SHOW);
        SetForegroundWindow(g_panel);
        UpdateControlPanel();
    } else {
        Log("控制面板创建失败 %lu", GetLastError());
    }
}

// ---- 悬浮文件投递盒（ArcZip Box 风格：UpdateLayeredWindow + GDI+ 亚像素抗锯齿真圆角与软投影）----
static int g_dbHot = 0;   // 0=无 1=图钉 2=关闭 3=投递区 4=已收文件胶囊 5=粘贴截图
static POINT g_dropBoxPos{ -1, -1 };
static bool g_dropBoxHasPos = false;

static void DropBoxLayoutRects(int dpi, RECT* rcPaste, RECT* rcPin, RECT* rcClose, RECT* rcBox, RECT* rcRecv) {
    auto S = [&](int v) { return DpiPx(v, dpi); };
    // 外留 12dp 投影边，主体卡片在 (12, 12) 大小 248x268
    if (rcPaste) *rcPaste = RECT{ S(150), S(24),  S(176), S(50)  };
    if (rcPin)   *rcPin   = RECT{ S(184), S(24),  S(210), S(50)  };
    if (rcClose) *rcClose = RECT{ S(218), S(24),  S(244), S(50)  };
    if (rcBox)   *rcBox   = RECT{ S(46),  S(78),  S(226), S(218) };
    if (rcRecv)  *rcRecv  = RECT{ S(28),  S(228), S(244), S(264) };
}

static void RenderDropBoxLayered(HWND h) {
    if (!h) return;
    RECT wndRc{};
    GetWindowRect(h, &wndRc);
    const int cw = wndRc.right - wndRc.left, ch = wndRc.bottom - wndRc.top;
    if (cw <= 0 || ch <= 0) return;

    const int dpi = PanelWindowDpi(h);
    auto S = [&](int v) -> float { return (float)DpiPx(v, dpi); };

    bool conn = g_xferConnected.load();
    bool pinned = g_dropBoxPinned.load();
    int pct = -1;
    int fbKind = 0;
    std::wstring status, speed, recvName, fbTitle, fbDetail;
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        if (g_xferFbKind != 0 && GetTickCount64() >= g_xferFbExpireTick) {
            g_xferFbKind = 0;
            g_xferFbTitle.clear();
            g_xferFbDetail.clear();
        }
        pct = g_xferPct;
        status = g_xferStatus;
        speed = g_xferSpeed;
        recvName = g_xferLastRecvName;
        fbKind = g_xferFbKind;
        fbTitle = g_xferFbTitle;
        fbDetail = g_xferFbDetail;
    }

    BITMAPV5HEADER bi{};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = cw;
    bi.bV5Height = -ch;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_RGB;
    void* bits = nullptr;
    HDC screenDc = GetDC(nullptr);
    HDC memDc = CreateCompatibleDC(screenDc);
    HBITMAP dib = CreateDIBSection(screenDc, (BITMAPINFO*)&bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!dib || !bits) {
        if (dib) DeleteObject(dib);
        if (memDc) DeleteDC(memDc);
        if (screenDc) ReleaseDC(nullptr, screenDc);
        return;
    }
    memset(bits, 0, (size_t)cw * ch * 4);
    HGDIOBJ oldBmp = SelectObject(memDc, dib);

    {
        Gdiplus::Bitmap canvas(cw, ch, cw * 4, PixelFormat32bppPARGB, (BYTE*)bits);
        Gdiplus::Graphics g(&canvas);
        g.SetSmoothingMode(Gdiplus::SmoothingModeHighQuality);
        g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
        g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);

        const float pad = S(12), cardW = S(248), cardH = S(268), rad = S(18);

        // 1. 柔和环境软阴影（4 层透明圆角扩散，彻底摆脱锯齿硬边）
        for (int i = 4; i >= 1; --i) {
            float exp = (float)i * S(2);
            BYTE alpha = (BYTE)(24 - i * 4);
            Gdiplus::GraphicsPath sp;
            AddRoundRectPath(sp, pad - exp * 0.5f, pad - exp * 0.25f + (float)i * S(1),
                             cardW + exp, cardH + exp, rad + exp * 0.4f, rad + exp * 0.4f,
                             rad + exp * 0.4f, rad + exp * 0.4f);
            Gdiplus::SolidBrush sb(Gdiplus::Color(alpha, 15, 23, 42));
            g.FillPath(&sb, &sp);
        }

        // 2. 白色卡片主体（抗锯齿 18dp 圆角）
        Gdiplus::GraphicsPath cardPath;
        AddRoundRectPath(cardPath, pad, pad, cardW, cardH, rad, rad, rad, rad);
        Gdiplus::SolidBrush cardBr(Gdiplus::Color(255, 255, 255, 255));
        g.FillPath(&cardBr, &cardPath);

        // 3. 顶部柔冷紫灰渐变标题栏（仅上圆角，底平接白区）
        const float hdrH = S(50);
        Gdiplus::GraphicsPath hdrPath;
        AddRoundRectPath(hdrPath, pad, pad, cardW, hdrH, rad, rad, 0.0f, 0.0f);
        Gdiplus::LinearGradientBrush hdrBr(
            Gdiplus::PointF(pad, pad), Gdiplus::PointF(pad, pad + hdrH),
            Gdiplus::Color(255, 186, 182, 206), Gdiplus::Color(255, 173, 169, 194));
        g.FillPath(&hdrBr, &hdrPath);

        // 应用图标
        HICON hIcon = (HICON)LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1),
                                        IMAGE_ICON, (int)S(24), (int)S(24), LR_DEFAULTCOLOR);
        if (hIcon) {
            std::unique_ptr<Gdiplus::Bitmap> ibmp(Gdiplus::Bitmap::FromHICON(hIcon));
            if (ibmp) {
                g.DrawImage(ibmp.get(), Gdiplus::RectF(pad + S(14), pad + S(13), S(24), S(24)));
            }
            DestroyIcon(hIcon);
        } else {
            Gdiplus::GraphicsPath ip;
            AddRoundRectPath(ip, pad + S(14), pad + S(13), S(24), S(24), S(6), S(6), S(6), S(6));
            Gdiplus::SolidBrush ibr(Gdiplus::Color(235, 255, 255, 255));
            g.FillPath(&ibr, &ip);
        }

        // 标题 SecDisplay + Box 状态胶囊
        Gdiplus::FontFamily ff(L"Microsoft YaHei UI");
        Gdiplus::Font fTitle(&ff, S(12), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
        Gdiplus::Font fSmall(&ff, S(10), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::Font fHint(&ff, S(11), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::Font fFb(&ff, S(12), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
        Gdiplus::Font fPct(&ff, S(22), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);

        Gdiplus::SolidBrush titleBr(Gdiplus::Color(255, 32, 30, 44));
        g.DrawString(L"SecDisplay", -1, &fTitle, Gdiplus::PointF(pad + S(44), pad + S(8)), &titleBr);

        Gdiplus::GraphicsPath pill;
        AddRoundRectPath(pill, pad + S(44), pad + S(27), S(46), S(16), S(8), S(8), S(8), S(8));
        Gdiplus::SolidBrush pillBr(Gdiplus::Color(215, 244, 243, 250));
        g.FillPath(&pillBr, &pill);
        Gdiplus::SolidBrush dotBr(conn ? Gdiplus::Color(255, 22, 163, 74) : Gdiplus::Color(255, 148, 163, 184));
        g.FillEllipse(&dotBr, pad + S(50), pad + S(32), S(6), S(6));
        Gdiplus::SolidBrush boxTxtBr(Gdiplus::Color(255, 58, 55, 74));
        g.DrawString(L"Box", -1, &fSmall, Gdiplus::PointF(pad + S(59), pad + S(28)), &boxTxtBr);

        // 顶部三个抗锯齿圆形按钮：粘贴 / 图钉 / 关闭
        RECT rcPaste{}, rcPin{}, rcClose{}, rcBox{}, rcRecv{};
        DropBoxLayoutRects(dpi, &rcPaste, &rcPin, &rcClose, &rcBox, &rcRecv);
        auto drawCircle = [&](const RECT& r, Gdiplus::Color fill) {
            Gdiplus::SolidBrush cb(fill);
            g.FillEllipse(&cb, (float)r.left, (float)r.top,
                          (float)(r.right - r.left), (float)(r.bottom - r.top));
            Gdiplus::Pen cp(Gdiplus::Color(90, 255, 255, 255), 1.0f);
            g.DrawEllipse(&cp, (float)r.left, (float)r.top,
                          (float)(r.right - r.left), (float)(r.bottom - r.top));
        };

        // 粘贴按钮（剪贴板图标）
        drawCircle(rcPaste, g_dbHot == 5 ? Gdiplus::Color(255, 224, 236, 255) : Gdiplus::Color(235, 248, 247, 252));
        {
            float cx = (rcPaste.left + rcPaste.right) * 0.5f;
            float cy = (rcPaste.top + rcPaste.bottom) * 0.5f;
            Gdiplus::Pen cp(g_dbHot == 5 ? Gdiplus::Color(255, 37, 99, 235) : Gdiplus::Color(255, 72, 74, 88), S(2) * 0.75f);
            cp.SetLineJoin(Gdiplus::LineJoinRound);
            Gdiplus::GraphicsPath board;
            AddRoundRectPath(board, cx - S(4), cy - S(4), S(9), S(10), S(2), S(2), S(2), S(2));
            g.DrawPath(&cp, &board);
            Gdiplus::GraphicsPath clip;
            AddRoundRectPath(clip, cx - S(2), cy - S(6), S(5), S(3), S(1), S(1), S(1), S(1));
            Gdiplus::SolidBrush cbr(Gdiplus::Color(255, 248, 247, 252));
            g.FillPath(&cbr, &clip);
            g.DrawPath(&cp, &clip);
        }

        // 图钉按钮
        drawCircle(rcPin, g_dbHot == 1 ? Gdiplus::Color(255, 224, 236, 255) : Gdiplus::Color(235, 248, 247, 252));
        {
            float cx = (rcPin.left + rcPin.right) * 0.5f;
            float cy = (rcPin.top + rcPin.bottom) * 0.5f;
            Gdiplus::Color pc = pinned ? Gdiplus::Color(255, 37, 99, 235) : Gdiplus::Color(255, 108, 112, 126);
            Gdiplus::Pen pp(pc, S(2) * 0.8f);
            pp.SetStartCap(Gdiplus::LineCapRound);
            pp.SetEndCap(Gdiplus::LineCapRound);
            pp.SetLineJoin(Gdiplus::LineJoinRound);
            Gdiplus::PointF pts[4] = {
                { cx - S(2), cy - S(5) }, { cx + S(4), cy - S(5) },
                { cx + S(3), cy },        { cx - S(3), cy }
            };
            if (pinned) {
                Gdiplus::SolidBrush pbr(pc);
                g.FillPolygon(&pbr, pts, 4);
            } else {
                g.DrawPolygon(&pp, pts, 4);
            }
            g.DrawLine(&pp, cx - S(5), cy + S(1), cx + S(5), cy + S(1));
            g.DrawLine(&pp, cx, cy + S(1), cx - S(2), cy + S(6));
        }

        // 关闭按钮
        drawCircle(rcClose, g_dbHot == 2 ? Gdiplus::Color(255, 254, 226, 226) : Gdiplus::Color(235, 248, 247, 252));
        {
            float cx = (rcClose.left + rcClose.right) * 0.5f;
            float cy = (rcClose.top + rcClose.bottom) * 0.5f;
            float d = S(4);
            Gdiplus::Pen xp(g_dbHot == 2 ? Gdiplus::Color(255, 185, 28, 28) : Gdiplus::Color(255, 48, 48, 58), S(2) * 0.85f);
            xp.SetStartCap(Gdiplus::LineCapRound);
            xp.SetEndCap(Gdiplus::LineCapRound);
            g.DrawLine(&xp, cx - d, cy - d, cx + d, cy + d);
            g.DrawLine(&xp, cx + d, cy - d, cx - d, cy + d);
        }

        // 4. 中央发光投递盒（支持：待机 / 传输进度条 / 成功或失败瞬时回执）
        const bool boxActive = (g_dbHot == 3 || pct >= 0);
        const bool hasFb = (pct < 0 && fbKind != 0);
        const bool fbOk = (fbKind > 0);
        float bx = (float)rcBox.left, by = (float)rcBox.top;
        float bw = (float)(rcBox.right - rcBox.left), bh = (float)(rcBox.bottom - rcBox.top);
        for (int i = 3; i >= 1; --i) {
            float e = (float)i * S(3);
            Gdiplus::GraphicsPath gp;
            AddRoundRectPath(gp, bx - e, by - e, bw + e * 2, bh + e * 2,
                             S(14) + e * 0.5f, S(14) + e * 0.5f, S(14) + e * 0.5f, S(14) + e * 0.5f);
            Gdiplus::Color gc = boxActive
                ? Gdiplus::Color((BYTE)(28 - i * 6), 59, 130, 246)
                : (hasFb
                   ? (fbOk ? Gdiplus::Color((BYTE)(28 - i * 6), 34, 197, 94)
                           : Gdiplus::Color((BYTE)(28 - i * 6), 239, 68, 68))
                   : Gdiplus::Color((BYTE)(20 - i * 4), 148, 163, 184));
            Gdiplus::SolidBrush gb(gc);
            g.FillPath(&gb, &gp);
        }

        Gdiplus::GraphicsPath boxPath;
        AddRoundRectPath(boxPath, bx, by, bw, bh, S(14), S(14), S(14), S(14));
        Gdiplus::Color boxFillCol = boxActive
            ? Gdiplus::Color(255, 232, 241, 255)
            : (hasFb ? (fbOk ? Gdiplus::Color(255, 236, 253, 245) : Gdiplus::Color(255, 254, 242, 242))
                     : Gdiplus::Color(255, 229, 231, 235));
        Gdiplus::Color boxBorderCol = boxActive
            ? Gdiplus::Color(220, 59, 130, 246)
            : (hasFb ? (fbOk ? Gdiplus::Color(220, 34, 197, 94) : Gdiplus::Color(220, 239, 68, 68))
                     : Gdiplus::Color(160, 210, 214, 222));
        Gdiplus::SolidBrush boxFill(boxFillCol);
        g.FillPath(&boxFill, &boxPath);
        Gdiplus::Pen boxBorder(boxBorderCol, 1.3f);
        g.DrawPath(&boxBorder, &boxPath);

        Gdiplus::StringFormat sfCenter;
        sfCenter.SetAlignment(Gdiplus::StringAlignmentCenter);
        sfCenter.SetLineAlignment(Gdiplus::StringAlignmentCenter);

        Gdiplus::StringFormat sfEllipsis;
        sfEllipsis.SetAlignment(Gdiplus::StringAlignmentCenter);
        sfEllipsis.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        sfEllipsis.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
        sfEllipsis.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

        if (pct >= 0) {
            wchar_t pbuf[32];
            swprintf(pbuf, 32, L"%d%%", pct);
            Gdiplus::SolidBrush pbr(Gdiplus::Color(255, 37, 99, 235));
            g.DrawString(pbuf, -1, &fPct, Gdiplus::RectF(bx, by + S(26), bw, S(44)), &sfCenter, &pbr);

            float px1 = bx + S(24), pw = bw - S(48), py1 = by + S(80), ph = S(8);
            Gdiplus::GraphicsPath trackP;
            AddRoundRectPath(trackP, px1, py1, pw, ph, ph * 0.5f, ph * 0.5f, ph * 0.5f, ph * 0.5f);
            Gdiplus::SolidBrush trackBr(Gdiplus::Color(255, 203, 213, 225));
            g.FillPath(&trackBr, &trackP);
            float fw = pw * (float)std::min(100, std::max(0, pct)) / 100.0f;
            if (fw > S(4)) {
                Gdiplus::GraphicsPath fillP;
                AddRoundRectPath(fillP, px1, py1, fw, ph, ph * 0.5f, ph * 0.5f, ph * 0.5f, ph * 0.5f);
                Gdiplus::SolidBrush fillBr(Gdiplus::Color(255, 37, 99, 235));
                g.FillPath(&fillBr, &fillP);
            }
            Gdiplus::SolidBrush sbr(Gdiplus::Color(255, 71, 85, 105));
            g.DrawString(speed.c_str(), -1, &fHint, Gdiplus::RectF(bx, by + S(96), bw, S(28)), &sfCenter, &sbr);
        } else if (hasFb) {
            float icx = bx + bw * 0.5f, icy = by + S(44);
            float cr = S(18);
            Gdiplus::Color badgeCol = fbOk ? Gdiplus::Color(255, 22, 163, 74) : Gdiplus::Color(255, 220, 38, 38);
            Gdiplus::SolidBrush badgeBr(badgeCol);
            g.FillEllipse(&badgeBr, icx - cr, icy - cr, cr * 2, cr * 2);

            Gdiplus::Pen wp(Gdiplus::Color(255, 255, 255, 255), S(2) * 1.3f);
            wp.SetStartCap(Gdiplus::LineCapRound);
            wp.SetEndCap(Gdiplus::LineCapRound);
            wp.SetLineJoin(Gdiplus::LineJoinRound);
            if (fbOk) {
                Gdiplus::PointF chk[3] = {
                    { icx - S(7), icy + S(0) },
                    { icx - S(2), icy + S(6) },
                    { icx + S(8), icy - S(6) }
                };
                g.DrawLines(&wp, chk, 3);
            } else {
                float d = S(6);
                g.DrawLine(&wp, icx - d, icy - d, icx + d, icy + d);
                g.DrawLine(&wp, icx + d, icy - d, icx - d, icy + d);
            }

            Gdiplus::SolidBrush fbr(fbOk ? Gdiplus::Color(255, 21, 128, 61) : Gdiplus::Color(255, 185, 28, 28));
            g.DrawString(fbTitle.c_str(), -1, &fFb, Gdiplus::RectF(bx + S(8), by + S(74), bw - S(16), S(24)), &sfEllipsis, &fbr);
            if (!fbDetail.empty()) {
                Gdiplus::SolidBrush dbr(Gdiplus::Color(255, 100, 116, 139));
                g.DrawString(fbDetail.c_str(), -1, &fSmall, Gdiplus::RectF(bx + S(10), by + S(98), bw - S(20), S(22)), &sfEllipsis, &dbr);
            }
        } else {
            float icx = bx + bw * 0.5f, icy = by + bh * 0.5f - S(8);
            Gdiplus::Color ic = g_dbHot == 3 ? Gdiplus::Color(255, 37, 99, 235) : Gdiplus::Color(255, 134, 138, 146);
            Gdiplus::Pen ip(ic, S(2) * 1.15f);
            ip.SetStartCap(Gdiplus::LineCapRound);
            ip.SetEndCap(Gdiplus::LineCapRound);
            ip.SetLineJoin(Gdiplus::LineJoinRound);

            // 向下箭头
            g.DrawLine(&ip, icx, icy - S(22), icx, icy + S(2));
            Gdiplus::PointF arrow[3] = {
                { icx - S(8), icy - S(6) }, { icx, icy + S(2) }, { icx + S(8), icy - S(6) }
            };
            g.DrawLines(&ip, arrow, 3);
            // 托盘外框 + 凹口横线
            Gdiplus::PointF tray[6] = {
                { icx - S(14), icy - S(4) }, { icx - S(20), icy + S(8) },
                { icx - S(20), icy + S(22) }, { icx + S(20), icy + S(22) },
                { icx + S(20), icy + S(8) }, { icx + S(14), icy - S(4) }
            };
            g.DrawLines(&ip, tray, 6);
            Gdiplus::PointF notch[6] = {
                { icx - S(20), icy + S(8) }, { icx - S(8), icy + S(8) },
                { icx - S(5), icy + S(13) }, { icx + S(5), icy + S(13) },
                { icx + S(8), icy + S(8) }, { icx + S(20), icy + S(8) }
            };
            g.DrawLines(&ip, notch, 6);

            Gdiplus::SolidBrush hbr(g_dbHot == 3 ? Gdiplus::Color(255, 37, 99, 235) : Gdiplus::Color(255, 115, 120, 130));
            g.DrawString(L"拖入或点击选文件", -1, &fHint,
                         Gdiplus::RectF(bx, by + bh - S(30), bw, S(24)), &sfCenter, &hbr);
        }

        // 5. 底部已收文件胶囊或状态/快捷键提示
        if (!recvName.empty() && pct < 0) {
            Gdiplus::GraphicsPath rp;
            float rx = (float)rcRecv.left, ry = (float)rcRecv.top;
            float rw = (float)(rcRecv.right - rcRecv.left), rh = (float)(rcRecv.bottom - rcRecv.top);
            AddRoundRectPath(rp, rx, ry, rw, rh, S(14), S(14), S(14), S(14));
            Gdiplus::SolidBrush rbr(g_dbHot == 4 ? Gdiplus::Color(255, 220, 252, 231) : Gdiplus::Color(255, 236, 253, 245));
            g.FillPath(&rbr, &rp);
            Gdiplus::Pen rpen(Gdiplus::Color(255, 167, 243, 208), 1.0f);
            g.DrawPath(&rpen, &rp);
            std::wstring label = L"↓ " + recvName;
            Gdiplus::SolidBrush tbr(Gdiplus::Color(255, 21, 128, 61));
            g.DrawString(label.c_str(), -1, &fHint, Gdiplus::RectF(rx + S(10), ry, rw - S(20), rh), &sfEllipsis, &tbr);
        } else {
            Gdiplus::SolidBrush sbr(Gdiplus::Color(255, 100, 116, 139));
            std::wstring hintTxt = (pct < 0 && conn && !hasFb) ? L"Ctrl+V 粘贴 · Ctrl+Alt+B 呼出" : status;
            g.DrawString(hintTxt.c_str(), -1, &fHint,
                         Gdiplus::RectF(pad + S(12), pad + S(214), cardW - S(24), S(38)),
                         &sfEllipsis, &sbr);
        }

        // 卡片细微外边框
        Gdiplus::Pen cardBorder(Gdiplus::Color(48, 30, 41, 59), 1.0f);
        g.DrawPath(&cardBorder, &cardPath);
    }

    POINT srcPt{ 0, 0 };
    SIZE wndSz{ cw, ch };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    UpdateLayeredWindow(h, screenDc, nullptr, &wndSz, memDc, &srcPt, 0, &bf, ULW_ALPHA);

    SelectObject(memDc, oldBmp);
    DeleteObject(dib);
    DeleteDC(memDc);
    ReleaseDC(nullptr, screenDc);
}

static void ArmDropBoxFeedbackTimer(HWND h) {
    if (!h) return;
    UINT delayMs = 0;
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        if (g_xferFbKind != 0) {
            ULONGLONG now = GetTickCount64();
            if (now >= g_xferFbExpireTick) {
                g_xferFbKind = 0;
                g_xferFbTitle.clear();
                g_xferFbDetail.clear();
            } else {
                ULONGLONG rem = g_xferFbExpireTick - now;
                delayMs = (UINT)std::min<ULONGLONG>(rem + 30, 5000);
            }
        }
    }
    if (delayMs > 0) SetTimer(h, kDropBoxFbTimer, delayMs, nullptr);
    else KillTimer(h, kDropBoxFbTimer);
}

static LRESULT CALLBACK DropBoxWndProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CREATE:
        DragAcceptFiles(h, TRUE);
        ArmDropBoxFeedbackTimer(h);
        RenderDropBoxLayered(h);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        BeginPaint(h, &ps);
        EndPaint(h, &ps);
        RenderDropBoxLayered(h);
        return 0;
    }
    case WM_APP_XFER_UI: {
        ArmDropBoxFeedbackTimer(h);
        RenderDropBoxLayered(h);
        return 0;
    }
    case WM_TIMER:
        if (w == kDropBoxFbTimer) {
            bool expiredOrNone = true;
            bool changed = false;
            UINT nextDelay = 0;
            {
                std::lock_guard<std::mutex> lk(g_xferMtx);
                if (g_xferFbKind != 0) {
                    ULONGLONG now = GetTickCount64();
                    if (now >= g_xferFbExpireTick) {
                        g_xferFbKind = 0;
                        g_xferFbTitle.clear();
                        g_xferFbDetail.clear();
                        changed = true;
                    } else {
                        expiredOrNone = false;
                        nextDelay = (UINT)std::min<ULONGLONG>((g_xferFbExpireTick - now) + 30, 5000);
                    }
                }
            }
            if (expiredOrNone) {
                KillTimer(h, kDropBoxFbTimer);
            } else if (nextDelay > 0) {
                SetTimer(h, kDropBoxFbTimer, nextDelay, nullptr);
            }
            if (changed) RenderDropBoxLayered(h);
            return 0;
        }
        break;
    case WM_SETCURSOR:
        if (LOWORD(l) == HTCLIENT) {
            SetCursor(LoadCursorW(nullptr, g_dbHot != 0 ? (LPCWSTR)IDC_HAND : (LPCWSTR)IDC_ARROW));
            return TRUE;
        }
        break;
    case WM_MOUSEMOVE: {
        POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        const int dpi = PanelWindowDpi(h);
        RECT rcPaste{}, rcPin{}, rcClose{}, rcBox{}, rcRecv{};
        DropBoxLayoutRects(dpi, &rcPaste, &rcPin, &rcClose, &rcBox, &rcRecv);
        int hot = 0;
        if (PtInRect(&rcPin, pt)) hot = 1;
        else if (PtInRect(&rcClose, pt)) hot = 2;
        else if (PtInRect(&rcBox, pt)) hot = 3;
        else if (PtInRect(&rcRecv, pt)) hot = 4;
        else if (PtInRect(&rcPaste, pt)) hot = 5;
        if (hot != g_dbHot) {
            g_dbHot = hot;
            RenderDropBoxLayered(h);
        }
        TRACKMOUSEEVENT tme{ sizeof(tme), TME_LEAVE, h, 0 };
        TrackMouseEvent(&tme);
        return 0;
    }
    case WM_MOUSELEAVE:
        if (g_dbHot != 0) {
            g_dbHot = 0;
            RenderDropBoxLayered(h);
        }
        return 0;
    case WM_LBUTTONDOWN: {
        POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        const int dpi = PanelWindowDpi(h);
        RECT rcPaste{}, rcPin{}, rcClose{}, rcBox{}, rcRecv{};
        DropBoxLayoutRects(dpi, &rcPaste, &rcPin, &rcClose, &rcBox, &rcRecv);
        if (PtInRect(&rcPaste, pt)) {
            PasteClipboardToTransfer(h);
            return 0;
        }
        if (PtInRect(&rcPin, pt)) {
            bool next = !g_dropBoxPinned.load();
            g_dropBoxPinned = next;
            SetWindowPos(h, next ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
            RenderDropBoxLayered(h);
            Log("悬浮投递盒置顶: %s", next ? "开" : "关");
            return 0;
        }
        if (PtInRect(&rcClose, pt)) {
            RECT wr{};
            if (GetWindowRect(h, &wr)) { g_dropBoxPos = { wr.left, wr.top }; g_dropBoxHasPos = true; }
            g_dbHot = 0;
            ShowWindow(h, SW_HIDE);
            return 0;
        }
        if (PtInRect(&rcBox, pt)) {
            PickAndSendFiles(h);
            return 0;
        }
        if (PtInRect(&rcRecv, pt)) {
            std::wstring recvPath;
            {
                std::lock_guard<std::mutex> lk(g_xferMtx);
                recvPath = g_xferLastRecvPath;
            }
            if (!recvPath.empty()) {
                std::wstring arg = L"/select,\"" + recvPath + L"\"";
                ShellExecuteW(nullptr, L"open", L"explorer.exe", arg.c_str(), nullptr, SW_SHOWNORMAL);
            } else {
                std::wstring dir = GetTransferInboxDir();
                ShellExecuteW(nullptr, L"open", dir.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
            }
            return 0;
        }
        // 卡片内除按钮/热区外的任意空白处（标题栏、四周边距、底部）均可直接拖移整盒
        ReleaseCapture();
        SendMessageW(h, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    }
    case WM_EXITSIZEMOVE:
    case WM_MOVE:
        if (IsWindowVisible(h) && !IsIconic(h)) {
            RECT wr{};
            if (GetWindowRect(h, &wr)) {
                g_dropBoxPos = { wr.left, wr.top };
                g_dropBoxHasPos = true;
            }
        }
        return 0;
    case WM_DROPFILES: {
        HDROP drop = (HDROP)w;
        UINT cnt = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
        for (UINT i = 0; i < cnt; ++i) {
            UINT len = DragQueryFileW(drop, i, nullptr, 0);
            if (len > 0 && len < 4096) {
                std::wstring path(len + 1, L'\0');
                if (DragQueryFileW(drop, i, &path[0], len + 1) > 0) {
                    path.resize(wcslen(path.c_str()));
                    EnqueueFileTransfer(path);
                }
            }
        }
        DragFinish(drop);
        return 0;
    }
    case WM_DPICHANGED: {
        const RECT* suggested = (const RECT*)l;
        const int newDpi = HIWORD(w) ? (int)HIWORD(w) : PanelWindowDpi(h);
        if (suggested) {
            SetWindowPos(h, nullptr, suggested->left, suggested->top,
                         DpiPx(272, newDpi), DpiPx(292, newDpi),
                         SWP_NOZORDER | SWP_NOACTIVATE);
        }
        RenderDropBoxLayered(h);
        return 0;
    }
    case WM_CLOSE: {
        RECT wr{};
        if (GetWindowRect(h, &wr)) { g_dropBoxPos = { wr.left, wr.top }; g_dropBoxHasPos = true; }
        g_dbHot = 0;
        ShowWindow(h, SW_HIDE);
        return 0;
    }
    }
    return DefWindowProcW(h, msg, w, l);
}

static void ShowDropBoxWindow() {
    HWND cur = g_dropBox.load();
    if (cur) {
        RECT wr{};
        if (GetWindowRect(cur, &wr)) {
            // 若所在外接屏已断开导致窗口跑出所有显示器，拉回当前工作区右下角；否则保留用户拖动的位置
            if (!MonitorFromRect(&wr, MONITOR_DEFAULTTONULL)) {
                RECT wa{};
                SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
                // 先移到主工作区右下角附近，再取目标显示器的真实 DPI 精算宽高
                SetWindowPos(cur, nullptr, std::max((int)wa.left, (int)wa.right - 300),
                             std::max((int)wa.top, (int)wa.bottom - 320), 0, 0,
                             SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                const int dpi = PanelWindowDpi(cur);
                int rw = DpiPx(272, dpi), rh = DpiPx(292, dpi);
                int rx = (wa.right > wa.left) ? (wa.right - rw - DpiPx(16, dpi)) : (GetSystemMetrics(SM_CXSCREEN) - rw - 16);
                int ry = (wa.bottom > wa.top) ? (wa.bottom - rh - DpiPx(16, dpi)) : (GetSystemMetrics(SM_CYSCREEN) - rh - 40);
                SetWindowPos(cur, nullptr, rx, ry, rw, rh, SWP_NOZORDER | SWP_NOACTIVATE);
                g_dropBoxPos = { rx, ry };
                g_dropBoxHasPos = true;
            }
        }
        ArmDropBoxFeedbackTimer(cur);
        ShowWindow(cur, SW_SHOWNOACTIVATE);
        SetWindowPos(cur, g_dropBoxPinned.load() ? HWND_TOPMOST : HWND_NOTOPMOST,
                     0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        RenderDropBoxLayered(cur);
        return;
    }

    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = DropBoxWndProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.hCursor = LoadCursorW(nullptr, (LPCWSTR)IDC_ARROW);
        wc.hbrBackground = nullptr;
        wc.lpszClassName = L"SecDisplayDropBox";
        RegisterClassExW(&wc);
        registered = true;
    }

    const int dpi = PanelWindowDpi(nullptr);
    int w = DpiPx(272, dpi), hgt = DpiPx(292, dpi);
    RECT wa{};
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = (wa.right > wa.left) ? (wa.right - w - DpiPx(16, dpi)) : (GetSystemMetrics(SM_CXSCREEN) - w - 16);
    int y = (wa.bottom > wa.top) ? (wa.bottom - hgt - DpiPx(16, dpi)) : (GetSystemMetrics(SM_CYSCREEN) - hgt - 40);
    if (g_dropBoxHasPos) {
        RECT testRc{ g_dropBoxPos.x, g_dropBoxPos.y, g_dropBoxPos.x + w, g_dropBoxPos.y + hgt };
        if (MonitorFromRect(&testRc, MONITOR_DEFAULTTONULL)) {
            x = g_dropBoxPos.x;
            y = g_dropBoxPos.y;
        }
    }
    DWORD exStyle = WS_EX_LAYERED | WS_EX_TOOLWINDOW | (g_dropBoxPinned.load() ? WS_EX_TOPMOST : 0);
    HWND h = CreateWindowExW(exStyle, L"SecDisplayDropBox", L"SecDisplay Box",
                             WS_POPUP | WS_CLIPCHILDREN, x, y, w, hgt,
                             nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (h) {
        g_dropBox = h;
        const int realDpi = PanelWindowDpi(h);
        if (realDpi != dpi) {
            int rw = DpiPx(272, realDpi), rh = DpiPx(292, realDpi);
            int rx = g_dropBoxHasPos ? x : ((wa.right > wa.left) ? (wa.right - rw - DpiPx(16, realDpi)) : (GetSystemMetrics(SM_CXSCREEN) - rw - 16));
            int ry = g_dropBoxHasPos ? y : ((wa.bottom > wa.top) ? (wa.bottom - rh - DpiPx(16, realDpi)) : (GetSystemMetrics(SM_CYSCREEN) - rh - 40));
            SetWindowPos(h, nullptr, rx, ry, rw, rh, SWP_NOZORDER | SWP_NOACTIVATE);
        }
        RenderDropBoxLayered(h);
        ShowWindow(h, SW_SHOWNOACTIVATE);
        Log("Windows 悬浮投递盒已打开 hwnd=%p", (void*)h);
    }
}

static void ToggleDropBoxWindow() {
    HWND cur = g_dropBox.load();
    if (cur && IsWindowVisible(cur)) {
        RECT wr{};
        if (GetWindowRect(cur, &wr)) { g_dropBoxPos = { wr.left, wr.top }; g_dropBoxHasPos = true; }
        g_dbHot = 0;
        ShowWindow(cur, SW_HIDE);
        Log("悬浮投递盒已通过快捷键隐藏");
    } else {
        ShowDropBoxWindow();
        if (HWND db = g_dropBox.load()) {
            SetForegroundWindow(db);
        }
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

// 查询当前显示器对应的硬件光标最大边长（如 200% DPI 下 Intel Iris Xe 为 64x64；
// 100% DPI 下系统 SM_CXCURSOR=32 但 WDDM 硬件平面至少支持 64x64，下限设为 64 避免 100% DPI 下缩过头）。
// 稳态光标严格压在此上限内才能走 GPU 硬件光标层，避免退化成 DWM 软件光标产生拖影/残影。
static int HardwareCursorMaxSide(HWND hwnd) {
    typedef UINT (WINAPI *GetDpiForWindowFn)(HWND);
    typedef int (WINAPI *GetSysMetricsForDpiFn)(int, UINT);
    static GetDpiForWindowFn fnDpi = (GetDpiForWindowFn)GetProcAddress(GetModuleHandleA("user32.dll"), "GetDpiForWindow");
    static GetSysMetricsForDpiFn fnMet = (GetSysMetricsForDpiFn)GetProcAddress(GetModuleHandleA("user32.dll"), "GetSystemMetricsForDpi");
    UINT dpi = (fnDpi && hwnd) ? fnDpi(hwnd) : 0;
    if (dpi > 0 && fnMet) {
        int cx = fnMet(SM_CXCURSOR, dpi);
        int cy = fnMet(SM_CYCURSOR, dpi);
        int m = (cx < cy ? cx : cy);
        if (m < 64) m = 64;
        if (m > 128) m = 128;
        return m;
    }
    double scale = WindowDpiScale(hwnd);
    int m = (int)(32.0 * scale + 0.5);
    if (m < 64) m = 64;
    if (m > 128) m = 128;
    return m;
}

// 当前应使用的光标缩放（千分比）：屏幕物理像素 / Mac 逻辑点。
// 只反映「稳态」尺寸；晃动放大由叠加层单独绘制，不参与 HCURSOR 尺寸，避免超过硬件上限。
// 在 ApplyCursorImage 之前声明，由下面定义。
static int DesiredCursorScalePm();

// 1x1 全透明光标（AND 掩码全 1 = 保留桌面像素），用于「完全不显示指针」的场合。
static HCURSOR HiddenCursorHandle() {
    if (g_hiddenCursor) return g_hiddenCursor;
    static const BYTE kAnd[2] = { 0xFF, 0xFF };   // 每行按 16 位对齐，1x1 需 2 字节
    static const BYTE kXor[2] = { 0x00, 0x00 };
    g_hiddenCursor = CreateCursor(GetModuleHandleW(nullptr), 0, 0, 1, 1, kAnd, kXor);
    return g_hiddenCursor;
}

// 视频有效区域换算到屏幕坐标。
static RECT VideoRectOnScreen() {
    RECT out{ 0, 0, 0, 0 };
    if (!g_hwnd) return out;
    RECT rc{};
    if (!GetClientRect(g_hwnd, &rc)) return out;
    const int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
    if (cw <= 0 || ch <= 0) return out;
    RECT vr = VideoRectInClient(cw, ch);
    POINT tl{ 0, 0 };
    ClientToScreen(g_hwnd, &tl);
    out.left = tl.x + vr.left;
    out.top = tl.y + vr.top;
    out.right = tl.x + vr.right;
    out.bottom = tl.y + vr.bottom;
    return out;
}

// 指针是否由副屏窗口接管：窗口可见且指针位于视频画面内。
// 只有接管期间才用远程坐标驱动系统光标；用户把鼠标移出画面时立刻交还本机光标，
// 这样指针可以自然滑到主屏，不会被 0x03 包一直拽回副屏窗口。
static bool PortalCursorOwned() {
    if (!g_hwnd || IsIconic(g_hwnd)) return false;
    POINT pt{};
    if (!GetCursorPos(&pt)) return false;
    RECT vr = VideoRectOnScreen();
    if (vr.right <= vr.left || vr.bottom <= vr.top) return false;
    return pt.x >= vr.left && pt.x < vr.right && pt.y >= vr.top && pt.y < vr.bottom;
}

// 预乘 alpha 的 BGRA 双线性重采样。放大与缩小共用，避免最近邻锯齿。
static void ResampleBgraPremul(const uint8_t* src, int sw, int sh,
                               std::vector<uint8_t>& dst, int dw, int dh) {
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || !src) { dst.clear(); return; }
    dst.assign((size_t)dw * dh * 4, 0);
    const double scaleX = (double)sw / (double)dw;
    const double scaleY = (double)sh / (double)dh;
    for (int yy = 0; yy < dh; ++yy) {
        double fy = ((double)yy + 0.5) * scaleY - 0.5;
        if (fy < 0.0) fy = 0.0;
        if (fy > (double)(sh - 1)) fy = (double)(sh - 1);
        const int y0 = (int)fy;
        const int y1 = (y0 + 1 < sh) ? (y0 + 1) : (sh - 1);
        const double wy = fy - y0;
        const double wy0 = 1.0 - wy;
        const uint8_t* row0 = src + (size_t)y0 * sw * 4;
        const uint8_t* row1 = src + (size_t)y1 * sw * 4;
        uint8_t* outRow = dst.data() + (size_t)yy * dw * 4;
        for (int xx = 0; xx < dw; ++xx) {
            double fx = ((double)xx + 0.5) * scaleX - 0.5;
            if (fx < 0.0) fx = 0.0;
            if (fx > (double)(sw - 1)) fx = (double)(sw - 1);
            const int x0 = (int)fx;
            const int x1 = (x0 + 1 < sw) ? (x0 + 1) : (sw - 1);
            const double wx = fx - x0;
            const double wx0 = 1.0 - wx;
            const double w00 = wx0 * wy0, w10 = wx * wy0, w01 = wx0 * wy, w11 = wx * wy;
            const uint8_t* p00 = row0 + (size_t)x0 * 4;
            const uint8_t* p10 = row0 + (size_t)x1 * 4;
            const uint8_t* p01 = row1 + (size_t)x0 * 4;
            const uint8_t* p11 = row1 + (size_t)x1 * 4;
            uint8_t* dp = outRow + (size_t)xx * 4;
            for (int c = 0; c < 4; ++c) {
                const int v = (int)(p00[c] * w00 + p10[c] * w10 + p01[c] * w01 + p11[c] * w11 + 0.5);
                dp[c] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
            }
        }
    }
}

static void DestroyZoomOverlayResources() {
    if (g_zoomOverlayDC) { DeleteDC(g_zoomOverlayDC); g_zoomOverlayDC = nullptr; }
    if (g_zoomOverlayBmp) { DeleteObject(g_zoomOverlayBmp); g_zoomOverlayBmp = nullptr; }
    g_zoomOverlayBits = nullptr;
    g_zoomOverlayW = g_zoomOverlayH = 0;
}

static bool EnsureZoomOverlay() {
    if (g_zoomOverlay && IsWindow(g_zoomOverlay)) return true;
    if (!g_hwnd) return false;
    g_zoomOverlay = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        L"STATIC", L"", WS_POPUP,
        0, 0, 1, 1, g_hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
    return g_zoomOverlay != nullptr;
}

static void HideZoomOverlay() {
    if (g_zoomOverlayShown) {
        if (g_zoomOverlay && IsWindow(g_zoomOverlay)) ShowWindow(g_zoomOverlay, SW_HIDE);
        g_zoomOverlayShown = false;
        Log("晃动放大: 叠加层隐藏");
    }
    if (g_cursorVisible.load()) {
        SetCursor(g_customCursor ? g_customCursor : LoadCursor(nullptr, IDC_ARROW));
    }
}

// 立即结束晃动放大（失焦、改窗口几何、切换全屏等场景）。
static void AbortShake() {
    if (g_shakeActive) {
        g_shakeActive = false;
        g_shakePhase = SHAKE_IDLE;
        g_shakeZoom = 1.0;
        if (g_hwnd) KillTimer(g_hwnd, kShakeTimer);
        SetShakeTimePeriod(false);
    }
    HideZoomOverlay();
}

// 按当前放大倍数把光标绘制到叠加层（以指针热点对齐）。
// 用分层窗自绘而不是放大 HCURSOR：HCURSOR 一旦超过硬件上限，DWM 会退化为软件光标，
// 在 D3D 交换链上拖出残影并可能同时显示两个指针。
// 放大叠加层的几何计算（纯函数，便于自检与复用）。
// k 为「原生像素 → 屏幕物理像素」比例；返回层尺寸与放大后的热点偏移。
struct ZoomGeometry { int dw = 0, dh = 0, hx = 0, hy = 0; };
static ZoomGeometry ComputeZoomGeometry(int sw, int sh, int shx, int shy, double k, int maxSide) {
    ZoomGeometry g;
    if (sw <= 0 || sh <= 0 || k <= 0.0) return g;
    int dw = (int)(sw * k + 0.5);
    int dh = (int)(sh * k + 0.5);
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    double fit = 1.0;
    if (dw > maxSide) fit = std::min(fit, (double)maxSide / dw);
    if (dh > maxSide) fit = std::min(fit, (double)maxSide / dh);
    if (fit < 1.0) {
        k *= fit;
        dw = (int)(dw * fit + 0.5);
        dh = (int)(dh * fit + 0.5);
    }
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    g.dw = dw;
    g.dh = dh;
    g.hx = (int)(shx * k + 0.5);
    g.hy = (int)(shy * k + 0.5);
    return g;
}

static void UpdateZoomOverlay(double zoom) {
    if (zoom <= 1.02) { HideZoomOverlay(); return; }
    if (!EnsureZoomOverlay()) return;
    if (g_steadySpriteK <= 0.0) return;
    std::vector<uint8_t> sprite;
    int sw = 0, sh = 0, shx = 0, shy = 0;
    {
        std::lock_guard<std::mutex> lk(g_spriteMtx);
        if (g_nativeSprite.empty() || g_nativeW <= 0 || g_nativeH <= 0) return;
        sprite = g_nativeSprite;
        sw = g_nativeW; sh = g_nativeH; shx = g_nativeHotX; shy = g_nativeHotY;
    }
    // 关键：从「稳态实际绘制比例」出发再乘 zoom。
    // 若直接重新推导 (displayScale/nativeScale)，会绕过 ApplyCursorImage 里的 hwMax 钳位，
    // 起晃第一帧就会从被钳过的尺寸跳到未钳尺寸（能差 25%），曲线立刻变得突兀。
    double k = g_steadySpriteK * zoom;
    if (k <= 0.0) return;
    const int kMaxSide = 512;
    const ZoomGeometry geo = ComputeZoomGeometry(sw, sh, shx, shy, k, kMaxSide);
    const int dw = geo.dw, dh = geo.dh;
    if (dw <= 0 || dh <= 0) return;

    // 一次性按上限分配 DIB/DC：放大过程中尺寸每帧变化，反复 CreateDIBSection 会明显拖慢。
    // 分配后只把当前尺寸的行拷进左上角，UpdateLayeredWindow 用 psize 指定实际区域。
    if (!g_zoomOverlayBits || !g_zoomOverlayDC) {
        DestroyZoomOverlayResources();
        BITMAPV5HEADER bi{};
        bi.bV5Size = sizeof(bi);
        bi.bV5Width = kMaxSide;
        bi.bV5Height = -kMaxSide;           // 负值 = 自顶向下
        bi.bV5Planes = 1;
        bi.bV5BitCount = 32;
        bi.bV5Compression = BI_RGB;
        HDC screen = GetDC(nullptr);
        g_zoomOverlayBmp = CreateDIBSection(screen, (BITMAPINFO*)&bi, DIB_RGB_COLORS,
                                            &g_zoomOverlayBits, nullptr, 0);
        g_zoomOverlayDC = CreateCompatibleDC(screen);
        if (screen) ReleaseDC(nullptr, screen);
        if (!g_zoomOverlayBmp || !g_zoomOverlayDC || !g_zoomOverlayBits) {
            DestroyZoomOverlayResources();
            return;
        }
        SelectObject(g_zoomOverlayDC, g_zoomOverlayBmp);
        g_zoomOverlayW = kMaxSide;
        g_zoomOverlayH = kMaxSide;
    }
    if (dw > g_zoomOverlayW || dh > g_zoomOverlayH) return;

    std::vector<uint8_t> scaled;
    ResampleBgraPremul(sprite.data(), sw, sh, scaled, dw, dh);
    if (scaled.size() != (size_t)dw * dh * 4) return;
    // 逐行拷贝：DIB 的 stride 是 512*4，不能整块 memcpy
    {
        uint8_t* base = (uint8_t*)g_zoomOverlayBits;
        const size_t dstStride = (size_t)g_zoomOverlayW * 4;
        const size_t rowBytes = (size_t)dw * 4;
        for (int y = 0; y < dh; ++y) {
            memcpy(base + (size_t)y * dstStride, scaled.data() + (size_t)y * rowBytes, rowBytes);
        }
    }

    POINT cur{};
    if (!GetCursorPos(&cur)) return;
    POINT dstPt{ cur.x - geo.hx, cur.y - geo.hy };
    SIZE sz{ dw, dh };
    POINT srcPt{ 0, 0 };
    BLENDFUNCTION bf{ AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
    // 先隐藏硬件光标再提交放大帧。反过来的话，UpdateLayeredWindow 已把放大图
    // 呈现到屏幕，而旧系统箭头仍可能存活到下一次 WM_SETCURSOR，形成双指针。
    SetCursor(HiddenCursorHandle());
    if (UpdateLayeredWindow(g_zoomOverlay, nullptr, &dstPt, &sz, g_zoomOverlayDC,
                            &srcPt, 0, &bf, ULW_ALPHA)) {
        if (!g_zoomOverlayShown) {
            ShowWindow(g_zoomOverlay, SW_SHOWNOACTIVATE);
            g_zoomOverlayShown = true;
            Log("晃动放大: 叠加层显示 %dx%d (zoom %.2fx)", dw, dh, zoom);
        }
    } else {
        // 更新失败时不能留着上一帧的放大图与隐藏光标
        HideZoomOverlay();
    }
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

    // 缩放基准：Mac 送来的位图现在是「原生像素」（2x 屏上是 56x80），
    // 需要先除以会话头通告的 backing scale 还原成逻辑点，再乘「屏幕物理像素 / 逻辑点」
    // 得到最终绘制尺寸。这样稳态是下采样（锐利），晃动放大从上采样起点更高（不发糊）。
    const int hwMax = HardwareCursorMaxSide(g_hwnd);
    const int displayScalePm = DesiredCursorScalePm();
    const double nativeScale = (g_sessScaleTenths.load() >= 5) ? (g_sessScaleTenths.load() / 10.0) : 1.0;
    double k = ((double)displayScalePm / 1000.0) / nativeScale;
    if (k <= 0.0) return;
    // 稳态严格压进硬件光标上限：只要超过一点，DWM 就会切换成软件光标，拖动时出现残影/双指针。
    const double maxSide = (double)(w > h ? w : h) * k;
    if (maxSide > (double)hwMax) k *= (double)hwMax / maxSide;
    const int scalePm = (int)(k * nativeScale * 1000.0 + 0.5);
    const int capInt = hwMax;
    g_steadySpriteK = k;   // 叠加层按同一基准放大，避免起晃第一帧尺寸跳变

    // 放大动画用的高分辨率源：始终保留原生位图（未缩放），由叠加层按需重采样。
    {
        std::lock_guard<std::mutex> lk(g_spriteMtx);
        g_nativeSprite = bgra;
        g_nativeW = rawW;
        g_nativeH = rawH;
        g_nativeHotX = rawHotX;
        g_nativeHotY = rawHotY;
    }

    if (g_customCursor && fp == g_cursorAppliedFp && scalePm == g_cursorAppliedScalePm && capInt == g_cursorAppliedCap) {
        return;   // 同一张图同一缩放与上限，沿用现有 HCURSOR
    }
    // 命中稳态缓存：直接切换句柄，零 GDI 分配（箭头/I型/手型间切换不再卡顿）
    for (int i = 0; i < kCursorCacheCap; ++i) {
        if (g_cursorCache[i].cur && g_cursorCache[i].fp == fp &&
            g_cursorCache[i].scalePm == scalePm && g_cursorCache[i].maxSideCap == capInt) {
            HCURSOR old = g_customCursor;
            g_customCursor = g_cursorCache[i].cur;
            g_cursorAppliedFp = fp;
            g_cursorAppliedScalePm = scalePm;
            g_cursorAppliedCap = capInt;
            if (!g_zoomOverlayShown && g_cursorVisible.load()) SetCursor(g_customCursor);
            if (old && old != g_customCursor && !IsInCursorCache(old)) DestroyCursor(old);
            return;
        }
    }

    int w2 = (int)(w * k + 0.5);
    int h2 = (int)(h * k + 0.5);
    if (w2 < 1) w2 = 1;
    if (h2 < 1) h2 = 1;
    if (w2 != w || h2 != h) {
        std::vector<uint8_t> dst;
        ResampleBgraPremul(bgra.data(), w, h, dst, w2, h2);
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

    Log("光标位图 %dx%d hot=(%d,%d) DPI %.2fx hwMax=%d → 稳态 %dx%d hot=(%d,%d)",
        rawW, rawH, rawHotX, rawHotY, WindowDpiScale(g_hwnd), hwMax, w, h, hotX, hotY);

    // 先挂上新的再销毁旧的：反过来的话，销毁到 SetCursor 之间系统光标句柄是悬空的
    HCURSOR old = g_customCursor;
    g_customCursor = cur;
    g_cursorAppliedFp = fp;
    g_cursorAppliedScalePm = scalePm;   // 唯一权威：当前实际应用的缩放
    g_cursorAppliedCap = capInt;
    if (!g_zoomOverlayShown && g_cursorVisible.load()) SetCursor(cur);
    {
        HCURSOR victim = g_cursorCache[g_cursorCacheNext].cur;
        g_cursorCache[g_cursorCacheNext] = CachedCursor{ fp, scalePm, capInt, cur };
        g_cursorCacheNext = (g_cursorCacheNext + 1) % kCursorCacheCap;
        if (victim && victim != cur && victim != old) DestroyCursor(victim);
    }
    if (old && old != cur && !IsInCursorCache(old)) DestroyCursor(old);
}

// 晃动检测。返回 true 表示「本次这一个光标包判定为晃动」，
// 不是「当前是否处于放大态」——调用方靠它区分真晃动和收缩期间的孤立噪声包。
// 只看最近 kShakeWinMs 的轨迹，求 x（或 y）方向的符号反转次数与总摆幅。
// 用「反转次数 + 摆幅」双条件：单靠摆幅会把慢速大范围拖动误判成晃动。
static bool DetectShake(int64_t now, int x, int y) {
    // 采样入环
    if (g_shakeCount > 0) {
        // 同一毫秒内多次移动只取最后一次，避免轨迹点重复导致方向判定噪音
        int prevIdx = (g_shakeHead - 1 + kShakeCap) % kShakeCap;
        if (g_shakeBuf[prevIdx].t == now) {
            g_shakeBuf[prevIdx].x = x;
            g_shakeBuf[prevIdx].y = y;
            // 返回 false 而不是 g_shakeActive：调用方用它决定是否把缩放
            // 拉回满值，返回 true 会让收缩动画期间闪一下。
            return false;
        }
    }
    g_shakeBuf[g_shakeHead] = ShakeSample{ now, x, y };
    g_shakeHead = (g_shakeHead + 1) % kShakeCap;
    if (g_shakeCount < kShakeCap) ++g_shakeCount;

    // 收集窗口内的采样（按时间顺序）
    int n = 0;
    ShakeSample win[kShakeCap];
    for (int i = 0; i < g_shakeCount && n < kShakeCap; ++i) {
        int idx = (g_shakeHead - g_shakeCount + i + kShakeCap) % kShakeCap;
        if (now - g_shakeBuf[idx].t <= kShakeWinMs) win[n++] = g_shakeBuf[idx];
    }
    if (n < 4) return false;   // 样本不足，本次不判定为晃动

    // 位移方向序列（用相邻点差值，按窗口 DPI 缩放门槛，避免高 DPI 下误触）。
    // 200% DPI 下 180 物理像素只等于 90 逻辑像素、8px 只等于 4 逻辑像素，
    // 同一段手部晃动的物理距离在高 DPI 屏上门槛会减半，所以乘 WindowDpiScale。
    const double dpiScale = WindowDpiScale(g_hwnd);
    const int minStepPx = (int)(5.0 * dpiScale + 0.5);
    const int minSpanPx = (int)(kShakeMinSpanPx * dpiScale + 0.5);
    int reversalsX = 0, reversalsY = 0;
    int spanX = 0, spanY = 0;
    int minX = win[0].x, maxX = win[0].x, minY = win[0].y, maxY = win[0].y;
    int lastDirX = 0, lastDirY = 0;
    for (int i = 1; i < n; ++i) {
        int dx = win[i].x - win[i - 1].x;
        int dy = win[i].y - win[i - 1].y;
        if (win[i].x < minX) minX = win[i].x;
        if (win[i].x > maxX) maxX = win[i].x;
        if (win[i].y < minY) minY = win[i].y;
        if (win[i].y > maxY) maxY = win[i].y;
        if (dx > minStepPx || dx < -minStepPx) {
            int d = dx > 0 ? 1 : -1;
            if (lastDirX != 0 && d != lastDirX) ++reversalsX;
            lastDirX = d;
        }
        if (dy > minStepPx || dy < -minStepPx) {
            int d = dy > 0 ? 1 : -1;
            if (lastDirY != 0 && d != lastDirY) ++reversalsY;
            lastDirY = d;
        }
    }
    spanX = maxX - minX;
    spanY = maxY - minY;

    const bool shakeX = reversalsX >= kShakeMinReversals && spanX >= minSpanPx;
    const bool shakeY = reversalsY >= kShakeMinReversals && spanY >= minSpanPx;
    const bool shaking = shakeX || shakeY;

    if (shaking) {
        if (!g_shakeEnabled.load()) return false;
        const double nowQpc = QpcNowMs();
        g_shakeLastPointerQpcMs = nowQpc;
        // 平滑接续：处于 IDLE 或正在 SHRINK 时，从当前缩放倍率启动平滑放大曲线（InOutCubic），
        // 不再瞬间跳变到 2.8x；已在 GROW 或 HOLD 时只延长保持时刻，过渡连续不抖动。
        if (!g_shakeActive || g_shakePhase == SHAKE_IDLE || g_shakePhase == SHAKE_SHRINK) {
            if (!g_shakeActive) {
                Log("检测到快速晃动（反转 x%d y%d，摆幅 x%dp y%dp），平滑放大光标 %.1fx",
                    reversalsX, reversalsY, spanX, spanY, kShakeCursorZoom);
            }
            g_shakeActive = true;
            g_shakePhase = SHAKE_GROW;
            g_shakeAnimStartMs = nowQpc;
            g_shakeAnimFromZoom = g_shakeZoom;
            SetShakeTimePeriod(true);
            if (SetTimer(g_hwnd, kShakeTimer, kShakeTickMs, nullptr) == 0) {
                Log("警告: 创建晃动定时器失败，放弃本次放大");
                AbortShake();
                return false;
            }
        }
        return true;
    }
    // 不再晃动。返回值语义是「本次是否判定为晃动」，不是「是否仍处于放大态」——
    // 调用方靠它区分「真晃动」和「收缩期间的孤立噪声包」。
    // HOLD 由 TickShakeAnim 判断：指针还在移动就延长保持期；连续静止
    // kShakeHoldMs 后才开始 SHRINK。
    return false;
}

// 清空晃动采样缓冲。窗口几何变化（移动、缩放、换 DPI、切换显示模式）后
// 屏幕坐标会整体跳变，相邻样本之间的差值会被当成一次大摆幅，
// 配合正常移动的反转次数就可能误触发放大。
static void ResetShakeSamples() {
    g_shakeCount = 0;
    g_shakeHead = 0;
}

// 末端带轻微过冲的缓出曲线，逼近 macOS 的弹簧起势（切换点不会出现速度突变）。
static double EaseOutBack(double t, double c1) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    const double u = t - 1.0;
    return 1.0 + (c1 + 1.0) * u * u * u + c1 * u * u;
}

static double EaseInOutCubic(double t) {
    if (t <= 0.0) return 0.0;
    if (t >= 1.0) return 1.0;
    return (t < 0.5) ? (4.0 * t * t * t) : (1.0 - std::pow(-2.0 * t + 2.0, 3.0) * 0.5);
}

// 晃动放大动画：Grow[EaseOutBack 带过冲] -> Hold -> Shrink[EaseInOutCubic]，QPC 亚毫秒时钟。
// 每帧同步绘制到叠加层（不重建 HCURSOR），所以放大倍数可以接近 macOS 而不会拖出残影。
// 返回 true 表示动画或保持仍在进行，需要继续定时器。
static bool TickShakeAnim(double nowQpc) {
    if (!g_shakeActive || g_shakePhase == SHAKE_IDLE) return false;

    if (g_shakePhase == SHAKE_GROW) {
        double p = (nowQpc - g_shakeAnimStartMs) / kShakeGrowMs;
        if (p >= 1.0) {
            g_shakeZoom = kShakeCursorZoom;
            g_shakePhase = SHAKE_HOLD;
            g_shakeAnimStartMs = nowQpc;
        } else {
            const double e = EaseOutBack(p, kShakeOvershootC1);
            g_shakeZoom = g_shakeAnimFromZoom + (kShakeCursorZoom - g_shakeAnimFromZoom) * e;
            UpdateZoomOverlay(g_shakeZoom);
            return true;
        }
    }
    if (g_shakePhase == SHAKE_HOLD) {
        if (nowQpc - g_shakeLastPointerQpcMs < kShakeHoldMs) {
            UpdateZoomOverlay(g_shakeZoom);
            return true;
        }
        g_shakePhase = SHAKE_SHRINK;
        g_shakeAnimStartMs = nowQpc;
        g_shakeAnimFromZoom = g_shakeZoom;
    }
    if (g_shakePhase == SHAKE_SHRINK) {
        double p = (nowQpc - g_shakeAnimStartMs) / kShakeShrinkMs;
        if (p >= 1.0) {
            g_shakeActive = false;
            g_shakePhase = SHAKE_IDLE;
            g_shakeZoom = 1.0;
            HideZoomOverlay();
            return false;
        }
        g_shakeZoom = g_shakeAnimFromZoom + (1.0 - g_shakeAnimFromZoom) * EaseInOutCubic(p);
        UpdateZoomOverlay(g_shakeZoom);
        return true;
    }
    return false;
}

// 当前应使用的缩放（千分比）。结合「视频有效区域 / Mac 逻辑宽度」与显示器 DPI，
// 保证窗口模式下桌面缩小时光标同比例缩小、全屏下在不超硬件上限前提下尽量 1:1 视觉对齐。
static int DesiredCursorScalePm() {
    const double dpi = WindowDpiScale(g_hwnd);
    double targetScale = dpi;
    const int scaleTenths = g_sessScaleTenths.load();
    const int cwCoord = g_coordW.load();
    if (g_hwnd && !g_coordUserSpecified && scaleTenths >= 5 && cwCoord > 0) {
        RECT rc{};
        if (GetClientRect(g_hwnd, &rc)) {
            const int cw = rc.right - rc.left;
            const int ch = rc.bottom - rc.top;
            if (cw >= 64 && ch >= 64) {
                const RECT vr = VideoRectInClient(cw, ch);
                const int rw = vr.right - vr.left;
                if (rw > 0) {
                    const double macLogicalW = (double)cwCoord / ((double)scaleTenths / 10.0);
                    if (macLogicalW > 0.0) {
                        double videoScale = (double)rw / macLogicalW;
                        const double minS = std::max(0.75, dpi * 0.45);
                        const double maxS = dpi * 1.5;
                        if (videoScale < minS) videoScale = minS;
                        if (videoScale > maxS) videoScale = maxS;
                        targetScale = videoScale;
                    }
                }
            }
        }
    }
    const int basePm = (int)(targetScale * 1000.0 + 0.5);
    // 注意：不再乘晃动倍数。放大由 ZoomOverlay 绘制，HCURSOR 始终保持稳态尺寸，
    // 这样系统光标永远落在硬件光标上限内，不会退化成 DWM 软件光标（残影/双指针的根因）。
    return basePm;
}

// 放大状态变化后重建 HCURSOR。缩放参与指纹，所以改 g_shakeActive 后
// 只要重新置 pending 再走 ApplyCursorImage 就能重建。
static void RefreshCursorScale() {
    {
        std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
        if (g_cursorImage.bgra.empty()) return;
        g_cursorImage.pending = true;
    }
    ApplyCursorImage();
}

// 在鼠标移动消息（Mac 0x03 或本机 WM_MOUSEMOVE）里按目标帧率推进晃动动画，
// 避免高频移动期间低优先级 WM_TIMER 被消息队列饿死导致放大瞬间跳变。
static void DriveShakeStep(int screenX, int screenY) {
    const int64_t nowMs = GetTickCount64();
    const bool wasActive = g_shakeActive;
    // 每次真实指针移动都刷新「最后一次移动」时刻：HOLD 以它为起点，
    // 指针持续移动时保持放大，静止满 kShakeHoldMs 后才收缩。
    const double moveQpc = QpcNowMs();
    g_shakeLastPointerQpcMs = moveQpc;
    DetectShake(nowMs, screenX, screenY);
    if (g_shakeActive) {
        const double nowQpc = moveQpc;
        if (!wasActive || (nowQpc - g_shakeLastRefreshQpcMs >= (double)kShakeTickMs * 0.9)) {
            g_shakeLastRefreshQpcMs = nowQpc;
            const bool keep = TickShakeAnim(nowQpc);
            if (!keep) {
                Log("晃动结束，光标已恢复原尺寸");
                if (g_hwnd) KillTimer(g_hwnd, kShakeTimer);
                SetShakeTimePeriod(false);
            }
        }
    } else if (wasActive) {
        HideZoomOverlay();
        if (g_hwnd) KillTimer(g_hwnd, kShakeTimer);
        SetShakeTimePeriod(false);
    }
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
        // 最小化/还原过渡期间 Windows 偶尔会发 2x2 的瞬态客户区，低于 64px 一律忽略并取消定时器，
        // 否则交换链被切成 2x2 会直接黑屏。
        if (w == SIZE_MINIMIZED) {
            KillTimer(h, TIMER_SYNC_SWAP);
            UpdateExecutionState();
        } else {
            const int cw = LOWORD(l), ch = HIWORD(l);
            if (cw >= 64 && ch >= 64) {
                g_pendingClientW = cw;
                g_pendingClientH = ch;
                g_syncSwapRetry = 0;
                SetTimer(h, TIMER_SYNC_SWAP, 120, nullptr);
                // 客户区尺寸变了，远程坐标到屏幕坐标的换算比例也变了
                ResetShakeSamples();
                AbortShake();
            } else {
                KillTimer(h, TIMER_SYNC_SWAP);
            }
            UpdateExecutionState();
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
            RECT cur{};
            if (g_presenter && !IsIconic(h) && GetClientRect(h, &cur) &&
                cur.right - cur.left >= 64 && cur.bottom - cur.top >= 64) {
                const int tw = cur.right - cur.left;
                const int th = cur.bottom - cur.top;
                if (!g_presenter->Resize(tw, th)) {
                    // 后缓冲还被呈现线程占着，隔一轮再试，最多 8 次
                    if (++g_syncSwapRetry < 8) {
                        SetTimer(h, TIMER_SYNC_SWAP, 150, nullptr);
                    } else {
                        Log("交换链同步放弃: 目标 %dx%d 连续失败", tw, th);
                        g_syncSwapRetry = 0;
                    }
                } else {
                    g_syncSwapRetry = 0;
                    RefreshCursorScale();
                }
            }
            return 0;
        }
        if (w == TIMER_SLEEP_WATCHDOG) {
            KillTimer(h, TIMER_SLEEP_WATCHDOG);
            if (g_hostMode.load() && g_winHost.IsPausedForSleep()) {
                Log("电源事件: 休眠可能被取消或阻塞，看门狗自动恢复虚拟屏");
                g_resumeRetryCount = 0;
                SetTimer(h, TIMER_RESUME_HOST, 200, nullptr);
            }
            return 0;
        }
        if (w == TIMER_RESUME_HOST) {
            KillTimer(h, TIMER_RESUME_HOST);
            if (g_hostMode.load()) {
                if (g_winHost.IsPausedForSleep()) {
                    if (g_winHost.ResumeFromSleep()) {
                        g_resumeRetryCount = 0;
                        UpdateControlPanel();
                    } else if (++g_resumeRetryCount <= 3) {
                        Log("电源恢复后重建虚拟屏未就绪，2.5 秒后第 %d 次重试", g_resumeRetryCount);
                        SetTimer(h, TIMER_RESUME_HOST, 2500, nullptr);
                    } else {
                        g_winHost.ClearPausedForSleep();
                        g_resumeRetryCount = 0;
                        Log("警告: 电源恢复后重建虚拟屏连续失败，可点击控制面板「重挂虚拟屏」");
                        UpdateControlPanel();
                    }
                } else if (g_winHost.IsRunning()) {
                    g_winHost.OnDisplayChange(true);
                }
            }
            return 0;
        }
        if (w == kShakeTimer) {
            const double nowQpc = QpcNowMs();
            // 鼠标移动路径（DriveShakeStep）刚推进过就跳过，避免同一帧算两次、
            // 重复做一次叠加层重采样与 UpdateLayeredWindow。
            if (nowQpc - g_shakeLastRefreshQpcMs < (double)kShakeTickMs * 0.5) return 0;
            g_shakeLastRefreshQpcMs = nowQpc;
            const bool keep = TickShakeAnim(nowQpc);
            if (!keep) {
                Log("晃动结束，光标已恢复原尺寸");
                KillTimer(h, kShakeTimer);
                SetShakeTimePeriod(false);
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
        if (!g_cursorVisible.load()) {
            // 指针离开副屏时立即收起放大叠加层，避免冻结的放大图滞留到动画结束。
            AbortShake();
        }
        if (g_zoomOverlayShown) {
            SetCursor(HiddenCursorHandle());
        } else if (g_cursorVisible.load()) {
            SetCursor(g_customCursor ? g_customCursor : LoadCursor(nullptr, IDC_ARROW));
        } else {
            // 用 1x1 透明光标而不是 nullptr：nullptr 只维持到下一次系统光标刷新，
            // 刷新后箭头会重新出现，和 Mac 端「已离开副屏」的状态冲突。
            SetCursor(HiddenCursorHandle());
        }
        return 0;
    case WM_APP_UPDATE_POWER:
        UpdateExecutionState();
        return 0;
    case WM_APP_SET_CLIP_TEXT: {
        std::deque<PendingClipText> batch;
        {
            std::lock_guard<std::mutex> lk(g_clipTextMtx);
            batch.swap(g_clipTextQ);
        }
        if (batch.empty()) return 0;
        const PendingClipText& latest = batch.back();
        bool opened = false;
        for (int attempt = 0; attempt < 3; ++attempt) {
            if (OpenClipboard(h)) { opened = true; break; }
            Sleep(10);
        }
        bool wrote = false;
        if (opened) {
            if (EmptyClipboard()) {
                size_t bytes = (latest.text.size() + 1) * sizeof(wchar_t);
                HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
                if (hMem) {
                    void* dst = GlobalLock(hMem);
                    if (dst) {
                        memcpy(dst, latest.text.c_str(), bytes);
                        GlobalUnlock(hMem);
                        if (SetClipboardData(CF_UNICODETEXT, hMem)) {
                            wrote = true;
                        } else {
                            GlobalFree(hMem);
                        }
                    } else {
                        GlobalFree(hMem);
                    }
                }
            }
            CloseClipboard();
        }
        if (wrote) {
            SetTransferStatus(L"已写入剪贴板: " + latest.preview, -1, L"");
            SetTransferFeedback(1, L"已写入剪贴板", latest.preview);
            Log("中转站收到文本 #%u (%zu B)，已写入剪贴板", latest.id, latest.utf8Bytes);
        } else {
            SetTransferStatus(L"写入剪贴板失败: " + latest.preview, -1, L"");
            SetTransferFeedback(-1, L"写入剪贴板失败", latest.preview);
            Log("中转站收到文本 #%u (%zu B)，写入剪贴板失败", latest.id, latest.utf8Bytes);
        }
        return 0;
    }
    case WM_DISPLAYCHANGE:
        if (g_hostMode.load()) {
            g_winHost.OnDisplayChange();
            return 0;
        }
        UpdateRefreshHz();
        ResetShakeSamples();
        return 0;
    case WM_POWERBROADCAST:
        if (w == PBT_APMSUSPEND) {
            KillTimer(h, TIMER_RESUME_HOST);
            if (g_hostMode.load()) {
                Log("电源事件: 系统即将进入睡眠/休眠 (PBT_APMSUSPEND)");
                if (g_winHost.PauseForSleep()) {
                    SetTimer(h, TIMER_SLEEP_WATCHDOG, 30000, nullptr);
                }
                UpdateControlPanel();
            }
            return TRUE;
        }
        if (w == PBT_APMRESUMEAUTOMATIC || w == PBT_APMRESUMESUSPEND ||
            w == PBT_APMRESUMECRITICAL || w == PBT_APMRESUMESTANDBY) {
            KillTimer(h, TIMER_SLEEP_WATCHDOG);
            if (g_hostMode.load()) {
                Log("电源事件: 系统唤醒 (wParam=0x%llX)", (unsigned long long)w);
                SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
                if (g_winHost.IsPausedForSleep()) {
                    // 延迟 1.5s 再恢复虚拟屏，给雷电/显示驱动完成重枚举留出窗口并防抖多次唤醒事件
                    g_resumeRetryCount = 0;
                    SetTimer(h, TIMER_RESUME_HOST, 1500, nullptr);
                } else if (w == PBT_APMRESUMESUSPEND) {
                    if (g_winHost.IsRunning() && g_winHost.VddActive()) {
                        g_winHost.OnDisplayChange(true);
                    } else {
                        secdisplay::WinVirtualDisplay::EnsureInternalPanelAwake([](const char* s) { Log("%s", s); });
                    }
                }
                UpdateControlPanel();
            }
            return TRUE;
        }
        if (w == PBT_POWERSETTINGCHANGE && l) {
            const auto* pbs = reinterpret_cast<const POWERBROADCAST_SETTING*>(l);
            static const GUID kGuidLidSwitch = {
                0xBA3E0F4D, 0xB817, 0x4094, { 0xA2, 0xD1, 0xD5, 0x63, 0x79, 0xE6, 0xA0, 0xF3 }
            };
            if (IsEqualGUID(pbs->PowerSetting, kGuidLidSwitch) && pbs->DataLength >= sizeof(DWORD)) {
                DWORD lidOpen = *reinterpret_cast<const DWORD*>(pbs->Data);
                Log("电源事件: 笔记本合盖开关状态变化 -> %s", lidOpen ? "已开盖" : "已合盖");
                if (lidOpen && g_hostMode.load()) {
                    if (g_winHost.IsRunning() && g_winHost.VddActive()) {
                        g_winHost.OnDisplayChange(true);
                    } else {
                        secdisplay::WinVirtualDisplay::EnsureInternalPanelAwake([](const char* s) { Log("%s", s); });
                    }
                }
            }
            return TRUE;
        }
        break;
    case WM_EXITSIZEMOVE:
        // 显示模式变化或窗口跨屏移动后，刷新率可能变了，--pace 的节拍要跟着更新
        UpdateRefreshHz();
        // 晃动轨迹用屏幕坐标，窗口移动/尺寸变化会让相邻样本出现几百像素的突跳，
        // 直接计入摆幅会误触发放大。清空采样缓冲，从新几何重新累积。
        ResetShakeSamples();
        return 0;
    case WM_MOUSEACTIVATE:
        // 明确要求「激活并投递这次点击」，避免第一次点击只用于激活窗口而不转发给 Mac。
        return MA_ACTIVATE;
    case WM_ACTIVATE:
        if (LOWORD(w) == WA_INACTIVE) {
            // 失焦时结束晃动放大：叠加层是 TOPMOST，留着会盖在别人的窗口上。
            AbortShake();
        }
        break;   // 焦点状态仍交给 DefWindowProc
    case WM_MOVE:
        ResetShakeSamples();
        return 0;
    case WM_DPICHANGED:
        // 窗口被拖到另一块缩放不同的显示器：按新 DPI 重建光标位图。
        // 原始位图仍留在 g_cursorImage.bgra，只是 pending 已被清掉，这里重新置位。
        {
            std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
            if (!g_cursorImage.bgra.empty()) g_cursorImage.pending = true;
        }
        ApplyCursorImage();
        ResetShakeSamples();
        break;   // 窗口位置/尺寸仍交给 DefWindowProc
    case WM_APP_REMOTE_CURSOR: {
        // 先清合并标志再读坐标：确保读取之后若网络线程又收到更新，不会漏掉下一次通知。
        g_cursorMsgPending.store(false);
        // 门控：
        //   1. 最小化时不移动光标
        //   2. 窗口模式下非前台不抢夺用户在其他软件里的光标；全屏副屏时允许跨弹窗操作
        //   3. 本机物理鼠标最近 60ms 内有活动时，本地输入优先
        if (IsIconic(g_hwnd)) return 0;
        if (!g_isFullscreen && GetForegroundWindow() != g_hwnd) return 0;
        // 指针已经离开视频画面（例如用户把它滑到主屏）时不再拽回来：
        // 远程 0x03 只负责「画面内」的光标，出画面即交还本机光标，
        // 否则每次移动都会被夹回副屏窗口，表现为「鼠标被困在副屏里出不去」。
        // 例外：Mac 光标刚重新回到副屏时允许拉回一次（g_pullCursorIn）。
        const bool owned = PortalCursorOwned();
        if (owned) g_pullCursorIn.store(false);   // 已在画面内，凭证不再需要，避免出去后又被拽回一次
        if (!owned && !g_pullCursorIn.load()) return 0;
        const uint64_t gateNow = GetTickCount64();
        // 本机物理 HID 输入刚动过时短暂让位，避免两条位置源互相拉扯。
        // 不把本地点击、滚轮或 WM_MOUSEMOVE 算进来：后者可能正是 SetCursorPos
        // 的迟到回声，把它当成让位理由会形成「移动 → 冻结 → 再移动」循环。
        const bool localBusy = gateNow - (uint64_t)g_lastHardwareMouseMs.load() < 60;
        // 「回到副屏」的一次性拉回必须绕过本地优先门控：用户正是用手把指针推回来，
        // 硬件鼠标一定刚刚动过，否则这次拉回会被永久丢弃。
        if (localBusy && owned) return 0;
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
        RECT vr = VideoRectInClient(cw, ch);
        int rw = vr.right - vr.left, rh = vr.bottom - vr.top;
        if (rw <= 0 || rh <= 0) return 0;
        int sx = tl.x + vr.left + (int)(cx / vw * rw);
        int sy = tl.y + vr.top + (int)(cy / vh * rh);
        if (sx < tl.x + vr.left) sx = tl.x + vr.left;
        if (sx >= tl.x + vr.right) sx = tl.x + vr.right - 1;
        if (sy < tl.y + vr.top) sy = tl.y + vr.top;
        if (sy >= tl.y + vr.bottom) sy = tl.y + vr.bottom - 1;
        // 真正执行了拉回才消费一次性凭证，避免被后续 return 吞掉。
        if (!owned) g_pullCursorIn.store(false);
        const uint64_t nowMoveMs = GetTickCount64();
        g_lastRemoteCursorX = sx;
        g_lastRemoteCursorY = sy;
        g_lastRemoteCursorMoveMs = (int64_t)nowMoveMs;
        RecordRemoteTarget(sx, sy, nowMoveMs);
        SetCursorPos(sx, sy);

        // 晃动检测与高频推进：触发期间直接在光标消息内同步推进缩放曲线，避免 WM_TIMER 饿死
        DriveShakeStep(sx, sy);
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
        case ID_TRAY_PANEL:   ShowControlPanel(); return 0;
        case ID_TRAY_DROPBOX: ShowDropBoxWindow(); return 0;
        case ID_TRAY_MODE:    SwitchAppMode(!g_hostMode.load()); return 0;
        case ID_TRAY_KVM:
            if (g_hostMode.load()) {
                g_winHost.ToggleKvm();
                UpdateControlPanel();
            }
            return 0;
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
                L"Ctrl+Alt+B 一键呼出 / 隐藏悬浮文件投递盒\n"
                L"F11 切换全屏 / 窗口\n"
                L"Esc 也可退出",
                L"关于 SecDisplay", MB_OK | MB_ICONINFORMATION);
            return 0;
        }
        return 0;
    case WM_HOTKEY:
        if (w == HOTKEY_QUIT_ID) RequestQuit();
        else if (w == HOTKEY_HIDE_ID) ToggleMinimize();
        else if (w == HOTKEY_DROPBOX_ID) ToggleDropBoxWindow();
        else if (w == HOTKEY_KVM_ID && g_hostMode.load()) {
            g_winHost.ToggleKvm();
            UpdateControlPanel();
        }
        return 0;
    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP: {
        const bool down = (m == WM_KEYDOWN || m == WM_SYSKEYDOWN);
        const bool sysKey = (m == WM_SYSKEYDOWN || m == WM_SYSKEYUP);
        // lParam bit30 = 前一次状态已按下，用来识别系统自动重复。
        // 不区分的话按住 Esc 会先退出全屏、再被重复事件当成「再按一次」而直接退出进程。
        const bool repeat = (l & 0x40000000) != 0;
        // 本地快捷键只保留「退出」和「全屏」两个，且不转发，避免误触。
        // 原来还有 'F' 切全屏——键盘转发接入后按 F 会把远端画面放大，已移除。
        // 按下与抬起必须成对消费：只吞 keyDown 会向 Mac 投出无配对的 keyUp。
        if (w == VK_ESCAPE) {
            if (down && !repeat) {
                if (g_isFullscreen) ExitFullscreen(); else RequestQuit();
            }
            return 0;
        }
        if (w == VK_F11) {
            if (down && !repeat) {
                if (g_isFullscreen) ExitFullscreen(); else EnterFullscreen();
            }
            return 0;
        }
        // Alt+F4 交给系统走 SC_CLOSE。本分支接管了 WM_SYSKEYDOWN，若直接 return 0
        // 就吞掉了系统默认的关闭路径（窗口与全屏都退不出去）。
        if (sysKey && w == VK_F4) {
            if (down && !repeat) SendMessageW(h, WM_SYSCOMMAND, SC_CLOSE, 0);
            return 0;
        }
        // 其余按键全部转发给 Mac
        const uint16_t scan = (uint16_t)((l >> 16) & 0xFF);
        const bool extended = ((l >> 24) & 0x1) != 0;
        uint8_t flags = 0;
        if (extended) flags |= 0x01;
        if (sysKey)   flags |= 0x02;
        QueueKeyEvent((uint16_t)(w & 0xFFFF), scan, down ? 1 : 0, flags);
        return 0;
    }
    case WM_INPUT: {
        // 物理鼠标 HID 输入（SetCursorPos 不会触发 WM_INPUT），用于把真实本地移动与程序回声区分开
        UINT sz = sizeof(RAWINPUT);
        RAWINPUT raw{};
        if (GetRawInputData((HRAWINPUT)l, RID_INPUT, &raw, &sz, sizeof(RAWINPUTHEADER)) != (UINT)-1) {
            if (raw.header.dwType == RIM_TYPEMOUSE) {
                const RAWMOUSE& rm = raw.data.mouse;
                if (rm.usButtonFlags != 0 || rm.lLastX != 0 || rm.lLastY != 0) {
                    g_lastHardwareMouseMs.store(GetTickCount64());
                }
            }
        }
        break;
    }
    case WM_MOUSEMOVE: {
        // 过滤程序 SetCursorPos 产生的 WM_MOUSEMOVE 回声（最近 40ms 内、2px 以内的目标点）。
        // 过滤失败会把远程移动误判成本地鼠标输入，导致 60ms 冻结并向 Mac 回传 0x04 把光标拽回。
        POINT pt{ GET_X_LPARAM(l), GET_Y_LPARAM(l) };
        ClientToScreen(h, &pt);
        if (IsRemoteCursorEcho(pt.x, pt.y, GetTickCount64())) {
            return 0;
        }
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            g_lastLocalInputMs = GetTickCount64();
            // 只记最新位置，由 inputThread 8ms 合并发送，避免逐消息刷包
            g_moveX = vx;
            g_moveY = vy;
            g_moveDirty = true;
            DriveShakeStep(pt.x, pt.y);
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
        // 按住时捕获鼠标：不捕获的话拖拽一旦滑出客户区就收不到 up，
        // 表现为「按下拖不动 / 松手后还在拖」，点选文字、拖窗口时特别明显。
        if (down) {
            SetCapture(h);
        } else if (b == 0) {
            ReleaseCapture();
        }
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            // 按键事件逐条排队：down 和 up 各自成包，不再合并成最终状态。
            g_moveX = vx;
            g_moveY = vy;
            QueueInputEvent(vx, vy, b, 0);
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
            // 每个滚轮消息单独排队，保留原来的方向翻转（Windows 正值向上）。
            if (delta > 32767) delta = 32767;
            if (delta < -32768) delta = -32768;
            QueueInputEvent(vx, vy, g_buttons.load(), (int16_t)(-delta));
        }
        return 0;
    }
    case WM_SETCURSOR:
        // 放大动画期间由叠加层绘制光标，系统光标用 1x1 透明光标隐藏，
        // 否则屏幕上会同时出现「放大光标 + 系统箭头」两个指针。
        if (g_zoomOverlayShown) {
            SetCursor(HiddenCursorHandle());
            return TRUE;
        }
        // 光标已离开副屏（Mac 发过 visible=0）时不画任何光标
        if (!g_cursorVisible.load()) {
            SetCursor(HiddenCursorHandle());
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
    case WM_CAPTURECHANGED:
        // 捕获被系统/其他窗口夺走时收不到 WM_LBUTTONUP，必须补一个全释放包，
        // 否则 Mac 端会一直停在按下状态（表现为「松手还在拖」）。
        // 注意：本消息的 lParam 是「抢走捕获的窗口句柄」，不是坐标，不能当坐标解析。
        if (g_buttons.load() != 0) {
            g_buttons = 0;
            POINT pt{};
            float vx = g_moveX.load(), vy = g_moveY.load();
            if (GetCursorPos(&pt)) {
                POINT cp = pt;
                if (ScreenToClient(g_hwnd, &cp)) {
                    float tx, ty;
                    if (ClientToVideo(cp.x, cp.y, &tx, &ty)) { vx = tx; vy = ty; }
                }
            }
            QueueInputEvent(vx, vy, 0, 0);
            Log("鼠标捕获丢失，已补发全释放");
        }
        return 0;
    case WM_LBUTTONDBLCLK: {
        // 双击必须转发给 Mac，而不是被本地「切换全屏」吞掉：
        // 以前双击内容会展成全屏，用户体感就是「点不进去/点错」。全屏请用 F11 或最大化按钮。
        g_buttons = (uint8_t)(g_buttons.load() | 0x1);
        g_lastLocalInputMs = GetTickCount64();
        SetCapture(h);
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            g_moveX = vx;
            g_moveY = vy;
            QueueInputEvent(vx, vy, g_buttons.load(), 0);
        }
        return 0;
    }
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
    bool hostMode = false;    // --mode sender：Windows 作为主控发送端（Mac 当副屏）
    int hostWidth = 2880;     // 主控虚拟屏宽（默认 2880x1800 匹配 Retina 16:10 清晰度，不与 receiver 的 1600x1000 混淆）
    int hostHeight = 1800;    // 主控虚拟屏高
    int hostFps = 60;         // 主控发送帧率上限
    int hostBitrateMbps = 50; // 主控发送目标码率（Mbps，PeakConstrainedVBR）
    int hostDpi = 0;          // 虚拟屏独立 DPI 缩放百分比（0=跟随系统，100..300）
    int waitLockMs = 0;       // 角色切换重启时等待旧实例释放单实例锁的毫秒数
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
        } else if (a == "--sender" || a == "--host") {
            cfg.hostMode = true;
        } else if (a == "--receiver") {
            cfg.hostMode = false;
        } else if (a == "--mode" && i + 1 < argc) {
            std::string m = argv[++i];
            std::transform(m.begin(), m.end(), m.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            if (m == "sender" || m == "host" || m == "1") {
                cfg.hostMode = true;
            } else if (m == "receiver" || m == "client" || m == "0") {
                cfg.hostMode = false;
            } else {
                Log("警告: 未知 --mode 参数 %s，保持默认模式", m.c_str());
            }
        } else if (a == "--host-size" && i + 2 < argc) {
            cfg.hostWidth = atoi(argv[++i]);
            cfg.hostHeight = atoi(argv[++i]);
        } else if (a == "--fps" && i + 1 < argc) {
            cfg.hostFps = atoi(argv[++i]);
        } else if (a == "--bitrate" && i + 1 < argc) {
            cfg.hostBitrateMbps = atoi(argv[++i]);
        } else if (a == "--host-dpi" && i + 1 < argc) {
            cfg.hostDpi = atoi(argv[++i]);
        } else if (a == "--wait-lock" && i + 1 < argc) {
            cfg.waitLockMs = atoi(argv[++i]);
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
    if (cfg.width <= 0 || cfg.width > 7680) cfg.width = 2880;
    if (cfg.height <= 0 || cfg.height > 4320) cfg.height = 1800;
    if (cfg.hostWidth <= 0 || cfg.hostWidth > 7680) cfg.hostWidth = 2880;
    if (cfg.hostHeight <= 0 || cfg.hostHeight > 4320) cfg.hostHeight = 1800;
    if (cfg.port <= 0 || cfg.port > 65535) cfg.port = 9922;
    if (cfg.hostFps < 24 || cfg.hostFps > 144) cfg.hostFps = 60;
    if (cfg.hostBitrateMbps < 10 || cfg.hostBitrateMbps > 200) cfg.hostBitrateMbps = 50;
    if (cfg.hostDpi != 0 && (cfg.hostDpi < 100 || cfg.hostDpi > 300)) cfg.hostDpi = 0;
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
        else if (key == "mode") {
            std::string mv = val;
            std::transform(mv.begin(), mv.end(), mv.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            cfg.hostMode = (mv == "sender" || mv == "host" || mv == "1");
        } else if (key == "hostwidth") cfg.hostWidth = atoi(val.c_str());
        else if (key == "hostheight") cfg.hostHeight = atoi(val.c_str());
        else if (key == "fps") cfg.hostFps = atoi(val.c_str());
        else if (key == "bitrate") cfg.hostBitrateMbps = atoi(val.c_str());
        else if (key == "hostdpi") cfg.hostDpi = atoi(val.c_str());
        else continue;
        ++applied;
    }
    Log("已读取配置 %s（%d 项）", path.c_str(), applied);
}

static void SaveModeToConfigFile(bool toHostMode) {
    if (!g_useConfigFile) return;
    std::string cfgPath = g_activeCfgPath.empty() ? (ExeDir() + "\\config.ini") : g_activeCfgPath;
    std::vector<std::string> lines;
    bool replaced = false;
    {
        std::ifstream fin(cfgPath);
        if (fin) {
            std::string ln;
            while (std::getline(fin, ln)) {
                std::string t = TrimStr(ln);
                std::string low = t;
                std::transform(low.begin(), low.end(), low.begin(),
                               [](unsigned char c) { return (char)std::tolower(c); });
                if (low.rfind("mode=", 0) == 0 || low.rfind("mode ", 0) == 0) {
                    lines.push_back(toHostMode ? "mode=sender" : "mode=receiver");
                    replaced = true;
                } else {
                    lines.push_back(ln);
                }
            }
        }
    }
    if (!replaced) lines.push_back(toHostMode ? "mode=sender" : "mode=receiver");
    std::ofstream fout(cfgPath, std::ios::trunc);
    if (fout) {
        for (const auto& l : lines) fout << l << "\n";
    }
}

static void LaunchSelfForModeSwitch(bool toHostMode) {
    wchar_t exePath[MAX_PATH] = {};
    GetModuleFileNameW(nullptr, exePath, MAX_PATH);
    std::wstring cmd = L"\"" + std::wstring(exePath) + L"\"";
    for (const auto& a : g_preservedArgs) {
        std::wstring wa = ToWide(a.c_str(), (int)a.size());
        if (wa.find(L' ') != std::wstring::npos || wa.find(L'\t') != std::wstring::npos) {
            cmd += L" \"" + wa + L"\"";
        } else {
            cmd += L" " + wa;
        }
    }
    cmd += L" --mode ";
    cmd += (toHostMode ? L"sender" : L"receiver");
    cmd += L" --wait-lock 3000";

    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end());
    cmdBuf.push_back(L'\0');
    STARTUPINFOW si{}; si.cb = sizeof(si);
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(exePath, cmdBuf.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) {
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    }
}

static void SwitchAppMode(bool toHostMode) {
    if (g_switchRoleRequested.exchange(true)) return;
    g_switchRoleToHost = toHostMode;
    SaveModeToConfigFile(toHostMode);
    Log("角色切换请求: %s，准备重启进程", toHostMode ? "主控模式 (Mac 当副屏)" : "副屏模式 (接收 Mac)");
    RequestQuit();
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
    int scaleTenths = (n >= 7) ? (int)p[6] : 0;
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return;
    const bool sizeOrFpsChanged = (g_sessW.load() != w || g_sessH.load() != h || g_sessFps.load() != fps);
    const bool scaleChanged = (g_sessScaleTenths.load() != scaleTenths);
    if (!sizeOrFpsChanged && !scaleChanged) return;

    g_sessScaleTenths = scaleTenths;
    if (!sizeOrFpsChanged) {
        if (g_hwnd) {
            {
                std::lock_guard<std::mutex> lk(g_cursorImage.mtx);
                if (!g_cursorImage.bgra.empty()) g_cursorImage.pending = true;
            }
            PostMessageA(g_hwnd, WM_APPLY_CURSOR, 0, 0);
        }
        return;
    }

    g_sessW = w; g_sessH = h; g_sessFps = fps;
    // 坐标基准立即跟随会话头，不与 presenter->Resize 成败绑定：
    // 否则 Resize 失败时 g_coordW 停在旧值，会把远程光标压缩进画面左上角。
    if (!g_coordUserSpecified) {
        g_coordW = w;
        g_coordH = h;
    }
    Log("会话头: 协议 v%u  虚拟屏 %dx%d @ %d fps  scale=%.1fx",
        ver, w, h, fps, scaleTenths >= 5 ? (scaleTenths / 10.0) : 0.0);

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
        // 会话头切档：流尺寸变化时原子更新交换链与处理器；全屏模式下交换链保持显示器客户区尺寸不变，
        // 由 VideoProcessorBlt 按 FitRect 等比铺满整屏，不再把交换链缩成小分辨率导致只占左上角。
        int sw = g_sessW.load(), sh = g_sessH.load();
        if (sw > 0 && sh > 0 && (sw != cfg.width || sh != cfg.height) &&
            !(sw == failedW && sh == failedH)) {
            const bool fs = g_isFullscreen.load();
            int outW = sw, outH = sh;
            if (fs && g_hwnd) {
                RECT crc{};
                if (GetClientRect(g_hwnd, &crc) && (crc.right - crc.left) >= 64 && (crc.bottom - crc.top) >= 64) {
                    outW = crc.right - crc.left;
                    outH = crc.bottom - crc.top;
                }
            }
            if (presenter->Configure(outW, outH, sw, sh, sw, sh)) {
                cfg.width = sw; cfg.height = sh;
                g_displayW = sw; g_displayH = sh;
                if (cfg.coordW <= 0) { g_coordW = sw; g_coordH = sh; }
                if (!fs) ResizeWindowForVideo(sw, sh);
                Log("按会话头切换管线尺寸: 流 %dx%d  输出 %dx%d", sw, sh, outW, outH);
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
        if (g_hwnd) PostMessageW(g_hwnd, WM_APP_UPDATE_POWER, 0, 0);
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
        g_connStartTick.store(GetTickCount64());
        ResetTimestampBase();

        // 先发 8 字节接收端握手标识（Mac Sender/Receiver 据此秒级识别角色是否匹配），再请求关键帧
        {
            const uint8_t pktInit[9] = { TYPE_ROLE_HELLO, 'S', 'D', 'R', 'X', 1, 2, 0, TYPE_KEYFRAME_REQUEST };
            bool ok = false;
            {
                std::lock_guard<std::mutex> lk(g_sendMtx);
                ok = SendCtrlAllUnderLock(sock, pktInit, sizeof(pktInit));
            }
            if (ok) Log("已发送接收端握手并请求关键帧（0x7E/0x02）");
        }

        Decoder decoder;
        if (!decoder.Init(gfx, cfg.width, cfg.height)) {
            Log("解码器初始化失败，断开重试");
            if (g_sock.load() == sock) g_sock = INVALID_SOCKET;
            if (g_hwnd) PostMessageW(g_hwnd, WM_APP_UPDATE_POWER, 0, 0);
            closesocket(sock);
            if (!cfg.reconnect) break;
            SleepAlive(2000);
            continue;
        }

        std::atomic<bool> connAlive{ true };
        std::atomic<bool> roleConflictDetected{ false };
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
                const uint8_t* hdr4 = reinterpret_cast<const uint8_t*>(&len);
                if (hdr4[0] == TYPE_ROLE_HELLO && hdr4[1] == 'S' && hdr4[2] == 'D' && hdr4[3] == 'R') {
                    Log("角色冲突: Mac 端当前也是副屏接收模式，已拒绝连接");
                    roleConflictDetected = true;
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
                if (packet[0] == TYPE_KVM_MOUSE) {
                    OnKvmMousePacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_KVM_KEY) {
                    OnKvmKeyPacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_KVM_STATE) {
                    OnKvmStatePacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] == TYPE_ROLE_CONFLICT) {
                    uint8_t reason = (len > HEADER_BYTES) ? packet[HEADER_BYTES] : 0;
                    if (reason == 3) {
                        Log("协议异常: Mac 端检测到控制流越界并主动断开 (0x7F reason=3)");
                    } else {
                        Log("角色冲突: Mac 端当前为 %s，无法与本机副屏模式配对",
                            reason == 2 ? "副屏模式" : "不兼容角色");
                        roleConflictDetected = true;
                    }
                    break;
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
                g_srcP50.store(d50); g_srcP95.store(d95);
                g_presP50.store(p50); g_presP95.store(p95);

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
        g_rxKvmActive = false;
        ReleaseRxKvmInputs();
        latestCv.notify_all();
        present.join();
        watch.join();

        // 断线必须把画面清掉并给出提示。否则 FLIP 交换链会一直显示最后一帧，
        // 用户看到的是几分钟前的旧画面，容易误判成「显示的是别的屏」。
        presenter->ClearToIdle();
        if (g_alive) {
            ShowStatusHint(roleConflictDetected.load()
                ? L"角色冲突: Mac 端也是副屏模式，请将一端切为主控"
                : L"连接已断开，2 秒后重连…");
        }

        decoder.Shutdown();
        if (g_sock.load() == sock) g_sock = INVALID_SOCKET;
        if (g_hwnd) PostMessageW(g_hwnd, WM_APP_UPDATE_POWER, 0, 0);
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
// 雷电双向文件中转站客户端（独立 TCP 端口 port+1 = 9923）
// ---------------------------------------------------------------------------

static bool XferSendAll(SOCKET s, std::mutex& mtx, const uint8_t* data, size_t len) {
    std::lock_guard<std::mutex> lk(mtx);
    size_t sent = 0;
    while (sent < len && g_alive) {
        int r = send(s, (const char*)(data + sent), (int)std::min<size_t>(len - sent, 1 << 20), 0);
        if (r <= 0) return false;
        sent += (size_t)r;
    }
    return sent == len;
}

static bool XferRecvAll(SOCKET s, uint8_t* buf, size_t len) {
    size_t got = 0;
    int idleTimeouts = 0;
    while (got < len && g_alive) {
        int r = recv(s, (char*)(buf + got), (int)std::min<size_t>(len - got, 1 << 20), 0);
        if (r > 0) {
            got += (size_t)r;
            idleTimeouts = 0;
        } else if (r == 0) {
            return false;
        } else {
            int err = WSAGetLastError();
            // Mac 每 15 秒发一次 PING；连续 45 秒无任何数据包视为静默断线（如拔雷电线）
            if (err == WSAETIMEDOUT && ++idleTimeouts < 45) continue;
            return false;
        }
    }
    return got == len;
}

static std::wstring SanitizeFilenameW(const std::string& utf8, uint32_t id) {
    std::wstring w = ToWide(utf8.c_str(), (int)utf8.size());
    size_t pos = w.find_last_of(L"\\/");
    if (pos != std::wstring::npos) w = w.substr(pos + 1);
    std::wstring clean;
    clean.reserve(w.size());
    for (wchar_t c : w) {
        if (c < 0x20 || c == 0x7f || c == L':' || c == L'*' || c == L'?' ||
            c == L'"' || c == L'<' || c == L'>' || c == L'|' || c == L'/' || c == L'\\') {
            continue;
        }
        clean.push_back(c);
    }
    // 去掉 Windows 文件名禁止的末尾空格与句点
    while (!clean.empty() && (clean.back() == L' ' || clean.back() == L'.')) {
        clean.pop_back();
    }
    if (clean.empty() || clean == L"." || clean == L"..") {
        wchar_t fb[32];
        swprintf(fb, 32, L"file_%u", id);
        return fb;
    }
    // 避开 Windows DOS 设备保留名（CON / PRN / AUX / NUL / COM1..9 / LPT1..9）
    size_t dot = clean.find(L'.');
    std::wstring stem = (dot == std::wstring::npos) ? clean : clean.substr(0, dot);
    std::wstring up;
    for (wchar_t c : stem) up.push_back((wchar_t)towupper(c));
    if (up == L"CON" || up == L"PRN" || up == L"AUX" || up == L"NUL" ||
        (up.size() == 4 && (up.compare(0, 3, L"COM") == 0 || up.compare(0, 3, L"LPT") == 0) &&
         up[3] >= L'1' && up[3] <= L'9')) {
        clean = L"_" + clean;
    }
    return clean;
}

static std::wstring UniqueDestPathW(const std::wstring& dir, const std::wstring& name) {
    std::wstring first = dir + L"\\" + name;
    if (GetFileAttributesW(first.c_str()) == INVALID_FILE_ATTRIBUTES) return first;
    size_t dot = name.find_last_of(L'.');
    std::wstring stem = (dot == std::wstring::npos) ? name : name.substr(0, dot);
    std::wstring ext  = (dot == std::wstring::npos) ? L"" : name.substr(dot);
    for (int i = 1; i <= 9999; ++i) {
        wchar_t idx[32];
        swprintf(idx, 32, L" (%d)", i);
        std::wstring cand = dir + L"\\" + stem + idx + ext;
        if (GetFileAttributesW(cand.c_str()) == INVALID_FILE_ATTRIBUTES) return cand;
    }
    wchar_t ts[32];
    swprintf(ts, 32, L"_%llu", (unsigned long long)GetTickCount64());
    return dir + L"\\" + stem + ts + ext;
}

static void TransferLoop(RunConfig cfg) {
    const uint16_t xferPort = (uint16_t)(cfg.port + 1);
    const std::wstring inbox = GetTransferInboxDir();
    Log("中转站线程启动: 目标 %s:%d，目录 %s",
        cfg.host.c_str(), xferPort, ToUtf8(inbox.c_str()).c_str());

    auto putU16 = [](std::vector<uint8_t>& v, uint16_t x) {
        v.push_back((uint8_t)(x >> 8)); v.push_back((uint8_t)(x & 0xFF));
    };
    auto putU32 = [](std::vector<uint8_t>& v, uint32_t x) {
        v.push_back((uint8_t)((x >> 24) & 0xFF)); v.push_back((uint8_t)((x >> 16) & 0xFF));
        v.push_back((uint8_t)((x >> 8) & 0xFF));  v.push_back((uint8_t)(x & 0xFF));
    };
    auto putU64 = [&](std::vector<uint8_t>& v, uint64_t x) {
        putU32(v, (uint32_t)(x >> 32));
        putU32(v, (uint32_t)(x & 0xFFFFFFFFu));
    };
    auto rdU16 = [](const uint8_t* p) -> uint16_t {
        return ((uint16_t)p[0] << 8) | p[1];
    };
    auto rdU32 = [](const uint8_t* p) -> uint32_t {
        return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    };
    auto rdU64 = [&](const uint8_t* p) -> uint64_t {
        return ((uint64_t)rdU32(p) << 32) | rdU32(p + 4);
    };

    while (g_alive) {
        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) { SleepAlive(2000); continue; }

        int bufSz = 4 * 1024 * 1024;
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, (const char*)&bufSz, sizeof(bufSz));
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (const char*)&bufSz, sizeof(bufSz));
        int nodelay = 1, keepalive = 1;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
        setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(xferPort);
        if (inet_pton(AF_INET, cfg.host.c_str(), &addr.sin_addr) != 1) {
            closesocket(sock);
            SleepAlive(3000);
            continue;
        }

        u_long nb = 1;
        ioctlsocket(sock, FIONBIO, &nb);
        connect(sock, (sockaddr*)&addr, sizeof(addr));
        fd_set wfds, efds;
        FD_ZERO(&wfds); FD_ZERO(&efds);
        FD_SET(sock, &wfds); FD_SET(sock, &efds);
        timeval tv{ 2, 0 };
        int sel = select(0, nullptr, &wfds, &efds, &tv);
        int soErr = 0; int soLen = sizeof(soErr);
        getsockopt(sock, SOL_SOCKET, SO_ERROR, (char*)&soErr, &soLen);
        if (sel <= 0 || FD_ISSET(sock, &efds) || soErr != 0) {
            closesocket(sock);
            SleepAlive(2000);
            continue;
        }
        nb = 0;
        ioctlsocket(sock, FIONBIO, &nb);

        DWORD rcvTo = 1000, sndTo = 5000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, (const char*)&rcvTo, sizeof(rcvTo));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sndTo, sizeof(sndTo));

        g_xferSock = sock;
        g_xferConnected = true;
        SetTransferStatus(L"已连接 · 可拖入文件或点击「发送文件到 Mac」");
        Log("中转站已连接 %s:%d", cfg.host.c_str(), xferPort);

        std::atomic<bool> xferAlive{ true };
        std::mutex xferSendMtx;

        std::thread sendThread([&] {
            std::vector<uint8_t> readBuf(262144);
            while (g_alive && xferAlive) {
                XferOutItem item;
                uint32_t tid = 0;
                {
                    std::unique_lock<std::mutex> lk(g_xferMtx);
                    g_xferCv.wait_for(lk, std::chrono::milliseconds(500), [&] {
                        return !g_alive || !xferAlive || !g_xferOutQ.empty();
                    });
                    if (!g_alive || !xferAlive) break;
                    if (g_xferOutQ.empty()) continue;
                    item = g_xferOutQ.front();
                    g_xferOutQ.pop_front();
                    tid = g_xferNextId++;
                    if (g_xferNextId == 0) g_xferNextId = 1;
                }
                if (item.isText) {
                    std::vector<uint8_t> frame;
                    frame.reserve(5 + 4 + item.textUtf8.size());
                    frame.push_back(XFER_TEXT);
                    putU32(frame, (uint32_t)(4 + item.textUtf8.size()));
                    putU32(frame, tid);
                    frame.insert(frame.end(), item.textUtf8.begin(), item.textUtf8.end());
                    SetTransferStatus(L"发送文本: " + item.preview, 0, L"");
                    if (!XferSendAll(sock, xferSendMtx, frame.data(), frame.size())) {
                        if (g_alive) {
                            std::lock_guard<std::mutex> lk(g_xferMtx);
                            g_xferOutQ.push_front(item);
                        }
                        xferAlive = false;
                        break;
                    }
                    SetTransferStatus(L"已发送文本: " + item.preview, -1, L"");
                    SetTransferFeedback(1, L"已发送文本", item.preview);
                    Log("中转站发送文本完成 #%u (%zu B)", tid, item.textUtf8.size());
                    continue;
                }
                const std::wstring& path = item.path;

                HANDLE hf = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                                        nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
                if (hf == INVALID_HANDLE_VALUE) {
                    Log("中转站打开文件失败: %s (%lu)", ToUtf8(path.c_str()).c_str(), GetLastError());
                    SetTransferStatus(L"无法读取所选文件");
                    size_t sl = path.find_last_of(L"\\/");
                    SetTransferFeedback(-1, L"读取失败", (sl == std::wstring::npos) ? path : path.substr(sl + 1));
                    if (item.deleteAfterSend) DeleteFileW(path.c_str());
                    continue;
                }
                LARGE_INTEGER li{};
                if (!GetFileSizeEx(hf, &li)) {
                    CloseHandle(hf);
                    if (item.deleteAfterSend) DeleteFileW(path.c_str());
                    continue;
                }
                uint64_t totalSize = (uint64_t)li.QuadPart;

                size_t slash = path.find_last_of(L"\\/");
                std::wstring baseW = (slash == std::wstring::npos) ? path : path.substr(slash + 1);
                std::string baseU8 = ToUtf8(baseW.c_str());
                if (baseU8.size() > 4096) baseU8.resize(4096);

                std::vector<uint8_t> beginFrame;
                beginFrame.reserve(5 + 14 + baseU8.size());
                beginFrame.push_back(XFER_BEGIN);
                putU32(beginFrame, (uint32_t)(14 + baseU8.size()));
                putU32(beginFrame, tid);
                putU64(beginFrame, totalSize);
                putU16(beginFrame, (uint16_t)baseU8.size());
                beginFrame.insert(beginFrame.end(), baseU8.begin(), baseU8.end());

                SetTransferStatus(L"发送中: " + baseW + L" (0%)", 0, L"0 MB/s");
                Log("中转站开始发送 #%u: %s (%llu B)", tid, baseU8.c_str(), (unsigned long long)totalSize);
                ULONGLONG t0 = GetTickCount64();
                ULONGLONG lastUi = t0;

                if (!XferSendAll(sock, xferSendMtx, beginFrame.data(), beginFrame.size())) {
                    CloseHandle(hf);
                    { std::lock_guard<std::mutex> lk(g_xferMtx); g_xferOutQ.push_front(item); }
                    xferAlive = false;
                    break;
                }

                uint64_t sentTotal = 0;
                bool readErr = false, netErr = false;
                while (g_alive && xferAlive) {
                    DWORD nRead = 0;
                    if (!ReadFile(hf, readBuf.data(), (DWORD)readBuf.size(), &nRead, nullptr)) {
                        readErr = true;
                        break;
                    }
                    if (nRead == 0) break;
                    std::vector<uint8_t> frame;
                    frame.reserve(5 + 8 + nRead);
                    frame.push_back(XFER_CHUNK);
                    putU32(frame, (uint32_t)(8 + nRead));
                    putU32(frame, tid);
                    putU32(frame, (uint32_t)nRead);
                    frame.insert(frame.end(), readBuf.begin(), readBuf.begin() + nRead);
                    if (!XferSendAll(sock, xferSendMtx, frame.data(), frame.size())) {
                        netErr = true;
                        break;
                    }
                    sentTotal += nRead;
                    ULONGLONG now = GetTickCount64();
                    if (now - lastUi >= 200) {
                        lastUi = now;
                        double dt = std::max(0.01, (double)(now - t0) / 1000.0);
                        double speed = (double)sentTotal / dt / 1048576.0;
                        int pct = totalSize > 0 ? (int)((double)sentTotal * 100.0 / (double)totalSize) : 100;
                        wchar_t sb[256], spdb[64];
                        swprintf(sb, 256, L"发送 %s · %d%% · %.0f MB/s", baseW.c_str(), pct, speed);
                        swprintf(spdb, 64, L"%.0f MB/s", speed);
                        SetTransferStatus(sb, pct, spdb);
                    }
                }
                CloseHandle(hf);

                bool complete = !readErr && !netErr && xferAlive && g_alive && (sentTotal == totalSize);
                if (netErr || !xferAlive || !g_alive) {
                    // 连接已断：切勿补发 endFrame 或记发送成功，直接把未传完文件放回队头等重连
                    if (g_alive) {
                        std::lock_guard<std::mutex> lk(g_xferMtx);
                        g_xferOutQ.push_front(item);
                    } else if (item.deleteAfterSend) {
                        DeleteFileW(path.c_str());
                    }
                    xferAlive = false;
                    break;
                }

                std::vector<uint8_t> endFrame;
                endFrame.push_back(XFER_END);
                putU32(endFrame, 5);
                putU32(endFrame, tid);
                endFrame.push_back(complete ? 1 : 0);
                if (!XferSendAll(sock, xferSendMtx, endFrame.data(), endFrame.size())) {
                    if (g_alive) {
                        std::lock_guard<std::mutex> lk(g_xferMtx);
                        g_xferOutQ.push_front(item);
                    } else if (item.deleteAfterSend) {
                        DeleteFileW(path.c_str());
                    }
                    xferAlive = false;
                    break;
                }
                if (item.deleteAfterSend) DeleteFileW(path.c_str());
                if (complete) {
                    double dt = std::max(0.001, (double)(GetTickCount64() - t0) / 1000.0);
                    double speed = (double)sentTotal / dt / 1048576.0;
                    wchar_t sb[256], fbt[64];
                    swprintf(sb, 256, L"已发送: %s (%s · %.0f MB/s)",
                             baseW.c_str(), FormatBytesW(sentTotal).c_str(), speed);
                    swprintf(fbt, 64, L"已发送 · %.0f MB/s", speed);
                    SetTransferStatus(sb, -1, L"");
                    SetTransferFeedback(1, fbt, baseW);
                    Log("中转站发送完成 #%u: %s (%.1f MB/s)", tid, baseU8.c_str(), speed);
                } else {
                    SetTransferStatus(L"发送失败: " + baseW, -1, L"");
                    SetTransferFeedback(-1, L"发送失败", baseW);
                }
            }
        });

        struct RecvState {
            HANDLE hf = INVALID_HANDLE_VALUE;
            std::wstring safeName;
            std::wstring partPath;
            uint64_t expected = 0;
            uint64_t received = 0;
            ULONGLONG started = 0;
            ULONGLONG lastUi = 0;
        };
        std::unordered_map<uint32_t, RecvState> recvs;
        auto sendAck = [&](uint32_t id, bool ok) {
            std::vector<uint8_t> f;
            f.push_back(XFER_ACK);
            putU32(f, 5);
            putU32(f, id);
            f.push_back(ok ? 1 : 0);
            XferSendAll(sock, xferSendMtx, f.data(), f.size());
        };

        std::vector<uint8_t> payload;
        while (g_alive && xferAlive) {
            uint8_t hdr[5];
            if (!XferRecvAll(sock, hdr, 5)) break;
            uint8_t type = hdr[0];
            uint32_t len = rdU32(hdr + 1);
            if (len > 1024 * 1024) { Log("中转站收到异常大帧 %u", len); break; }
            payload.resize(len);
            if (len > 0 && !XferRecvAll(sock, payload.data(), len)) break;

            if (type == XFER_BEGIN && len >= 14) {
                uint32_t id = rdU32(payload.data());
                uint64_t size = rdU64(payload.data() + 4);
                uint16_t nameLen = rdU16(payload.data() + 12);
                if (len < (uint32_t)(14 + nameLen)) continue;
                std::string raw((const char*)(payload.data() + 14), nameLen);
                std::wstring safe = SanitizeFilenameW(raw, id);
                if (recvs.count(id)) {
                    if (recvs[id].hf != INVALID_HANDLE_VALUE) CloseHandle(recvs[id].hf);
                    DeleteFileW(recvs[id].partPath.c_str());
                    recvs.erase(id);
                }
                wchar_t partName[64];
                swprintf(partName, 64, L"\\.secdisplay_tmp_%u.part", id);
                std::wstring partPath = inbox + partName;
                HANDLE hf = CreateFileW(partPath.c_str(), GENERIC_WRITE, 0, nullptr,
                                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                if (hf == INVALID_HANDLE_VALUE) {
                    Log("中转站创建临时文件失败 %lu", GetLastError());
                    sendAck(id, false);
                    continue;
                }
                RecvState st{};
                st.hf = hf; st.safeName = safe; st.partPath = partPath;
                st.expected = size; st.started = GetTickCount64(); st.lastUi = st.started;
                recvs[id] = st;
                SetTransferStatus(L"正在接收: " + safe + L" (0%)", 0, L"0 MB/s");
                Log("中转站开始接收 #%u: %s (%llu B)", id, ToUtf8(safe.c_str()).c_str(), (unsigned long long)size);
            } else if (type == XFER_CHUNK && len >= 8) {
                uint32_t id = rdU32(payload.data());
                uint32_t dlen = rdU32(payload.data() + 4);
                auto it = recvs.find(id);
                // 无溢出检查：用 len - 8 而非 8 + dlen，防止 dlen 接近 0xFFFFFFFF 时回绕越界读
                if (it == recvs.end() || dlen > len - 8) continue;
                DWORD written = 0;
                if (dlen > 0 && (!WriteFile(it->second.hf, payload.data() + 8, dlen, &written, nullptr) || written != dlen)) {
                    std::wstring errName = it->second.safeName;
                    CloseHandle(it->second.hf);
                    DeleteFileW(it->second.partPath.c_str());
                    recvs.erase(it);
                    SetTransferStatus(L"保存失败: " + errName, -1, L"");
                    SetTransferFeedback(-1, L"保存失败", errName);
                    sendAck(id, false);
                    continue;
                }
                it->second.received += dlen;
                ULONGLONG now = GetTickCount64();
                if (now - it->second.lastUi >= 200) {
                    it->second.lastUi = now;
                    double dt = std::max(0.01, (double)(now - it->second.started) / 1000.0);
                    double speed = (double)it->second.received / dt / 1048576.0;
                    int pct = it->second.expected > 0
                        ? (int)((double)it->second.received * 100.0 / (double)it->second.expected) : 100;
                    wchar_t sb[256], spdb[64];
                    swprintf(sb, 256, L"接收 %s · %d%% · %.0f MB/s", it->second.safeName.c_str(), pct, speed);
                    swprintf(spdb, 64, L"%.0f MB/s", speed);
                    SetTransferStatus(sb, pct, spdb);
                }
            } else if (type == XFER_END && len >= 5) {
                uint32_t id = rdU32(payload.data());
                bool okFlag = (payload[4] == 1);
                auto it = recvs.find(id);
                if (it == recvs.end()) continue;
                RecvState st = it->second;
                recvs.erase(it);
                CloseHandle(st.hf);
                if (okFlag && st.received == st.expected) {
                    std::wstring dest = UniqueDestPathW(inbox, st.safeName);
                    if (MoveFileExW(st.partPath.c_str(), dest.c_str(), 0)) {
                        double dt = std::max(0.001, (double)(GetTickCount64() - st.started) / 1000.0);
                        double speed = (double)st.received / dt / 1048576.0;
                        size_t sl = dest.find_last_of(L"\\/");
                        std::wstring finalName = (sl == std::wstring::npos) ? dest : dest.substr(sl + 1);
                        {
                            std::lock_guard<std::mutex> lk(g_xferMtx);
                            g_xferLastRecvPath = dest;
                            g_xferLastRecvName = finalName;
                        }
                        wchar_t sb[256];
                        swprintf(sb, 256, L"已收到: %s (%s · %.0f MB/s)",
                                 finalName.c_str(), FormatBytesW(st.received).c_str(), speed);
                        SetTransferStatus(sb, -1, L"");
                        SetTransferFeedback(1, L"收到文件", finalName);
                        Log("中转站接收完成 #%u: %s (%.1f MB/s)", id, ToUtf8(finalName.c_str()).c_str(), speed);
                        sendAck(id, true);
                    } else {
                        DeleteFileW(st.partPath.c_str());
                        SetTransferStatus(L"保存失败: " + st.safeName);
                        SetTransferFeedback(-1, L"保存失败", st.safeName);
                        sendAck(id, false);
                    }
                } else {
                    DeleteFileW(st.partPath.c_str());
                    SetTransferStatus(L"接收未完成: " + st.safeName);
                    SetTransferFeedback(-1, L"接收中断", st.safeName);
                    sendAck(id, false);
                }
            } else if (type == XFER_TEXT && len >= 4) {
                uint32_t id = rdU32(payload.data());
                if (len == 4) {
                    sendAck(id, false);
                    continue;
                }
                std::wstring wtext = ToWideStrict((const char*)(payload.data() + 4), (int)(len - 4));
                if (wtext.empty()) {
                    Log("中转站收到文本 #%u 解码失败", id);
                    sendAck(id, false);
                    continue;
                }
                std::wstring preview = MakeTextPreviewW(wtext);
                bool posted = false;
                if (g_hwnd && g_alive) {
                    {
                        std::lock_guard<std::mutex> lk(g_clipTextMtx);
                        g_clipTextQ.push_back(PendingClipText{ id, std::move(wtext), preview, (size_t)(len - 4) });
                    }
                    posted = (PostMessageW(g_hwnd, WM_APP_SET_CLIP_TEXT, 0, 0) != FALSE);
                    if (!posted) {
                        std::lock_guard<std::mutex> lk(g_clipTextMtx);
                        if (!g_clipTextQ.empty() && g_clipTextQ.back().id == id) g_clipTextQ.pop_back();
                    }
                }
                sendAck(id, posted);
            } else if (type == XFER_ACK && len >= 5) {
                uint32_t ackId = rdU32(payload.data());
                bool ok = (payload[4] == 1);
                if (!ok) {
                    Log("中转站对端保存失败 #%u", ackId);
                    SetTransferFeedback(-1, L"对端保存失败", L"");
                }
            }
        }

        // 先 shutdown 打破可能阻塞在 send 的 sendThread，再设标志并 join
        g_xferConnected = false;
        if (g_xferSock.load() == sock) g_xferSock = INVALID_SOCKET;
        shutdown(sock, SD_BOTH);
        xferAlive = false;
        g_xferCv.notify_all();
        if (sendThread.joinable()) sendThread.join();
        for (auto& kv : recvs) {
            if (kv.second.hf != INVALID_HANDLE_VALUE) CloseHandle(kv.second.hf);
            DeleteFileW(kv.second.partPath.c_str());
        }
        recvs.clear();

        closesocket(sock);
        SetTransferStatus(L"中转连接断开，2 秒后重连…");
        if (!g_alive) break;
        SleepAlive(2000);
    }
    Log("中转站线程退出");
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

static const char* LidActionName(DWORD v) {
    switch (v) {
    case 0: return "无操作";
    case 1: return "睡眠";
    case 2: return "休眠";
    case 3: return "关机";
    default: return "未知";
    }
}

// 启动时检查当前电源方案合盖动作：若 AC/DC 仍设为睡眠/休眠，合盖用雷电扩展屏可能触发断显或掉电黑屏
static void CheckWindowsLidPowerPolicy() {
    HMODULE hPowr = LoadLibraryA("powrprof.dll");
    if (!hPowr) return;
    typedef DWORD (WINAPI *GetActiveFn)(HKEY, GUID**);
    typedef DWORD (WINAPI *ReadValFn)(HKEY, const GUID*, const GUID*, const GUID*, LPDWORD);
    auto pGetActive = reinterpret_cast<GetActiveFn>(GetProcAddress(hPowr, "PowerGetActiveScheme"));
    auto pReadAC    = reinterpret_cast<ReadValFn>(GetProcAddress(hPowr, "PowerReadACValueIndex"));
    auto pReadDC    = reinterpret_cast<ReadValFn>(GetProcAddress(hPowr, "PowerReadDCValueIndex"));
    if (pGetActive && pReadAC && pReadDC) {
        GUID* activeScheme = nullptr;
        if (pGetActive(nullptr, &activeScheme) == ERROR_SUCCESS && activeScheme) {
            static const GUID kSubButtons = {
                0x4f971e89, 0xeebd, 0x4455, { 0xa8, 0xde, 0x9e, 0x59, 0x04, 0x0e, 0x73, 0x47 }
            };
            static const GUID kLidAction = {
                0x5ca83367, 0x6e45, 0x459f, { 0xa2, 0x7b, 0x47, 0x6b, 0x1d, 0x01, 0xc9, 0x36 }
            };
            DWORD acVal = 0, dcVal = 0;
            bool hasAc = (pReadAC(nullptr, activeScheme, &kSubButtons, &kLidAction, &acVal) == ERROR_SUCCESS);
            bool hasDc = (pReadDC(nullptr, activeScheme, &kSubButtons, &kLidAction, &dcVal) == ERROR_SUCCESS);
            if (hasAc || hasDc) {
                char acBuf[32], dcBuf[32];
                if (hasAc) snprintf(acBuf, sizeof(acBuf), "%s(%lu)", LidActionName(acVal), (unsigned long)acVal);
                else snprintf(acBuf, sizeof(acBuf), "未知");
                if (hasDc) snprintf(dcBuf, sizeof(dcBuf), "%s(%lu)", LidActionName(dcVal), (unsigned long)dcVal);
                else snprintf(dcBuf, sizeof(dcBuf), "未知");
                Log("电源合盖策略: 接通电源=%s  电池=%s", acBuf, dcBuf);
                if ((hasAc && acVal != 0) || (hasDc && dcVal != 0)) {
                    Log("警告: 合盖动作非「无操作」，合盖连接雷电屏可能导致休眠黑屏；"
                        "建议以管理员执行: powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 && "
                        "powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0 && "
                        "powercfg /setactive SCHEME_CURRENT");
                }
            }
            LocalFree(activeScheme);
        }
    }
    FreeLibrary(hPowr);
}

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

// ---------------------------------------------------------------------------
// 光标自检：不依赖 Mac，直接验证晃动曲线、叠加层几何与重采样。
// 用法：SecDisplayReceiver.exe --selftest-cursor
// 结果同时写 stderr 与 %TEMP%\secdisplay-selftest-cursor.log，退出码 0/1。
// 目的：远程（无人值守）环境也能客观确认光标放大链路没有回归。
// ---------------------------------------------------------------------------
static int RunCursorSelfTest() {
    char tmpPath[MAX_PATH] = { 0 };
    if (!GetTempPathA(MAX_PATH, tmpPath)) tmpPath[0] = 0;
    std::string outPath = std::string(tmpPath) + "secdisplay-selftest-cursor.log";
    FILE* out = fopen(outPath.c_str(), "w");
    int fails = 0;
    auto check = [&](bool ok, const char* what) {
        if (!ok) ++fails;
        char line[512];
        snprintf(line, sizeof(line), "[%s] %s", ok ? "PASS" : "FAIL", what);
        printf("%s\n", line);
        fflush(stdout);
        Log("%s", line);
        if (out) { fprintf(out, "%s\n", line); fflush(out); }
    };

    // 1) 合成光标精灵（32x40，完全不透明，便于统计覆盖率）
    const int W = 32, H = 40;
    std::vector<uint8_t> sprite((size_t)W * H * 4, 0);
    for (int y = 0; y < H; ++y) {
        for (int x = 0; x < W; ++x) {
            uint8_t* p = &sprite[((size_t)y * W + x) * 4];
            p[0] = (uint8_t)(x * 8);     // B
            p[1] = (uint8_t)(y * 6);     // G
            p[2] = 200;                  // R
            p[3] = 255;                  // A
        }
    }
    {
        std::lock_guard<std::mutex> lk(g_spriteMtx);
        g_nativeSprite = sprite;
        g_nativeW = W; g_nativeH = H;
        g_nativeHotX = 4; g_nativeHotY = 3;
    }
    g_sessScaleTenths = 20;    // 模拟 2x 会话
    g_steadySpriteK = 1.0;     // 稳态 1:1（100% 显示比例）

    // 2) 叠加层需要一个 owner 窗口
    WNDCLASSA wc{};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "SecDisplaySelfTest";
    if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        printf("[FAIL] 注册自检窗口类失败 err=%lu\n", (unsigned long)GetLastError());
        fflush(stdout);
        if (out) fclose(out);
        return 1;
    }
    g_hwnd = CreateWindowExA(0, "SecDisplaySelfTest", "selftest", WS_OVERLAPPEDWINDOW,
                             0, 0, 800, 600, nullptr, nullptr, wc.hInstance, nullptr);
    check(g_hwnd != nullptr, "创建测试窗口");
    if (!g_hwnd) { if (out) fclose(out); return 1; }

    // 3) 曲线：起势单调不减、峰值有轻微过冲、结束精确回到 1.0
    g_shakeActive = true;
    g_shakePhase = SHAKE_GROW;
    g_shakeAnimFromZoom = 1.0;
    g_shakeAnimStartMs = 1000.0;
    g_shakeLastPointerQpcMs = 1000.0;
    g_shakeZoom = 1.0;
    double prev = 1.0, peak = 1.0;
    bool reversalSeen = false;   // EaseOutBack 允许一次「升过头再回落」
    bool secondReversal = false;
    int dir = 0;
    const int kSteps = 36;
    for (int i = 0; i <= kSteps; ++i) {
        TickShakeAnim(1000.0 + kShakeGrowMs * (double)i / (double)kSteps);
        const double d = g_shakeZoom - prev;
        if (std::abs(d) > 1e-9) {
            const int nd = d > 0 ? 1 : -1;
            if (dir != 0 && nd != dir) { if (reversalSeen) secondReversal = true; reversalSeen = true; }
            dir = nd;
        }
        prev = g_shakeZoom;
        if (g_shakeZoom > peak) peak = g_shakeZoom;
    }
    check(reversalSeen && !secondReversal, "起势只有一次「冲过头再回落」的方向反转");
    check(std::abs(g_shakeZoom - kShakeCursorZoom) < 1e-6, "起势结束停在目标倍数");
    check(peak > kShakeCursorZoom * 1.005 && peak < kShakeCursorZoom * 1.08, "峰值过冲在 0.5%~8% 区间");

    const double tMoveDuringHold = 1000.0 + kShakeGrowMs + kShakeHoldMs - 1.0;
    g_shakeLastPointerQpcMs = tMoveDuringHold;
    const double tHoldExtended = tMoveDuringHold + 1.0;
    TickShakeAnim(tHoldExtended);
    check(g_shakeActive && g_shakePhase == SHAKE_HOLD &&
          std::abs(g_shakeZoom - kShakeCursorZoom) < 1e-6,
          "最后一次晃动满 500ms 后若指针仍有移动，应保持放大");

    const double tAfterHold = tMoveDuringHold + kShakeHoldMs + 1.0;
    TickShakeAnim(tAfterHold);
    check(g_shakeActive && g_shakePhase == SHAKE_SHRINK, "指针停止移动满 500ms 后开始收缩");
    for (int i = 0; i <= 20; ++i) {
        TickShakeAnim(tAfterHold + kShakeShrinkMs * (double)i / 20.0);
    }
    check(!g_shakeActive && std::abs(g_shakeZoom - 1.0) < 1e-6, "回落结束且 zoom 归 1");

    // 4) 几何（纯函数，不依赖会话是否支持分层窗口）
    const ZoomGeometry geo = ComputeZoomGeometry(W, H, 4, 3, 1.0 * 2.2, 512);
    check(geo.dw == 70 && geo.dh == 88, "放大几何：尺寸 = 精灵 * 2.2");
    check(geo.hx == 9 && geo.hy == 7, "放大几何：热点同比缩放");
    const ZoomGeometry capped = ComputeZoomGeometry(200, 200, 10, 10, 10.0, 512);
    check(capped.dw <= 512 && capped.dh <= 512 && capped.dw == 512, "放大几何：不超过 512 上限");

    // 5) 叠加层：真实调用一遍（无崩溃 + 若会话支持则校验窗口几何）
    POINT cur{};
    GetCursorPos(&cur);
    UpdateZoomOverlay(2.2);
    const DWORD overlayErr = GetLastError();   // 立刻取样，后面任何调用都会覆盖它
    if (g_zoomOverlayShown) {
        RECT wr{};
        if (g_zoomOverlay) GetWindowRect(g_zoomOverlay, &wr);
        check(std::abs((wr.right - wr.left) - geo.dw) <= 2 &&
              std::abs((wr.bottom - wr.top) - geo.dh) <= 2, "叠加层窗口尺寸与几何一致");
        check(std::abs(wr.left - (cur.x - geo.hx)) <= 2 &&
              std::abs(wr.top - (cur.y - geo.hy)) <= 2, "叠加层窗口位置与热点对齐");
        check(GetCursor() == HiddenCursorHandle(), "放大帧提交后硬件光标已隐藏，避免双指针");
    } else {
        // SSH / session 0 下 DWM 分层窗不可用，属环境限制，不算失败
        printf("[INFO] 当前会话不支持分层叠加窗，跳过窗口几何校验 (err=%lu)\n",
               (unsigned long)overlayErr);
        fflush(stdout);
        if (out) { fprintf(out, "[INFO] 当前会话不支持分层叠加窗，跳过窗口几何校验 (err=%lu)\n",
                            (unsigned long)overlayErr); fflush(out); }
    }

    // 6) 重采样：输出尺寸与不透明覆盖率
    std::vector<uint8_t> scaled;
    ResampleBgraPremul(sprite.data(), W, H, scaled, geo.dw, geo.dh);
    int opaque = 0;
    for (size_t i = 3; i < scaled.size(); i += 4) if (scaled[i] > 0) ++opaque;
    check(scaled.size() == (size_t)geo.dw * geo.dh * 4 && opaque > 0, "重采样输出尺寸与覆盖正确");

    // 7) 收口：隐藏、以及 zoom<=1.02 不显示
    HideZoomOverlay();
    check(!g_zoomOverlayShown, "叠加层可正确隐藏");
    check(GetCursor() != HiddenCursorHandle(), "叠加层隐藏后恢复硬件光标");
    UpdateZoomOverlay(1.0);
    check(!g_zoomOverlayShown, "zoom<=1.02 不显示叠加层");

    char summary[128];
    snprintf(summary, sizeof(summary), "SELFTEST_%s fails=%d", fails == 0 ? "PASS" : "FAIL", fails);
    printf("%s\n", summary);
    fflush(stdout);
    Log("%s", summary);
    if (out) { fprintf(out, "%s\n", summary); fclose(out); }

    if (g_zoomOverlay && IsWindow(g_zoomOverlay)) DestroyWindow(g_zoomOverlay);
    DestroyWindow(g_hwnd);
    g_hwnd = nullptr;
    return fails == 0 ? 0 : 1;
}

int main(int argc, char** argv) {
    // GUI 子系统下默认无控制台黑框；若用户主动从 cmd/PowerShell 交互运行，则附着父控制台输出日志
    if (GetConsoleWindow() == nullptr) {
        DWORD errType = GetFileType(GetStdHandle(STD_ERROR_HANDLE));
        DWORD outType = GetFileType(GetStdHandle(STD_OUTPUT_HANDLE));
        if (errType == FILE_TYPE_UNKNOWN) {
            if (AttachConsole(ATTACH_PARENT_PROCESS)) {
                if (outType == FILE_TYPE_UNKNOWN) freopen("CONOUT$", "w", stdout);
                freopen("CONOUT$", "w", stderr);
            }
        }
    }
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
    for (int i = 1; i < argc; ++i) {
        if (std::string(argv[i]) == "--selftest-cursor") return RunCursorSelfTest();
    }
    // 免参数启动：先读 exe 同目录 config.ini，再让命令行覆盖。
    // --config 指定别的文件，--no-config 跳过配置文件。
    std::string cfgPath = ExeDir() + "\\config.ini";
    bool useConfigFile = true;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--config" && i + 1 < argc) {
            cfgPath = argv[++i];
            g_preservedArgs.push_back("--config");
            g_preservedArgs.push_back(cfgPath);
        } else if (a == "--no-config") {
            useConfigFile = false;
            g_preservedArgs.push_back(a);
        } else if (a == "--sender" || a == "--host" || a == "--receiver") {
            continue;
        } else if ((a == "--mode" || a == "--wait-lock") && i + 1 < argc) {
            ++i;
            continue;
        } else {
            g_preservedArgs.push_back(a);
        }
    }
    g_activeCfgPath = cfgPath;
    g_useConfigFile = useConfigFile;
    if (useConfigFile) LoadConfigFile(cfg, cfgPath);
    ParseArgs(argc, argv, cfg);

    // 单实例。旧实例被新实例踢掉后收流线程退出、交换链停止 Present，
    // 窗口会永久停在最后一帧，看起来就像「显示的是别的屏」。
    // 这里直接拒绝第二个实例，并把已有窗口提到前台（角色切换重启时短暂等待旧实例释放锁）。
    {
        int waited = 0;
        for (;;) {
            g_instMutex = CreateMutexW(nullptr, TRUE, L"Global\\SecDisplayReceiver");
            if (g_instMutex && GetLastError() != ERROR_ALREADY_EXISTS) break;
            if (g_instMutex) { CloseHandle(g_instMutex); g_instMutex = nullptr; }
            if (waited >= cfg.waitLockMs) {
                HWND existing = FindWindowA("SecDisplayReceiver", nullptr);
                if (existing) { ShowWindow(existing, SW_RESTORE); SetForegroundWindow(existing); }
                if (cfg.waitLockMs > 0) {
                    Log("等待旧实例释放互斥锁超时 (%d ms)，本次启动退出", cfg.waitLockMs);
                } else {
                    Log("已有 SecDisplay 实例在运行，本次启动退出");
                }
                return 0;
            }
            Sleep(50);
            waited += 50;
        }
    }

    if (!cfg.logFile.empty()) {
        // 追加模式，保留历史便于回看崩溃前的日志。
        // 用标准 fopen 而不是 fopen_s：后者是 MSVC 扩展，MinGW 构建会不通过。
        g_logFile = fopen(cfg.logFile.c_str(), "a");
        if (!g_logFile) fprintf(stderr, "无法打开日志文件 %s\n", cfg.logFile.c_str());
    }

    g_hostMode = cfg.hostMode;
    Log(cfg.hostMode ? "================ SecDisplay 主控发送端 (Win→Mac) ================"
                     : "================ SecDisplay 接收端 ================");
    if (cfg.hostMode) {
        Log("模式: 主控发送  端口 %d/%d  虚拟屏 %dx%d@%dHz  码率 %dMbps",
            cfg.port, cfg.port + 1, cfg.hostWidth, cfg.hostHeight, cfg.hostFps, cfg.hostBitrateMbps);
    } else {
        Log("目标 %s:%d  分辨率 %dx%d  %s  重连 %s",
            cfg.host.c_str(), cfg.port, cfg.width, cfg.height,
            cfg.fullscreen ? "全屏" : "窗口",
            cfg.reconnect ? "开" : "关");
    }
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
    {
        Gdiplus::GdiplusStartupInput gsi;
        Gdiplus::GdiplusStartup(&g_gdipToken, &gsi, nullptr);
    }

    WNDCLASSA wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "SecDisplayReceiver";
    wc.hIcon = LoadIconA(wc.hInstance, MAKEINTRESOURCEA(1));
    RegisterClassA(&wc);

    if (cfg.hostMode) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { Log("WSAStartup 失败"); return 5; }

        HWND hwnd = CreateWindowExA(0, "SecDisplayReceiver", "SecDisplay Host",
                                    WS_OVERLAPPED, 0, 0, 1, 1,
                                    nullptr, nullptr, wc.hInstance, nullptr);
        if (!hwnd) { Log("宿主消息窗口创建失败"); return 3; }
        g_hwnd = hwnd;
        g_peerHost = cfg.host;
        g_peerPort = cfg.port;
        g_logPath = cfg.logFile;

        TrayCreate(hwnd);
        RegisterHotKey(hwnd, HOTKEY_QUIT_ID, MOD_CONTROL | MOD_ALT, 'Q');
        RegisterHotKey(hwnd, HOTKEY_DROPBOX_ID, MOD_CONTROL | MOD_ALT, 'B');
        RegisterHotKey(hwnd, HOTKEY_KVM_ID, MOD_CONTROL | MOD_ALT, 'K');
        static const GUID kGuidLidSwitchHost = {
            0xBA3E0F4D, 0xB817, 0x4094, { 0xA2, 0xD1, 0xD5, 0x63, 0x79, 0xE6, 0xA0, 0xF3 }
        };
        HPOWERNOTIFY hPowerLid = RegisterPowerSettingNotification(hwnd, &kGuidLidSwitchHost, DEVICE_NOTIFY_WINDOW_HANDLE);
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED);
        CheckWindowsLidPowerPolicy();

        g_hostReqW = cfg.hostWidth;
        g_hostReqH = cfg.hostHeight;
        g_hostReqFps = cfg.hostFps;
        g_hostReqMbps = cfg.hostBitrateMbps;
        g_hostReqDpi = cfg.hostDpi;

        if (!g_winHost.Start(cfg.host, cfg.hostWidth, cfg.hostHeight, cfg.hostFps, cfg.hostBitrateMbps,
                             (uint16_t)cfg.port, [](const char* s) { Log("%s", s); }, cfg.hostDpi)) {
            Log("警告: 主控发送端启动失败（检查 Parsec VDD 驱动是否就绪）");
        }
        std::thread xfer(TransferLoop, cfg);
        ShowControlPanel();

        MSG msg;
        while (GetMessage(&msg, nullptr, 0, 0)) {
            if (msg.message == WM_KEYDOWN && msg.wParam == 'V' &&
                (GetKeyState(VK_CONTROL) & 0x8000) &&
                !(GetKeyState(VK_MENU) & 0x8000) &&
                !(GetKeyState(VK_SHIFT) & 0x8000)) {
                HWND act = GetActiveWindow();
                HWND hp = g_panel.load();
                HWND db = g_dropBox.load();
                if (act && (act == hp || act == db || (hp && IsChild(hp, act)))) {
                    PasteClipboardToTransfer(act);
                    continue;
                }
            }
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }

        SetThreadExecutionState(ES_CONTINUOUS);
        KillTimer(hwnd, TIMER_RESUME_HOST);
        KillTimer(hwnd, TIMER_SLEEP_WATCHDOG);
        if (hPowerLid) UnregisterPowerSettingNotification(hPowerLid);
        TrayRemove();
        UnregisterHotKey(hwnd, HOTKEY_QUIT_ID);
        UnregisterHotKey(hwnd, HOTKEY_DROPBOX_ID);
        UnregisterHotKey(hwnd, HOTKEY_KVM_ID);
        g_alive = false;
        g_winHost.Stop();
        g_xferCv.notify_all();
        {
            SOCKET xs = g_xferSock.load();
            if (xs != INVALID_SOCKET) shutdown(xs, SD_BOTH);
        }
        if (xfer.joinable()) xfer.join();
        HWND panelToDestroy = g_panel.exchange(nullptr);
        if (panelToDestroy) DestroyWindow(panelToDestroy);
        HWND dbToDestroy = g_dropBox.exchange(nullptr);
        if (dbToDestroy) DestroyWindow(dbToDestroy);
        {
            std::lock_guard<std::mutex> lk(g_xferMtx);
            for (const auto& it : g_xferOutQ) {
                if (it.deleteAfterSend) DeleteFileW(it.path.c_str());
            }
            g_xferOutQ.clear();
        }
        g_theme.ReleaseAll();
        if (g_gdipToken) { Gdiplus::GdiplusShutdown(g_gdipToken); g_gdipToken = 0; }
        WSACleanup();
        MFShutdown();
        CoUninitialize();
        if (g_instMutex) { ReleaseMutex(g_instMutex); CloseHandle(g_instMutex); g_instMutex = nullptr; }

        if (g_switchRoleRequested.load()) {
            LaunchSelfForModeSwitch(g_switchRoleToHost.load());
        }
        Log("主控端退出，进程结束");
        if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
        return 0;
    }

    Graphics gfx;
    if (!gfx.Init(cfg.width, cfg.height)) return 2;
    g_gfx = &gfx;   // 控制面板查询 GPU 显存用

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

    // 注册鼠标 Raw Input，精准识别真实物理鼠标移动（SetCursorPos 不会触发 WM_INPUT）
    {
        RAWINPUTDEVICE rid{};
        rid.usUsagePage = 0x01;
        rid.usUsage     = 0x02;
        rid.dwFlags     = RIDEV_INPUTSINK;
        rid.hwndTarget  = hwnd;
        if (!RegisterRawInputDevices(&rid, 1, sizeof(rid))) {
            Log("警告: RegisterRawInputDevices 失败 %lu", GetLastError());
        }
    }

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
    // Ctrl+Alt+B 一键呼出/隐藏悬浮文件投递盒
    if (!RegisterHotKey(hwnd, HOTKEY_DROPBOX_ID, MOD_CONTROL | MOD_ALT, 'B')) {
        Log("全局热键 Ctrl+Alt+B 注册失败（可能已被占用）");
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

    g_displayW = cfg.width;
    g_displayH = cfg.height;
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
        if (!presenter.Configure(cw, ch, cfg.width, cfg.height, cfg.width, cfg.height)) {
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
    g_coordUserSpecified = (cfg.coordW > 0);
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
            // 按键/滚轮事件按顺序逐条发，绝不合并。
            for (;;) {
                InputEvent e;
                {
                    std::lock_guard<std::mutex> lk(g_inputQmtx);
                    if (g_inputQ.empty()) break;
                    e = g_inputQ.front();
                    g_inputQ.pop_front();
                }
                SendInputPacket(e.x, e.y, e.buttons, e.wheel);
                lastMoveMs = GetTickCount64();
                g_moveDirty = false;   // 事件包已带最新位置
            }
            // 键盘事件按顺序逐条发
            for (;;) {
                KeyEvent k;
                {
                    std::lock_guard<std::mutex> lk(g_keyQmtx);
                    if (g_keyQ.empty()) break;
                    k = g_keyQ.front();
                    g_keyQ.pop_front();
                }
                SendKeyPacket(k.vk, k.scan, k.down, k.flags);
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
    std::thread xfer(TransferLoop, cfg);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        // 控制面板或悬浮投递盒处于激活态时，拦截纯 Ctrl+V 一键发送剪贴板截图/文件
        if (msg.message == WM_KEYDOWN && msg.wParam == 'V' &&
            (GetKeyState(VK_CONTROL) & 0x8000) &&
            !(GetKeyState(VK_MENU) & 0x8000) &&
            !(GetKeyState(VK_SHIFT) & 0x8000)) {
            HWND act = GetActiveWindow();
            HWND hp = g_panel.load();
            HWND db = g_dropBox.load();
            if (act && (act == hp || act == db || (hp && IsChild(hp, act)))) {
                PasteClipboardToTransfer(act);
                continue;
            }
        }
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    // 退出清理：先停网络/中转/输入线程，再毁控制面板窗口，消除跨线程访问 g_panel 竞态
    SetThreadExecutionState(ES_CONTINUOUS);
    SetShakeTimePeriod(false);
    g_presenter = nullptr;
    TrayRemove();
    UnregisterHotKey(hwnd, HOTKEY_QUIT_ID);
    UnregisterHotKey(hwnd, HOTKEY_HIDE_ID);
    UnregisterHotKey(hwnd, HOTKEY_DROPBOX_ID);
    if (g_customCursor && !IsInCursorCache(g_customCursor)) {
        DestroyCursor(g_customCursor);
    }
    g_customCursor = nullptr;
    for (int i = 0; i < kCursorCacheCap; ++i) {
        if (g_cursorCache[i].cur) {
            DestroyCursor(g_cursorCache[i].cur);
            g_cursorCache[i].cur = nullptr;
        }
    }
    if (g_hintFont)  { DeleteObject(g_hintFont);  g_hintFont = nullptr; }
    if (g_hintBrush) { DeleteObject(g_hintBrush); g_hintBrush = nullptr; }
    if (g_hintHwnd)  { DestroyWindow(g_hintHwnd); g_hintHwnd = nullptr; }
    g_alive = false;
    g_xferCv.notify_all();
    {
        SOCKET xs = g_xferSock.load();
        if (xs != INVALID_SOCKET) shutdown(xs, SD_BOTH);
    }
    {
        SOCKET s = g_sock.load();
        if (s != INVALID_SOCKET) shutdown(s, SD_BOTH);
    }
    if (net.joinable()) net.join();
    if (xfer.joinable()) xfer.join();
    if (inputThread.joinable()) inputThread.join();
    HWND panelToDestroy = g_panel.exchange(nullptr);
    if (panelToDestroy) { DestroyWindow(panelToDestroy); }
    HWND dbToDestroy = g_dropBox.exchange(nullptr);
    if (dbToDestroy) { DestroyWindow(dbToDestroy); }
    {
        std::lock_guard<std::mutex> lk(g_xferMtx);
        for (const auto& it : g_xferOutQ) {
            if (it.deleteAfterSend) DeleteFileW(it.path.c_str());
        }
        g_xferOutQ.clear();
    }
    g_theme.ReleaseAll();
    if (g_gdipToken) {
        Gdiplus::GdiplusShutdown(g_gdipToken);
        g_gdipToken = 0;
    }

    WSACleanup();
    presenter.Shutdown();
    gfx.Shutdown();
    MFShutdown();
    CoUninitialize();
    if (g_instMutex) { ReleaseMutex(g_instMutex); CloseHandle(g_instMutex); g_instMutex = nullptr; }

    if (g_switchRoleRequested.load()) {
        LaunchSelfForModeSwitch(g_switchRoleToHost.load());
    }

    Log("主循环退出，进程结束");
    if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
    return 0;
}
