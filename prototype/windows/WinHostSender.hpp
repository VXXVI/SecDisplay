#pragma once
// ============================================================================
// WinHostSender.hpp —— Windows 主控发送端引擎（Mac 当 Windows 副屏）
//
// 管线：
//   WinVirtualDisplay (Parsec VDD 扩展屏)
//     → DXGI Desktop Duplication (零拷贝抓取虚拟屏 BGRA 纹理)
//     → ID3D11VideoProcessor (GPU BGRA → NV12, BT.709)
//     → Media Foundation H.264 硬件编码 (Intel Quick Sync Async MFT / 软编兜底)
//     → Annex-B 转 AVCC（IDR 自动补齐 SPS/PPS）
//     → TCP 服务端 9922（0x01 视频 / 0x03 光标 / 0x05 光标图像 / 0x06 会话头）
//     ← 接收 Mac 副屏回传（0x02 关键帧请求 / 0x04 鼠标 / 0x07 健康度 / 0x09 键盘）
// ============================================================================

#include "WinVdd.hpp"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <d3d11.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <codecapi.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#ifndef SIO_KEEPALIVE_VALS
#define SIO_KEEPALIVE_VALS _WSAIOW(IOC_VENDOR, 4)
#endif

struct WinHostKeepAliveCfg {
    ULONG onoff;
    ULONG keepalivetime;
    ULONG keepaliveinterval;
};

#ifdef _MSC_VER
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#endif

namespace secdisplay {

struct WinHostStats {
    std::atomic<bool>     clientConnected{false};
    std::atomic<bool>     kvmActive{false};
    std::atomic<int>      width{0};
    std::atomic<int>      height{0};
    std::atomic<int>      fps{60};
    std::atomic<uint64_t> framesEncoded{0};
    std::atomic<uint64_t> framesSent{0};
    std::atomic<uint64_t> bytesSent{0};
    std::atomic<uint64_t> framesDropped{0};
    std::atomic<uint64_t> encodeFail{0};
    std::atomic<uint64_t> fenceTimeouts{0};
    std::atomic<uint64_t> cursorSent{0};
    std::atomic<uint64_t> inputRecv{0};
    std::atomic<double>   lastEncMs{0.0};
    std::atomic<int>      bitrateMbps{80};
    std::atomic<int>      targetBitrateMbps{80};
    std::atomic<uint64_t> connStartTick{0};
    std::atomic<uint64_t> lastSentTick{0};
    std::mutex            infoMtx;
    std::string           peerAddr = "--";
    std::wstring          encoderName = L"--";
    std::string           lastError;
};

class WinHostSender {
public:
    using LogFn = std::function<void(const char*)>;

    WinHostSender() = default;
    ~WinHostSender() { Stop(); }

    WinHostSender(const WinHostSender&) = delete;
    WinHostSender& operator=(const WinHostSender&) = delete;

    WinHostStats& Stats() { return stats_; }
    const WinHostStats& Stats() const { return stats_; }

    bool Start(const std::string& targetHost, int width, int height, int fps, int bitrateMbps, uint16_t port, LogFn logFn, int dpiPercent = 0) {
        Stop();
        pausedForSleep_.store(false);
        displayReconcilePending_.store(false);
        displayWakeInternal_.store(false);
        logFn_ = std::move(logFn);
        targetHost_ = targetHost.empty() ? "10.10.10.1" : targetHost;
        reqW_ = width > 0 ? width : 2880;
        reqH_ = height > 0 ? height : 1800;
        reqFps_ = (fps >= 24 && fps <= 144) ? fps : 60;
        reqDpi_ = dpiPercent;
        if (bitrateMbps < 10) bitrateMbps = 10;
        if (bitrateMbps > 200) bitrateMbps = 200;
        targetMbps_.store(bitrateMbps);
        curMbps_.store(bitrateMbps);
        port_ = port > 0 ? port : 9922;

        stats_.targetBitrateMbps = bitrateMbps;
        stats_.bitrateMbps = bitrateMbps;
        stats_.fps = reqFps_;
        stats_.lastSentTick = 0;
        {
            std::lock_guard<std::mutex> ilk(stats_.infoMtx);
            stats_.lastError.clear();
        }

        if (!vdd_.Start(reqW_, reqH_, reqFps_, logFn_, dpiPercent)) {
            std::string drvDesc;
            WinVirtualDisplay::QueryDriverStatus(&drvDesc);
            {
                std::lock_guard<std::mutex> ilk(stats_.infoMtx);
                stats_.lastError = drvDesc.empty() ? "虚拟屏启动失败" : drvDesc;
            }
            EmitLog("WinHost: 虚拟屏启动失败");
            return false;
        }
        WinVddBounds b = vdd_.Bounds();
        if (b.width <= 0 || b.height <= 0) {
            {
                std::lock_guard<std::mutex> ilk(stats_.infoMtx);
                stats_.lastError = "虚拟屏尺寸无效";
            }
            EmitLog("WinHost: 虚拟屏报告无效尺寸，停止启动");
            vdd_.Stop();
            return false;
        }
        stats_.width = b.width;
        stats_.height = b.height;
        stats_.fps = ClampHz(b.hz, reqFps_);

        {
            char msg[128];
            snprintf(msg, sizeof(msg), "WinHost: 主控端启动，准备连接 Mac 副屏 %s:%u",
                     targetHost_.c_str(), port_);
            EmitLog(msg);
        }

        {
            std::lock_guard<std::mutex> blk(bitrateMtx_);
            localSlowStreak_ = 0;
            lastDownscaleTick_ = 0;
            lastLocalCongestionTick_ = 0;
            lastRemoteCongestionTick_ = 0;
            lastCongestionLogTick_ = 0;
        }
        ClearVideoQueue();
        activeVideoEpoch_.store(0);
        alive_.store(true);
        acceptThread_ = std::thread(&WinHostSender::ConnectLoop, this);
        captureThread_ = std::thread(&WinHostSender::CaptureEncodeLoop, this);
        cursorThread_ = std::thread(&WinHostSender::CursorLoop, this);
        videoSendThread_ = std::thread(&WinHostSender::VideoSendLoop, this);
        kvmSendThread_ = std::thread(&WinHostSender::KvmSendLoop, this);
        return true;
    }

    // 不断虚拟屏的快速重连：仅关闭当前 TCP 套接字，ConnectLoop 在 1.5~3.5s 内自动重连
    void RestartConnection() {
        std::lock_guard<std::mutex> slk(sendMtx_);
        SOCKET cur = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lk(sockMtx_);
            cur = clientSock_;
        }
        if (cur != INVALID_SOCKET) {
            shutdown(cur, SD_BOTH);
        }
        EmitLog("WinHost: 已触发快速重连（保留虚拟屏）");
    }

    bool SetResolution(int width, int height, int hz = 0) {
        int useHz = ClampHz(hz, reqFps_);
        if (!vdd_.SetMode(width, height, useHz)) return false;
        WinVddBounds b = vdd_.Bounds();
        reqW_ = b.width;
        reqH_ = b.height;
        stats_.width = b.width;
        stats_.height = b.height;
        stats_.fps = ClampHz(b.hz, useHz);
        forceKeyframe_.store(true);
        return true;
    }

    void SetTargetMbps(int mbps) {
        int clamped = std::clamp(mbps, 10, 200);
        std::lock_guard<std::mutex> blk(bitrateMtx_);
        targetMbps_.store(clamped);
        curMbps_.store(clamped);
        localSlowStreak_ = 0;
        stats_.targetBitrateMbps = clamped;
        stats_.bitrateMbps = clamped;
    }

    bool VddActive() const { return vdd_.IsActive(); }

    void Stop() {
        SetKvmActive(false);
        alive_.store(false);
        videoCv_.notify_all();
        kvmCv_.notify_all();
        // 按 sendMtx_ -> sockMtx_ 顺序校验身份并一起 shutdown+closesocket，彻底消除锁外句柄复用竞态
        {
            std::lock_guard<std::mutex> slk(sendMtx_);
            std::lock_guard<std::mutex> lk(sockMtx_);
            if (clientSock_ != INVALID_SOCKET) {
                shutdown(clientSock_, SD_BOTH);
                closesocket(clientSock_);
                clientSock_ = INVALID_SOCKET;
            }
        }
        activeVideoEpoch_.store(0);
        stats_.clientConnected = false;

        if (acceptThread_.joinable()) acceptThread_.join();
        if (captureThread_.joinable()) captureThread_.join();
        if (cursorThread_.joinable()) cursorThread_.join();
        if (videoSendThread_.joinable()) videoSendThread_.join();
        if (kvmHookThread_.joinable()) kvmHookThread_.join();
        if (kvmSendThread_.joinable()) kvmSendThread_.join();
        ClearVideoQueue();

        ReleaseAllInputs();
        vdd_.Stop();
        EmitLog("WinHost: 发送端已停止");
    }

    bool IsKvmActive() const { return kvmActive_.load(); }
    bool ToggleKvm() { return SetKvmActive(!kvmActive_.load()); }

    bool SetKvmActive(bool on) {
        if (on) {
            if (!alive_.load() || !stats_.clientConnected.load()) {
                EmitLog("WinHost: Mac 副屏未连接，无法开启 KVM 键鼠穿透");
                return false;
            }
            if (kvmActive_.load()) return true;
            if (kvmHookThread_.joinable()) kvmHookThread_.join();

            int ax = GetSystemMetrics(SM_XVIRTUALSCREEN) + GetSystemMetrics(SM_CXVIRTUALSCREEN) / 2;
            int ay = GetSystemMetrics(SM_YVIRTUALSCREEN) + GetSystemMetrics(SM_CYVIRTUALSCREEN) / 2;
            if (ax == 0 && ay == 0) {
                ax = 640; ay = 400;
            }
            SetCursorPos(ax, ay);
            kvmAnchorX_.store(ax);
            kvmAnchorY_.store(ay);
            kvmHookButtons_ = 0;
            {
                std::lock_guard<std::mutex> klk(kvmMtx_);
                kvmButtons_ = 0;
                kvmDxAccum_ = 0;
                kvmDyAccum_ = 0;
                kvmQueue_.clear();
            }
            kvmHookReady_ = false;
            kvmHookOk_ = false;
            kvmHookTid_ = 0;
            kvmActive_.store(true);
            stats_.kvmActive.store(true);

            kvmHookThread_ = std::thread(&WinHostSender::KvmHookLoop, this);
            {
                std::unique_lock<std::mutex> klk(kvmMtx_);
                kvmReadyCv_.wait_for(klk, std::chrono::milliseconds(1500), [this]() { return kvmHookReady_; });
            }
            if (!kvmHookOk_) {
                kvmActive_.store(false);
                stats_.kvmActive.store(false);
                if (kvmHookThread_.joinable()) kvmHookThread_.join();
                EmitLog("WinHost: 安装 KVM 低级键鼠钩子失败");
                return false;
            }
            EnqueueKvmState(true);
            EmitLog("WinHost: 已开启 KVM 键鼠穿透（操作 Mac 桌面），再按 Ctrl+Alt+K 退出");
            return true;
        } else {
            bool was = kvmActive_.exchange(false);
            stats_.kvmActive.store(false);
            DWORD tid = kvmHookTid_.load();
            if (tid != 0) {
                PostThreadMessageW(tid, WM_QUIT, 0, 0);
            }
            if (was) {
                EnqueueKvmState(false);
                EmitLog("WinHost: 已退出 KVM 键鼠穿透，恢复操作 Windows");
            }
            if (kvmHookThread_.joinable() && GetCurrentThreadId() != tid) {
                kvmHookThread_.join();
            }
            return true;
        }
    }

    void RequestKeyframe() {
        forceKeyframe_.store(true);
    }

    void OnDisplayChange(bool forceWakeInternal = false) {
        if (forceWakeInternal) displayWakeInternal_.store(true);
        displayReconcilePending_.store(true);
    }

    bool IsPausedForSleep() const { return pausedForSleep_.load(); }
    void ClearPausedForSleep() { pausedForSleep_.store(false); }

    bool PauseForSleep() {
        if (!alive_.load() && !vdd_.IsActive()) {
            return pausedForSleep_.load();
        }
        pausedForSleep_.store(true);
        EmitLog("WinHost: 系统即将进入休眠，暂停推流并卸载虚拟屏以保护内建屏");
        Stop();
        return true;
    }

    bool ResumeFromSleep() {
        if (!pausedForSleep_.load()) return false;
        EmitLog("WinHost: 系统从休眠恢复，先唤醒内建显示路径再重建虚拟屏");
        WinVirtualDisplay::EnsureInternalPanelAwake(logFn_);
        std::string hostCopy = targetHost_;
        LogFn logCopy = logFn_;
        bool ok = Start(hostCopy, reqW_, reqH_, reqFps_, targetMbps_.load(), port_, std::move(logCopy), reqDpi_);
        if (!ok) {
            // Start() 内部清除了 pausedForSleep_；若驱动刚唤醒尚未就绪，保留暂停状态供调用方重试
            pausedForSleep_.store(true);
        }
        return ok;
    }

