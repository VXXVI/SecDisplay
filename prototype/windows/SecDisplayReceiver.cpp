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
#include <string>
#include <vector>
#include <unordered_map>
#include <atomic>
#include <thread>
#include <mutex>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

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
    std::atomic<uint64_t> decodeFail{0};
    std::atomic<uint64_t> lastLatencyUs{0};
};

static Stats g_stats;

// 复用预分配缓冲，避免每帧分配
static char g_logBuf[1024];
static std::mutex g_logLock;
static FILE* g_logFile = nullptr;   // 可选：同时写日志文件，方便后台监控时 tail

static void Log(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::lock_guard<std::mutex> lk(g_logLock);
    int n = vsnprintf(g_logBuf, sizeof(g_logBuf) - 2, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n > (int)sizeof(g_logBuf) - 2) n = (int)sizeof(g_logBuf) - 2;
    g_logBuf[n] = '\n';
    fwrite(g_logBuf, 1, n + 1, stderr);
    fflush(stderr);
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

static std::atomic<int> g_videoW{0};
static std::atomic<int> g_videoH{0};
static std::atomic<double> g_cursorX{-1};
static std::atomic<double> g_cursorY{-1};

// 输入回传：把窗口内的鼠标位置和按键状态发给 Mac，由它重放事件。
// 不再用 SetCursorPos 搬本机光标——那会和用户自己的鼠标抢位置，
// 表现就是「点这里，菜单出现在别处」。
static std::atomic<SOCKET> g_sock{ INVALID_SOCKET };
static std::atomic<uint8_t> g_buttons{ 0 };
static std::atomic<int64_t> g_lastLocalInputMs{ 0 };

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
}

/// 窗口客户区坐标 → 视频像素坐标（0..videoW, 0..videoH）
static bool ClientToVideo(int cx, int cy, float* vx, float* vy) {
    if (!g_hwnd) return false;
    RECT rc{};
    if (!GetClientRect(g_hwnd, &rc)) return false;
    int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
    int vw = g_videoW.load(), vh = g_videoH.load();
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
    if (!visible) return;

    g_cursorX = rx;
    g_cursorY = ry;

    int vw = g_videoW.load(), vh = g_videoH.load();
    if (vw <= 0 || vh <= 0) return;
}

// ---------------------------------------------------------------------------
// 网络
// ---------------------------------------------------------------------------

