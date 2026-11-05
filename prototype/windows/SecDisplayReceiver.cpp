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
#include <windows.h>
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
#include <vector>
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
}

static uint64_t NowMicros() {
    static LARGE_INTEGER freq = {};
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return (uint64_t)(c.QuadPart * 1000000ULL / freq.QuadPart);
}

// ---------------------------------------------------------------------------
// 协议常量（必须与 Mac 端一致）
//   帧: [4 字节大端 长度][1 字节 类型][8 字节大端 采集时间戳 us][载荷]
//   长度字段 = 1 + 8 + 载荷长度（不含长度字段自身）
// ---------------------------------------------------------------------------

static const uint8_t TYPE_VIDEO = 0x01;
static const uint8_t TYPE_KEYFRAME_REQUEST = 0x02;
static const size_t HEADER_BYTES = 9;   // 类型 1 + 时间戳 8
static const size_t MAX_PACKET = 64u * 1024u * 1024u;

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
// 只用于算相对延迟，这里换算成与本地 QPC 可比的相对时钟。
static uint64_t ConvertMacTimestamp(uint64_t macMicros) {
    // CFAbsoluteTime 纪元 = Unix 纪元 + 978307200 秒
    static uint64_t offsetUs = 0;
    static bool init = false;
    if (!init) {
        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        uint64_t nowUnixUs = (((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime) / 10ULL;
        // 用第一帧建立偏移：本地时刻 - 远端时刻
        offsetUs = NowMicros() - (macMicros - 978307200ULL * 1000000ULL);
        init = true;
    }
    return macMicros + offsetUs;
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

bool Graphics::CreateDevice() {
    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;

    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                   levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                   &device, nullptr, &context);
    if (FAILED(hr)) {
        // 11_1 在某些环境不可用，退回 11_0
        D3D_FEATURE_LEVEL lv[] = { D3D_FEATURE_LEVEL_11_0 };
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                               lv, ARRAYSIZE(lv), D3D11_SDK_VERSION,
                               &device, nullptr, &context);
    }
    if (FAILED(hr)) { Log("D3D11CreateDevice 失败 %08X", hr); return false; }

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

    // 优先硬件 MFT
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                           &inInfo, nullptr, &acts, &count);
    bool hardware = SUCCEEDED(hr) && count > 0;

    if (!hardware) {
        Log("未找到硬件 H.264 解码器，回退软件解码");
        hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                       &inInfo, nullptr, &acts, &count);
    }
    if (FAILED(hr) || count == 0) { Log("MFTEnumEx 失败 %08X", hr); return false; }

    hr = acts[0]->ActivateObject(IID_PPV_ARGS(&transform_));
    for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
    CoTaskMemFree(acts);
    if (FAILED(hr)) { Log("激活解码器失败 %08X", hr); return false; }

    // 低延迟：不缓冲、不解码后等待
    ComPtr<IMFAttributes> attrs;
    if (SUCCEEDED(transform_->GetAttributes(&attrs)) && attrs) {
        // 硬件 MFT 默认是异步模式，不解除锁定的话 ProcessInput/ProcessOutput 不工作，
        // 表现为永远无输出、黑屏。
        attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
        attrs->SetUINT32(MF_LOW_LATENCY, TRUE);
        attrs->SetUINT32(MF_SA_DISABLE_THINNING, TRUE);
    }

    // 硬件解码：注入 D3D 管理器
    if (hardware && gfx_ && gfx_->deviceManager) {
        hr = transform_->ProcessMessage(MFT_MESSAGE_SET_D3D11_MANAGER,
                                        (ULONG_PTR)gfx_->deviceManager.Get());
        if (FAILED(hr)) Log("设置 D3D11 管理器失败 %08X（将走系统内存路径）", hr);
    }

    DWORD inId = 0, outId = 0;
    transform_->GetStreamIDs(1, &inId, 1, &outId);
    outId_ = outId;

    transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

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
    Log("已注入 SPS(%zu) PPS(%zu)", sps.size(), pps.size());
    return true;
}