    bool IsRunning() const { return alive_.load(); }

private:
    static constexpr uint8_t kTypeVideo       = 0x01;
    static constexpr uint8_t kTypeKeyframeReq = 0x02;
    static constexpr uint8_t kTypeCursorPos   = 0x03;
    static constexpr uint8_t kTypeMouseInput  = 0x04;
    static constexpr uint8_t kTypeCursorImg   = 0x05;
    static constexpr uint8_t kTypeSession     = 0x06;
    static constexpr uint8_t kTypeFeedback    = 0x07;
    static constexpr uint8_t kTypeKeyInput    = 0x09;
    static constexpr uint8_t kTypeKvmMouse    = 0x0A;
    static constexpr uint8_t kTypeKvmKey      = 0x0B;
    static constexpr uint8_t kTypeKvmState    = 0x0C;

    WinVirtualDisplay vdd_;
    WinHostStats stats_;
    LogFn logFn_;

    static int ClampHz(int hz, int fallback) {
        return (hz >= 24 && hz <= 240) ? hz : fallback;
    }

    std::string targetHost_ = "10.10.10.1";
    int reqW_ = 2560;
    int reqH_ = 1600;
    int reqFps_ = 60;
    int reqDpi_ = 0;
    std::atomic<int> targetMbps_{80};
    std::atomic<int> curMbps_{80};
    uint16_t port_ = 9922;

    std::atomic<bool> alive_{false};
    std::atomic<bool> forceKeyframe_{true};
    std::atomic<bool> displayReconcilePending_{false};
    std::atomic<bool> displayWakeInternal_{false};
    std::atomic<bool> pausedForSleep_{false};
    std::atomic<uint64_t> lastPayloadUs_{0};

    std::mutex sockMtx_;
    std::mutex sendMtx_;
    SOCKET clientSock_ = INVALID_SOCKET;
    uint64_t connEpoch_ = 0;

    std::thread acceptThread_;
    std::thread captureThread_;
    std::thread cursorThread_;
    std::thread videoSendThread_;
    std::thread kvmHookThread_;
    std::thread kvmSendThread_;

    struct VideoQueueItem {
        std::vector<uint8_t> pkt;
        uint64_t epoch = 0;
        bool isIdr = false;
    };
    std::mutex videoMtx_;
    std::condition_variable videoCv_;
    std::deque<VideoQueueItem> videoQueue_;
    std::atomic<uint64_t> activeVideoEpoch_{0};

    std::mutex bitrateMtx_;
    int localSlowStreak_ = 0;
    ULONGLONG lastDownscaleTick_ = 0;
    ULONGLONG lastLocalCongestionTick_ = 0;
    ULONGLONG lastRemoteCongestionTick_ = 0;
    ULONGLONG lastCongestionLogTick_ = 0;

    static inline std::atomic<WinHostSender*> s_kvmOwner_{nullptr};
    std::atomic<bool> kvmActive_{false};
    std::atomic<DWORD> kvmHookTid_{0};
    std::mutex kvmMtx_;
    std::condition_variable kvmCv_;
    std::condition_variable kvmReadyCv_;
    bool kvmHookReady_ = false;
    bool kvmHookOk_ = false;
    std::atomic<LONG> kvmAnchorX_{0};
    std::atomic<LONG> kvmAnchorY_{0};
    uint8_t kvmHookButtons_ = 0; // 仅在 kvmHookThread_ 内读写
    uint8_t kvmButtons_ = 0;     // 由 kvmMtx_ 保护供 KvmSendLoop 使用
    int kvmDxAccum_ = 0;
    int kvmDyAccum_ = 0;
    std::deque<std::vector<uint8_t>> kvmQueue_;
    std::set<uint16_t> kvmForwardedVks_; // 仅在 kvmHookThread_ 内访问

    void EmitLog(const char* s) {
        if (logFn_ && s) logFn_(s);
    }

    static uint64_t NowMicros() {
        // 与协议一致：任意单调/墙钟微秒即可，用 FILETIME 转 2001 纪元微秒
        FILETIME ft{};
        GetSystemTimeAsFileTime(&ft);
        ULARGE_INTEGER ui{};
        ui.LowPart = ft.dwLowDateTime;
        ui.HighPart = ft.dwHighDateTime;
        // 1601->2001 偏移: 12622780800 秒
        uint64_t unixUs = (ui.QuadPart - 116444736000000000ULL) / 10ULL;
        return unixUs > 978307200000000ULL ? (unixUs - 978307200000000ULL) : unixUs;
    }

