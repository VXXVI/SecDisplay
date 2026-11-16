#pragma once
// ============================================================================
// WinVdd.hpp —— Windows 虚拟扩展屏管理（基于 Parsec VDD IddCx 驱动）
//
// 职责：
//   1. 检查 Parsec Virtual Display Adapter (Root\Parsec\VDA) 驱动状态
//   2. 写入自定义分辨率到 HKLM\SOFTWARE\Parsec\vdd（支持 3024x1964 等 Mac 屏比例）
//   3. 通过 DeviceIoControl 添加/保持/卸载虚拟显示器，后台线程 80ms 保活
//      （进程崩溃或退出约 1 秒后驱动自动拔出虚拟屏，避免孤儿残留）
//   4. 自动解除镜像并切到扩展桌面（SetDisplayConfig SDC_TOPOLOGY_EXTEND），
//      将虚拟屏置于主屏右侧并应用目标分辨率与刷新率
//   5. 解析虚拟屏对应的 GDI 设备名（\\.\DISPLAYx）、虚拟桌面矩形与 DXGI 输出
// ============================================================================

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef _MSC_VER
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "cfgmgr32.lib")
#pragma comment(lib, "advapi32.lib")
#endif

namespace secdisplay {

struct WinVddBounds {
    int left = 0;
    int top = 0;
    int width = 0;
    int height = 0;
    int hz = 60;
    std::wstring deviceName;   // e.g. L"\\\\.\\DISPLAY15"
};

class WinVirtualDisplay {
public:
    using LogFn = std::function<void(const char*)>;

    WinVirtualDisplay() = default;
    ~WinVirtualDisplay() { Stop(); }

    WinVirtualDisplay(const WinVirtualDisplay&) = delete;
    WinVirtualDisplay& operator=(const WinVirtualDisplay&) = delete;

    // 检查 Parsec VDD 是否已安装且可用（0=OK，非0为未安装或需重启等）
    static int QueryDriverStatus(std::string* outDesc = nullptr) {
        static const GUID kClassGuid = {
            0x4d36e968, 0xe325, 0x11ce, { 0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18 }
        };
        const char* kHwId = "Root\\Parsec\\VDA";

        HDEVINFO devInfo = SetupDiGetClassDevsA(&kClassGuid, nullptr, nullptr, DIGCF_PRESENT);
        if (devInfo == INVALID_HANDLE_VALUE) {
            if (outDesc) *outDesc = "SetupDiGetClassDevs 失败";
            return -1;
        }

        int result = -2;
        SP_DEVINFO_DATA devData{};
        devData.cbSize = sizeof(devData);
        for (DWORD idx = 0; SetupDiEnumDeviceInfo(devInfo, idx, &devData); ++idx) {
            DWORD req = 0, regType = 0;
            SetupDiGetDeviceRegistryPropertyA(devInfo, &devData, SPDRP_HARDWAREID, nullptr, nullptr, 0, &req);
            if (req == 0) continue;
            std::vector<char> buf(req + 2, 0);
            if (!SetupDiGetDeviceRegistryPropertyA(devInfo, &devData, SPDRP_HARDWAREID, &regType,
                                                   (PBYTE)buf.data(), req, &req)) {
                continue;
            }
            bool matched = false;
            for (const char* p = buf.data(); p < buf.data() + req && *p; p += strlen(p) + 1) {
                if (_stricmp(p, kHwId) == 0) { matched = true; break; }
            }
            if (!matched) continue;

            ULONG status = 0, problem = 0;
            if (CM_Get_DevNode_Status(&status, &problem, devData.DevInst, 0) != CR_SUCCESS) {
                if (outDesc) *outDesc = "无法读取设备节点状态";
                result = -3;
                break;
            }
            if ((status & DN_STARTED) && !(status & DN_HAS_PROBLEM)) {
                if (outDesc) *outDesc = "Parsec VDD 就绪";
                result = 0;
            } else if (status & DN_HAS_PROBLEM) {
                if (outDesc) *outDesc = "Parsec VDD 设备异常 code=" + std::to_string(problem);
                result = (int)problem;
            } else {
                if (outDesc) *outDesc = "Parsec VDD 状态未知";
                result = -4;
            }
            break;
        }
        SetupDiDestroyDeviceInfoList(devInfo);
        if (result == -2 && outDesc) *outDesc = "未安装 Parsec Virtual Display Adapter";
        return result;
    }

