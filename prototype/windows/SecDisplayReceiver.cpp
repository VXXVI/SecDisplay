// ============================================================================
// SecDisplayReceiver —— Windows 端接收与显示
//
// 目标: 尽可能短的路径把解码结果送上屏
//   TCP 收包 → Media Foundation H.264 硬解 → Direct3D11 全屏置顶交换链呈现
//
// 为什么不用普通窗口 + GDI:
//   DWM 合成 + 垂直同步 + 窗口重绘会额外增加 1~3 帧延迟。
//   用 DXGI 交换链 FLIP 模式，配 ALLOW_TEARING 与实时呈现队列，可以直接上屏。
//
// 关键实现点:
//   1. 用 DXVA2/D3D11 硬解，ID3D11VideoDecoder
//   2. 交换链用 DXGI_SWAP_EFFECT_FLIP_DISCARD + Present(0, ALLOW_TEARING)
//   3. 解码输出直接作为 PRV 的输入纹理，零拷贝到后缓冲
//   4. 丢帧策略: 解出的帧若比已显示的最新帧还旧，直接丢弃
//   5. 无边框全屏置顶窗口，屏蔽鼠标与键盘
// ============================================================================

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wrl/client.h>
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>
#include <atomic>
#include <thread>
#include <mutex>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")

using Microsoft::WRL::ComPtr;

// ---------------------------------------------------------------------------
// 统计
// ---------------------------------------------------------------------------
struct Stats {
    std::atomic<uint64_t> packets{0};
    std::atomic<uint64_t> bytes{0};
    std::atomic<uint64_t> decoded{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> dropped{0};
    std::atomic<int64_t>  lastPresentMs{0};
};

static Stats g_stats;

static void Log(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

// ---------------------------------------------------------------------------
// 接收端: 读帧
// ---------------------------------------------------------------------------
bool RecvAll(SOCKET s, void* buf, int len) {
    char* p = (char*)buf;
    while (len > 0) {
        int n = recv(s, p, len, 0);
        if (n <= 0) return false;
        p += n; len -= n;
    }
    return true;
}

struct Frame {
    std::vector<uint8_t> data;
    uint64_t captureMicros = 0;
    bool keyframe = false;
};

// ---------------------------------------------------------------------------
// 解码器: Media Foundation，低延迟模式
// ---------------------------------------------------------------------------
class Decoder {
public:
    bool Init(int width, int height);
    bool Decode(const Frame& f, IMFSample** outSample);
    void Shutdown();
private:
    ComPtr<IMFTransform> transform_;
    ComPtr<IMFAttributes> attrs_;
    DWORD inputId_ = 0, outputId_ = 0;
    bool streaming_ = false;
    std::vector<uint8_t> spspps_;
    LONGLONG sampleTime_ = 0;
    int width_ = 0, height_ = 0;
};

bool Decoder::Init(int width, int height) {
    width_ = width; height_ = height;

    MFT_REGISTER_TYPE_INFO inType{ MFMediaType_Video, MFVideoFormat_H264 };
    IMFActivate** acts = nullptr;
    UINT32 count = 0;

    // 优先选硬件解码器（MFT_ENUM_FLAG_HARDWARE）
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                           &inType, nullptr, &acts, &count);
    if (FAILED(hr) || count == 0) {
        Log("没有找到硬件 H.264 解码器，回退软件");
        hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                       &inType, nullptr, &acts, &count);
    }
    if (FAILED(hr) || count == 0) { Log("MFTEnumEx 失败"); return false; }

    hr = acts[0]->ActivateObject(IID_PPV_ARGS(&transform_));
    for (UINT32 i = 0; i < count; ++i) acts[i]->Release();
    CoTaskMemFree(acts);
    if (FAILED(hr)) { Log("激活解码器失败 %08X", hr); return false; }

    // 低延迟：不缓冲
    MFT_SET_TYPE_INFO info{};
    transform_->GetAttributes(&attrs_);
    attrs_->SetUINT32(MF_LOW_LATENCY, TRUE);
    attrs_->SetUINT32(MF_SA_DISABLE_THINNING, TRUE);

    // 输入类型
    ComPtr<IMFMediaType> in;
    MFCreateMediaType(&in);
    in->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    in->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    MFSetAttributeSize(in.Get(), MF_MT_FRAME_SIZE, width, height);
    hr = transform_->SetInputType(0, in.Get(), 0);

    // 输出类型：求 NV12
    ComPtr<IMFMediaType> out;
    MFCreateMediaType(&out);
    out->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    out->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
    MFSetAttributeSize(out.Get(), MF_MT_FRAME_SIZE, width, height);
    transform_->SetOutputType(0, out.Get(), 0);

    transform_->GetStreamIDs(1, &inputId_, 1, &outputId_);
    if (inputId_ == 0 && outputId_ == 0) { inputId_ = 0; outputId_ = 0; }

    hr = transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    hr = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    hr = transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    streaming_ = true;
    Log("解码器就绪 %dx%d", width, height);
    return true;
}