bool Decoder::SetOutputTypeD3D() {
    ComPtr<IMFMediaType> out;
    HRESULT hr = MFCreateMediaType(&out);
    if (FAILED(hr)) return false;
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(out.Get(), MF_MT_FRAME_SIZE, width_, height_);
    out->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);

    hr = transform_->SetOutputType(0, out.Get(), 0);
    if (FAILED(hr)) {
        Log("SetOutputType(NV12) 失败 %08X", hr);
        return false;
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
            ComPtr<IMFAttributes> at;
            allocator_->GetAttributes(&at);
            at->SetUINT32(MF_SA_DISABLE_THINNING, TRUE);      // 预分配，避免每帧分配
            at->SetUINT32(MF_SA_MINIMUM_OUTPUT_SAMPLE_COUNT, 4);
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
                transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
                transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
                ready_ = false;
            }
        }
    }
    if (!ready_) {
        if (!SetOutputTypeD3D()) return false;
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

private:
    Graphics* gfx_ = nullptr;
    ComPtr<IDXGISwapChain1> swap_;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoCtx_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11VideoProcessorEnumerator> enum_;
    int width_ = 0, height_ = 0;
    bool tearing_ = false;
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
    Log("免垂直同步呈现: %s", tearing_ ? "支持" : "不支持（将按垂直同步呈现）");

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

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = width;
    cd.InputHeight = height;
    cd.OutputWidth = width;
    cd.OutputHeight = height;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;

    hr = videoDevice_->CreateVideoProcessorEnumerator(&cd, &enum_);
    if (FAILED(hr)) { Log("视频处理器枚举失败 %08X", hr); return false; }
    hr = videoDevice_->CreateVideoProcessor(enum_.Get(), 0, &processor_);
    if (FAILED(hr)) { Log("视频处理器创建失败 %08X", hr); return false; }
    videoCtx_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0,
                                                  D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);

    Log("呈现器就绪");
    return true;
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
        td.Width = width_;
        td.Height = height_;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_NV12;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_DECODER;
        ComPtr<ID3D11Texture2D> tex;
        if (FAILED(gfx_->device->CreateTexture2D(&td, nullptr, &tex))) { twoD->Unlock2D(); return; }

        D3D11_BOX box{ 0, 0, 0, (UINT)width_, (UINT)height_, 1 };
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
    if (FAILED(videoDevice_->CreateVideoProcessorInputView(inputTex.Get(), enum_.Get(),
                                                           &ivd, &inView))) return;

    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;

    ComPtr<ID3D11VideoProcessorOutputView> outView;
    if (FAILED(videoDevice_->CreateVideoProcessorOutputView(backTex.Get(), enum_.Get(),
                                                            &ovd, &outView))) return;

    D3D11_VIDEO_PROCESSOR_STREAM stream{};
    stream.Enable = TRUE;
    stream.pInputSurface = inView.Get();
    if (FAILED(videoCtx_->VideoProcessorBlt(processor_.Get(), outView.Get(), 0, 1, &stream))) return;

    // 关键：免垂直同步 + 允许撕裂，尽快上屏
    UINT presentFlags = tearing_ ? DXGI_PRESENT_ALLOW_TEARING : 0;
    HRESULT hr = swap_->Present(0, presentFlags);
    if (FAILED(hr) && tearing_) {
        // tearing 失败就降级
        tearing_ = false;
        swap_->Present(1, 0);
    }
    g_stats.presented++;
}

void Presenter::Shutdown() {
    processor_.Reset();
    enum_.Reset();
    videoCtx_.Reset();
    videoDevice_.Reset();
    swap_.Reset();
}

// ---------------------------------------------------------------------------
// 窗口
// ---------------------------------------------------------------------------

static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(h, m, w, l);
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