    // 写入自定义分辨率到 HKLM\SOFTWARE\Parsec\vdd\0（供 3024x1964 等非内置模式使用）
    static bool EnsureCustomResolution(int w, int h, int hz) {
        if (w <= 0 || h <= 0 || hz <= 0) return false;
        HKEY hKey = nullptr;
        LSTATUS st = RegCreateKeyExW(
            HKEY_LOCAL_MACHINE, L"SOFTWARE\\Parsec\\vdd\\0", 0, nullptr,
            REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &hKey, nullptr);
        if (st != ERROR_SUCCESS) return false;
        DWORD dw = (DWORD)w, dh = (DWORD)h, dhz = (DWORD)hz;
        LSTATUS r1 = RegSetValueExW(hKey, L"width",  0, REG_DWORD, (const BYTE*)&dw,  sizeof(dw));
        LSTATUS r2 = RegSetValueExW(hKey, L"height", 0, REG_DWORD, (const BYTE*)&dh,  sizeof(dh));
        LSTATUS r3 = RegSetValueExW(hKey, L"hz",     0, REG_DWORD, (const BYTE*)&dhz, sizeof(dhz));
        RegCloseKey(hKey);
        return r1 == ERROR_SUCCESS && r2 == ERROR_SUCCESS && r3 == ERROR_SUCCESS;
    }

    bool Start(int width, int height, int hz, LogFn logFn = nullptr, int targetDpiPercent = 0) {
        Stop();
        logFn_ = std::move(logFn);

        if (width <= 0) width = 2880;
        if (height <= 0) height = 1800;
        if (hz <= 0) hz = 60;

        // 对非内置常见尺寸写自定义模式槽位 0（需要在 AddDisplay 前写入）
        if (!EnsureCustomResolution(width, height, hz)) {
            EmitLog("WinVDD: 写入 HKLM\\SOFTWARE\\Parsec\\vdd\\0 失败（需管理员权限），自定义分辨率可能回落");
        }

        handle_ = OpenVddDevice();
        if (handle_ == INVALID_HANDLE_VALUE || handle_ == nullptr) {
            handle_ = INVALID_HANDLE_VALUE;
            std::string drvDesc;
            int st = QueryDriverStatus(&drvDesc);
            char msg[224];
            snprintf(msg, sizeof(msg), "WinVDD: 打开 Parsec VDD 设备句柄失败 (status=%d: %s)", st, drvDesc.c_str());
            EmitLog(msg);
            return false;
        }

        DWORD ver = IoControl(kIoctlVersion, nullptr, 0);
        if (ver == (DWORD)-1) {
            EmitLog("WinVDD: 读取驱动版本失败");
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
            return false;
        }
        {
            char msg[128];
            snprintf(msg, sizeof(msg), "WinVDD: 驱动已打开 version=0.%lu", ver);
            EmitLog(msg);
        }

        // 先启动 80ms 保活线程，避免刚建屏超过 1s 被 watchdog 回收
        keepAliveRun_.store(true);
        keepAliveThread_ = std::thread([this]() {
            while (keepAliveRun_.load()) {
                HANDLE h = handle_;
                if (h != INVALID_HANDLE_VALUE) {
                    IoControl(kIoctlUpdate, nullptr, 0);
                }
                for (int i = 0; i < 8 && keepAliveRun_.load(); ++i) Sleep(10);
            }
        });

        DWORD idx = IoControl(kIoctlAdd, nullptr, 0);
        if (idx == (DWORD)-1) {
            EmitLog("WinVDD: VddAddDisplay 失败");
            Stop();
            return false;
        }
        vddIndex_ = (int)idx;
        {
            char msg[96];
            snprintf(msg, sizeof(msg), "WinVDD: 已插接虚拟显示器 index=%d", vddIndex_);
            EmitLog(msg);
        }

        // 等待 DisplayConfig 枚举到 PSCCDD0 / ParsecVDA，并处理 Windows 默认镜像模式
        std::wstring devName;
        bool clonedWithPrimary = false;
        for (int attempt = 0; attempt < 35; ++attempt) {
            Sleep(120);
            if (FindParsecSourceDevice(&devName, &clonedWithPrimary)) break;
        }

        if (devName.empty() || clonedWithPrimary) {
            // Windows 首次接入虚拟显示器经常默认 Clone 到 \\.\DISPLAY1，强切为扩展模式
            LONG er = SetDisplayConfig(0, nullptr, 0, nullptr, SDC_TOPOLOGY_EXTEND | SDC_APPLY);
            {
                char msg[96];
                snprintf(msg, sizeof(msg), "WinVDD: 切换扩展桌面 topology r=%ld", er);
                EmitLog(msg);
            }
            for (int attempt = 0; attempt < 25; ++attempt) {
                Sleep(120);
                bool stillCloned = false;
                if (FindParsecSourceDevice(&devName, &stillCloned) && !stillCloned) break;
            }
        }

        if (devName.empty()) {
            EmitLog("WinVDD: 未能定位 ParsecVDA 对应的 GDI 显示路径");
            Stop();
            return false;
        }

        // 把虚拟屏放置在主屏右侧并设置请求分辨率
        {
            std::lock_guard<std::mutex> lk(mtx_);
            reqWidth_ = width;
            reqHeight_ = height;
            reqHz_ = hz;
            lastDpiPercent_ = targetDpiPercent;
        }
        ApplyDisplayMode(devName, width, height, hz);
        ApplyDisplayDpiScale(devName, targetDpiPercent);

        // 读取最终生效的桌面边界
        WinVddBounds b{};
        b.deviceName = devName;
        if (!ReadCurrentBounds(devName, &b)) {
            b.left = 0;
            b.top = 0;
            b.width = width;
            b.height = height;
            b.hz = hz;
        }
        bool hasOther = HasOtherAttachedDisplay(devName);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            ++modeGen_;
            bounds_ = b;
            active_ = true;
            hadOtherDisplay_ = hasOther;
        }