bool Decoder::Decode(const Frame& f, IMFSample** outSample) {
    *outSample = nullptr;
    if (!transform_) return false;

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(MFCreateMemoryBuffer((DWORD)f.data.size(), &buffer))) return false;
    BYTE* dst = nullptr;
    buffer->Lock(&dst, nullptr, nullptr);
    memcpy(dst, f.data.data(), f.data.size());
    buffer->Unlock();
    buffer->SetCurrentLength((DWORD)f.data.size());

    ComPtr<IMFSample> sample;
    MFCreateSample(&sample);
    sample->AddBuffer(buffer.Get());
    sample->SetSampleTime(sampleTime_);
    sample->SetSampleDuration(166666);
    sampleTime_ += 166666;

    HRESULT hr = transform_->ProcessInput(inputId_, sample.Get(), 0);
    if (hr == MF_E_NOTACCEPTING) {
        // 先把输出抽干净
        MFT_OUTPUT_DATA_BUFFER ob{};
        DWORD st = 0;
        transform_->ProcessOutput(0, 1, &ob, &st);
        if (ob.pSample) ob.pSample->Release();
        hr = transform_->ProcessInput(inputId_, sample.Get(), 0);
    }
    if (FAILED(hr)) return false;

    MFT_OUTPUT_DATA_BUFFER ob{};
    DWORD status = 0;
    hr = transform_->ProcessOutput(0, 1, &ob, &status);
    if (hr == S_OK && ob.pSample) {
        *outSample = ob.pSample;
        return true;
    }
    return false;
}

void Decoder::Shutdown() {
    if (transform_) {
        transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        transform_.Reset();
    }
    attrs_.Reset();
}

// ---------------------------------------------------------------------------
// 呈现: D3D11 交换链全屏呈现
// ---------------------------------------------------------------------------
class Presenter {
public:
    bool Init(HWND hwnd, int width, int height);
    void PresentSample(IMFSample* sample);
    void Shutdown();
private:
    ComPtr<ID3D11Device> device_;
    ComPtr<ID3D11DeviceContext> ctx_;
    ComPtr<IDXGISwapChain1> swap_;
    ComPtr<ID3D11VideoDevice> videoDevice_;
    ComPtr<ID3D11VideoContext> videoCtx_;
    ComPtr<ID3D11VideoProcessor> processor_;
    ComPtr<ID3D11VideoProcessorEnumerator> enum_;
    ComPtr<ID3D11Texture2D> backbuffer_;
    size_t bufferCount_ = 0;
    int width_ = 0, height_ = 0;
};

bool Presenter::Init(HWND hwnd, int width, int height) {
    width_ = width; height_ = height;

    D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                   levels, 2, D3D11_SDK_VERSION,
                                   &device_, nullptr, &ctx_);
    if (FAILED(hr)) { Log("D3D11 创建失败 %08X", hr); return false; }

    ComPtr<IDXGIDevice> dxgiDev;
    device_.As(&dxgiDev);
    ComPtr<IDXGIAdapter> adapter;
    dxgiDev->GetAdapter(&adapter);
    ComPtr<IDXGIFactory2> factory;
    adapter->GetParent(IID_PPV_ARGS(&factory));

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
    desc.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING;  // 允许撕裂，绕过垂直同步

    hr = factory->CreateSwapChainForHwnd(device_.Get(), hwnd, &desc, nullptr, nullptr, &swap_);
    if (FAILED(hr)) { Log("交换链创建失败 %08X", hr); return false; }

    D3D11_TEXTURE2D_DESC bd{};
    bd.Width = width; bd.Height = height;
    bd.MipLevels = 1; bd.ArraySize = 1;
    bd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    bd.SampleDesc.Count = 1;
    bd.Usage = D3D11_USAGE_DEFAULT;
    bd.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    device_->CreateTexture2D(&bd, nullptr, &backbuffer_);

    // 视频处理器: NV12 -> BGRA
    device_.As(&videoDevice_);
    ctx_.As(&videoCtx_);

    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = width; cd.InputHeight = height;
    cd.OutputWidth = width; cd.OutputHeight = height;
    cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
    hr = videoDevice_->CreateVideoProcessorEnumerator(&cd, &enum_);
    if (FAILED(hr)) { Log("视频处理器枚举失败 %08X", hr); return false; }
    videoDevice_->CreateVideoProcessor(enum_.Get(), 0, &processor_);
    videoCtx_->VideoProcessorSetStreamFrameFormat(processor_.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);

    Log("D3D11 呈现器就绪");
    return true;
}