int main(int argc, char** argv) {
    const char* host = argc > 1 ? argv[1] : "192.168.77.1";
    int port = argc > 2 ? atoi(argv[2]) : 9922;
    int width = argc > 3 ? atoi(argv[3]) : 2560;
    int height = argc > 4 ? atoi(argv[4]) : 1600;

    setvbuf(stderr, nullptr, _IONBF, 0);

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
    if (!gfx.Init(width, height)) return 2;

    WNDCLASSA wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "SecDisplayReceiver";
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                                "SecDisplayReceiver", "SecDisplay",
                                WS_POPUP | WS_VISIBLE,
                                0, 0,
                                GetSystemMetrics(SM_CXSCREEN),
                                GetSystemMetrics(SM_CYSCREEN),
                                nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) { Log("窗口创建失败"); return 3; }

    Presenter presenter;
    if (!presenter.Init(&gfx, hwnd, width, height)) return 4;

    Decoder decoder;
    if (!decoder.Init(&gfx, width, height)) return 5;

    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { Log("WSAStartup 失败"); return 6; }

    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) { Log("socket 失败"); return 6; }

    int nodelay = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (const char*)&rcvbuf, sizeof(rcvbuf));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        Log("IP 地址无效: %s", host);
        return 6;
    }

    Log("连接 %s:%d ...", host, port);
    if (connect(sock, (sockaddr*)&addr, sizeof(addr)) != 0) {
        Log("连接失败 %d", WSAGetLastError());
        return 7;
    }
    Log("已连接，目标 %dx%d", width, height);

    std::atomic<bool> running{ true };
    std::vector<uint8_t> packet;

    std::thread recvThread([&] {
        while (running) {
            uint32_t len = 0;
            if (!RecvAll(sock, &len, 4)) break;
            len = ntohl(len);
            if (len < HEADER_BYTES || len > MAX_PACKET) {
                Log("包长度异常 %u，断开", len);
                break;
            }

            packet.resize(len);
            if (!RecvAll(sock, packet.data(), (int)len)) break;

            uint8_t type = packet[0];
            if (type != TYPE_VIDEO) continue;   // 目前只收视频帧

            uint64_t ts = 0;
            for (int i = 0; i < 8; ++i) ts = (ts << 8) | packet[1 + i];

            g_stats.packets++;
            g_stats.bytes += len;

            IMFSample* smp = nullptr;
            if (decoder.Decode(packet.data() + HEADER_BYTES, len - HEADER_BYTES, &smp) && smp) {
                g_stats.decoded++;
                uint64_t localTs = ConvertMacTimestamp(ts);
                uint64_t now = NowMicros();
                if (now > localTs) g_stats.lastLatencyUs = now - localTs;
                presenter.PresentSample(smp);
                smp->Release();
            }
        }
        running = false;
    });

    std::thread statThread([&] {
        uint64_t lastBytes = 0, lastDecoded = 0;
        while (running) {
            for (int i = 0; i < 20 && running; ++i) Sleep(100);
            if (!running) break;
            uint64_t b = g_stats.bytes, d = g_stats.decoded;
            double mbps = (b - lastBytes) * 8 / 2.0 / 1e6;
            Log("包 %llu  解码 %llu(+%llu)  %.1f Mbps  延迟 %.1f ms  解码失败 %llu",
                (unsigned long long)g_stats.packets,
                (unsigned long long)d,
                (unsigned long long)(d - lastDecoded),
                mbps,
                g_stats.lastLatencyUs / 1000.0,
                (unsigned long long)g_stats.decodeFail);
            lastBytes = b;
            lastDecoded = d;
        }
    });

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    running = false;
    shutdown(sock, SD_BOTH);
    if (recvThread.joinable()) recvThread.join();
    if (statThread.joinable()) statThread.join();

    closesocket(sock);
    WSACleanup();
    decoder.Shutdown();
    presenter.Shutdown();
    gfx.Shutdown();
    MFShutdown();
    CoUninitialize();
    return 0;
}