    static void PutU16BE(uint8_t* p, uint16_t v) {
        p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)(v & 0xFF);
    }
    static void PutU32BE(uint8_t* p, uint32_t v) {
        p[0] = (uint8_t)((v >> 24) & 0xFF); p[1] = (uint8_t)((v >> 16) & 0xFF);
        p[2] = (uint8_t)((v >> 8) & 0xFF);  p[3] = (uint8_t)(v & 0xFF);
    }
    static void PutU64BE(uint8_t* p, uint64_t v) {
        PutU32BE(p, (uint32_t)(v >> 32));
        PutU32BE(p + 4, (uint32_t)(v & 0xFFFFFFFFu));
    }
    static void PutF32BE(uint8_t* p, float f) {
        uint32_t u = 0; memcpy(&u, &f, 4);
        PutU32BE(p, u);
    }
    static uint16_t RdU16BE(const uint8_t* p) {
        return ((uint16_t)p[0] << 8) | p[1];
    }
    static uint32_t RdU32BE(const uint8_t* p) {
        return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
    }
    static float RdF32BE(const uint8_t* p) {
        uint32_t u = RdU32BE(p);
        float f = 0.0f; memcpy(&f, &u, 4);
        return f;
    }

    bool SendRawPacket(const uint8_t* data, size_t len) {
        std::lock_guard<std::mutex> slk(sendMtx_);
        SOCKET s = INVALID_SOCKET;
        {
            std::lock_guard<std::mutex> lk(sockMtx_);
            s = clientSock_;
        }
        if (s == INVALID_SOCKET) return false;

        size_t sent = 0;
        while (sent < len && alive_.load()) {
            int n = send(s, (const char*)(data + sent), (int)std::min<size_t>(len - sent, 1 << 20), 0);
            if (n > 0) {
                sent += (size_t)n;
            } else {
                int err = WSAGetLastError();
                if (err == WSAEINTR) continue;
                CloseClientUnderSendLock(s);
                return false;
            }
        }
        if (sent == len) {
            stats_.bytesSent += len;
            return true;
        }
        return false;
    }

    // 调用方已持有 sendMtx_
    void CloseClientUnderSendLock(SOCKET expected) {
        std::lock_guard<std::mutex> lk(sockMtx_);
        if (clientSock_ == expected && expected != INVALID_SOCKET) {
            shutdown(clientSock_, SD_BOTH);
            closesocket(clientSock_);
            clientSock_ = INVALID_SOCKET;
            activeVideoEpoch_.store(0);
            stats_.clientConnected = false;
            std::lock_guard<std::mutex> ilk(stats_.infoMtx);
            stats_.peerAddr = "--";
        }
    }

    void DisconnectClient(SOCKET expected) {
        if (expected == INVALID_SOCKET) return;
        {
            std::lock_guard<std::mutex> slk(sendMtx_);
            CloseClientUnderSendLock(expected);
        }
        std::lock_guard<std::mutex> vlk(videoMtx_);
        if (!stats_.clientConnected.load()) {
            videoQueue_.clear();
        }
    }

    void ClearVideoQueue() {
        std::lock_guard<std::mutex> vlk(videoMtx_);
        videoQueue_.clear();
    }

    void SendSessionHeader(int w, int h, int fps) {
        if (w <= 0 || h <= 0) return;
        uint8_t pkt[20];
        PutU32BE(pkt, 16);                 // 1 type + 8 ts + 7 payload
        pkt[4] = kTypeSession;
        PutU64BE(pkt + 5, NowMicros());
        pkt[13] = 1;                       // protocol version
        PutU16BE(pkt + 14, (uint16_t)w);
        PutU16BE(pkt + 16, (uint16_t)h);
        pkt[18] = (uint8_t)std::clamp(fps, 1, 240);
        pkt[19] = 0;
        SendRawPacket(pkt, sizeof(pkt));
    }

    void SendHeartbeat() {
        uint8_t pkt[13];
        PutU32BE(pkt, 9);
        pkt[4] = kTypeSession;
        PutU64BE(pkt + 5, NowMicros());
        SendRawPacket(pkt, sizeof(pkt));
    }

    void EnqueueVideoAvcc(std::vector<uint8_t>&& avcc, uint64_t tsUs, bool isIdr) {
        if (avcc.empty()) return;
        uint64_t epoch = activeVideoEpoch_.load();
        if (epoch == 0 || !stats_.clientConnected.load()) return;

        std::vector<uint8_t> pkt(13 + avcc.size());
        PutU32BE(pkt.data(), (uint32_t)(9 + avcc.size()));
        pkt[4] = kTypeVideo;
        PutU64BE(pkt.data() + 5, tsUs);
        memcpy(pkt.data() + 13, avcc.data(), avcc.size());

        bool dropped = false;
        bool skipThisFrame = false;
        {
            std::lock_guard<std::mutex> vlk(videoMtx_);
            if (isIdr) {
                // 新关键帧到达时若队列仍有积压，直接清掉过期旧帧，确保画面立刻刷新而不排队卡顿
                if (!videoQueue_.empty()) {
                    stats_.framesDropped += videoQueue_.size();
                    videoQueue_.clear();
                    dropped = true;
                }
            } else if (videoQueue_.size() >= 3) {
                // 队列积压 >= 3 帧：从队尾清掉待发的非 IDR 帧，跳过本 P 帧并立刻补请求关键帧避免参考链断链
                while (!videoQueue_.empty() && !videoQueue_.back().isIdr) {
                    videoQueue_.pop_back();
                    stats_.framesDropped++;
                    dropped = true;
                }
                if (!dropped || videoQueue_.size() >= 3) {
                    stats_.framesDropped++;
                    dropped = true;
                }
                skipThisFrame = true;
                forceKeyframe_.store(true);
            }
            if (!skipThisFrame) {
                videoQueue_.push_back(VideoQueueItem{ std::move(pkt), epoch, isIdr });
            }
        }
        if (!skipThisFrame) {
            videoCv_.notify_one();
        }
        if (dropped) {
            NoteLocalCongestion(0.0, true);
        }
    }

    void VideoSendLoop() {
        while (alive_.load()) {
            VideoQueueItem item;
            {
                std::unique_lock<std::mutex> vlk(videoMtx_);
                videoCv_.wait(vlk, [this]() { return !alive_.load() || !videoQueue_.empty(); });
                if (!alive_.load()) break;
                item = std::move(videoQueue_.front());
                videoQueue_.pop_front();
            }
            if (item.epoch == 0 || item.epoch != activeVideoEpoch_.load()) {
                continue;
            }
            ULONGLONG t0 = GetTickCount64();
            if (SendRawPacket(item.pkt.data(), item.pkt.size())) {
                double sendMs = (double)(GetTickCount64() - t0);
                stats_.framesSent++;
                stats_.lastSentTick = GetTickCount64();
                lastPayloadUs_.store(NowMicros());
                if (sendMs > 28.0) {
                    NoteLocalCongestion(sendMs, false);
                }
            } else {
                stats_.framesDropped++;
            }
        }
    }

    void SendCursorPos(float rx, float ry, bool visible) {
        uint8_t pkt[22];
        PutU32BE(pkt, 18);                 // 1 + 8 + 4 + 4 + 1
        pkt[4] = kTypeCursorPos;
        PutU64BE(pkt + 5, NowMicros());
        PutF32BE(pkt + 13, rx);
        PutF32BE(pkt + 17, ry);
        pkt[21] = visible ? 1 : 0;
        if (SendRawPacket(pkt, sizeof(pkt))) {
            stats_.cursorSent++;
        }
    }

    void SendCursorImage(int w, int h, int hotX, int hotY, const std::vector<uint8_t>& bgra) {
        if (w <= 0 || h <= 0 || bgra.size() != (size_t)w * (size_t)h * 4) return;
        std::vector<uint8_t> pkt(4 + 1 + 8 + 12 + bgra.size());
        PutU32BE(pkt.data(), (uint32_t)(1 + 8 + 12 + bgra.size()));
        pkt[4] = kTypeCursorImg;
        PutU64BE(pkt.data() + 5, NowMicros());
        PutU16BE(pkt.data() + 13, (uint16_t)w);
        PutU16BE(pkt.data() + 15, (uint16_t)h);
        PutU16BE(pkt.data() + 17, (uint16_t)std::clamp(hotX, 0, w - 1));
        PutU16BE(pkt.data() + 19, (uint16_t)std::clamp(hotY, 0, h - 1));
        PutU32BE(pkt.data() + 21, (uint32_t)bgra.size());
        memcpy(pkt.data() + 25, bgra.data(), bgra.size());
        SendRawPacket(pkt.data(), pkt.size());
    }

    // ---- TCP 主动连接 Mac 副屏（绕开 macOS 本地网络 TCC 对出站连接的阻断）----
    void ConnectLoop() {
        int connFailCount = 0;
        while (alive_.load()) {
            addrinfo hints{};
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;
            hints.ai_family = AF_UNSPEC;
            addrinfo* resList = nullptr;
            char portStr[16];
            snprintf(portStr, sizeof(portStr), "%u", port_);
            int gaiErr = getaddrinfo(targetHost_.c_str(), portStr, &hints, &resList);
            if (gaiErr != 0 || !resList) {
                ++connFailCount;
                if (connFailCount == 1 || connFailCount % 30 == 0) {
                    char msg[192];
                    snprintf(msg, sizeof(msg), "WinHost: 解析目标地址 %s:%u 失败 (err=%d, 第%d次)",
                             targetHost_.c_str(), port_, gaiErr, connFailCount);
                    EmitLog(msg);
                }
                if (resList) freeaddrinfo(resList);
                for (int i = 0; i < 20 && alive_.load(); ++i) Sleep(100);
                continue;
            }

            // 优先选择 IPv4，其次 IPv6
            addrinfo* chosen = nullptr;
            for (addrinfo* p = resList; p; p = p->ai_next) {
                if (p->ai_family == AF_INET) { chosen = p; break; }
            }
            if (!chosen) chosen = resList;

            SOCKET cs = socket(chosen->ai_family, chosen->ai_socktype, chosen->ai_protocol);
            if (cs == INVALID_SOCKET) {
                freeaddrinfo(resList);
                for (int i = 0; i < 15 && alive_.load(); ++i) Sleep(100);
                continue;
            }

            int bufSz = 4 * 1024 * 1024;
            setsockopt(cs, SOL_SOCKET, SO_SNDBUF, (const char*)&bufSz, sizeof(bufSz));
            setsockopt(cs, SOL_SOCKET, SO_RCVBUF, (const char*)&bufSz, sizeof(bufSz));
            int nodelay = 1, keepalive = 1;
            setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, (const char*)&nodelay, sizeof(nodelay));
            setsockopt(cs, SOL_SOCKET, SO_KEEPALIVE, (const char*)&keepalive, sizeof(keepalive));
            {
                WinHostKeepAliveCfg ka{ 1, 5000, 2000 };
                DWORD retBytes = 0;
                WSAIoctl(cs, SIO_KEEPALIVE_VALS, &ka, sizeof(ka), nullptr, 0, &retBytes, nullptr, nullptr);
            }

            u_long nb = 1;
            ioctlsocket(cs, FIONBIO, &nb);
            connect(cs, chosen->ai_addr, (int)chosen->ai_addrlen);
            freeaddrinfo(resList);

            fd_set wfds, efds;
            FD_ZERO(&wfds); FD_ZERO(&efds);
            FD_SET(cs, &wfds); FD_SET(cs, &efds);
            timeval tv{ 1, 500000 };
            int sel = select(0, nullptr, &wfds, &efds, &tv);
            int soErr = 0; int soLen = sizeof(soErr);
            getsockopt(cs, SOL_SOCKET, SO_ERROR, (char*)&soErr, &soLen);
            if (sel <= 0 || FD_ISSET(cs, &efds) || soErr != 0) {
                ++connFailCount;
                if (connFailCount == 1 || connFailCount % 30 == 0) {
                    int repErr = (sel == 0 && soErr == 0) ? WSAETIMEDOUT : (soErr ? soErr : WSAGetLastError());
                    char msg[160];
                    snprintf(msg, sizeof(msg), "WinHost: 连接 Mac 副屏 %s:%u 失败 (err=%d, 第%d次)",
                             targetHost_.c_str(), port_, repErr, connFailCount);
                    EmitLog(msg);
                }
                closesocket(cs);
                for (int i = 0; i < 15 && alive_.load(); ++i) Sleep(100);
                continue;
            }
            connFailCount = 0;
            nb = 0;
            ioctlsocket(cs, FIONBIO, &nb);

            DWORD rcvTo = 500, sndTo = 1500;
            setsockopt(cs, SOL_SOCKET, SO_RCVTIMEO, (const char*)&rcvTo, sizeof(rcvTo));
            setsockopt(cs, SOL_SOCKET, SO_SNDTIMEO, (const char*)&sndTo, sizeof(sndTo));

            std::string peer = targetHost_ + ":" + std::to_string(port_);

            uint64_t epoch = 0;
            {
                std::lock_guard<std::mutex> slk(sendMtx_);
                std::lock_guard<std::mutex> lk(sockMtx_);
                SOCKET oldSock = clientSock_;
                clientSock_ = cs;
                epoch = ++connEpoch_;
                if (oldSock != INVALID_SOCKET) {
                    shutdown(oldSock, SD_BOTH);
                    closesocket(oldSock);
                }
            }
            {
                std::lock_guard<std::mutex> ilk(stats_.infoMtx);
                stats_.peerAddr = peer;
            }
            stats_.connStartTick = GetTickCount64();
            lastPayloadUs_.store(0);
            forceKeyframe_.store(true);

            // 先清视频发送队列、发会话头再开放 activeVideoEpoch_ 与 clientConnected=true，确保 0x06 总是早于首帧 0x01 到达
            ClearVideoQueue();
            WinVddBounds b = vdd_.Bounds();
            int initHz = ClampHz(b.hz, reqFps_);
            SendSessionHeader(b.width, b.height, initHz);
            activeVideoEpoch_.store(epoch);
            stats_.clientConnected = true;

            {
                char msg[128];
                snprintf(msg, sizeof(msg), "WinHost: 已连接 Mac 副屏 %s", peer.c_str());
                EmitLog(msg);
            }

            ClientRecvLoop(cs, epoch);

            if (!alive_.load()) break;
            for (int i = 0; i < 15 && alive_.load(); ++i) Sleep(100);
        }
    }

    void ClientRecvLoop(SOCKET cs, uint64_t epoch) {
        uint8_t buf[4096];
        std::vector<uint8_t> acc;
        acc.reserve(4096);
        ULONGLONG lastRxTick = GetTickCount64();
        while (alive_.load()) {
            {
                std::lock_guard<std::mutex> lk(sockMtx_);
                if (clientSock_ != cs || connEpoch_ != epoch) break;
            }
            int n = recv(cs, (char*)buf, sizeof(buf), 0);
            if (n > 0) {
                lastRxTick = GetTickCount64();
                acc.insert(acc.end(), buf, buf + n);
                ProcessControlBytes(acc);
            } else if (n == 0) {
                break;
            } else {
                int err = WSAGetLastError();
                if (err == WSAETIMEDOUT || err == WSAEINTR) {
                    // Mac 端每 2 秒发送一次 0x07 反馈；连续 30 秒无任何对端回包判定链路已死
                    if (GetTickCount64() - lastRxTick >= 30000ULL) {
                        EmitLog("WinHost: 超过 30 秒未收到 Mac 副屏心跳/反馈，主动重连");
                        break;
                    }
                    continue;
                }
                break;
            }
        }
        DisconnectClient(cs);
        SetKvmActive(false);
        ReleaseAllInputs();
        EmitLog("WinHost: Mac 副屏连接断开");
    }

    // ---- 双向 KVM 键鼠穿透（Windows 主控键鼠直接操作 Mac 原生系统）----
    static std::vector<uint8_t> BuildKvmMousePkt(int16_t dx, int16_t dy, uint8_t buttons, int16_t wheel) {
        std::vector<uint8_t> pkt(20);
        PutU32BE(pkt.data(), 16); // 1 + 8 + 7
        pkt[4] = kTypeKvmMouse;
        PutU64BE(pkt.data() + 5, NowMicros());
        PutU16BE(pkt.data() + 13, (uint16_t)dx);
        PutU16BE(pkt.data() + 15, (uint16_t)dy);
        pkt[17] = buttons;
        PutU16BE(pkt.data() + 18, (uint16_t)wheel);
        return pkt;
    }

    static std::vector<uint8_t> BuildKvmKeyPkt(uint16_t vk, uint16_t scan, bool down, uint8_t flags) {
        std::vector<uint8_t> pkt(19);
        PutU32BE(pkt.data(), 15); // 1 + 8 + 6
        pkt[4] = kTypeKvmKey;
        PutU64BE(pkt.data() + 5, NowMicros());
        PutU16BE(pkt.data() + 13, vk);
        PutU16BE(pkt.data() + 15, scan);
        pkt[17] = down ? 1 : 0;
        pkt[18] = flags;
        return pkt;
    }

    void EnqueueKvmState(bool active) {
        std::vector<uint8_t> pkt(14);
        PutU32BE(pkt.data(), 10); // 1 + 8 + 1
        pkt[4] = kTypeKvmState;
        PutU64BE(pkt.data() + 5, NowMicros());
        pkt[13] = active ? 1 : 0;
        {
            std::lock_guard<std::mutex> klk(kvmMtx_);
            if (!active) {
                kvmDxAccum_ = 0;
                kvmDyAccum_ = 0;
            }
            kvmQueue_.push_back(std::move(pkt));
        }
        kvmCv_.notify_one();
    }

    void EnqueueKvmKey(uint16_t vk, uint16_t scan, bool down, uint8_t flags) {
        auto pkt = BuildKvmKeyPkt(vk, scan, down, flags);
        {
            std::lock_guard<std::mutex> klk(kvmMtx_);
            if (kvmQueue_.size() > 512) kvmQueue_.pop_front();
            kvmQueue_.push_back(std::move(pkt));
        }
        kvmCv_.notify_one();
    }

    void EnqueueKvmMouseEvent(int dx, int dy, uint8_t buttons, int16_t wheel, bool immediate) {
        std::lock_guard<std::mutex> klk(kvmMtx_);
        kvmDxAccum_ += dx;
        kvmDyAccum_ += dy;
        kvmButtons_ = buttons;
        if (immediate) {
            int16_t sdx = (int16_t)std::clamp(kvmDxAccum_, -32000, 32000);
            int16_t sdy = (int16_t)std::clamp(kvmDyAccum_, -32000, 32000);
            kvmDxAccum_ = 0;
            kvmDyAccum_ = 0;
            if (kvmQueue_.size() > 512) kvmQueue_.pop_front();
            kvmQueue_.push_back(BuildKvmMousePkt(sdx, sdy, buttons, wheel));
        }
        kvmCv_.notify_one();
    }

    void RequestKvmExitFromHook() {
        bool was = kvmActive_.exchange(false);
        stats_.kvmActive.store(false);
        DWORD tid = kvmHookTid_.load();
        if (tid != 0) PostThreadMessageW(tid, WM_QUIT, 0, 0);
        if (was) {
            EnqueueKvmState(false);
            EmitLog("WinHost: 热键退出 KVM 键鼠穿透，恢复操作 Windows");
        }
    }

    void KvmSendLoop() {
        while (alive_.load()) {
            std::vector<uint8_t> pkt;
            {
                std::unique_lock<std::mutex> klk(kvmMtx_);
                if (kvmQueue_.empty() && kvmDxAccum_ == 0 && kvmDyAccum_ == 0) {
                    kvmCv_.wait(klk, [this]() {
                        return !alive_.load() || !kvmQueue_.empty() || kvmDxAccum_ != 0 || kvmDyAccum_ != 0;
                    });
                } else if (kvmQueue_.empty()) {
                    kvmCv_.wait_for(klk, std::chrono::milliseconds(8), [this]() {
                        return !alive_.load() || !kvmQueue_.empty();
                    });
                }
                if (!alive_.load()) break;
                if (!kvmQueue_.empty()) {
                    pkt = std::move(kvmQueue_.front());
                    kvmQueue_.pop_front();
                } else if (kvmDxAccum_ != 0 || kvmDyAccum_ != 0) {
                    int16_t sdx = (int16_t)std::clamp(kvmDxAccum_, -32000, 32000);
                    int16_t sdy = (int16_t)std::clamp(kvmDyAccum_, -32000, 32000);
                    kvmDxAccum_ = 0;
                    kvmDyAccum_ = 0;
                    pkt = BuildKvmMousePkt(sdx, sdy, kvmButtons_, 0);
                }
            }
            if (!pkt.empty()) {
                SendRawPacket(pkt.data(), pkt.size());
            }
        }
    }

    static LRESULT CALLBACK KvmKeyboardProc(int code, WPARAM wParam, LPARAM lParam) {
        WinHostSender* inst = s_kvmOwner_.load();
        if (code == HC_ACTION && inst && inst->kvmActive_.load() && lParam) {
            const auto* kb = (const KBDLLHOOKSTRUCT*)lParam;
            if (!(kb->flags & LLKHF_INJECTED)) {
                uint16_t vk = (uint16_t)kb->vkCode;
                uint16_t scan = (uint16_t)kb->scanCode;
                bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
                uint8_t flags = (kb->flags & LLKHF_EXTENDED) ? 0x01 : 0;

                if (down && (vk == 'K' || vk == VK_ESCAPE) &&
                    (GetAsyncKeyState(VK_CONTROL) & 0x8000) &&
                    (GetAsyncKeyState(VK_MENU) & 0x8000)) {
                    inst->RequestKvmExitFromHook();
                    return 1;
                }
                if (down) {
                    inst->kvmForwardedVks_.insert(vk);
                    inst->EnqueueKvmKey(vk, scan, true, flags);
                    return 1;
                } else {
                    if (inst->kvmForwardedVks_.erase(vk) == 0) {
                        // 放行进入热键残余的 Ctrl/Alt 抬起事件，避免 Windows 本机卡键
                        return CallNextHookEx(nullptr, code, wParam, lParam);
                    }
                    inst->EnqueueKvmKey(vk, scan, false, flags);
                    return 1;
                }
            }
        }
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    static LRESULT CALLBACK KvmMouseProc(int code, WPARAM wParam, LPARAM lParam) {
        WinHostSender* inst = s_kvmOwner_.load();
        if (code == HC_ACTION && inst && inst->kvmActive_.load() && lParam) {
            const auto* ms = (const MSLLHOOKSTRUCT*)lParam;
            if (!(ms->flags & LLMHF_INJECTED)) {
                if (wParam == WM_MOUSEMOVE) {
                    LONG ax = inst->kvmAnchorX_.load();
                    LONG ay = inst->kvmAnchorY_.load();
                    int dx = (int)(ms->pt.x - ax);
                    int dy = (int)(ms->pt.y - ay);
                    if (dx != 0 || dy != 0) {
                        inst->EnqueueKvmMouseEvent(dx, dy, inst->kvmHookButtons_, 0, false);
                        DWORD tid = inst->kvmHookTid_.load();
                        if (tid != 0) PostThreadMessageW(tid, WM_APP + 1, 0, 0);
                    }
                    return 1;
                }
                uint8_t btns = inst->kvmHookButtons_;
                int16_t wheel = 0;
                bool handled = true;
                switch (wParam) {
                case WM_LBUTTONDOWN: btns |= 0x01; break;
                case WM_LBUTTONUP:   btns &= ~0x01; break;
                case WM_RBUTTONDOWN: btns |= 0x02; break;
                case WM_RBUTTONUP:   btns &= ~0x02; break;
                case WM_MBUTTONDOWN: btns |= 0x04; break;
                case WM_MBUTTONUP:   btns &= ~0x04; break;
                case WM_MOUSEWHEEL:  wheel = (int16_t)HIWORD(ms->mouseData); break;
                default: handled = false; break;
                }
                if (handled) {
                    inst->kvmHookButtons_ = btns;
                    inst->EnqueueKvmMouseEvent(0, 0, btns, wheel, true);
                    return 1;
                }
            }
        }
        return CallNextHookEx(nullptr, code, wParam, lParam);
    }

    void KvmHookLoop() {
        MSG dummy{};
        PeekMessageW(&dummy, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
        kvmHookTid_.store(GetCurrentThreadId());
        kvmForwardedVks_.clear();
        s_kvmOwner_.store(this);

        HHOOK hKb = SetWindowsHookExW(WH_KEYBOARD_LL, KvmKeyboardProc, GetModuleHandleW(nullptr), 0);
        HHOOK hMs = SetWindowsHookExW(WH_MOUSE_LL, KvmMouseProc, GetModuleHandleW(nullptr), 0);
        bool ok = (hKb != nullptr && hMs != nullptr);
        {
            std::lock_guard<std::mutex> klk(kvmMtx_);
            kvmHookOk_ = ok;
            kvmHookReady_ = true;
        }
        kvmReadyCv_.notify_all();

        if (ok) {
            MSG msg{};
            while (kvmActive_.load() && alive_.load() && GetMessageW(&msg, nullptr, 0, 0) > 0) {
                if (msg.message == WM_APP + 1 && kvmActive_.load()) {
                    SetCursorPos(kvmAnchorX_.load(), kvmAnchorY_.load());
                    continue;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        if (hKb) UnhookWindowsHookEx(hKb);
        if (hMs) UnhookWindowsHookEx(hMs);
        kvmForwardedVks_.clear();
        WinHostSender* expected = this;
        s_kvmOwner_.compare_exchange_strong(expected, nullptr);
        kvmHookTid_.store(0);
    }

    void ProcessControlBytes(std::vector<uint8_t>& acc) {
        // 接收端回传格式：与 SecDisplayReceiver.cpp 完全对称（无 4B 长度前缀）
        //   0x02: 1B 关键帧请求
        //   0x04: 12B [0x04][x f32 BE][y f32 BE][buttons u8][wheel i16 BE]
        //   0x07: 13B [0x07][presentP95 u16][sourceP95 u16][decFps10 u16][presDrop u16][pacedDrop u16][res u16]
        //   0x09: 7B  [0x09][vk u16][scan u16][down u8][flags u8]
        size_t pos = 0;
        while (pos < acc.size()) {
            uint8_t t = acc[pos];
            if (t == kTypeKeyframeReq) {
                forceKeyframe_.store(true);
                pos += 1;
            } else if (t == kTypeMouseInput) {
                if (acc.size() - pos < 12) break;
                float x = RdF32BE(acc.data() + pos + 1);
                float y = RdF32BE(acc.data() + pos + 5);
                uint8_t buttons = acc[pos + 9];
                int16_t wheel = (int16_t)RdU16BE(acc.data() + pos + 10);
                InjectMouse(x, y, buttons, wheel);
                stats_.inputRecv++;
                pos += 12;
            } else if (t == kTypeKeyInput) {
                if (acc.size() - pos < 7) break;
                uint16_t vk = RdU16BE(acc.data() + pos + 1);
                uint16_t scan = RdU16BE(acc.data() + pos + 3);
                bool down = acc[pos + 5] != 0;
                uint8_t flags = acc[pos + 6];
                InjectKeyboard(vk, scan, down, flags);
                stats_.inputRecv++;
                pos += 7;
            } else if (t == kTypeFeedback) {
                if (acc.size() - pos < 13) break;
                uint16_t presentP95 = RdU16BE(acc.data() + pos + 1);
                uint16_t sourceP95  = RdU16BE(acc.data() + pos + 3);
                uint16_t presDrop   = RdU16BE(acc.data() + pos + 7);
                uint16_t pacedDrop  = RdU16BE(acc.data() + pos + 9);
                AdjustAdaptiveBitrate(presentP95, sourceP95, presDrop, pacedDrop);
                pos += 13;
            } else {
                // 未知控制字节跳过 1 字节同步恢复
                pos += 1;
            }
        }
        if (pos > 0) acc.erase(acc.begin(), acc.begin() + pos);
        if (acc.size() > 65536) acc.clear();
    }

    void NoteLocalCongestion(double latencyMs, bool queueDropped) {
        const double frameBudgetMs = 1000.0 / (double)std::max(24, reqFps_);
        const double slowThresh = std::max(26.0, frameBudgetMs * 1.6);
        ULONGLONG nowTick = GetTickCount64();

        int prevMbps = 0, nextMbps = 0, tgtMbps = 0;
        bool logDrop = false;
        {
            std::lock_guard<std::mutex> blk(bitrateMtx_);
            if (!queueDropped) {
                if (latencyMs <= slowThresh) {
                    localSlowStreak_ = 0;
                    return;
                }
                if (++localSlowStreak_ < 4) {
                    return;
                }
            }
            localSlowStreak_ = 0;
            if (nowTick - lastDownscaleTick_ < 900ULL) {
                return;
            }
            tgtMbps = targetMbps_.load();
            prevMbps = curMbps_.load();
            int minMbps = std::max(15, tgtMbps / 3);
            nextMbps = std::max(minMbps, (prevMbps * 4) / 5);
            if (nextMbps < prevMbps) {
                curMbps_.store(nextMbps);
                stats_.bitrateMbps = nextMbps;
                lastDownscaleTick_ = nowTick;
                lastLocalCongestionTick_ = nowTick;
                if (nowTick - lastCongestionLogTick_ >= 3000ULL) {
                    lastCongestionLogTick_ = nowTick;
                    logDrop = true;
                }
            } else {
                lastLocalCongestionTick_ = nowTick;
            }
        }
        if (logDrop) {
            char msg[160];
            snprintf(msg, sizeof(msg),
                     "WinHost: %s，动态下调码率 %d -> %d Mbps (目标 %dM)",
                     queueDropped ? "发送队列积压丢帧" : "编码/发送耗时偏高",
                     prevMbps, nextMbps, tgtMbps);
            EmitLog(msg);
        }
    }

    void AdjustAdaptiveBitrate(uint16_t presentP95, uint16_t sourceP95,
                               uint16_t presDrop, uint16_t pacedDrop) {
        ULONGLONG nowTick = GetTickCount64();
        int prevMbps = 0, nextMbps = 0, tgtMbps = 0;
        bool logDrop = false;
        {
            std::lock_guard<std::mutex> blk(bitrateMtx_);
            tgtMbps = targetMbps_.load();
            prevMbps = curMbps_.load();
            nextMbps = prevMbps;
            int minMbps = std::max(15, tgtMbps / 3);
            if (presDrop > 2 || pacedDrop > 2 || (presentP95 > sourceP95 + 25 && presentP95 > 45)) {
                if (nowTick - lastDownscaleTick_ >= 900ULL) {
                    nextMbps = std::max(minMbps, (int)(prevMbps * 0.78));
                    lastDownscaleTick_ = nowTick;
                }
                lastRemoteCongestionTick_ = nowTick;
                if (nextMbps < prevMbps && nowTick - lastCongestionLogTick_ >= 3000ULL) {
                    lastCongestionLogTick_ = nowTick;
                    logDrop = true;
                }
            } else if (presDrop == 0 && pacedDrop == 0 && prevMbps < tgtMbps) {
                // 本地发送拥塞或对端丢帧后保留 4 秒冷静期，避免码率在高低之间反复震荡
                if (nowTick - lastLocalCongestionTick_ >= 4000ULL &&
                    nowTick - lastRemoteCongestionTick_ >= 4000ULL) {
                    nextMbps = std::min(tgtMbps, prevMbps + std::max(2, tgtMbps / 15));
                }
            }
            curMbps_.store(nextMbps);
            stats_.bitrateMbps = nextMbps;
        }
        if (logDrop) {
            char msg[160];
            snprintf(msg, sizeof(msg),
                     "WinHost: Mac 副屏反馈拥塞 (p95=%u/%u drop=%u)，下调码率 %d -> %d Mbps",
                     (unsigned)presentP95, (unsigned)sourceP95, (unsigned)(presDrop + pacedDrop),
                     prevMbps, nextMbps);
            EmitLog(msg);
        }
    }

    // ---- 反向输入注入（Mac 副屏 → Windows 虚拟屏）----
    struct HeldKeyEntry {
        uint16_t vk;
        uint16_t scan;
        uint8_t  flags;
    };
    std::mutex inputMtx_;
    uint8_t prevMouseButtons_ = 0;
    std::map<uint64_t, HeldKeyEntry> heldKeys_;

    void InjectMouse(float rx, float ry, uint8_t buttons, int16_t wheel) {
        WinVddBounds b = vdd_.Bounds();
        if (b.width <= 0 || b.height <= 0) return;

        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
        int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        int vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (vw <= 1 || vh <= 1) return;

        double deskX = (double)b.left + std::clamp((double)rx, 0.0, (double)(b.width - 1));
        double deskY = (double)b.top  + std::clamp((double)ry, 0.0, (double)(b.height - 1));
        LONG normX = (LONG)std::clamp((deskX - vx) * 65535.0 / (double)(vw - 1), 0.0, 65535.0);
        LONG normY = (LONG)std::clamp((deskY - vy) * 65535.0 / (double)(vh - 1), 0.0, 65535.0);

        std::vector<INPUT> inputs;
        INPUT mv{};
        mv.type = INPUT_MOUSE;
        mv.mi.dx = normX;
        mv.mi.dy = normY;
        mv.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        inputs.push_back(mv);

        {
            std::lock_guard<std::mutex> ilk(inputMtx_);
            auto addBtn = [&](uint8_t mask, DWORD downFlag, DWORD upFlag) {
                bool was = (prevMouseButtons_ & mask) != 0;
                bool now = (buttons & mask) != 0;
                if (now == was) return;
                INPUT bi{};
                bi.type = INPUT_MOUSE;
                bi.mi.dx = normX;
                bi.mi.dy = normY;
                bi.mi.dwFlags = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | (now ? downFlag : upFlag);
                inputs.push_back(bi);
            };
            addBtn(0x01, MOUSEEVENTF_LEFTDOWN,   MOUSEEVENTF_LEFTUP);
            addBtn(0x02, MOUSEEVENTF_RIGHTDOWN,  MOUSEEVENTF_RIGHTUP);
            addBtn(0x04, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP);
            prevMouseButtons_ = buttons;
        }

        if (wheel != 0) {
            INPUT wi{};
            wi.type = INPUT_MOUSE;
            wi.mi.dx = normX;
            wi.mi.dy = normY;
            wi.mi.dwFlags = MOUSEEVENTF_WHEEL | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
            // Mac 发来的 wheel 正数为向下（SecDisplayReceiver 传给 Mac 时做了 -delta）；
            // Windows MOUSEEVENTF_WHEEL 正数向上，故取反还原
            wi.mi.mouseData = (DWORD)(-(int)wheel);
            inputs.push_back(wi);
        }

        SendInput((UINT)inputs.size(), inputs.data(), sizeof(INPUT));
    }

    void InjectKeyboard(uint16_t vk, uint16_t scan, bool down, uint8_t flags) {
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
            std::lock_guard<std::mutex> ilk(inputMtx_);
            uint64_t k = (vk != 0)
                ? (uint64_t)vk
                : (0x8000000000000000ULL | ((uint64_t)(flags & 0x01) << 32) | (uint64_t)scan);
            if (down) {
                heldKeys_[k] = HeldKeyEntry{ vk, scan, flags };
            } else {
                heldKeys_.erase(k);
            }
        }
        SendInput(1, &in, sizeof(INPUT));
    }

    void ReleaseAllInputs() {
        std::vector<INPUT> inputs;
        {
            std::lock_guard<std::mutex> ilk(inputMtx_);
            if (prevMouseButtons_ & 0x01) {
                INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_LEFTUP;
                inputs.push_back(bi);
            }
            if (prevMouseButtons_ & 0x02) {
                INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_RIGHTUP;
                inputs.push_back(bi);
            }
            if (prevMouseButtons_ & 0x04) {
                INPUT bi{}; bi.type = INPUT_MOUSE; bi.mi.dwFlags = MOUSEEVENTF_MIDDLEUP;
                inputs.push_back(bi);
            }
            prevMouseButtons_ = 0;

            for (const auto& kv : heldKeys_) {
                const HeldKeyEntry& e = kv.second;
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
            heldKeys_.clear();
        }
        if (!inputs.empty()) {
            SendInput((UINT)inputs.size(), inputs.data(), sizeof(INPUT));
        }
    }

    // ---- 光标位置与位图采集（Windows → Mac）----
    void CursorLoop() {
        HCURSOR lastCursor = nullptr;
        int lastX = -99999, lastY = -99999;
        bool lastVis = false;
        ULONGLONG lastSendMs = 0;

        while (alive_.load()) {
            Sleep(11);
            if (!stats_.clientConnected.load()) {
                lastCursor = nullptr;
                lastVis = false;
                continue;
            }
            CURSORINFO ci{};
            ci.cbSize = sizeof(ci);
            if (!GetCursorInfo(&ci)) continue;

            WinVddBounds b = vdd_.Bounds();
            bool vis = (ci.flags & CURSOR_SHOWING) &&
                       ci.ptScreenPos.x >= b.left && ci.ptScreenPos.x < b.left + b.width &&
                       ci.ptScreenPos.y >= b.top  && ci.ptScreenPos.y < b.top + b.height;

            float rx = (float)(ci.ptScreenPos.x - b.left);
            float ry = (float)(ci.ptScreenPos.y - b.top);
            ULONGLONG now = GetTickCount64();

            if (vis != lastVis || (vis && (ci.ptScreenPos.x != lastX || ci.ptScreenPos.y != lastY)) ||
                (now - lastSendMs >= 250)) {
                SendCursorPos(rx, ry, vis);
                lastX = ci.ptScreenPos.x;
                lastY = ci.ptScreenPos.y;
                lastVis = vis;
                lastSendMs = now;
            }

            if (vis && ci.hCursor && ci.hCursor != lastCursor) {
                int w = 0, h = 0, hx = 0, hy = 0;
                std::vector<uint8_t> bgra;
                if (ExtractCursorBgra(ci.hCursor, &w, &h, &hx, &hy, &bgra)) {
                    SendCursorImage(w, h, hx, hy, bgra);
                    lastCursor = ci.hCursor;
                }
            }
        }
    }

    static bool ExtractCursorBgra(HCURSOR hc, int* outW, int* outH, int* outHx, int* outHy,
                                  std::vector<uint8_t>* outBgra) {
        ICONINFO ii{};
        if (!GetIconInfo(hc, &ii)) return false;

        int w = 0, h = 0;
        BITMAP bm{};
        if (ii.hbmColor && GetObjectW(ii.hbmColor, sizeof(bm), &bm)) {
            w = bm.bmWidth;
            h = abs(bm.bmHeight);
        } else if (ii.hbmMask && GetObjectW(ii.hbmMask, sizeof(bm), &bm)) {
            w = bm.bmWidth;
            h = abs(bm.bmHeight) / 2;
        }
        if (w <= 0 || h <= 0 || w > 128 || h > 128) {
            if (ii.hbmColor) DeleteObject(ii.hbmColor);
            if (ii.hbmMask) DeleteObject(ii.hbmMask);
            return false;
        }

        HDC hdc = CreateCompatibleDC(nullptr);
        BITMAPINFO bmi{};
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        std::vector<uint8_t> pixels((size_t)w * (size_t)h * 4, 0);
        bool dibOk = false;
        if (ii.hbmColor) {
            if (GetDIBits(hdc, ii.hbmColor, 0, (UINT)h, pixels.data(), &bmi, DIB_RGB_COLORS) > 0) {
                dibOk = true;
                bool hasAlpha = false;
                for (size_t i = 3; i < pixels.size(); i += 4) {
                    if (pixels[i] != 0) { hasAlpha = true; break; }
                }
                if (!hasAlpha && ii.hbmMask) {
                    std::vector<uint8_t> mask((size_t)w * (size_t)h * 4, 0);
                    if (GetDIBits(hdc, ii.hbmMask, 0, (UINT)h, mask.data(), &bmi, DIB_RGB_COLORS) > 0) {
                        for (size_t i = 0; i < pixels.size(); i += 4) {
                            pixels[i + 3] = (mask[i] == 0) ? 255 : 0;
                        }
                    }
                }
            }
        } else if (ii.hbmMask) {
            // 单色光标：上半部分 AND 掩码，下半部分 XOR 掩码
            BITMAPINFO mbmi = bmi;
            mbmi.bmiHeader.biHeight = -(h * 2);
            std::vector<uint8_t> full((size_t)w * (size_t)h * 2 * 4, 0);
            if (GetDIBits(hdc, ii.hbmMask, 0, (UINT)(h * 2), full.data(), &mbmi, DIB_RGB_COLORS) > 0) {
                dibOk = true;
                size_t half = (size_t)w * (size_t)h * 4;
                for (size_t i = 0; i < half; i += 4) {
                    uint8_t andB = full[i];
                    uint8_t xorB = full[half + i];
                    if (andB == 0) {
                        uint8_t v = xorB ? 255 : 0;
                        pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 255;
                    } else if (xorB != 0) {
                        // 反色像素（I 型光标常见）：用白描边黑/半透白示意
                        pixels[i] = 20; pixels[i + 1] = 20; pixels[i + 2] = 20; pixels[i + 3] = 220;
                    } else {
                        pixels[i] = pixels[i + 1] = pixels[i + 2] = pixels[i + 3] = 0;
                    }
                }
            }
        }

        DeleteDC(hdc);
        if (ii.hbmColor) DeleteObject(ii.hbmColor);
        if (ii.hbmMask) DeleteObject(ii.hbmMask);
        if (!dibOk) return false;

        *outW = w;
        *outH = h;
        *outHx = (int)ii.xHotspot;
        *outHy = (int)ii.yHotspot;
        *outBgra = std::move(pixels);
        return true;
    }

    // ---- Annex-B → AVCC 转换与 SPS/PPS 缓存 ----
    struct AvccConverter {
        std::vector<uint8_t> sps;
        std::vector<uint8_t> pps;

        static size_t FindStartCode(const uint8_t* data, size_t size, size_t from, size_t* scLen) {
            for (size_t i = from; i + 2 < size; ++i) {
                if (data[i] == 0 && data[i + 1] == 0) {
                    if (data[i + 2] == 1) { *scLen = 3; return i; }
                    if (i + 3 < size && data[i + 2] == 0 && data[i + 3] == 1) { *scLen = 4; return i; }
                }
            }
            return size;
        }

        static void AppendAvccNal(std::vector<uint8_t>& out, const uint8_t* nal, size_t len) {
            if (len == 0) return;
            uint32_t n = (uint32_t)len;
            out.push_back((uint8_t)((n >> 24) & 0xFF));
            out.push_back((uint8_t)((n >> 16) & 0xFF));
            out.push_back((uint8_t)((n >> 8) & 0xFF));
            out.push_back((uint8_t)(n & 0xFF));
            out.insert(out.end(), nal, nal + len);
        }

        // 追加转换一个 Annex-B 样本到 outAvcc（不清空已有数据，支持多输出 AU 拼接）
        bool ConvertAppend(const uint8_t* annexb, size_t size, std::vector<uint8_t>& outAvcc, bool* outIsIdr) {
            if (!annexb || size < 4) return false;

            std::vector<std::pair<const uint8_t*, size_t>> nals;
            size_t scLen = 0;
            size_t pos = FindStartCode(annexb, size, 0, &scLen);
            if (pos >= size) return false;

            while (pos < size) {
                size_t nalStart = pos + scLen;
                size_t nextScLen = 0;
                size_t nextPos = FindStartCode(annexb, size, nalStart, &nextScLen);
                size_t nalLen = nextPos - nalStart;
                if (nalLen > 0) nals.emplace_back(annexb + nalStart, nalLen);
                pos = nextPos;
                scLen = nextScLen;
            }

            bool hasSps = false, hasPps = false, isIdr = false;
            for (auto& pr : nals) {
                uint8_t nt = pr.first[0] & 0x1F;
                if (nt == 7) { sps.assign(pr.first, pr.first + pr.second); hasSps = true; }
                else if (nt == 8) { pps.assign(pr.first, pr.first + pr.second); hasPps = true; }
                else if (nt == 5) { isIdr = true; }
            }
            if (isIdr && outIsIdr) *outIsIdr = true;

            if (isIdr && !hasSps && !sps.empty() && !pps.empty()) {
                AppendAvccNal(outAvcc, sps.data(), sps.size());
                AppendAvccNal(outAvcc, pps.data(), pps.size());
            } else if (isIdr && !hasPps && !pps.empty() && hasSps) {
                AppendAvccNal(outAvcc, pps.data(), pps.size());
            }

            const size_t before = outAvcc.size();
            for (auto& pr : nals) {
                AppendAvccNal(outAvcc, pr.first, pr.second);
            }
            return outAvcc.size() > before;
        }
    };

    // ---- Media Foundation H.264 编码器 ----
    struct MfH264Encoder {
        Microsoft::WRL::ComPtr<ID3D11Device> dev;
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
        Microsoft::WRL::ComPtr<IMFDXGIDeviceManager> dxgiMgr;
        Microsoft::WRL::ComPtr<ID3D11VideoDevice> vdev;
        Microsoft::WRL::ComPtr<ID3D11VideoContext> vctx;
        Microsoft::WRL::ComPtr<ID3D11VideoProcessorEnumerator> vpEnum;
        Microsoft::WRL::ComPtr<ID3D11VideoProcessor> vp;
        static constexpr int kNv12PoolSize = 6;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> bgraCopy;
        Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView> bgraInputView;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> nv12Pool[kNv12PoolSize];
        Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> nv12OutputViews[kNv12PoolSize];
        int poolIdx = 0;
        Microsoft::WRL::ComPtr<ID3D11Query> vpFence;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> stagingBgra;

        Microsoft::WRL::ComPtr<IMFTransform> mft;
        Microsoft::WRL::ComPtr<IMFMediaEventGenerator> evtGen;
        Microsoft::WRL::ComPtr<ICodecAPI> codecApi;
        bool isAsync = false;
        bool isHardware = false;
        int gpuConvFailStreak = 0;
        int needInput = 0;
        int w = 0, h = 0, fps = 60, mbps = 80;
        int lastAppliedMbps = 0;
        uint64_t frameIdx = 0;
        std::wstring friendlyName = L"--";
        AvccConverter avccConv;

        void Shutdown() {
            if (mft) {
                mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
                mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
            }
            codecApi.Reset();
            evtGen.Reset();
            mft.Reset();
            bgraInputView.Reset();
            bgraCopy.Reset();
            for (int i = 0; i < kNv12PoolSize; ++i) {
                nv12OutputViews[i].Reset();
                nv12Pool[i].Reset();
            }
            poolIdx = 0;
            vpFence.Reset();
            stagingBgra.Reset();
            vp.Reset();
            vpEnum.Reset();
            vctx.Reset();
            vdev.Reset();
            dxgiMgr.Reset();
            ctx.Reset();
            dev.Reset();
            gpuConvFailStreak = 0;
            needInput = 0;
        }

        bool Init(ID3D11Device* d3dDev, ID3D11DeviceContext* d3dCtx, int width, int height, int targetFps, int bitrateMbps, LogFn& logFn) {
            Shutdown();
            dev = d3dDev;
            ctx = d3dCtx;
            w = width;
            h = height;
            fps = targetFps;
            mbps = bitrateMbps;
            lastAppliedMbps = bitrateMbps;
            frameIdx = 0;

            UINT token = 0;
            if (SUCCEEDED(MFCreateDXGIDeviceManager(&token, &dxgiMgr))) {
                dxgiMgr->ResetDevice(dev.Get(), token);
            }

            // 开启 D3D11 多线程保护：Intel QSV Async MFT 内部工作线程会并发访问 D3D11 设备
            {
                Microsoft::WRL::ComPtr<ID3D11Multithread> mt;
                if (SUCCEEDED(dev.As(&mt)) && mt) {
                    mt->SetMultithreadProtected(TRUE);
                }
            }

            // 创建 GPU BGRA -> NV12 VideoProcessor
            if (SUCCEEDED(dev.As(&vdev)) && SUCCEEDED(ctx.As(&vctx))) {
                D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd{};
                cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
                cd.InputWidth = (UINT)w;
                cd.InputHeight = (UINT)h;
                cd.OutputWidth = (UINT)w;
                cd.OutputHeight = (UINT)h;
                cd.Usage = D3D11_VIDEO_USAGE_PLAYBACK_NORMAL;
                if (SUCCEEDED(vdev->CreateVideoProcessorEnumerator(&cd, &vpEnum))) {
                    vdev->CreateVideoProcessor(vpEnum.Get(), 0, &vp);
                }
            }

            D3D11_TEXTURE2D_DESC bd{};
            bd.Width = (UINT)w;
            bd.Height = (UINT)h;
            bd.MipLevels = 1;
            bd.ArraySize = 1;
            bd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            bd.SampleDesc.Count = 1;
            bd.Usage = D3D11_USAGE_DEFAULT;
            bd.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            if (FAILED(dev->CreateTexture2D(&bd, nullptr, &bgraCopy))) {
                if (logFn) logFn("WinHost: 创建 BGRA 缓冲纹理失败");
                return false;
            }

            D3D11_TEXTURE2D_DESC nd{};
            nd.Width = (UINT)w;
            nd.Height = (UINT)h;
            nd.MipLevels = 1;
            nd.ArraySize = 1;
            nd.Format = DXGI_FORMAT_NV12;
            nd.SampleDesc.Count = 1;
            nd.Usage = D3D11_USAGE_DEFAULT;
            nd.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
            for (int i = 0; i < kNv12PoolSize; ++i) {
                if (FAILED(dev->CreateTexture2D(&nd, nullptr, &nv12Pool[i]))) {
                    if (logFn) logFn("WinHost: 创建 NV12 纹理池失败");
                    return false;
                }
            }
            {
                D3D11_QUERY_DESC qd{ D3D11_QUERY_EVENT, 0 };
                if (FAILED(dev->CreateQuery(&qd, &vpFence))) {
                    vpFence.Reset();
                }
            }
            if (vp && vpEnum && vdev && vctx) {
                D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
                ivd.FourCC = 0;
                ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
                ivd.Texture2D.MipSlice = 0;
                if (FAILED(vdev->CreateVideoProcessorInputView(bgraCopy.Get(), vpEnum.Get(), &ivd, &bgraInputView))) {
                    bgraInputView.Reset();
                }
                for (int i = 0; i < kNv12PoolSize; ++i) {
                    D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
                    ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
                    ovd.Texture2D.MipSlice = 0;
                    if (FAILED(vdev->CreateVideoProcessorOutputView(nv12Pool[i].Get(), vpEnum.Get(), &ovd, &nv12OutputViews[i]))) {
                        nv12OutputViews[i].Reset();
                    }
                }
                RECT srcRc{ 0, 0, w, h };
                RECT dstRc{ 0, 0, w, h };
                vctx->VideoProcessorSetStreamFrameFormat(vp.Get(), 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
                vctx->VideoProcessorSetStreamAutoProcessingMode(vp.Get(), 0, FALSE);
                vctx->VideoProcessorSetStreamSourceRect(vp.Get(), 0, TRUE, &srcRc);
                vctx->VideoProcessorSetStreamDestRect(vp.Get(), 0, TRUE, &dstRc);
                vctx->VideoProcessorSetOutputTargetRect(vp.Get(), TRUE, &dstRc);
                D3D11_VIDEO_PROCESSOR_COLOR_SPACE inCs{};
                inCs.RGB_Range = 0;
                inCs.YCbCr_Matrix = 1;
                vctx->VideoProcessorSetStreamColorSpace(vp.Get(), 0, &inCs);
                D3D11_VIDEO_PROCESSOR_COLOR_SPACE outCs{};
                outCs.RGB_Range = 0;
                outCs.YCbCr_Matrix = 1;
                outCs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
                vctx->VideoProcessorSetOutputColorSpace(vp.Get(), &outCs);
            }

            MFT_REGISTER_TYPE_INFO outInfo{ MFMediaType_Video, MFVideoFormat_H264 };
            IMFActivate** acts = nullptr;
            UINT32 cnt = 0;
            HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER,
                                   MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_ASYNCMFT |
                                   MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                                   nullptr, &outInfo, &acts, &cnt);
            if (FAILED(hr) || cnt == 0) {
                if (acts) CoTaskMemFree(acts);
                if (logFn) logFn("WinHost: 未找到 H.264 编码器");
                return false;
            }

            bool ready = false;
            for (UINT32 i = 0; i < cnt && !ready; ++i) {
                LPWSTR nm = nullptr; UINT32 nml = 0;
                acts[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &nm, &nml);
                std::wstring candName = nm ? nm : L"H264 Encoder";
                if (nm) CoTaskMemFree(nm);

                Microsoft::WRL::ComPtr<IMFTransform> cand;
                if (FAILED(acts[i]->ActivateObject(IID_PPV_ARGS(&cand))) || !cand) continue;

                Microsoft::WRL::ComPtr<IMFAttributes> attr;
                bool candAsync = false;
                UINT32 d3d11Aware = 0;
                if (SUCCEEDED(cand->GetAttributes(&attr)) && attr) {
                    UINT32 a = 0;
                    attr->GetUINT32(MF_TRANSFORM_ASYNC, &a);
                    candAsync = (a != 0);
                    attr->GetUINT32(MF_SA_D3D11_AWARE, &d3d11Aware);
                    if (candAsync) {
                        if (FAILED(attr->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE))) continue;
                    }
                }

                bool hw = false;
                if (d3d11Aware && dxgiMgr) {
                    if (SUCCEEDED(cand->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)dxgiMgr.Get()))) {
                        hw = true;
                    }
                }

                // 设置输出类型 H.264（优先 High Profile，锐度更好）
                Microsoft::WRL::ComPtr<IMFMediaType> ot;
                MFCreateMediaType(&ot);
                ot->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                ot->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
                ot->SetUINT32(MF_MT_AVG_BITRATE, (UINT32)mbps * 1000000U);
                MFSetAttributeSize(ot.Get(), MF_MT_FRAME_SIZE, (UINT32)w, (UINT32)h);
                MFSetAttributeRatio(ot.Get(), MF_MT_FRAME_RATE, (UINT32)fps, 1);
                MFSetAttributeRatio(ot.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                ot->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                ot->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_High);
                if (FAILED(cand->SetOutputType(0, ot.Get(), 0))) {
                    ot->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
                    if (FAILED(cand->SetOutputType(0, ot.Get(), 0))) continue;
                }

                // 设置输入类型 NV12
                Microsoft::WRL::ComPtr<IMFMediaType> it;
                MFCreateMediaType(&it);
                it->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                it->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
                MFSetAttributeSize(it.Get(), MF_MT_FRAME_SIZE, (UINT32)w, (UINT32)h);
                MFSetAttributeRatio(it.Get(), MF_MT_FRAME_RATE, (UINT32)fps, 1);
                MFSetAttributeRatio(it.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                it->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                if (FAILED(cand->SetInputType(0, it.Get(), 0))) continue;

                // 低延迟编码参数：优先 PeakConstrainedVBR，兼顾静态文字锐度与动态带宽控制
                Microsoft::WRL::ComPtr<ICodecAPI> api;
                if (SUCCEEDED(cand.As(&api)) && api) {
                    VARIANT v{};
                    v.vt = VT_UI4;
                    v.ulVal = eAVEncCommonRateControlMode_PeakConstrainedVBR;
                    if (FAILED(api->SetValue(&CODECAPI_AVEncCommonRateControlMode, &v))) {
                        v.ulVal = eAVEncCommonRateControlMode_CBR;
                        api->SetValue(&CODECAPI_AVEncCommonRateControlMode, &v);
                    }
                    v.ulVal = (ULONG)mbps * 1000000UL;
                    api->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &v);
                    // 收紧峰值倍率到 1.25x，防止突发画面单帧码流尖峰塞满雷电/解码缓冲
                    int peakMbps = std::min(160, std::max(mbps + 10, (mbps * 5) / 4));
                    v.ulVal = (ULONG)peakMbps * 1000000UL;
                    api->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &v);
                    // 1 秒 GOP，丢包/背压触发补关键帧时最快恢复连贯画面
                    v.ulVal = (ULONG)std::max(24, fps);
                    api->SetValue(&CODECAPI_AVEncMPVGOPSize, &v);
                    v.ulVal = 0;
                    api->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &v);
                    VARIANT vb{};
                    vb.vt = VT_BOOL; vb.boolVal = VARIANT_TRUE;
                    api->SetValue(&CODECAPI_AVLowLatencyMode, &vb);
                }

                if (candAsync) {
                    if (FAILED(cand.As(&evtGen)) || !evtGen) continue;
                }

                cand->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
                cand->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

                mft = cand;
                codecApi = api;
                isAsync = candAsync;
                isHardware = hw;
                friendlyName = candName + (hw ? L" (硬件)" : L" (软件)");
                needInput = isAsync ? 0 : 1;
                ready = true;
            }

            for (UINT32 i = 0; i < cnt; ++i) acts[i]->Release();
            CoTaskMemFree(acts);

            if (!ready) {
                if (logFn) logFn("WinHost: 所有 H.264 编码器初始化失败");
                return false;
            }
            if (logFn) {
                char msg[256];
                int n = WideCharToMultiByte(CP_UTF8, 0, friendlyName.c_str(), -1, nullptr, 0, nullptr, nullptr);
                std::string u8(n > 0 ? (size_t)n - 1 : 0, '\0');
                if (n > 1) WideCharToMultiByte(CP_UTF8, 0, friendlyName.c_str(), -1, &u8[0], n, nullptr, nullptr);
                snprintf(msg, sizeof(msg), "WinHost: 编码器就绪 %dx%d@%d %dMbps -> %s",
                         w, h, fps, mbps, u8.c_str());
                logFn(msg);
            }
            return true;
        }

        void UpdateBitrateIfChanged(int newMbps) {
            if (newMbps == lastAppliedMbps || !codecApi) return;
            VARIANT v{};
            v.vt = VT_UI4;
            v.ulVal = (ULONG)newMbps * 1000000UL;
            if (SUCCEEDED(codecApi->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &v))) {
                VARIANT vmax{};
                vmax.vt = VT_UI4;
                int peakMbps = std::min(160, std::max(newMbps + 10, (newMbps * 5) / 4));
                vmax.ulVal = (ULONG)peakMbps * 1000000UL;
                codecApi->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &vmax);
                lastAppliedMbps = newMbps;
            }
        }

        ID3D11Texture2D* ConvertBgraToNv12(ID3D11Texture2D* bgraTex, WinHostStats* stats = nullptr, LogFn* logFn = nullptr) {
            if (!vp || !vpEnum || !vdev || !vctx || !bgraCopy) return nullptr;
            int slot = poolIdx;
            poolIdx = (poolIdx + 1) % kNv12PoolSize;
            ID3D11Texture2D* targetNv12 = nv12Pool[slot].Get();
            if (!targetNv12) return nullptr;

            // 先从 DXGI Duplication 表面拷贝到稳定 DEFAULT 纹理，确保采集纹理不与 VideoProcessor 并发冲突
            if (bgraTex != bgraCopy.Get()) {
                ctx->CopyResource(bgraCopy.Get(), bgraTex);
            }

            Microsoft::WRL::ComPtr<ID3D11VideoProcessorInputView> tmpIv;
            ID3D11VideoProcessorInputView* ivPtr = bgraInputView.Get();
            if (!ivPtr) {
                D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC ivd{};
                ivd.FourCC = 0;
                ivd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
                ivd.Texture2D.MipSlice = 0;
                if (FAILED(vdev->CreateVideoProcessorInputView(bgraCopy.Get(), vpEnum.Get(), &ivd, &tmpIv))) return nullptr;
                ivPtr = tmpIv.Get();
            }

            Microsoft::WRL::ComPtr<ID3D11VideoProcessorOutputView> tmpOv;
            ID3D11VideoProcessorOutputView* ovPtr = nv12OutputViews[slot].Get();
            if (!ovPtr) {
                D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC ovd{};
                ovd.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
                ovd.Texture2D.MipSlice = 0;
                if (FAILED(vdev->CreateVideoProcessorOutputView(targetNv12, vpEnum.Get(), &ovd, &tmpOv))) return nullptr;
                ovPtr = tmpOv.Get();
            }

            D3D11_VIDEO_PROCESSOR_STREAM st{};
            st.Enable = TRUE;
            st.pInputSurface = ivPtr;
            HRESULT hr = vctx->VideoProcessorBlt(vp.Get(), ovPtr, 0, 1, &st);
            if (FAILED(hr)) return nullptr;
            // 等待 VEBOX VideoProcessorBlt 在 GPU 上真实写完再喂给 VDBOX QSV MFT，
            // 仅调用 Flush() 不等待跨引擎完成，会导致画面出现随机白/黑短横线噪点。
            if (vpFence) {
                ctx->End(vpFence.Get());
                ctx->Flush();
                bool done = false;
                for (int spin = 0; spin < 100; ++spin) {
                    HRESULT qhr = ctx->GetData(vpFence.Get(), nullptr, 0, 0);
                    if (qhr == S_OK) { done = true; break; }
                    if (qhr != S_FALSE) break;
                    if (spin < 20) Sleep(0); else Sleep(1);
                }
                if (!done) {
                    // D3D11 规定同一 query 在未返回 S_OK 前不能再次 End，超时必须销毁并重建 query
                    vpFence.Reset();
                    D3D11_QUERY_DESC qd{ D3D11_QUERY_EVENT, 0 };
                    if (dev && FAILED(dev->CreateQuery(&qd, &vpFence))) {
                        vpFence.Reset();
                    }
                    if (stats) {
                        uint64_t cnt = ++stats->fenceTimeouts;
                        if ((cnt == 1 || cnt % 30 == 0) && logFn && *logFn) {
                            char msg[128];
                            snprintf(msg, sizeof(msg), "WinHost: VideoProcessor 围栏等待超时，已重建查询对象 (累计 %llu 次)",
                                     (unsigned long long)cnt);
                            (*logFn)(msg);
                        }
                    }
                }
            } else {
                ctx->Flush();
            }
            return targetNv12;
        }

        // 从 BGRA 纹理经 CPU 转为 NV12 系统内存（仅软件 MFT 兜底用）
        bool BuildCpuNv12Buffer(ID3D11Texture2D* bgraTex, Microsoft::WRL::ComPtr<IMFMediaBuffer>& outBuf) {
            if (!stagingBgra) {
                D3D11_TEXTURE2D_DESC sd{};
                sd.Width = (UINT)w; sd.Height = (UINT)h;
                sd.MipLevels = 1; sd.ArraySize = 1;
                sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
                sd.SampleDesc.Count = 1;
                sd.Usage = D3D11_USAGE_STAGING;
                sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                if (FAILED(dev->CreateTexture2D(&sd, nullptr, &stagingBgra))) return false;
            }
            ctx->CopyResource(stagingBgra.Get(), bgraTex);
            D3D11_MAPPED_SUBRESOURCE mapped{};
            if (FAILED(ctx->Map(stagingBgra.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return false;

            size_t uvW = (size_t)((w + 1) & ~1);
            size_t uvH = (size_t)((h + 1) / 2);
            DWORD nv12Size = (DWORD)((size_t)w * (size_t)h + uvW * uvH);
            if (FAILED(MFCreateMemoryBuffer(nv12Size, &outBuf)) || !outBuf) {
                ctx->Unmap(stagingBgra.Get(), 0);
                return false;
            }
            BYTE* dst = nullptr;
            if (FAILED(outBuf->Lock(&dst, nullptr, nullptr)) || !dst) {
                ctx->Unmap(stagingBgra.Get(), 0);
                return false;
            }
            uint8_t* yPlane = dst;
            uint8_t* uvPlane = dst + (size_t)w * (size_t)h;
            for (int y = 0; y < h; ++y) {
                const uint8_t* row = (const uint8_t*)mapped.pData + (size_t)y * mapped.RowPitch;
                uint8_t* yRow = yPlane + (size_t)y * (size_t)w;
                for (int x = 0; x < w; ++x) {
                    int b = row[x * 4 + 0];
                    int g = row[x * 4 + 1];
                    int r = row[x * 4 + 2];
                    int Y = ((47 * r + 157 * g + 16 * b + 128) >> 8) + 16;
                    yRow[x] = (uint8_t)std::clamp(Y, 16, 235);
                    if ((y & 1) == 0 && (x & 1) == 0 && (size_t)x + 1 < uvW) {
                        int U = ((-26 * r - 87 * g + 112 * b + 128) >> 8) + 128;
                        int V = ((112 * r - 102 * g - 10 * b + 128) >> 8) + 128;
                        size_t uvIdx = (size_t)(y / 2) * uvW + (size_t)x;
                        uvPlane[uvIdx + 0] = (uint8_t)std::clamp(U, 16, 240);
                        uvPlane[uvIdx + 1] = (uint8_t)std::clamp(V, 16, 240);
                    }
                }
            }
            outBuf->Unlock();
            outBuf->SetCurrentLength(nv12Size);
            ctx->Unmap(stagingBgra.Get(), 0);
            return true;
        }

        bool DrainOneOutput(std::vector<uint8_t>& outAvcc, bool* outIsIdr) {
            MFT_OUTPUT_DATA_BUFFER odb{};
            odb.dwStreamID = 0;
            MFT_OUTPUT_STREAM_INFO osi{};
            if (FAILED(mft->GetOutputStreamInfo(0, &osi))) return false;
            Microsoft::WRL::ComPtr<IMFSample> localSample;
            if (!(osi.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
                MFCreateSample(&localSample);
                Microsoft::WRL::ComPtr<IMFMediaBuffer> mb;
                MFCreateMemoryBuffer(std::max<DWORD>(osi.cbSize, (DWORD)(w * h)), &mb);
                localSample->AddBuffer(mb.Get());
                odb.pSample = localSample.Get();
            }
            DWORD status = 0;
            HRESULT hr = mft->ProcessOutput(0, 1, &odb, &status);
            if (odb.pEvents) odb.pEvents->Release();
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
                Microsoft::WRL::ComPtr<IMFMediaType> nt;
                if (SUCCEEDED(mft->GetOutputAvailableType(0, 0, &nt))) {
                    mft->SetOutputType(0, nt.Get(), 0);
                }
                if (localSample == nullptr && odb.pSample) odb.pSample->Release();
                return false;
            }
            if (FAILED(hr) || !odb.pSample) {
                if (localSample == nullptr && odb.pSample) odb.pSample->Release();
                return false;
            }

            Microsoft::WRL::ComPtr<IMFMediaBuffer> buf;
            bool ok = false;
            if (SUCCEEDED(odb.pSample->ConvertToContiguousBuffer(&buf)) && buf) {
                BYTE* p = nullptr;
                DWORD len = 0;
                if (SUCCEEDED(buf->Lock(&p, nullptr, &len)) && p && len > 0) {
                    ok = avccConv.ConvertAppend(p, len, outAvcc, outIsIdr);
                    buf->Unlock();
                }
            }
            if (localSample == nullptr && odb.pSample) odb.pSample->Release();
            return ok;
        }

        bool EncodeTexture(ID3D11Texture2D* bgraTex, bool forceIdr, const std::atomic<bool>& aliveFlag,
                           std::vector<uint8_t>& outAvcc, bool* outIsIdr, LogFn* logFn = nullptr, WinHostStats* stats = nullptr) {
            outAvcc.clear();
            if (outIsIdr) *outIsIdr = false;
            if (!mft) return false;

            if (isAsync && evtGen) {
                // 非阻塞排空挂起事件（最长 ~80ms），严禁阻塞 GetEvent(0) 防止 Stop() 死锁；
                // 期间吐出的遗留 AU 直接并入 outAvcc，避免丢 P 帧引起花屏。
                for (int k = 0; k < 80 && needInput == 0 && aliveFlag.load(); ++k) {
                    Microsoft::WRL::ComPtr<IMFMediaEvent> ev;
                    HRESULT ehr = evtGen->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev);
                    if (ehr == MF_E_NO_EVENTS_AVAILABLE) {
                        Sleep(1);
                        continue;
                    }
                    if (FAILED(ehr) || !ev) break;
                    MediaEventType met = MEUnknown;
                    ev->GetType(&met);
                    if (met == METransformNeedInput) ++needInput;
                    else if (met == METransformHaveOutput) {
                        DrainOneOutput(outAvcc, outIsIdr);
                    }
                }
                if (needInput <= 0) return !outAvcc.empty();
            }

            Microsoft::WRL::ComPtr<IMFSample> inSample;
            MFCreateSample(&inSample);
            bool usedGpuSurface = false;
            if (isHardware) {
                if (ID3D11Texture2D* nv12Surf = ConvertBgraToNv12(bgraTex, stats, logFn)) {
                    gpuConvFailStreak = 0;
                    Microsoft::WRL::ComPtr<IMFMediaBuffer> buf;
                    if (SUCCEEDED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), nv12Surf, 0, FALSE, &buf))) {
                        Microsoft::WRL::ComPtr<IMF2DBuffer> b2d;
                        if (SUCCEEDED(buf.As(&b2d))) {
                            DWORD clen = 0;
                            b2d->GetContiguousLength(&clen);
                            buf->SetCurrentLength(clen);
                        }
                        inSample->AddBuffer(buf.Get());
                        usedGpuSurface = true;
                    }
                }
            }
            if (!usedGpuSurface) {
                if (isHardware) {
                    ++gpuConvFailStreak;
                    // 仅当 VideoProcessor 本身未就绪或连续多次失败才永久切回 CPU，避免单次瞬时失败永久降级
                    if (!vp || gpuConvFailStreak >= 10) {
                        if (logFn && *logFn) {
                            (*logFn)("WinHost: GPU BGRA->NV12 转换连续不可用，回落 CPU NV12");
                        }
                        isHardware = false;
                    }
                }
                Microsoft::WRL::ComPtr<IMFMediaBuffer> buf;
                if (!BuildCpuNv12Buffer(bgraTex, buf)) return !outAvcc.empty();
                inSample->AddBuffer(buf.Get());
            }

            LONGLONG dur = 10000000LL / std::max(1, fps);
            LONGLONG pts = (LONGLONG)frameIdx * dur;
            ++frameIdx;
            inSample->SetSampleTime(pts);
            inSample->SetSampleDuration(dur);

            if (forceIdr && codecApi) {
                VARIANT v{};
                v.vt = VT_UI4;
                v.ulVal = 1;
                codecApi->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &v);
            }

            if (FAILED(mft->ProcessInput(0, inSample.Get(), 0))) return !outAvcc.empty();
            if (isAsync) --needInput;

            if (isAsync && evtGen) {
                for (int tries = 0; tries < 40 && aliveFlag.load(); ++tries) {
                    Microsoft::WRL::ComPtr<IMFMediaEvent> ev;
                    HRESULT ehr = evtGen->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev);
                    if (ehr == MF_E_NO_EVENTS_AVAILABLE) {
                        if (!outAvcc.empty()) return true;
                        Sleep(1);
                        continue;
                    }
                    if (FAILED(ehr) || !ev) break;
                    MediaEventType met = MEUnknown;
                    ev->GetType(&met);
                    if (met == METransformNeedInput) {
                        ++needInput;
                        if (tries > 6 && needInput > 0) {
                            return !outAvcc.empty();
                        }
                    } else if (met == METransformHaveOutput) {
                        DrainOneOutput(outAvcc, outIsIdr);
                    }
                }
                return !outAvcc.empty();
            }

            DrainOneOutput(outAvcc, outIsIdr);
            return !outAvcc.empty();
        }
    };

    void CaptureEncodeLoop() {
        HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        bool didCo = SUCCEEDED(co);

        int initFailStreak = 0;
        auto backoffSleep = [&](const char* reason, HRESULT errHr) {
            ++initFailStreak;
            if (initFailStreak == 1 || initFailStreak % 20 == 0) {
                char msg[224];
                snprintf(msg, sizeof(msg), "WinHost: %s (hr=0x%08X, 第%d次)",
                         reason, (unsigned int)errHr, initFailStreak);
                EmitLog(msg);
            }
            int ms = (initFailStreak <= 2) ? 300 : (initFailStreak <= 5 ? 1000 : (initFailStreak <= 10 ? 3000 : 5000));
            for (int slept = 0; slept < ms && alive_.load(); slept += 100) Sleep(100);
        };

        while (alive_.load()) {
            if (displayReconcilePending_.exchange(false)) {
                bool wake = displayWakeInternal_.exchange(false);
                bool cd = false;
                if (vdd_.ReconcileExtendedTopology(&cd, wake)) {
                    forceKeyframe_.store(true);
                } else if (cd) {
                    if (wake) displayWakeInternal_.store(true);
                    displayReconcilePending_.store(true);
                }
            }
            WinVddBounds b = vdd_.RefreshBounds();
            if (b.width <= 0 || b.height <= 0) {
                backoffSleep("等待虚拟屏就绪", S_OK);
                continue;
            }

            Microsoft::WRL::ComPtr<IDXGIFactory1> fac;
            HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&fac));
            if (FAILED(hr)) {
                backoffSleep("CreateDXGIFactory1 失败", hr);
                continue;
            }

            Microsoft::WRL::ComPtr<IDXGIAdapter1> ad;
            Microsoft::WRL::ComPtr<IDXGIOutput> out;
            if (!vdd_.FindDxgiOutput(fac.Get(), ad, out)) {
                backoffSleep("未找到虚拟屏 DXGI 输出", S_FALSE);
                continue;
            }

            Microsoft::WRL::ComPtr<ID3D11Device> dev;
            Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
            D3D_FEATURE_LEVEL lv{};
            hr = D3D11CreateDevice(ad.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION, &dev, &lv, &ctx);
            if (FAILED(hr) || !dev) {
                backoffSleep("D3D11CreateDevice 失败", hr);
                continue;
            }

            Microsoft::WRL::ComPtr<IDXGIOutput1> out1;
            Microsoft::WRL::ComPtr<IDXGIOutputDuplication> dup;
            hr = out.As(&out1);
            if (SUCCEEDED(hr)) hr = out1->DuplicateOutput(dev.Get(), &dup);
            if (FAILED(hr) || !dup) {
                backoffSleep("DXGI DuplicateOutput 失败", hr);
                continue;
            }

            DXGI_OUTPUT_DESC od{};
            out->GetDesc(&od);
            int capW = (int)(od.DesktopCoordinates.right - od.DesktopCoordinates.left);
            int capH = (int)(od.DesktopCoordinates.bottom - od.DesktopCoordinates.top);
            if (capW <= 0 || capH <= 0) { capW = b.width; capH = b.height; }

            stats_.width = capW;
            stats_.height = capH;
            int encFps = ClampHz(b.hz, reqFps_);
            stats_.fps = encFps;

            MfH264Encoder enc;
            if (!enc.Init(dev.Get(), ctx.Get(), capW, capH, encFps, curMbps_.load(), logFn_)) {
                backoffSleep("H.264 编码器初始化失败", E_FAIL);
                continue;
            }
            {
                std::lock_guard<std::mutex> lk(stats_.infoMtx);
                stats_.encoderName = enc.friendlyName;
            }
            if (stats_.clientConnected.load()) {
                SendSessionHeader(capW, capH, encFps);
            }

            LARGE_INTEGER qpf{};
            QueryPerformanceFrequency(&qpf);
            ULONGLONG lastSessTick = GetTickCount64();
            ULONGLONG lastStatTick = lastSessTick;
            uint64_t lastStatSent = stats_.framesSent.load();
            uint64_t lastStatBytes = stats_.bytesSent.load();
            bool firstFrame = true;
            bool hasCachedBgra = false;
            int encFailStreak = 0;
            int badFormatCount = 0;
            bool sessionHealthy = false;
            bool needBackoff = false;
            const char* rebuildReason = "采集/编码上下文重建";
            HRESULT rebuildHr = S_OK;

            while (alive_.load()) {
                if (displayReconcilePending_.exchange(false)) {
                    bool wake = displayWakeInternal_.exchange(false);
                    bool cd = false;
                    if (vdd_.ReconcileExtendedTopology(&cd, wake)) {
                        forceKeyframe_.store(true);
                        break;
                    } else if (cd) {
                        if (wake) displayWakeInternal_.store(true);
                        displayReconcilePending_.store(true);
                    }
                }
                enc.UpdateBitrateIfChanged(curMbps_.load());
                {
                    ULONGLONG nowStat = GetTickCount64();
                    if (nowStat - lastStatTick >= 5000) {
                        double dt = (double)(nowStat - lastStatTick) / 1000.0;
                        uint64_t curSent = stats_.framesSent.load();
                        uint64_t curBytes = stats_.bytesSent.load();
                        double fpsNow = (double)(curSent - lastStatSent) / dt;
                        double mbpsNow = (double)(curBytes - lastStatBytes) * 8.0 / dt / 1e6;
                        lastStatTick = nowStat;
                        lastStatSent = curSent;
                        lastStatBytes = curBytes;
                        if (stats_.clientConnected.load()) {
                            ULONGLONG lastTx = stats_.lastSentTick.load();
                            unsigned long long ageMs = lastTx ? (unsigned long long)(nowStat - lastTx) : 0ULL;
                            char msg[256];
                            snprintf(msg, sizeof(msg),
                                     "WinHost: %dx%d  %.1f fps  %.1f Mbps (动态 %dM / 目标 %dM)  编码 %.2f ms  距上帧 %llu ms  失败 %llu  围栏超时 %llu  光标 %llu  输入 %llu",
                                     capW, capH, fpsNow, mbpsNow, curMbps_.load(), targetMbps_.load(), stats_.lastEncMs.load(),
                                     ageMs,
                                     (unsigned long long)stats_.encodeFail.load(),
                                     (unsigned long long)stats_.fenceTimeouts.load(),
                                     (unsigned long long)stats_.cursorSent.load(),
                                     (unsigned long long)stats_.inputRecv.load());
                            EmitLog(msg);
                        }
                    }
                }

                DXGI_OUTDUPL_FRAME_INFO fi{};
                Microsoft::WRL::ComPtr<IDXGIResource> res;
                hr = dup->AcquireNextFrame(16, &fi, &res);

                if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
                    if (!sessionHealthy) {
                        sessionHealthy = true;
                        initFailStreak = 0;
                    }
                    if (stats_.clientConnected.load()) {
                        if (forceKeyframe_.load() && hasCachedBgra && enc.bgraCopy) {
                            forceKeyframe_.store(false);
                            uint64_t capUs = NowMicros();
                            std::vector<uint8_t> avcc;
                            bool isIdr = false;
                            if (enc.EncodeTexture(enc.bgraCopy.Get(), true, alive_, avcc, &isIdr, &logFn_, &stats_) && !avcc.empty()) {
                                encFailStreak = 0;
                                stats_.framesEncoded++;
                                EnqueueVideoAvcc(std::move(avcc), capUs, isIdr);
                                if (!isIdr) forceKeyframe_.store(true);
                                continue;
                            } else {
                                stats_.encodeFail++;
                                forceKeyframe_.store(true);
                                if (++encFailStreak >= 30) {
                                    EmitLog("WinHost: 静止桌面补关键帧连续失败 30 次，重建采集与编码器");
                                    needBackoff = true;
                                    rebuildReason = "静止桌面补关键帧连续失败";
                                    rebuildHr = E_FAIL;
                                    break;
                                }
                            }
                        }
                        ULONGLONG nowTick = GetTickCount64();
                        if (nowTick - lastSessTick >= 5000) {
                            lastSessTick = nowTick;
                            SendSessionHeader(capW, capH, encFps);
                        }
                        uint64_t nowUs = NowMicros();
                        uint64_t prevUs = lastPayloadUs_.load();
                        // 静止桌面绝不重复发送同一帧 P 帧（QSV P 帧含非零残差/运动矢量，重复喂给解码器会叠加漂移出彩斑与噪点），
                        // 仅发 13 字节 0x06 心跳维持 TCP 链路活性。
                        if (prevUs == 0 || nowUs - prevUs >= 80000ULL) {
                            SendHeartbeat();
                            lastPayloadUs_.store(nowUs);
                        }
                    }
                    continue;
                }

                if (hr == DXGI_ERROR_ACCESS_LOST || FAILED(hr)) {
                    displayReconcilePending_.store(true);
                    needBackoff = true;
                    rebuildReason = "DXGI 输出上下文变更";
                    rebuildHr = hr;
                    break;
                }

                Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
                res.As(&tex);
                bool hasImage = (firstFrame || fi.LastPresentTime.QuadPart != 0 || fi.AccumulatedFrames > 0);
                if (tex && hasImage) {
                    if (!sessionHealthy) {
                        sessionHealthy = true;
                        initFailStreak = 0;
                    }
                    firstFrame = false;
                    D3D11_TEXTURE2D_DESC td{};
                    tex->GetDesc(&td);
                    if ((int)td.Width != capW || (int)td.Height != capH) {
                        char msg[128];
                        snprintf(msg, sizeof(msg), "WinHost: 分辨率变更 %ux%u -> 重建采集编码", td.Width, td.Height);
                        EmitLog(msg);
                        dup->ReleaseFrame();
                        needBackoff = true;
                        rebuildReason = "虚拟屏分辨率变更重建";
                        rebuildHr = S_OK;
                        break;
                    }
                    if (td.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
                        if (++badFormatCount == 1 || badFormatCount % 120 == 0) {
                            char msg[160];
                            snprintf(msg, sizeof(msg),
                                     "WinHost: 采集像素格式非 BGRA8 (format=%u，请关闭虚拟屏 HDR)，跳过本帧",
                                     (unsigned int)td.Format);
                            EmitLog(msg);
                        }
                        dup->ReleaseFrame();
                        continue;
                    }
                    badFormatCount = 0;

                    bool needSend = stats_.clientConnected.load();
                    if (enc.bgraCopy && (needSend || !hasCachedBgra || forceKeyframe_.load())) {
                        ctx->CopyResource(enc.bgraCopy.Get(), tex.Get());
                        hasCachedBgra = true;
                    }
                    if (needSend) {
                        LARGE_INTEGER t0{}, t1{};
                        QueryPerformanceCounter(&t0);
                        uint64_t capUs = NowMicros();
                        bool wantIdr = forceKeyframe_.exchange(false);
                        std::vector<uint8_t> avcc;
                        bool isIdr = false;
                        ID3D11Texture2D* srcTex = enc.bgraCopy ? enc.bgraCopy.Get() : tex.Get();
                        if (enc.EncodeTexture(srcTex, wantIdr, alive_, avcc, &isIdr, &logFn_, &stats_) && !avcc.empty()) {
                            QueryPerformanceCounter(&t1);
                            double encMs = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / (double)qpf.QuadPart;
                            stats_.lastEncMs = encMs;
                            stats_.framesEncoded++;
                            encFailStreak = 0;
                            if (!wantIdr) {
                                NoteLocalCongestion(encMs, false);
                            }
                            if (wantIdr && !isIdr) {
                                forceKeyframe_.store(true);
                            }
                            EnqueueVideoAvcc(std::move(avcc), capUs, isIdr);
                        } else {
                            stats_.encodeFail++;
                            if (wantIdr) forceKeyframe_.store(true);
                            if (++encFailStreak >= 30) {
                                EmitLog("WinHost: 编码连续失败 30 次，重建采集与编码器");
                                dup->ReleaseFrame();
                                needBackoff = true;
                                rebuildReason = "编码连续失败";
                                rebuildHr = E_FAIL;
                                break;
                            }
                        }
                    }
                }
                dup->ReleaseFrame();
            }
            enc.Shutdown();
            if (needBackoff && alive_.load()) {
                backoffSleep(rebuildReason, rebuildHr);
            }
        }

        if (didCo) CoUninitialize();
    }
};

} // namespace secdisplay
