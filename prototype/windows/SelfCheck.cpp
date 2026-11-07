// ============================================================================
// SelfCheck —— 环境自检
//
// Windows 端跑接收端之前先跑这个，确认：
//   - 显卡与硬件解码能力
//   - D3D11 视频处理器是否可用
//   - Media Foundation 编码/解码器清单
//   - 网络连通性与往返延迟
//   - 屏幕分辨率与刷新率
//
// 编译:
//   cl /EHsc /std:c++17 /O2 SelfCheck.cpp /link ole32.lib user32.lib
// 运行:
//   SelfCheck.exe [Mac的IP]
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
#include <mferror.h>
#include <wrl/client.h>
#include <cstdio>
#include <vector>
#include <string>
#include <cwctype>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dxguid.lib")   // D3D11_DECODER_PROFILE_* 这些 GUID 实现在这里
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")

using Microsoft::WRL::ComPtr;

static int g_fail = 0;
static int g_warn = 0;

static void OK(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  [OK]   "); vprintf(fmt, ap); printf("\n");
    va_end(ap);
}
static void WARN(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  [注意] "); vprintf(fmt, ap); printf("\n");
    va_end(ap);
    g_warn++;
}
static void FAIL(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt);
    printf("  [失败] "); vprintf(fmt, ap); printf("\n");
    va_end(ap);
    g_fail++;
}

// ---------------------------------------------------------------------------