static bool RecvAll(SOCKET s, void* buf, int len) {
    char* p = (char*)buf;
    while (len > 0) {
        int n = recv(s, p, len, 0);
        if (n <= 0) return false;
        p += n;
        len -= n;
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
    // 只拦截明显无效的输入（早于 2001-01-01 的 Unix 纪元微秒），
    // 避免无符号下溢。两端时钟未同步，delta 允许为负，靠窗口最小值归一。
    if (macMicros < 978307200ULL * 1000000ULL) return -1;
    const int64_t macUnixUs = (int64_t)(macMicros - 978307200ULL * 1000000ULL);
    const int64_t now = UnixNowMicros();
    const int64_t delta = now - macUnixUs;

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

    // 多线程保护：解码线程与呈现线程共享同一台设备
    ComPtr<ID3D11Multithread> mt;
    if (SUCCEEDED(device.As(&mt)) && mt) {
        if (!mt->SetMultithreadProtected(TRUE)) {
            Log("警告: 多线程保护未启用，共享设备可能有竞争");
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

    if (srcW_ != width_ || srcH_ != height_) {
        // 硬解输出比显示区高（例如 1808 vs 1800），只取左上角可见部分，避免被纵向压缩
        RECT src{ 0, 0, width_, height_ };
        videoCtx_->VideoProcessorSetStreamSourceRect(processor_.Get(), 0, TRUE, &src);
        Log("呈现器: 输入 %dx%d，只取 %dx%d", srcW_, srcH_, width_, height_);
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
static HWND g_hwnd = nullptr;
static bool g_isFullscreen = false;
static LONG_PTR g_savedStyle = 0;
static RECT g_savedRect{};

/// 在当前所在的显示器上铺满。配合 per-monitor DPI 感知，
/// 窗口客户区就是显示器的物理像素，交换链 1:1 不做缩放。
static void EnterFullscreen() {
    if (!g_hwnd || g_isFullscreen) return;
    g_savedStyle = GetWindowLongPtr(g_hwnd, GWL_STYLE);
    GetWindowRect(g_hwnd, &g_savedRect);

    HMONITOR mon = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfo(mon, &mi)) return;

    SetWindowLongPtr(g_hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);
    SetWindowPos(g_hwnd, HWND_TOP,
                 mi.rcMonitor.left, mi.rcMonitor.top,
                 mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    g_isFullscreen = true;
    Log("已切换到全屏");
}

static void ExitFullscreen() {
    if (!g_hwnd || !g_isFullscreen) return;
    SetWindowLongPtr(g_hwnd, GWL_STYLE, g_savedStyle);
    SetWindowPos(g_hwnd, nullptr,
                 g_savedRect.left, g_savedRect.top,
                 g_savedRect.right - g_savedRect.left,
                 g_savedRect.bottom - g_savedRect.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    g_isFullscreen = false;
    Log("已切换到窗口");
}

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) { PostQuitMessage(0); return 0; }
        // F11 或 F 切换全屏，方便窗口模式下按一下变全屏
        if (w == VK_F11 || w == 'F') {
            if (g_isFullscreen) ExitFullscreen(); else EnterFullscreen();
            return 0;
        }
        return 0;
    case WM_MOUSEMOVE: {
        float vx, vy;
        if (ClientToVideo(GET_X_LPARAM(l), GET_Y_LPARAM(l), &vx, &vy)) {
            g_lastLocalInputMs = GetTickCount64();
            SendInputPacket(vx, vy, g_buttons.load(), 0);
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
            SendInputPacket(vx, vy, b, 0);
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
            SendInputPacket(vx, vy, g_buttons.load(), (int16_t)(-delta));
        }
        return 0;
    }
    case WM_SETCURSOR:
        // 保持光标可见，不要被全屏窗口自动隐藏
        SetCursor(LoadCursor(nullptr, IDC_ARROW));
        return TRUE;
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
    int width = 2880;
    int height = 1800;
    bool fullscreen = true;   // 默认全屏铺满；--windowed 改成窗口
    bool reconnect = true;    // 断线自动重连
    bool vsync = true;        // true=垂直同步（画面均匀），false=免同步（延迟最低但可能抖）
    std::string logFile;      // 非空则同时写日志文件
};

static std::atomic<bool> g_alive{ true };

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
        } else if ((a == "--log" || a == "-l") && i + 1 < argc) {
            cfg.logFile = argv[++i];
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

        // 复位统计，重连后从头计数
        g_stats.packets = 0; g_stats.bytes = 0; g_stats.decoded = 0;
        g_stats.presented = 0; g_stats.dropped = 0; g_stats.decodeFail = 0;
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

        // 收流线程
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
                    OnCursorPacket(packet.data() + HEADER_BYTES, len - HEADER_BYTES);
                    continue;
                }
                if (packet[0] != TYPE_VIDEO) continue;

                uint64_t ts = 0;
                for (int i = 0; i < 8; ++i) ts = (ts << 8) | packet[1 + i];

                g_stats.packets++;
                g_stats.bytes += len;

                IMFSample* smp = nullptr;
                if (decoder.Decode(packet.data() + HEADER_BYTES, len - HEADER_BYTES, &smp) && smp) {
                g_stats.decoded++;
                // 解码器实际输出可能比显示尺寸高（硬解按宏块对齐），
                // 同步给呈现器，由它按显示尺寸裁边
                presenter->SetSourceSize(decoder.outWidth(), decoder.outHeight());
                int64_t extra = EstimateExtraDelayUs(ts);
                    if (extra >= 0) g_stats.lastLatencyUs = (uint64_t)extra;
                    presenter->PresentSample(smp);
                    smp->Release();
                }
            }
            connAlive = false;
        });

        // 监控线程：打印状态；长时间无新帧就补请求关键帧
        std::thread watch([&] {
            uint64_t lastBytes = 0, lastDecoded = 0;
            int stallRounds = 0;
            while (g_alive && connAlive) {
                for (int i = 0; i < 20 && g_alive && connAlive; ++i) Sleep(100);
                if (!g_alive || !connAlive) break;

                uint64_t b = g_stats.bytes, d = g_stats.decoded;
                double mbps = (b - lastBytes) * 8 / 2.0 / 1e6;
                Log("包 %llu  解码 %llu(+%llu)  %.1f Mbps  附加延迟 %.1f ms  解码失败 %llu",
                    (unsigned long long)g_stats.packets,
                    (unsigned long long)d,
                    (unsigned long long)(d - lastDecoded),
                    mbps,
                    g_stats.lastLatencyUs / 1000.0,
                    (unsigned long long)g_stats.decodeFail);

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

        hwnd = CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                               "SecDisplayReceiver", "SecDisplay",
                               WS_POPUP | WS_VISIBLE,
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
        AdjustWindowRect(&rc, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, FALSE);
        int winW = rc.right - rc.left;
        int winH = rc.bottom - rc.top;
        hwnd = CreateWindowExA(0, "SecDisplayReceiver", "SecDisplay - 按 Esc 退出",
                               WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
                               (sw - winW) / 2, (sh - winH) / 2,
                               winW, winH,
                               nullptr, nullptr, wc.hInstance, nullptr);
    }
    if (!hwnd) { Log("窗口创建失败"); return 3; }
    g_hwnd = hwnd;

    if (cfg.fullscreen) {
        // 再强制设一次位置和尺寸。某些情况下窗口创建时给的尺寸会被系统按 DPI 修正，
        // 这里用绝对定位兜底，确保铺满显示器。
        RECT wr{};
        GetWindowRect(hwnd, &wr);
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0,
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

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { Log("WSAStartup 失败"); return 5; }

    g_videoW = cfg.width;
    g_videoH = cfg.height;

    // 光标应用线程：把收到的归一化坐标映射到窗口客户区，直接移动系统光标。
    // Windows 的光标由硬件合成，不受视频帧率影响，所以指针是跟手的。
    std::thread cursorThread([] {
        POINT lastPt{ INT_MIN, INT_MIN };
        while (g_alive) {
            Sleep(4);   // ~250Hz 轮询，实际只在新位置到达时调用 SetCursorPos
            // 本机鼠标最近 1 秒内动过，就以用户的鼠标为准，不要抢位置。
            // 否则会出现「点这里、菜单弹在别处」。
            if (GetTickCount64() - (uint64_t)g_lastLocalInputMs.load() < 1000) continue;

            double cx = g_cursorX.load(), cy = g_cursorY.load();
            if (cx < 0 || cy < 0) continue;
            int vw = g_videoW.load(), vh = g_videoH.load();
            if (vw <= 0 || vh <= 0 || !g_hwnd) continue;

            RECT rc{};
            if (!GetClientRect(g_hwnd, &rc)) continue;
            int cw = rc.right - rc.left, ch = rc.bottom - rc.top;
            if (cw <= 0 || ch <= 0) continue;

            POINT tl{ rc.left, rc.top };
            ClientToScreen(g_hwnd, &tl);
            int sx = tl.x + (int)(cx / vw * cw);
            int sy = tl.y + (int)(cy / vh * ch);
            if (sx == lastPt.x && sy == lastPt.y) continue;
            lastPt.x = sx; lastPt.y = sy;
            SetCursorPos(sx, sy);
        }
    });

    std::thread net(NetworkLoop, cfg, &gfx, &presenter);

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    g_alive = false;
    if (net.joinable()) net.join();
    if (cursorThread.joinable()) cursorThread.join();

    WSACleanup();
    presenter.Shutdown();
    gfx.Shutdown();
    MFShutdown();
    CoUninitialize();

    if (g_logFile) { fclose(g_logFile); g_logFile = nullptr; }
    return 0;
}