        char msg[256];
        snprintf(msg, sizeof(msg),
                 "WinVDD: 虚拟屏就绪 %ls  范围 (%d,%d) %dx%d @ %dHz",
                 b.deviceName.c_str(), b.left, b.top, b.width, b.height, b.hz);
        EmitLog(msg);
        return true;
    }

    bool SetMode(int width, int height, int hz) {
        std::wstring devName;
        int dpiPct = 0;
        if (width <= 0) width = 2880;
        if (height <= 0) height = 1800;
        if (hz <= 0) hz = 60;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (!active_ || bounds_.deviceName.empty()) return false;
            devName = bounds_.deviceName;
            reqWidth_ = width;
            reqHeight_ = height;
            reqHz_ = hz;
            dpiPct = lastDpiPercent_;
            ++modeGen_;
        }
        if (!EnsureCustomResolution(width, height, hz)) {
            EmitLog("WinVDD: 写入 HKLM\\SOFTWARE\\Parsec\\vdd\\0 失败（需管理员权限），动态切分可能回落");
        }
        ApplyDisplayMode(devName, width, height, hz);
        ApplyDisplayDpiScale(devName, dpiPct);
        WinVddBounds b{};
        b.deviceName = devName;
        if (!ReadCurrentBounds(devName, &b)) {
            EmitLog("WinVDD: 动态切换分辨率后读回显示模式失败");
            return false;
        }
        bool hasOther = HasOtherAttachedDisplay(devName);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (active_ && bounds_.deviceName == devName) {
                ++modeGen_;
                bounds_ = b;
                hadOtherDisplay_ = hasOther;
            }
        }
        char msg[192];
        if (b.width != width || b.height != height) {
            snprintf(msg, sizeof(msg),
                     "WinVDD: 请求 %dx%d 未完全生效，当前实际 %dx%d @ %dHz（如需新自定义模式请点重挂虚拟屏）",
                     width, height, b.width, b.height, b.hz);
        } else {
            snprintf(msg, sizeof(msg), "WinVDD: 已动态切换虚拟屏 %dx%d @ %dHz",
                     b.width, b.height, b.hz);
        }
        EmitLog(msg);
        return (b.width == width && b.height == height);
    }

    // 检测到笔记本开盖/息屏恢复或系统切回镜像模式时，自动恢复扩展桌面并把虚拟屏摆到物理屏右侧
    bool ReconcileExtendedTopology(bool* outCooldown = nullptr) {
        if (outCooldown) *outCooldown = false;
        bool wasOther = false;
        int rw = 2880, rh = 1800, rhz = 60, dpiPct = 0;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (!active_ || bounds_.deviceName.empty()) return false;
            wasOther = hadOtherDisplay_;
            rw = reqWidth_;
            rh = reqHeight_;
            rhz = reqHz_;
            dpiPct = lastDpiPercent_;
        }
        ULONGLONG nowTick = GetTickCount64();
        if (nowTick - lastReconcileTick_ < 2500ULL) {
            if (outCooldown) *outCooldown = true;
            return false;
        }
        lastReconcileTick_ = nowTick;

        std::wstring devName;
        bool cloned = false;
        bool found = FindParsecSourceDevice(&devName, &cloned);
        if (!found) {
            // 系统切成了「仅主屏幕」时 ParsecVDA 路径不活跃，强制扩屏找回
            LONG er = SetDisplayConfig(0, nullptr, 0, nullptr, SDC_TOPOLOGY_EXTEND | SDC_APPLY);
            if (er == ERROR_SUCCESS) {
                for (int i = 0; i < 15; ++i) {
                    Sleep(100);
                    if (FindParsecSourceDevice(&devName, &cloned) && !cloned) break;
                }
            }
            if (devName.empty()) return false;
            cloned = true; // 刚从隐藏恢复，按需重新布置分辨率与右侧位置
        }

        WinVddBounds curB{};
        curB.deviceName = devName;
        bool hasBounds = ReadCurrentBounds(devName, &curB);
        bool hasOtherNow = HasOtherAttachedDisplay(devName);
        bool lidReopened = (!wasOther && hasOtherNow && hasBounds && curB.left == 0 && curB.top == 0);

        if (!cloned && !lidReopened) {
            std::lock_guard<std::mutex> lk(mtx_);
            hadOtherDisplay_ = hasOtherNow;
            return false;
        }

        if (cloned) {
            LONG er = SetDisplayConfig(0, nullptr, 0, nullptr, SDC_TOPOLOGY_EXTEND | SDC_APPLY);
            char msg[128];
            snprintf(msg, sizeof(msg), "WinVDD: 检测到镜像/拓扑异常，自动恢复扩展桌面 topology r=%ld", er);
            EmitLog(msg);
            for (int i = 0; i < 15; ++i) {
                Sleep(100);
                bool stillCloned = false;
                if (FindParsecSourceDevice(&devName, &stillCloned) && !stillCloned) break;
            }
        } else {
            EmitLog("WinVDD: 检测到物理主屏重新接入，自动将虚拟屏归位至主屏右侧");
        }

        ApplyDisplayMode(devName, rw, rh, rhz);
        ApplyDisplayDpiScale(devName, dpiPct);

        WinVddBounds nb{};
        nb.deviceName = devName;
        if (!ReadCurrentBounds(devName, &nb)) return false;
        bool hasOtherAfter = HasOtherAttachedDisplay(devName);
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (active_) {
                ++modeGen_;
                bounds_ = nb;
                hadOtherDisplay_ = hasOtherAfter;
            }
        }
        char msg[192];
        snprintf(msg, sizeof(msg), "WinVDD: 扩展桌面已恢复 %ls  范围 (%d,%d) %dx%d @ %dHz",
                 nb.deviceName.c_str(), nb.left, nb.top, nb.width, nb.height, nb.hz);
        EmitLog(msg);
        return true;
    }

    void Stop() {
        keepAliveRun_.store(false);
        if (keepAliveThread_.joinable()) keepAliveThread_.join();

        if (handle_ != INVALID_HANDLE_VALUE) {
            if (vddIndex_ >= 0 && vddIndex_ <= 65535) {
                UINT16 id16 = (UINT16)(((vddIndex_ & 0xFF) << 8) | ((vddIndex_ >> 8) & 0xFF));
                DWORD r = IoControl(kIoctlRemove, &id16, sizeof(id16));
                char msg[128];
                if (r == (DWORD)-1) {
                    snprintf(msg, sizeof(msg), "WinVDD: 拔出虚拟显示器失败 index=%d", vddIndex_);
                } else {
                    snprintf(msg, sizeof(msg), "WinVDD: 已拔出虚拟显示器 index=%d", vddIndex_);
                }
                EmitLog(msg);
                vddIndex_ = -1;
            }
            CloseHandle(handle_);
            handle_ = INVALID_HANDLE_VALUE;
        }

        std::lock_guard<std::mutex> lk(mtx_);
        active_ = false;
        bounds_ = WinVddBounds{};
    }

    bool IsActive() const {
        std::wstring devName;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (!active_) return false;
            devName = bounds_.deviceName;
        }
        if (devName.empty()) return false;
        WinVddBounds probe{};
        return ReadCurrentBounds(devName, &probe);
    }

    WinVddBounds Bounds() const {
        std::lock_guard<std::mutex> lk(mtx_);
        return bounds_;
    }

    // 刷新并返回最新位置与分辨率（用户在 Windows 显示设置里拖动排列或改分辨率后自动对齐）
    WinVddBounds RefreshBounds() {
        std::wstring devName;
        WinVddBounds fallback{};
        uint64_t gen = 0;
        {
            std::lock_guard<std::mutex> lk(mtx_);
            if (!active_ || bounds_.deviceName.empty()) return bounds_;
            devName = bounds_.deviceName;
            fallback = bounds_;
            gen = modeGen_;
        }
        WinVddBounds nb{};
        nb.deviceName = devName;
        if (ReadCurrentBounds(devName, &nb)) {
            std::lock_guard<std::mutex> lk(mtx_);
            if (active_ && bounds_.deviceName == devName && modeGen_ == gen) {
                bounds_ = nb;
            }
            return nb;
        }
        return fallback;
    }

    // 根据虚拟屏 GDI 设备名查找对应的 DXGI Adapter 和 Output
    bool FindDxgiOutput(IDXGIFactory1* fac,
                        Microsoft::WRL::ComPtr<IDXGIAdapter1>& outAdapter,
                        Microsoft::WRL::ComPtr<IDXGIOutput>& outOutput) const {
        if (!fac) return false;
        WinVddBounds b = Bounds();
        if (b.deviceName.empty()) return false;

        Microsoft::WRL::ComPtr<IDXGIAdapter1> ad;
        for (UINT ai = 0; SUCCEEDED(fac->EnumAdapters1(ai, &ad)); ++ai) {
            Microsoft::WRL::ComPtr<IDXGIOutput> out;
            for (UINT oi = 0; SUCCEEDED(ad->EnumOutputs(oi, &out)); ++oi) {
                DXGI_OUTPUT_DESC od{};
                if (SUCCEEDED(out->GetDesc(&od)) && od.AttachedToDesktop) {
                    if (_wcsicmp(od.DeviceName, b.deviceName.c_str()) == 0) {
                        outAdapter = ad;
                        outOutput = out;
                        return true;
                    }
                }
                out.Reset();
            }
            ad.Reset();
        }
        return false;
    }