static void CheckOS() {
    printf("\n=== 1. 系统 ===\n");
    OSVERSIONINFOEXW vi{};
    vi.dwOSVersionInfoSize = sizeof(vi);
#pragma warning(push)
#pragma warning(disable:4996)
    GetVersionExW((OSVERSIONINFOW*)&vi);
#pragma warning(pop)
    OK("Windows %lu.%lu build %lu", vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
    if (vi.dwBuildNumber < 19041) {
        WARN("版本较旧，Media Foundation 部分接口可能不可用");
    }
    SYSTEM_INFO si{};
    GetNativeSystemInfo(&si);
    if (si.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64) OK("架构 x64");
    else if (si.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_ARM64) OK("架构 ARM64");
    else WARN("架构 %u，未重点验证", si.wProcessorArchitecture);
}

static void CheckGPU() {
    printf("\n=== 2. 显卡与硬件解码 ===\n");
    IDXGIFactory1* fac = nullptr;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&fac)))) { FAIL("DXGI 工厂创建失败"); return; }

    IDXGIAdapter1* ad = nullptr;
    for (UINT i = 0; fac->EnumAdapters1(i, &ad) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        ad->GetDesc1(&desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) { ad->Release(); ad = nullptr; continue; }

        wprintf(L"  显卡 %u: %s\n", i, desc.Description);
        printf("         显存 %.1f GB，厂商 %04X", desc.DedicatedVideoMemory / 1073741824.0, desc.VendorId);

        // 标出虚拟显示器适配器，这类通常不能做视频解码
        {
            std::wstring n(desc.Description);
            for (auto& c : n) c = towlower(c);
            bool virt = n.find(L"virtual") != std::wstring::npos
                     || n.find(L"duet") != std::wstring::npos
                     || n.find(L"gameviewer") != std::wstring::npos
                     || n.find(L"parsec") != std::wstring::npos
                     || n.find(L"sunlogin") != std::wstring::npos;
            if (virt) printf("  [虚拟显示器适配器，通常无解码能力]");
        }
        printf("\n");

        D3D_FEATURE_LEVEL lv = D3D_FEATURE_LEVEL_11_0;
        ComPtr<ID3D11Device> dev;
        HRESULT hr = D3D11CreateDevice(ad, D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                       D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                       &lv, 1, D3D11_SDK_VERSION,
                                       &dev, nullptr, nullptr);
        if (FAILED(hr)) {
            WARN("  D3D11 设备创建失败 %08X（可能旧版 Win7 平台更新缺失）", hr);
            ad->Release(); ad = nullptr;
            continue;
        }
        OK("  D3D11 特性等级 %x.%x", (lv >> 12) & 0xF, (lv >> 8) & 0xF);

        // 硬件解码 profile
        ComPtr<ID3D11VideoDevice> vd;
        if (SUCCEEDED(dev.As(&vd))) {
            UINT n = vd->GetVideoDecoderProfileCount();
            bool h264 = false;
            for (UINT k = 0; k < n; ++k) {
                GUID g{};
                if (SUCCEEDED(vd->GetVideoDecoderProfile(k, &g))) {
                    // 注：D3D11_DECODER_PROFILE_H264_VLD_JPEG / _1080P 这两个名字
                    // 在 Windows SDK 里并不存在，只有 NOFGT / FGT 是真实定义的 profile。
                    if (g == D3D11_DECODER_PROFILE_H264_VLD_NOFGT ||
                        g == D3D11_DECODER_PROFILE_H264_VLD_FGT) {
                        h264 = true;
                    }
                }
            }
            if (h264) OK("  支持 H.264 硬件解码（%u 个 profile）", n);
            else FAIL("  不支持 H.264 硬件解码，将退化为软件解码");
        } else {
            FAIL("  无法获取 ID3D11VideoDevice");
        }

        // 视频处理器（NV12 -> BGRA 转换要用）
        ComPtr<ID3D11VideoDevice> vd2;
        if (SUCCEEDED(dev.As(&vd2))) {
            D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
            cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
            cd.InputWidth = 2240; cd.InputHeight = 1400;
            cd.OutputWidth = 2240; cd.OutputHeight = 1400;
            cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
            ComPtr<ID3D11VideoProcessorEnumerator> en;
            if (SUCCEEDED(vd2->CreateVideoProcessorEnumerator(&cd, &en))) {
                OK("  D3D11 视频处理器可用");
            } else {
                FAIL("  视频处理器不可用，画面无法呈现");
            }
        }

        ComPtr<IDXGIDevice> dxdev;
        dev.As(&dxdev);
        ComPtr<IDXGIAdapter> parent;
        dxdev->GetAdapter(&parent);
        ComPtr<IDXGIFactory5> f5;
        if (SUCCEEDED(parent->GetParent(IID_PPV_ARGS(&f5)))) {
            BOOL allow = FALSE;
            if (SUCCEEDED(f5->CheckFeatureSupport(DXGI_FEATURE_PRESENT_ALLOW_TEARING,
                                                  &allow, sizeof(allow)))) {
                if (allow) OK("  支持免垂直同步呈现（可省约 16ms）");
                else WARN("  不支持免垂直同步，延迟会多一帧");
            }
        }
        ad->Release(); ad = nullptr;
    }
    fac->Release();
}

static void CheckMF() {
    printf("\n=== 3. Media Foundation 编解码器 ===\n");
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) { FAIL("MFStartup 失败"); return; }

    MFT_REGISTER_TYPE_INFO in{ MFMediaType_Video, MFVideoFormat_H264 };

    // 硬件解码器
    IMFActivate** acts = nullptr;
    UINT32 cnt = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                           MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                           &in, nullptr, &acts, &cnt);
    if (SUCCEEDED(hr) && cnt > 0) {
        OK("找到 %u 个硬件 H.264 解码器", cnt);
        for (UINT32 i = 0; i < cnt && i < 3; ++i) {
            LPWSTR name = nullptr;
            UINT32 len = 0;
            if (SUCCEEDED(acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &len))) {
                wprintf(L"         %s\n", name);
                CoTaskMemFree(name);
            }
            acts[i]->Release();
        }
    } else {
        FAIL("没有硬件 H.264 解码器");
    }
    if (acts) CoTaskMemFree(acts);

    // 软件解码器
    acts = nullptr; cnt = 0;
    hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER,
                   MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                   &in, nullptr, &acts, &cnt);
    if (SUCCEEDED(hr) && cnt > 0) OK("找到 %u 个软件 H.264 解码器（兜底路径）", cnt);
    else WARN("没有软件解码器兜底");
    if (acts) { for (UINT32 i = 0; i < cnt; ++i) acts[i]->Release(); CoTaskMemFree(acts); }

    MFShutdown();
}