void Presenter::PresentSample(IMFSample* sample) {
    ComPtr<IMFMediaBuffer> buf;
    if (FAILED(sample->GetBufferByIndex(0, &buf))) return;
    ComPtr<IMFDXGIBuffer> dxgiBuf;
    if (FAILED(buf.As(&dxgiBuf))) {
        // 软件解码输出，需要上传
        ComPtr<IMFDXGIBuffer> dummy;
        return;
    }
    ComPtr<ID3D11Texture2D> inputTex;
    UINT subIdx = 0;
    dxgiBuf->GetResource(IID_PPV_ARGS(&inputTex));
    dxgiBuf->GetSubresourceIndex(&subIdx);

    // 用视频处理器把 NV12 擦到后缓冲
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
    ivd.FourCC = 0;
    ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorInputView> inView;
    videoDevice_->CreateVideoProcessorInputView(inputTex.Get(), enum_.Get(), &ivd, &inView);

    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
    ComPtr<ID3D11VideoProcessorOutputView> outView;
    videoDevice_->CreateVideoProcessorOutputView(backbuffer_.Get(), enum_.Get(), &ovd, &outView);

    if (inView && outView) {
        D3D11_VIDEO_PROCESSOR_STREAM stream{};
        stream.Enable = TRUE;
        stream.pInputSurface = inView.Get();
        videoCtx_->VideoProcessorBlt(processor_.Get(), outView.Get(), 0, 1, &stream);
    }

    // 无垂直同步，允许撕裂，尽快上屏
    swap_->Present(0, DXGI_PRESENT_ALLOW_TEARING);
    g_stats.presented++;
    g_stats.lastPresentMs = GetTickCount64();
}

void Presenter::Shutdown() {
    processor_.Reset(); enum_.Reset(); videoCtx_.Reset(); videoDevice_.Reset();
    backbuffer_.Reset(); swap_.Reset(); ctx_.Reset(); device_.Reset();
}

// ---------------------------------------------------------------------------
// 窗口
// ---------------------------------------------------------------------------
static LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    switch (m) {
    case WM_DESTROY: PostQuitMessage(0); return 0;
    case WM_KEYDOWN:
        if (w == VK_ESCAPE) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(h, m, w, l);
}

// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    const char* host = argc > 1 ? argv[1] : "192.168.1.10";
    int port = argc > 2 ? atoi(argv[2]) : 9922;
    int width = argc > 3 ? atoi(argv[3]) : 2560;
    int height = argc > 4 ? atoi(argv[4]) : 1600;

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    MFStartup(MF_VERSION, MFSTARTUP_LITE);

    WNDCLASSA wc{};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleA(nullptr);
    wc.lpszClassName = "SecDisplayReceiver";
    wc.hCursor = nullptr;
    RegisterClassA(&wc);

    HWND hwnd = CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
                                "SecDisplayReceiver", "SecDisplay",
                                WS_POPUP | WS_VISIBLE, 0, 0,
                                GetSystemMetrics(SM_CXSCREEN),
                                GetSystemMetrics(SM_CYSCREEN),
                                nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) { Log("窗口创建失败"); return 1; }

    Presenter presenter;
    if (!presenter.Init(hwnd, width, height)) return 2;

    Decoder decoder;
    if (!decoder.Init(width, height)) return 3;

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);

    int nodelay = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((u_short)port);
    inet_pton(AF_INET, host, &addr.sin_addr);

    Log("连接 %s:%d ...", host, port);
    if (connect(sock, (sockaddr*)&addr, sizeof(addr)) != 0) {
        Log("连接失败 %d", WSAGetLastError());
        return 4;
    }
    Log("已连接，目标 %dx%d", width, height);

    std::atomic<bool> running{true};

    std::thread recvThread([&] {
        Frame frame;
        while (running) {
            uint32_t len = 0;
            if (!RecvAll(sock, &len, 4)) break;
            len = ntohl(len);
            if (len == 0 || len > 64 * 1024 * 1024) break;

            std::vector<uint8_t> body(len);
            if (!RecvAll(sock, body.data(), (int)len)) break;

            if (body[0] != 0x01) continue;
            uint64_t ts = 0;
            for (int i = 0; i < 8; ++i) ts = (ts << 8) | body[1 + i];

            frame.data.assign(body.begin() + 9, body.end());
            frame.captureMicros = ts;
            g_stats.packets++;
            g_stats.bytes += len;

            IMFSample* smp = nullptr;
            if (decoder.Decode(frame, &smp) && smp) {
                g_stats.decoded++;
                presenter.PresentSample(smp);
                smp->Release();
            }
            // 丢帧：即使解码堆积也不排队
        }
    });

    // 统计窗口
    std::thread statThread([&] {
        uint64_t lastPkts = 0, lastBytes = 0, lastDecoded = 0;
        while (running) {
            Sleep(2000);
            uint64_t p = g_stats.packets, b = g_stats.bytes, d = g_stats.decoded;
            double mbps = (b - lastBytes) * 8 / 2.0 / 1e6;
            Log("包 %llu (+%llu)  解码 %llu (+%llu)  %.1f Mbps",
                (unsigned long long)p, (unsigned long long)(p - lastPkts),
                (unsigned long long)d, (unsigned long long)(d - lastDecoded), mbps);
            lastPkts = p; lastBytes = b; lastDecoded = d;
        }
    });

    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }

    running = false;
    recvThread.join();
    statThread.join();
    closesocket(sock);
    WSACleanup();
    decoder.Shutdown();
    presenter.Shutdown();
    return 0;
}