private:
    static constexpr DWORD kIoctlAdd     = 0x0022e004;
    static constexpr DWORD kIoctlRemove  = 0x0022a008;
    static constexpr DWORD kIoctlUpdate  = 0x0022a00c;
    static constexpr DWORD kIoctlVersion = 0x0022e010;

    HANDLE handle_ = INVALID_HANDLE_VALUE;
    int vddIndex_ = -1;
    std::atomic<bool> keepAliveRun_{false};
    std::thread keepAliveThread_;
    mutable std::mutex mtx_;
    WinVddBounds bounds_{};
    bool active_ = false;
    bool hadOtherDisplay_ = false;
    uint64_t modeGen_ = 0;
    int reqWidth_ = 2880;
    int reqHeight_ = 1800;
    int reqHz_ = 60;
    int lastDpiPercent_ = 0;
    ULONGLONG lastReconcileTick_ = 0;
    LogFn logFn_;

    static bool HasOtherAttachedDisplay(const std::wstring& devName) {
        for (DWORD i = 0; ; ++i) {
            DISPLAY_DEVICEW dd{}; dd.cb = sizeof(dd);
            if (!EnumDisplayDevicesW(nullptr, i, &dd, 0)) break;
            if (!(dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
            if (_wcsicmp(dd.DeviceName, devName.c_str()) == 0) continue;
            DEVMODEW dm{}; dm.dmSize = sizeof(dm);
            if (EnumDisplaySettingsW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm) &&
                dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0) {
                return true;
            }
        }
        return false;
    }

    void EmitLog(const char* s) {
        if (logFn_ && s) logFn_(s);
    }

    static HANDLE OpenVddDevice() {
        static const GUID kAdapterGuid = {
            0x00b41627, 0x04c4, 0x429e, { 0xa2, 0x6e, 0x02, 0x65, 0xcf, 0x50, 0xc8, 0xfa }
        };
        HANDLE h = INVALID_HANDLE_VALUE;
        HDEVINFO devInfo = SetupDiGetClassDevsA(&kAdapterGuid, nullptr, nullptr,
                                                DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (devInfo == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;

        SP_DEVICE_INTERFACE_DATA ifData{};
        ifData.cbSize = sizeof(ifData);
        for (DWORD i = 0; SetupDiEnumDeviceInterfaces(devInfo, nullptr, &kAdapterGuid, i, &ifData); ++i) {
            DWORD sz = 0;
            SetupDiGetDeviceInterfaceDetailA(devInfo, &ifData, nullptr, 0, &sz, nullptr);
            if (sz == 0) continue;
            auto* detail = (SP_DEVICE_INTERFACE_DETAIL_DATA_A*)calloc(1, sz);
            if (!detail) continue;
            detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_A);
            if (SetupDiGetDeviceInterfaceDetailA(devInfo, &ifData, detail, sz, &sz, nullptr)) {
                h = CreateFileA(detail->DevicePath, GENERIC_READ | GENERIC_WRITE,
                                FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING |
                                FILE_FLAG_OVERLAPPED | FILE_FLAG_WRITE_THROUGH,
                                nullptr);
            }
            free(detail);
            if (h != nullptr && h != INVALID_HANDLE_VALUE) break;
        }
        SetupDiDestroyDeviceInfoList(devInfo);
        return h;
    }

    DWORD IoControl(DWORD code, const void* data, size_t sz) {
        if (handle_ == INVALID_HANDLE_VALUE) return (DWORD)-1;
        BYTE inBuf[32]{};
        if (data && sz > 0) memcpy(inBuf, data, sz < sizeof(inBuf) ? sz : sizeof(inBuf));
        OVERLAPPED ov{};
        ov.hEvent = CreateEventA(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) return (DWORD)-1;
        DWORD outBuf = 0, xfer = 0;
        BOOL ok = DeviceIoControl(handle_, code, inBuf, sizeof(inBuf), &outBuf, sizeof(outBuf), nullptr, &ov);
        if (!ok && GetLastError() != ERROR_IO_PENDING) {
            CloseHandle(ov.hEvent);
            return (DWORD)-1;
        }
        if (!GetOverlappedResultEx(handle_, &ov, &xfer, 5000, FALSE)) {
            CancelIoEx(handle_, &ov);
            GetOverlappedResultEx(handle_, &ov, &xfer, 1000, FALSE);
            CloseHandle(ov.hEvent);
            return (DWORD)-1;
        }
        CloseHandle(ov.hEvent);
        return outBuf;
    }

    static bool FindParsecSourceDevice(std::wstring* outDeviceName, bool* outCloned) {
        UINT32 numPaths = 0, numModes = 0;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPaths, &numModes) != ERROR_SUCCESS ||
            numPaths == 0) {
            return false;
        }
        std::vector<DISPLAYCONFIG_PATH_INFO> paths(numPaths);
        std::vector<DISPLAYCONFIG_MODE_INFO> modes(numModes);
        if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &numPaths, paths.data(),
                               &numModes, modes.data(), nullptr) != ERROR_SUCCESS) {
            return false;
        }

        std::wstring foundSrc;
        UINT32 foundSrcId = 0;
        LUID foundAdapter{};
        bool found = false;

        for (UINT32 i = 0; i < numPaths; ++i) {
            DISPLAYCONFIG_TARGET_DEVICE_NAME tname{};
            tname.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
            tname.header.size = sizeof(tname);
            tname.header.adapterId = paths[i].targetInfo.adapterId;
            tname.header.id = paths[i].targetInfo.id;
            if (DisplayConfigGetDeviceInfo(&tname.header) != ERROR_SUCCESS) continue;

            if (wcsstr(tname.monitorDevicePath, L"PSCCDD0") == nullptr &&
                wcsstr(tname.monitorFriendlyDeviceName, L"ParsecVDA") == nullptr) {
                continue;
            }

            DISPLAYCONFIG_SOURCE_DEVICE_NAME sname{};
            sname.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            sname.header.size = sizeof(sname);
            sname.header.adapterId = paths[i].sourceInfo.adapterId;
            sname.header.id = paths[i].sourceInfo.id;
            if (DisplayConfigGetDeviceInfo(&sname.header) != ERROR_SUCCESS) continue;

            foundSrc = sname.viewGdiDeviceName;
            foundSrcId = paths[i].sourceInfo.id;
            foundAdapter = paths[i].sourceInfo.adapterId;
            found = !foundSrc.empty();
            break;
        }

        if (!found) return false;

        // 检查是否有其他监视器共用同一 sourceInfo（Clone 模式）
        int sameSourceCount = 0;
        for (UINT32 i = 0; i < numPaths; ++i) {
            if (paths[i].sourceInfo.id == foundSrcId &&
                paths[i].sourceInfo.adapterId.LowPart == foundAdapter.LowPart &&
                paths[i].sourceInfo.adapterId.HighPart == foundAdapter.HighPart) {
                ++sameSourceCount;
            }
        }
        if (outDeviceName) *outDeviceName = foundSrc;
        if (outCloned) *outCloned = (sameSourceCount > 1);
        return true;
    }

    void ApplyDisplayMode(const std::wstring& devName, int w, int h, int hz) {
        auto scanRightEdge = [&](bool* outFound) -> LONG {
            bool found = false;
            LONG edge = LONG_MIN;
            for (DWORD i = 0; ; ++i) {
                DISPLAY_DEVICEW dd{}; dd.cb = sizeof(dd);
                if (!EnumDisplayDevicesW(nullptr, i, &dd, 0)) break;
                if (!(dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP)) continue;
                if (_wcsicmp(dd.DeviceName, devName.c_str()) == 0) continue;
                DEVMODEW dm{}; dm.dmSize = sizeof(dm);
                if (EnumDisplaySettingsW(dd.DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
                    LONG r = dm.dmPosition.x + (LONG)dm.dmPelsWidth;
                    if (!found || r > edge) {
                        edge = r;
                        found = true;
                    }
                }
            }
            if (outFound) *outFound = found;
            return found ? edge : 0;
        };

        bool foundOther = false;
        LONG rightEdge = scanRightEdge(&foundOther);
        if (!foundOther) {
            // 若物理主屏因空闲息屏导致当前无其它在线屏幕，Windows GDI ChangeDisplaySettingsEx 可能返回 DISP_CHANGE_FAILED(-1)；
            // 触发一次零位移输入唤醒显示会话，并重新枚举物理屏右边界
            INPUT wake{};
            wake.type = INPUT_MOUSE;
            wake.mi.dwFlags = MOUSEEVENTF_MOVE;
            if (SendInput(1, &wake, sizeof(INPUT)) == 0) {
                char msg[128];
                snprintf(msg, sizeof(msg), "WinVDD: 零位移唤醒输入失败 err=%lu", GetLastError());
                EmitLog(msg);
            } else {
                Sleep(250);
                rightEdge = scanRightEdge(&foundOther);
            }
        }

        auto applyRaw = [&](DWORD reqW, DWORD reqH, DWORD reqHz, bool withPos) -> bool {
            DEVMODEW dm{}; dm.dmSize = sizeof(dm);
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | (withPos ? DM_POSITION : 0);
            dm.dmPelsWidth = reqW;
            dm.dmPelsHeight = reqH;
            dm.dmDisplayFrequency = reqHz;
            if (withPos) {
                dm.dmPosition.x = rightEdge;
                dm.dmPosition.y = 0;
            }
            // 先用 flags=0 直接探测并生效，避免失败时在注册表留下未应用的脏模式条目
            LONG r = ChangeDisplaySettingsExW(devName.c_str(), &dm, nullptr, 0, nullptr);
            if (r != DISP_CHANGE_SUCCESSFUL) {
                return false;
            }
            WinVddBounds chk{};
            bool matched = false;
            for (int t = 0; t < 8; ++t) {
                Sleep(50);
                if (ReadCurrentBounds(devName, &chk) && chk.width == (int)reqW && chk.height == (int)reqH) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return false;
            if (withPos && chk.left != rightEdge) {
                char msg[128];
                snprintf(msg, sizeof(msg), "WinVDD: 虚拟屏位置实际 (%d,%d)，请求 (%ld,0)",
                         chk.left, chk.top, rightEdge);
                EmitLog(msg);
            }
            // 仅对已验证生效的分辨率持久化写入注册表
            ChangeDisplaySettingsExW(devName.c_str(), &dm, nullptr, CDS_UPDATEREGISTRY, nullptr);
            return true;
        };

        auto tryMode = [&](DWORD reqW, DWORD reqH, DWORD reqHz) -> bool {
            if (applyRaw(reqW, reqH, reqHz, true)) return true;
            return applyRaw(reqW, reqH, reqHz, false);
        };

        if (tryMode((DWORD)w, (DWORD)h, (DWORD)hz)) return;
        if (hz != 60 && tryMode((DWORD)w, (DWORD)h, 60)) return;
        // 退回到常见 16:10 模式
        if (tryMode(2560, 1600, 60)) {
            EmitLog("WinVDD: 目标分辨率不受支持，已回落 2560x1600@60");
            return;
        }
        if (!tryMode(1920, 1200, 60)) {
            EmitLog("WinVDD: 回落 1920x1200@60 也失败，保持驱动当前默认模式");
        }
    }

    static bool ReadCurrentBounds(const std::wstring& devName, WinVddBounds* out) {
        DEVMODEW dm{}; dm.dmSize = sizeof(dm);
        if (!EnumDisplaySettingsW(devName.c_str(), ENUM_CURRENT_SETTINGS, &dm)) return false;
        if (dm.dmPelsWidth == 0 || dm.dmPelsHeight == 0) return false;
        out->left = (int)dm.dmPosition.x;
        out->top = (int)dm.dmPosition.y;
        out->width = (int)dm.dmPelsWidth;
        out->height = (int)dm.dmPelsHeight;
        out->hz = (int)dm.dmDisplayFrequency;
        return true;
    }

    // 通过 DisplayConfig 私有 DPI 扩展包（-3 查询 / -4 设置）探测并按需应用独立缩放
    void ApplyDisplayDpiScale(const std::wstring& devName, int targetDpiPercent) {
        struct DpiScaleGet {
            DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            INT32 minScaleRel;
            INT32 curScaleRel;
            INT32 maxScaleRel;
        };
        struct DpiScaleSet {
            DISPLAYCONFIG_DEVICE_INFO_HEADER header;
            INT32 scaleRel;
        };
        static const int kDpiVals[] = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
        constexpr int kNumDpi = (int)(sizeof(kDpiVals) / sizeof(kDpiVals[0]));

        UINT32 np = 0, nm = 0;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS || np == 0) return;
        std::vector<DISPLAYCONFIG_PATH_INFO> paths(np);
        std::vector<DISPLAYCONFIG_MODE_INFO> modes(nm);
        if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths.data(), &nm, modes.data(), nullptr) != ERROR_SUCCESS) return;

        for (UINT32 i = 0; i < np; ++i) {
            DISPLAYCONFIG_SOURCE_DEVICE_NAME sn{};
            sn.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            sn.header.size = sizeof(sn);
            sn.header.adapterId = paths[i].sourceInfo.adapterId;
            sn.header.id = paths[i].sourceInfo.id;
            if (DisplayConfigGetDeviceInfo(&sn.header) != ERROR_SUCCESS) continue;
            if (_wcsicmp(sn.viewGdiDeviceName, devName.c_str()) != 0) continue;

            DpiScaleGet dg{};
            dg.header.type = (DISPLAYCONFIG_DEVICE_INFO_TYPE)-3;
            dg.header.size = sizeof(dg);
            dg.header.adapterId = paths[i].sourceInfo.adapterId;
            dg.header.id = paths[i].sourceInfo.id;
            if (DisplayConfigGetDeviceInfo(&dg.header) != ERROR_SUCCESS) return;

            int recIdx = std::clamp(-dg.minScaleRel, 0, kNumDpi - 1);
            int curIdx = std::clamp(recIdx + dg.curScaleRel, 0, kNumDpi - 1);
            char msg[160];
            snprintf(msg, sizeof(msg), "WinVDD: 虚拟屏当前 DPI 缩放 %d%% (系统推荐 %d%%)",
                     kDpiVals[curIdx], kDpiVals[recIdx]);
            EmitLog(msg);

            if (targetDpiPercent >= 100) {
                int bestIdx = recIdx;
                int bestDiff = 9999;
                for (int k = 0; k < kNumDpi; ++k) {
                    int d = std::abs(kDpiVals[k] - targetDpiPercent);
                    if (d < bestDiff) { bestDiff = d; bestIdx = k; }
                }
                int desiredRel = std::clamp(bestIdx - recIdx, (int)dg.minScaleRel, (int)dg.maxScaleRel);
                if (desiredRel != dg.curScaleRel) {
                    DpiScaleSet ds{};
                    ds.header.type = (DISPLAYCONFIG_DEVICE_INFO_TYPE)-4;
                    ds.header.size = sizeof(ds);
                    ds.header.adapterId = paths[i].sourceInfo.adapterId;
                    ds.header.id = paths[i].sourceInfo.id;
                    ds.scaleRel = desiredRel;
                    LONG sr = DisplayConfigSetDeviceInfo(&ds.header);
                    if (sr == ERROR_SUCCESS) {
                        int appliedIdx = std::clamp(recIdx + desiredRel, 0, kNumDpi - 1);
                        snprintf(msg, sizeof(msg), "WinVDD: 已设置虚拟屏 DPI 缩放 -> %d%%", kDpiVals[appliedIdx]);
                    } else {
                        snprintf(msg, sizeof(msg), "WinVDD: 设置虚拟屏 DPI 缩放失败 r=%ld", sr);
                    }
                    EmitLog(msg);
                }
            }
            break;
        }
    }
};

} // namespace secdisplay