static void CheckDisplay() {
    printf("\n=== 4. 屏幕 ===\n");
    DEVMODEW dm{};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm)) {
        OK("当前分辨率 %lux%lu @ %luHz，色深 %lu 位",
           dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency, dm.dmBitsPerPel);
        printf("         缩放比例建议与 Mac 端 logicalWidth/Height 对应\n");
        printf("         你要在 Mac 端配置: width=%lu height=%lu\n",
               dm.dmPelsWidth, dm.dmPelsHeight);
    } else {
        FAIL("无法读取屏幕设置");
    }
    printf("         物理尺寸 %lux%lu mm\n", GetSystemMetrics(SM_CXSCREEN),
           GetSystemMetrics(SM_CYSCREEN));
}

static void CheckNetwork(const char* host) {
    printf("\n=== 5. 网络 ===\n");
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) { FAIL("WSAStartup 失败"); return; }

    // 列出活动网卡
    char hostname[256] = {};
    gethostname(hostname, sizeof(hostname));
    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_INET;
    if (getaddrinfo(hostname, nullptr, &hints, &res) == 0) {
        for (auto p = res; p; p = p->ai_next) {
            sockaddr_in* a = (sockaddr_in*)p->ai_addr;
            char ip[64] = {};
            inet_ntop(AF_INET, &a->sin_addr, ip, sizeof(ip));
            if (strcmp(ip, "127.0.0.1") == 0) continue;
            OK("本机地址 %s", ip);
            printf("         在 Mac 端应连这个地址\n");
        }
        freeaddrinfo(res);
    }

    if (!host) {
        printf("\n  未指定 Mac 的 IP，跳过连通性测试\n");
        printf("  用法: SelfCheck.exe <Mac的IP>\n");
        WSACleanup();
        return;
    }

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    inet_pton(AF_INET, host, &addr.sin_addr);

    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    int okCount = 0;
    double totalMs = 0, maxMs = 0;
    const int PORT = 9922;

    for (int i = 0; i < 5; ++i) {
        SOCKET c = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        addr.sin_port = htons(PORT);
        QueryPerformanceCounter(&t0);
        int r = connect(c, (sockaddr*)&addr, sizeof(addr));
        QueryPerformanceCounter(&t1);
        if (r == 0) {
            double ms = (t1.QuadPart - t0.QuadPart) * 1000.0 / f.QuadPart;
            totalMs += ms;
            if (ms > maxMs) maxMs = ms;
            okCount++;
        }
        closesocket(c);
    }

    if (okCount == 0) {
        FAIL("连不上 %s:%d", host, PORT);
        printf("         检查：Mac 端发送端是否已启动？防火墙？IP 是否正确？\n");
    } else {
        OK("TCP 连接成功率 %d/5，平均建连 %.2f ms", okCount, totalMs / okCount);
        if (maxMs > 5) WARN("建连最慢 %.2f ms，网络抖动偏大", maxMs);
        printf("         注意：建连耗时包含握手，真实传输延迟通常更低\n");
    }
    closesocket(s);
    WSACleanup();
}

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("SecDisplay 环境自检\n");
    printf("===================\n");

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    CheckOS();
    CheckGPU();
    CheckMF();
    CheckDisplay();
    CheckNetwork(argc > 1 ? argv[1] : nullptr);

    printf("\n=== 结论 ===\n");
    if (g_fail == 0 && g_warn == 0) {
        printf("  全部通过，可以运行接收端。\n");
    } else {
        printf("  %d 项失败，%d 项需注意。\n", g_fail, g_warn);
        if (g_fail > 0) {
            printf("  有失败项时接收端很可能无法正常出画，请先解决。\n");
        }
    }
    CoUninitialize();
    return g_fail == 0 ? 0 : 1;
}
