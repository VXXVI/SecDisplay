// AppUI.swift —— 菜单栏面板（SwiftUI）
//
// 只做展示与控制，不碰采集/编码/网络。所有数据来自引擎全局量，
// 由主线程每秒刷新一次，避免 UI 线程和采集线程互相阻塞。

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// 面板共享状态
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var connected = false
    @Published var fps: Double = 0
    @Published var encMs: Double = 0
    @Published var capMs: Double = 0
    @Published var mbps: Double = 0
    @Published var inFlight = 0
    @Published var dropped = 0
    /// 采集连续异常次数。>0 表示 SCK 采集异常、看护正在重试。
    @Published var captureRestarts = 0
    @Published var width = 0
    @Published var height = 0
    @Published var scale: Double = 1.0
    @Published var cursorHz: Double = 0
    @Published var presetName = "-"
    @Published var cursorImageOn = true
    @Published var logLine = ""
    @Published var resolutionIndex = 0
    /// 采集帧率 / 码率上限（面板可调，UserDefaults 持久化）
    static let captureHzOptions: [Double] = [40, 45, 50, 60]
    static let bitrateOptions: [Int] = [80, 120, 160, 200, 240]
    @Published var captureHzIndex = 2
    @Published var bitrateIndex = 2
    @Published var showGuide = true
    /// 刷新时置位，避免程序化改选中项触发重启
    var suppressResolutionChange = false

    // ---- 新增：链路与对端观测 ----
    /// 码率：当前生效值 / 目标上限
    @Published var bitrateNow = 0
    @Published var bitrateTarget = 0
    /// 码率控制健康度（>1 过载）
    @Published var health: Double = 0
    /// Windows 侧反馈（0x07）：呈现间隔 p95、解码 fps、非节拍丢帧
    @Published var clientFps: Double = 0
    @Published var clientPresentP95: Double = 0
    @Published var clientQueueMs: Double = 0
    @Published var clientPresentDrop = 0
    /// 采集通道描述（像素格式 / 并发路数）
    @Published var capturePath = "-"
    /// 累计发送帧数与运行时长
    @Published var totalSent: UInt64 = 0
    @Published var uptimeSec: Double = 0
    /// 对端地址
    @Published var peer = "-"
    @Published var senderRoleConflict: String? = nil
    @Published var screenCaptureDenied = false
    @Published var tccConflictWarning: String? = nil
    @Published var resumeFeedback: String? = nil
    /// 光标的发送计数（位置 / 图像）
    @Published var cursorPosSent = 0
    @Published var cursorImgSent = 0

    // ---- 雷电文件中转站 ----
    @Published var transferConnected = false
    @Published var transferStatus = "等待连接"
    @Published var transferHistory: [String] = []
    @Published var transferInboxPath = ""
    @Published var transferDropTargeted = false
    @Published var transferBusy = false
    @Published var transferProgress: Double = 0
    @Published var transferSpeed = ""
    @Published var transferLastRecvURL: URL? = nil
    @Published var transferLastRecvName = ""
    @Published var transferFeedbackKind = 0
    @Published var transferFeedbackTitle = ""
    @Published var transferFeedbackDetail = ""
    @Published var dropBoxPinned = true
    @Published var dropBoxHoverTargeted = false

    // ---- 角色模式与 Mac 副屏接收状态 ----
    @Published var isReceiverMode = false
    @Published var isMirrorMode = false
    @Published var switchingMessage: String? = nil
    @Published var winHost = "10.10.10.2"
    @Published var winHostDraft = ""
    @Published var allowedHostsDraft = ""
    @Published var localIPsSummary = "-"
    @Published var recvConnected = false
    @Published var recvStreaming = false
    @Published var recvKvmActive = false
    @Published var senderKvmActive = false
    @Published var recvListening = false
    @Published var recvListenerError: String? = nil
    @Published var recvRejectedPeer: String? = nil
    @Published var recvPeer = "-"
    @Published var recvWidth = 0
    @Published var recvHeight = 0
    @Published var recvFps = 0
    @Published var recvDecodeFps: Double = 0
    @Published var recvMbps: Double = 0
    @Published var recvSourceP95: Double = 0
    @Published var recvPresentP95: Double = 0
    @Published var recvDecoded: UInt64 = 0
    @Published var recvErrors: UInt64 = 0
    @Published var recvDropped: UInt64 = 0
    @Published var recvCursor: UInt64 = 0
    @Published var recvInput: UInt64 = 0
    @Published var recvUptimeSec: Double = 0
    @Published var recvDecoderName = "VideoToolbox (H.264 硬件)"
    private var draftsInitialized = false

    // 只保留 3 档：2x Retina 下分别对应 Windows 2880×1800 的 1:1、轻载和极轻载。
    // 其他分辨率不再暴露，避免选项过多且与 16:10 物理屏比例不一致导致黑边。
    static let resolutions: [(label: String, w: Int, h: Int, lw: Int, lh: Int)] = [
        ("2880 × 1800 · 2x 推荐", 2880, 1800, 1440, 900),
        ("2240 × 1400 · 2x 流畅", 2240, 1400, 1120, 700),
        ("1920 × 1200 · 2x 省资源", 1920, 1200, 960, 600),
    ]

    private init() {}

    /// 主线程每秒调用
    func refresh() {
        if !isRestartingResolution {
            isReceiverMode = (appRole == .receiver)
            isMirrorMode = (appDisplayMode == .mirror)
        }
        if winHost != winHostAddress {
            winHost = winHostAddress
        }
        if !draftsInitialized {
            draftsInitialized = true
            winHostDraft = winHostAddress
            allowedHostsDraft = UserDefaults.standard.string(forKey: "SecDisplayAllowedHost") ?? ""
            showGuide = (UserDefaults.standard.object(forKey: "SecDisplayShowGuide") as? Bool) ?? true
        }
        logLine = Log.currentPath

        if appRole == .receiver {
            let ips = MacReceiverClient.localIPv4Summaries()
            localIPsSummary = ips.isEmpty ? "-" : ips.prefix(2).map { "\($0.ip) (\($0.label))" }.joined(separator: " / ")
            if let snap = macReceiverClient?.snapshot() {
                recvConnected = snap.connected
                recvStreaming = snap.streaming
                recvKvmActive = snap.kvmActive
                recvListening = snap.listening
                recvListenerError = snap.listenerError
                recvRejectedPeer = snap.rejectedPeer
                recvPeer = snap.peer
                recvWidth = snap.width
                recvHeight = snap.height
                recvFps = snap.sessionFps
                recvDecodeFps = snap.decodeFps
                recvMbps = snap.mbps
                recvSourceP95 = snap.sourceP95
                recvPresentP95 = snap.presentP95
                recvDecoded = snap.decodedFrames
                recvErrors = snap.decodeErrors
                recvDropped = snap.droppedFrames
                recvCursor = snap.cursorRecv
                recvInput = snap.inputSent
                recvUptimeSec = snap.uptimeSec
                recvDecoderName = snap.decoderName
            }
            refreshTransferOnly()
            return
        }

        connected = sender?.connected ?? false
        senderKvmActive = kvmPassthrough.isActive
        fps = peakFps
        encMs = lastEncAvgMs
        capMs = lastCapAvgMs
        mbps = lastMbps
        inFlight = sender?.inFlight ?? 0
        dropped = sender?.dropped ?? 0
        let snap = currentVideoSizeSnapshot()
        width = snap.w
        height = snap.h
        scale = vdBackingScale
        cursorHz = cursor?.targetHz ?? 0
        cursorImageOn = !disableCursorImage
        presetName = mainPresetLabel()
        suppressResolutionChange = true
        resolutionIndex = AppModel.resolutions.firstIndex { $0.w == snap.w && $0.h == snap.h && $0.lw == snap.lw && $0.lh == snap.lh } ?? -1
        cfgStateLock.lock()
        let hzNow = cfg.captureHz
        let mbNow = cfg.bitrateMbps
        cfgStateLock.unlock()
        captureHzIndex = AppModel.captureHzOptions.enumerated()
            .min(by: { abs($0.element - hzNow) < abs($1.element - hzNow) })?.offset ?? 2
        bitrateIndex = AppModel.bitrateOptions.enumerated()
            .min(by: { abs($0.element - mbNow) < abs($1.element - mbNow) })?.offset ?? 2
        suppressResolutionChange = false

        // 链路与对端
        bitrateNow = rateCtl?.currentBitrate ?? cfg.bitrateMbps
        bitrateTarget = cfg.bitrateMbps
        health = rateCtl?.lastHealth ?? 0
        let fb = sender?.latestFeedback() ?? FeedbackSignals()
        clientFps = fb.decodeFps
        clientPresentP95 = fb.presentP95
        clientQueueMs = max(0, fb.presentP95 - fb.sourceP95)
        clientPresentDrop = fb.presentDrop
        // 采集通道显示实测格式。SCK 可能忽略 pixelFormat 仍给 BGRA，
        // 这时显示配置值会骗人（日志里那条「内存收益失效」的警告就白打了）。
        // 还没采到帧时显示请求值加问号，提示尚未确认。
        let wantName = pixelFormatChoice == "420v" ? "420v" : "BGRA"
        let code = cap?.actualFormatCode ?? 0
        // 四字符码还原成可读名：420v / BGRA / 未知
        let actual: String
        switch code {
        case 0:                 actual = "\(wantName)?"
        case 0x34323076:        actual = "420v"     // '420v'
        case 0x42475241:        actual = "BGRA"     // 'BGRA'
        default:
            let b = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
            actual = String(bytes: b, encoding: .ascii) ?? "未知"
        }
        capturePath = actual + " · " + (cap?.captureBackendLabel ?? "4 路")
        captureRestarts = cap?.captureRestartCount ?? 0
        totalSent = UInt64(max(0, sender?.totalSent ?? 0))
        uptimeSec = CFAbsoluteTimeGetCurrent() - appStartTime
        peer = sender?.peerDescription ?? "-"
        senderRoleConflict = sender?.roleConflictMessage
        screenCaptureDenied = isScreenCaptureDenied()
        if !screenCaptureDenied { resumeFeedback = nil }
        tccConflictWarning = currentTccConflictWarning()
        cursorPosSent = cursor?.sentCount ?? 0
        cursorImgSent = cursorImage?.sentCount ?? 0
        refreshTransferOnly()
    }

    func refreshTransferOnly() {
        let ts = transferService.snapshot()
        transferConnected = ts.connected
        transferStatus = ts.statusText
        transferHistory = ts.history
        transferInboxPath = ts.inboxPath
        transferBusy = ts.busy
        transferProgress = ts.progress
        transferSpeed = ts.speedText
        transferLastRecvURL = ts.lastReceivedURL
        transferLastRecvName = ts.lastReceivedName
        transferFeedbackKind = ts.feedbackKind
        transferFeedbackTitle = ts.feedbackTitle
        transferFeedbackDetail = ts.feedbackDetail
    }

    func applyCaptureHz(_ idx: Int) {
        guard idx >= 0, idx < Self.captureHzOptions.count else { return }
        let hz = Self.captureHzOptions[idx]
        guard applyStreamTuning(captureHz: hz, maxMbps: nil) else { return }
        captureHzIndex = idx
        UserDefaults.standard.set(hz, forKey: "SecDisplayCaptureHz")
        // 注意：这里必须取「全局 presetName」（main.swift 的 String?），
        // 不能用 AppModel.presetName（那是面板显示的标签，会被同名属性遮蔽）。
        UserDefaults.standard.set(currentPresetTag(), forKey: "SecDisplayTuningPreset")
    }

    func applyBitrateCap(_ idx: Int) {
        guard idx >= 0, idx < Self.bitrateOptions.count else { return }
        let mb = Self.bitrateOptions[idx]
        guard applyStreamTuning(captureHz: nil, maxMbps: mb) else { return }
        bitrateIndex = idx
        UserDefaults.standard.set(mb, forKey: "SecDisplayMaxMbps")
        UserDefaults.standard.set(currentPresetTag(), forKey: "SecDisplayTuningPreset")
    }

    func setShowGuide(_ on: Bool) {
        showGuide = on
        UserDefaults.standard.set(on, forKey: "SecDisplayShowGuide")
        Log.info(on ? "连接引导动画已开启" : "连接引导动画已关闭")
    }
}

private func mainPresetLabel() -> String {
    if ProcessInfo.processInfo.environment["SECDISPLAY_W"] != nil {
        return "自定义"
    }
    return presetName ?? "自定义"
}

/// 文件作用域读取全局 `presetName`（main.swift 的 String?）。
/// 在 AppModel 方法里直接写 `presetName` 会被 `@Published var presetName` 遮蔽，
/// 写入 UserDefaults 的会是面板显示标签（如「自定义」），启动时与全局 nil 比较恒 false。
private func currentPresetTag() -> String? { presetName }

private let accent = Color(red: 0.22, green: 0.55, blue: 0.96)

private struct StatRow: View {
    let label: String
    let value: String
    var mono = true
    /// 告警色：非 nil 时用该颜色覆盖（过载/失败指标用）
    var warn: Color? = nil
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(warn ?? .primary)
        }
    }
}

/// 小节标题，带细分隔线，让长面板可扫读
private struct SectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
        }
    }
}

private struct ModeChoiceButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let selected: Bool
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? accent : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? accent.opacity(0.14) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? accent.opacity(0.75) : Color.secondary.opacity(0.18), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private func fmtUptime(_ s: Double) -> String {
    let t = Int(max(0, s))
    if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) }
    return String(format: "%02d:%02d", t / 60, t % 60)
}

/// 「画质与性能」设置卡片。单独抽出成 View 是为了能离屏导图审阅
/// （ScrollView 离屏只渲染视口，整面板导图看不到下半部分）。
struct QualitySettingsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "画质与性能")
            VStack(spacing: 9) {
                if model.isMirrorMode {
                    HStack {
                        Text("画面源").foregroundStyle(.secondary)
                        Spacer()
                        Text("Mac 主屏 \(model.width)×\(model.height)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("分辨率").foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.resolutionIndex },
                            set: { idx in
                                guard !model.suppressResolutionChange, idx >= 0,
                                      idx < AppModel.resolutions.count else { return }
                                let r = AppModel.resolutions[idx]
                                restartWithResolution(r.w, r.h, r.lw, r.lh)
                            })) {
                            ForEach(Array(AppModel.resolutions.enumerated()), id: \.offset) { i, r in
                                Text(r.label).tag(i)
                            }
                            if model.resolutionIndex < 0 {
                                Text("自定义").tag(-1)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }
                HStack {
                    Text("采集帧率").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.captureHzIndex },
                        set: { model.applyCaptureHz($0) })) {
                        ForEach(Array(AppModel.captureHzOptions.enumerated()), id: \.offset) { i, hz in
                            Text("\(Int(hz)) fps").tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                HStack {
                    Text("码率上限").foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { model.bitrateIndex },
                        set: { model.applyBitrateCap($0) })) {
                        ForEach(Array(AppModel.bitrateOptions.enumerated()), id: \.offset) { i, mb in
                            Text("\(mb) Mbps").tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                Divider()
                Toggle("发送真实光标图像", isOn: Binding(
                    get: { model.cursorImageOn },
                    set: { on in
                        disableCursorImage = !on
                        if on { cursorImage?.start() }
                        Log.info(on ? "面板开启光标图像(0x05)" : "面板关闭光标图像(0x05)")
                    }))
                    .toggleStyle(.switch)
                if !model.isMirrorMode {
                    Toggle("连接时播放位置引导", isOn: Binding(
                        get: { model.showGuide },
                        set: { model.setShowGuide($0) }))
                        .toggleStyle(.switch)
                    HStack(spacing: 8) {
                        Button("播放连接引导") {
                            ConnectionGuideOverlay.shared.show(vdID: vd?.displayID ?? 0)
                        }
                        Spacer()
                        Text("帧率/码率即时生效")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        Text("帧率/码率即时生效，分辨率自动跟随 Mac 主屏")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.07))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatusView: View {
    @ObservedObject var model = AppModel.shared
    /// 标题栏遮挡的高度，由 showControlPanel 按窗口实际 contentLayoutRect 算出。
    /// 写死 28pt 不可靠：SwiftUI 自己可能已经从 NSHostingView 拿到安全区，
    /// 再叠一个 28 就变成 56pt 空白；反过来若没拿到，24pt 又不够。
    var topInset: CGFloat = 28

    private var healthText: String {
        String(format: "%.2f", model.health)
    }
    private var healthColor: Color? {
        if model.health >= 1.0 { return .red }
        if model.health >= 0.7 { return .orange }
        return nil
    }
    private var statusColor: Color {
        if model.isReceiverMode {
            return model.recvStreaming ? .green : (model.recvConnected ? .orange : .secondary)
        }
        return model.connected ? .green : .orange
    }
    private var statusText: String {
        if model.isReceiverMode {
            return model.recvStreaming ? "副屏接收中" : (model.recvConnected ? "已连 Windows" : "等待主控端")
        }
        return model.connected ? "已连接" : "等待接收端"
    }
    private var resolutionText: String {
        if model.isReceiverMode {
            return model.recvWidth > 0 ? "\(model.recvWidth)×\(model.recvHeight) @ \(model.recvFps)Hz" : "Win→Mac"
        }
        return model.scale > 1.5 ? "\(model.width)×\(model.height) · 2x" : "\(model.width)×\(model.height) · 1x"
    }

    var body: some View {
        // 窗口是 .fullSizeContentView + 透明标题栏，内容会从窗口最上沿开始画，
        // 正好压在红绿灯按钮上。用一个固定高度的占位把标题栏高度让出来 ——
        // 放在 ScrollView 外面，不会跟着滚走。
        // ignoresSafeArea 是为了让高度可控：否则 SwiftUI 可能再加一次安全区。
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                // 头部：图标 + 当前角色 + 连接状态胶囊
                HStack(spacing: 10) {
                    if let icon = NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    } else {
                        Image(systemName: "display")
                            .font(.title2)
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SecDisplay").font(.headline)
                        Text(model.isReceiverMode
                             ? "Mac 当副屏 · 接收 Windows"
                             : (model.isMirrorMode ? "Windows 当副屏 · 镜像主屏" : "Windows 当副屏 · 扩展屏幕"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 7, height: 7)
                            Text(statusText).font(.caption.weight(.medium))
                        }
                        Text(resolutionText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusColor.opacity(0.13)))
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.07))
                )

                // 投屏设置：选择哪台电脑当副屏 + 扩展 / 镜像显示模式
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "投屏与副屏设置")

                    VStack(alignment: .leading, spacing: 5) {
                        Text("哪台电脑当副屏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ModeChoiceButton(
                                title: "Windows 当副屏",
                                subtitle: "Mac 画面投到 Windows",
                                icon: "macbook.and.iphone",
                                selected: !model.isReceiverMode,
                                disabled: model.switchingMessage != nil
                            ) {
                                if appRole != .sender {
                                    model.isReceiverMode = false
                                    restartWithConfig(role: .sender, displayMode: appDisplayMode, host: model.winHost)
                                }
                            }
                            ModeChoiceButton(
                                title: "Mac 当副屏",
                                subtitle: "接收 Windows 画面",
                                icon: "display",
                                selected: model.isReceiverMode,
                                disabled: model.switchingMessage != nil
                            ) {
                                if appRole != .receiver {
                                    model.isReceiverMode = true
                                    restartWithConfig(role: .receiver, displayMode: appDisplayMode, host: model.winHost)
                                }
                            }
                        }
                    }

                    if !model.isReceiverMode {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("显示方式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ModeChoiceButton(
                                    title: "扩展屏幕",
                                    subtitle: "独立虚拟副屏，多出一块桌面",
                                    icon: "rectangle.split.2x1",
                                    selected: !model.isMirrorMode,
                                    disabled: model.switchingMessage != nil
                                ) {
                                    if appDisplayMode != .extend {
                                        model.isMirrorMode = false
                                        restartWithConfig(role: .sender, displayMode: .extend, host: model.winHost)
                                    }
                                }
                                ModeChoiceButton(
                                    title: "镜像主屏",
                                    subtitle: "同步显示 Mac 主屏画面",
                                    icon: "rectangle.on.rectangle",
                                    selected: model.isMirrorMode,
                                    disabled: model.switchingMessage != nil
                                ) {
                                    if appDisplayMode != .mirror {
                                        model.isMirrorMode = true
                                        restartWithConfig(role: .sender, displayMode: .mirror, host: model.winHost)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("当前 Mac 作为副屏接收画面；扩展 / 镜像模式请在 Windows 主控面板中选择。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let sw = model.switchingMessage {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(sw)
                                .font(.caption)
                                .foregroundStyle(accent)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.07))
                )

                if model.isReceiverMode {
                    SectionHeader(title: "副屏连接（Windows 主控）")
                    VStack(spacing: 6) {
                        if let err = model.recvListenerError {
                            StatRow(label: "监听状态", value: err, mono: false, warn: .red)
                        } else {
                            StatRow(label: "监听端口", value: "\(cfg.port) / \(cfg.port &+ 1) (\(model.recvListening ? "监听中" : "启动中"))")
                        }
                        HStack {
                            Text("本机 IP").foregroundStyle(.secondary)
                            Spacer()
                            Text(model.localIPsSummary)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("复制") {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                let firstIP = MacReceiverClient.localIPv4Summaries().first?.ip ?? "10.10.10.1"
                                pb.setString(firstIP, forType: .string)
                            }
                            .controlSize(.mini)
                        }
                        StatRow(label: "对端", value: model.recvPeer)
                        if model.recvKvmActive {
                            HStack(spacing: 6) {
                                StatRow(label: "KVM 穿透", value: "Windows 正在控制本机", mono: false, warn: .orange)
                                Button("解除") {
                                    macReceiverClient?.forceReleaseLocalKvm()
                                    model.refresh()
                                }
                                .controlSize(.mini)
                            }
                        }
                        if let rej = model.recvRejectedPeer {
                            StatRow(label: "已拦截", value: rej, mono: false, warn: .orange)
                        }
                        HStack(spacing: 6) {
                            Text("允许主控 IP").foregroundStyle(.secondary)
                            Spacer()
                            TextField("自动(私有网段+防抢占)", text: $model.allowedHostsDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 175)
                                .onSubmit { applyAllowedHosts() }
                            Button("应用") { applyAllowedHosts() }
                                .controlSize(.small)
                        }
                        StatRow(label: "连接时长", value: fmtUptime(model.recvUptimeSec))
                        StatRow(label: "已解码帧", value: "\(model.recvDecoded) 帧")
                    }

                    SectionHeader(title: "解码 / 呈现（VideoToolbox）")
                    VStack(spacing: 6) {
                        StatRow(label: "解码器", value: model.recvDecoderName)
                        StatRow(label: "解码帧率", value: String(format: "%.1f fps", model.recvDecodeFps))
                        StatRow(label: "接收码率", value: String(format: "%.1f Mbps", model.recvMbps))
                        StatRow(label: "源 / 呈现 p95", value: String(format: "%.1f / %.1f ms", model.recvSourceP95, model.recvPresentP95))
                        StatRow(label: "错误 / 丢帧", value: "\(model.recvErrors) / \(model.recvDropped)",
                                warn: (model.recvErrors > 0 || model.recvDropped > 0) ? .orange : nil)
                        StatRow(label: "光标 / 输入", value: "\(model.recvCursor) / \(model.recvInput)")
                    }

                    HStack(spacing: 8) {
                        Button("打开副屏窗口") { macReceiverWindow?.show() }
                        Button("切换全屏") { macReceiverWindow?.toggleFullscreen() }
                        Button("请求关键帧") { macReceiverClient?.sendKeyframeRequest(throttled: false) }
                    }
                } else {
                    if model.screenCaptureDenied || model.tccConflictWarning != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if model.screenCaptureDenied {
                                Text("需要屏幕录制权限（已暂停采集防循环弹窗，授权后点「恢复采集」或「重启应用」）")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let conflict = model.tccConflictWarning {
                                Text(conflict)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let hint = model.resumeFeedback {
                                Text(hint)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            HStack(spacing: 6) {
                                Button("恢复采集") {
                                    if let c = cap {
                                        let err = c.resumeAfterPermissionGranted()
                                        model.resumeFeedback = err
                                        if err == nil { model.refresh() }
                                    } else {
                                        model.resumeFeedback = "采集器尚未初始化，请点「重启应用」"
                                    }
                                }
                                .controlSize(.small)
                                Button("打开录屏设置") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .controlSize(.small)
                            }
                            HStack(spacing: 6) {
                                Button("清理冲突并重授权") {
                                    resetScreenCaptureTccEntriesAndOpenSettings()
                                }
                                .controlSize(.small)
                                Button("重启应用") {
                                    restartWithRole(appRole, host: model.winHost)
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if let conflict = model.senderRoleConflict {
                        Text(conflict)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    // 连接
                    SectionHeader(title: "连接")
                    VStack(spacing: 6) {
                        StatRow(label: "对端", value: model.peer)
                        HStack(spacing: 6) {
                            Text("Windows IP").foregroundStyle(.secondary)
                            Spacer()
                            TextField("10.10.10.2", text: $model.winHostDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 145)
                                .onSubmit { applyWinHostSetting() }
                            Button("保存") { applyWinHostSetting() }
                                .controlSize(.small)
                        }
                        StatRow(label: "运行时长", value: fmtUptime(model.uptimeSec))
                        StatRow(label: "累计发送", value: "\(model.totalSent) 帧")
                    }

                    // 采集与编码（发送端本地）
                    SectionHeader(title: "采集 / 编码")
                    VStack(spacing: 6) {
                        StatRow(label: "采集峰值", value: String(format: "%.0f fps", model.fps))
                        StatRow(label: "采集通道", value: model.capturePath)
                        StatRow(label: "采集延迟", value: String(format: "%.1f ms", model.capMs))
                        StatRow(label: "编码延迟", value: String(format: "%.1f ms", model.encMs))
                        StatRow(label: "画质档位", value: model.presetName)
                        StatRow(label: "采集重启", value: model.captureRestarts == 0
                                ? "无" : "\(model.captureRestarts) 次",
                                warn: model.captureRestarts > 0 ? .orange : nil)
                    }

                    // 码率控制
                    SectionHeader(title: "码率控制")
                    VStack(spacing: 6) {
                        StatRow(label: "当前 / 目标",
                                value: "\(model.bitrateNow) / \(model.bitrateTarget) Mbps")
                        StatRow(label: "实际发送", value: String(format: "%.1f Mbps", model.mbps))
                        StatRow(label: "健康度", value: healthText, warn: healthColor)
                        StatRow(label: "在途 / 丢弃", value: "\(model.inFlight) / \(model.dropped)",
                                warn: model.dropped > 0 ? .orange : nil)
                    }

                    // Windows 侧观测（0x07 反馈）
                    SectionHeader(title: "接收端（Windows）")
                    VStack(spacing: 6) {
                        StatRow(label: "解码帧率", value: String(format: "%.1f fps", model.clientFps))
                        StatRow(label: "呈现 p95", value: String(format: "%.1f ms", model.clientPresentP95))
                        StatRow(label: "额外排队", value: String(format: "%.1f ms", model.clientQueueMs),
                                warn: model.clientQueueMs >= 15 ? .orange : nil)
                        StatRow(label: "非节拍丢帧", value: "\(model.clientPresentDrop)",
                                warn: model.clientPresentDrop > 0 ? .orange : nil)
                    }

                    // 光标
                    SectionHeader(title: "光标")
                    VStack(spacing: 6) {
                        StatRow(label: "采样频率", value: String(format: "%.0f Hz", model.cursorHz))
                        StatRow(label: "位置 / 图像", value: "\(model.cursorPosSent) / \(model.cursorImgSent)")
                    }
                }

                // 雷电文件中转站
                SectionHeader(title: "雷电文件中转站")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.transferConnected ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(model.transferStatus)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if model.transferBusy {
                        HStack(spacing: 8) {
                            ProgressView(value: model.transferProgress)
                                .progressViewStyle(.linear)
                            Text(String(format: "%.0f%% %@", model.transferProgress * 100.0, model.transferSpeed))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(accent)
                        }
                    } else if model.transferFeedbackKind != 0 {
                        HStack(spacing: 5) {
                            Image(systemName: model.transferFeedbackKind > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(model.transferFeedbackKind > 0 ? .green : .red)
                            Text(model.transferFeedbackDetail.isEmpty
                                 ? model.transferFeedbackTitle
                                 : "\(model.transferFeedbackTitle) · \(model.transferFeedbackDetail)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(model.transferFeedbackKind > 0 ? Color.green : Color.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("发送文件…") {
                            openTransferFilePicker()
                        }
                        Button("粘贴发送") {
                            pasteClipboardToTransfer()
                        }
                        Button("打开目录") {
                            let path = model.transferInboxPath.isEmpty
                                ? transferService.inboxURL.path
                                : model.transferInboxPath
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        Button("悬浮盒") {
                            showDropBoxPanel()
                        }
                    }
                    if !model.transferHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.transferHistory.prefix(3).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    } else {
                        Text("把文件拖到此卡片即可直接发送到 Windows")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(model.transferDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(model.transferDropTargeted ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .onDrop(of: [.fileURL], isTargeted: $model.transferDropTargeted) { providers in
                    var accepted = false
                    for p in providers where p.canLoadObject(ofClass: URL.self) {
                        accepted = true
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { transferService.enqueue(urls: [url]) }
                        }
                    }
                    return accepted
                }

                Divider()

                if !model.isReceiverMode {
                    QualitySettingsCard(model: model)
                }

                HStack(spacing: 8) {
                    if !model.isReceiverMode {
                        Button(model.senderKvmActive ? "退出穿透 (Ctrl+Opt+K)" : "键鼠控 Win (Ctrl+Opt+K)") {
                            kvmPassthrough.toggle()
                            model.senderKvmActive = kvmPassthrough.isActive
                        }
                        Button("强制关键帧") {
                            encoder?.forceEncodeLastFrame()
                            Log.info("面板请求强制关键帧")
                        }
                    }
                    Button("打开日志") { openLogsFolder() }
                    Button("复制诊断") { copyDiagnostics() }
                    Spacer()
                    Button("隐藏") { hideControlPanel() }
                    Button("退出") {
                        DispatchQueue.main.async { shutdown(signal: SIGTERM) }
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }

                Text("快捷键：⌘Q / Ctrl+Opt+Q 安全退出 · ⌘W / Esc 隐藏面板 · Ctrl+Opt+B 投递盒")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if !model.logLine.isEmpty {
                    Text(model.logLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 自己管顶部让位，就不要 SwiftUI 再叠一次安全区
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 420, idealWidth: 440, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
    }

    private func applyAllowedHosts() {
        let trimmed = model.allowedHostsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "SecDisplayAllowedHost")
        UserDefaults.standard.synchronize()
        macReceiverClient?.setAllowedHosts(trimmed)
        model.refresh()
    }

    private func applyWinHostSetting() {
        let trimmed = model.winHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        winHostAddress = trimmed
        model.winHost = trimmed
        UserDefaults.standard.set(trimmed, forKey: "SecDisplayWinHost")
        UserDefaults.standard.synchronize()
        Log.info("面板: 已保存 Windows IP -> \(trimmed)")
    }
}

/// 复制诊断信息到剪贴板。排障时比让人截图快得多。
func copyDiagnostics() {
    let m = AppModel.shared
    let text: String
    if m.isReceiverMode {
        text = """
        SecDisplay Mac 副屏诊断 (Win→Mac)
        ================================
        监听: \(m.recvListening ? "监听中" : "未就绪") \(m.recvListenerError ?? "")
        本机 IP: \(m.localIPsSummary)
        连接: \(m.recvConnected ? "已连接" : "未连接")  流状态: \(m.recvStreaming ? "正常" : "等待")
        主控端: \(m.recvPeer)  拦截: \(m.recvRejectedPeer ?? "无")
        分辨率: \(m.recvWidth)x\(m.recvHeight) @ \(m.recvFps)Hz
        解码器: \(m.recvDecoderName)
        解码帧率: \(String(format: "%.1f", m.recvDecodeFps)) fps  码率: \(String(format: "%.1f", m.recvMbps)) Mbps
        源p95 / 呈现p95: \(String(format: "%.1f / %.1f", m.recvSourceP95, m.recvPresentP95)) ms
        已解码: \(m.recvDecoded) 帧  解码错误: \(m.recvErrors)  丢帧: \(m.recvDropped)
        光标 / 输入: \(m.recvCursor) / \(m.recvInput)  运行 \(fmtUptime(m.recvUptimeSec))
        中转站(9923): \(m.transferConnected ? "已连接" : "等待") (\(m.transferStatus))
        日志: \(m.logLine)
        """
    } else {
        let fb = sender?.latestFeedback() ?? FeedbackSignals()
        text = """
        SecDisplay 发送端诊断 (\(m.isMirrorMode ? "镜像主屏" : "扩展屏幕"))
        ==================
        连接: \(m.connected ? "已连接" : "未连接")
        对端: \(m.peer)  记录WindowsIP: \(m.winHost)
        分辨率: \(m.width)x\(m.height)  scale=\(String(format: "%.2f", m.scale))
        采集通道: \(m.capturePath)
        采集峰值: \(String(format: "%.0f", m.fps)) fps
        采集延迟: \(String(format: "%.1f", m.capMs)) ms
        编码延迟: \(String(format: "%.1f", m.encMs)) ms
        码率: \(m.bitrateNow)/\(m.bitrateTarget) Mbps  实际 \(String(format: "%.1f", m.mbps)) Mbps
        健康度: \(String(format: "%.2f", m.health))
        在途/丢弃: \(m.inFlight)/\(m.dropped)
        对端解码: \(String(format: "%.1f", m.clientFps)) fps  呈现p95 \(String(format: "%.1f", m.clientPresentP95)) ms
        对端额外排队: \(String(format: "%.1f", m.clientQueueMs)) ms  非节拍丢帧 \(fb.presentDrop)  节拍丢帧 \(fb.pacedDrop)
        源码率p95: \(String(format: "%.1f", fb.sourceP95)) ms
        累计发送: \(m.totalSent) 帧  运行 \(fmtUptime(m.uptimeSec))
        中转站(9923): \(m.transferConnected ? "已连接" : "等待") (\(m.transferStatus))
        日志: \(m.logLine)
        """
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    Log.info("面板: 诊断信息已复制到剪贴板")
}

nonisolated(unsafe) var isRestartingResolution = false

func restartWithRole(_ role: SecDisplayRole, host: String) {
    restartWithConfig(role: role, displayMode: appDisplayMode, host: host)
}

func restartWithConfig(role: SecDisplayRole, displayMode: SecDisplayDisplayMode, host: String) {
    guard !isRestartingResolution else { return }
    isRestartingResolution = true
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetHost = trimmedHost.isEmpty ? winHostAddress : trimmedHost

    let dir = FileManager.default.currentDirectoryPath
    let pid = ProcessInfo.processInfo.processIdentifier
    let desc = role == .receiver
        ? "正在切换至 Mac 当副屏…"
        : (displayMode == .mirror ? "正在切换至镜像主屏…" : "正在切换至扩展屏幕…")
    AppModel.shared.switchingMessage = desc
    Log.info("面板切换配置 -> role=\(role.rawValue) displayMode=\(displayMode.rawValue) winHost=\(targetHost)，准备重启")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    if FileManager.default.fileExists(atPath: dir + "/run.sh") {
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.15; done; sleep 0.3; cd \"$1\" && SECDISPLAY_MODE=\"$2\" SECDISPLAY_DISPLAY_MODE=\"$3\" SECDISPLAY_HOST=\"$4\" ./run.sh restart",
                       "restart", dir, role.rawValue, displayMode.rawValue, targetHost]
    } else {
        let appPath = Bundle.main.bundlePath
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.15; done; sleep 0.3; open -n \"$1\" --env SECDISPLAY_MODE=\"$2\" --env SECDISPLAY_DISPLAY_MODE=\"$3\" --env SECDISPLAY_HOST=\"$4\" --args --mode \"$2\" --display-mode \"$3\" --host \"$4\" --wait-lock 3000",
                       "restart", appPath, role.rawValue, displayMode.rawValue, targetHost]
    }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        Log.info("切换重启拉起失败: \(error.localizedDescription)")
        isRestartingResolution = false
        AppModel.shared.switchingMessage = nil
        AppModel.shared.refresh()
        return
    }
    UserDefaults.standard.set(role.rawValue, forKey: "SecDisplayRole")
    UserDefaults.standard.set(displayMode.rawValue, forKey: "SecDisplayDisplayMode")
    UserDefaults.standard.set(targetHost, forKey: "SecDisplayWinHost")
    UserDefaults.standard.synchronize()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        shutdown(signal: SIGTERM)
    }
}

/// 面板里调「采集帧率 / 码率上限」时在线生效。
/// 事务化：先用候选值重建编码器，成功后才提交 cfg / UserDefaults / UI 状态；
/// 失败时任何状态都不变，避免「面板显示 60fps、实际仍是 50fps」。
/// 返回是否真的生效。
@discardableResult
func applyStreamTuning(captureHz: Double?, maxMbps: Int?) -> Bool {
    cfgStateLock.lock()
    let w = cfg.width, h = cfg.height
    let oldHz = cfg.captureHz, oldMbps = cfg.bitrateMbps
    cfgStateLock.unlock()

    let hzCandidate = captureHz.flatMap { ($0 >= 20 && $0 <= 120) ? $0 : nil } ?? oldHz
    let mbpsCandidate = maxMbps.flatMap { ($0 >= 20 && $0 <= 300) ? $0 : nil } ?? oldMbps

    guard let enc = encoder else { return false }
    guard enc.reconfigure(width: w, height: h,
                          bitrateMbps: mbpsCandidate, captureHz: hzCandidate) else {
        Log.info("面板应用码率/帧率失败（编码器重建被拒绝），保持原配置")
        return false
    }

    cfgStateLock.lock()
    cfg.captureHz = hzCandidate
    cfg.bitrateMbps = mbpsCandidate
    cfgStateLock.unlock()
    rateCtl?.updateTargetMbps(mbpsCandidate)
    rateCtl?.updateCaptureHz(hzCandidate)
    let fps = Int(hzCandidate.rounded())
    // sessionFps 由 updateSessionInfo 在 Sender 的串行队列内更新，避免主线程写竞争。
    sender?.updateSessionInfo(width: w, height: h, fps: fps,
                              scaleTenths: UInt8(clamping: Int((vdBackingScale * 10).rounded())))
    Log.info("面板应用码率/帧率: \(mbpsCandidate) Mbps, \(fps) fps")
    return true
}

/// 切换分辨率：虚拟屏和编码器都在启动时按尺寸建好，改尺寸只能重建进程。
/// 命令行启动走 run.sh restart；.app 启动时没有 run.sh，直接重启自身。
func restartWithResolution(_ w: Int, _ h: Int, _ lw: Int, _ lh: Int) {
    guard !isRestartingResolution else { return }
    isRestartingResolution = true
    AppModel.shared.switchingMessage = "正在切换分辨率 \(w)×\(h)…"
    let dir = FileManager.default.currentDirectoryPath
    let pid = ProcessInfo.processInfo.processIdentifier
    Log.info("面板切换分辨率 \(w)x\(h)，准备重启")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    if FileManager.default.fileExists(atPath: dir + "/run.sh") {
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.15; done; sleep 0.3; cd \"$1\" && SECDISPLAY_W=\"$2\" SECDISPLAY_H=\"$3\" SECDISPLAY_LOGICAL_W=\"$4\" SECDISPLAY_LOGICAL_H=\"$5\" SECDISPLAY_MODE=\"$6\" SECDISPLAY_DISPLAY_MODE=\"$7\" ./run.sh restart",
                       "restart", dir, "\(w)", "\(h)", "\(lw)", "\(lh)", appRole.rawValue, appDisplayMode.rawValue]
    } else {
        // .app 场景：等待旧进程退出后用 open 重新拉起 bundle，保持 TCC 归属在 bundle 上。
        let appPath = Bundle.main.bundlePath
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.15; done; sleep 0.3; open -n \"$1\" --env SECDISPLAY_W=\"$2\" --env SECDISPLAY_H=\"$3\" --env SECDISPLAY_LOGICAL_W=\"$4\" --env SECDISPLAY_LOGICAL_H=\"$5\" --env SECDISPLAY_MODE=\"$6\" --env SECDISPLAY_DISPLAY_MODE=\"$7\" --args --mode \"$6\" --display-mode \"$7\" --wait-lock 3000",
                       "restart", appPath, "\(w)", "\(h)", "\(lw)", "\(lh)", appRole.rawValue, appDisplayMode.rawValue]
    }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        Log.info("切换分辨率重启拉起失败: \(error.localizedDescription)")
        isRestartingResolution = false
        AppModel.shared.switchingMessage = nil
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        shutdown(signal: SIGTERM)
    }
}

/// 打开日志目录。命令行运行时日志在 ./logs，打包成 app 后在 ~/Library/Logs/SecDisplay。
func openLogsFolder() {
    let fm = FileManager.default
    let cwdLogs = fm.currentDirectoryPath + "/logs"
    if fm.fileExists(atPath: cwdLogs) {
        NSWorkspace.shared.open(URL(fileURLWithPath: cwdLogs))
        return
    }
    let p = Log.currentPath
    if fm.fileExists(atPath: p) {
        NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "")
    } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: (p as NSString).deletingLastPathComponent))
    }
}

private let panelStateLock = NSLock()
nonisolated(unsafe) private var panelVisibleFlag = false

private func setPanelVisible(_ v: Bool) {
    panelStateLock.lock()
    panelVisibleFlag = v
    panelStateLock.unlock()
}

/// 面板可见标志。保留供 UI 侧查询，输入回放已不再依赖它
/// （面板点不动的真根因是 NSEvent 全局监视器抢在 NSApplication 初始化前
/// 建立 SkyLight 会话，已由延迟注册修复）。
var isControlPanelVisible: Bool {
    panelStateLock.lock()
    let v = panelVisibleFlag
    panelStateLock.unlock()
    return v
}

private var panelWindow: NSWindow?

private final class PanelWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        setPanelVisible(false)
        let receiverWinVisible = (macReceiverWindow?.window.isVisible == true)
        if !receiverWinVisible {
            NSApp.setActivationPolicy(.accessory)
        }
        Log.info("面板通过关闭按钮隐藏")
    }
}

private let panelWindowDelegate = PanelWindowDelegate()

/// 隐藏面板但保留进程。面板只是个查看窗口，关掉不该影响推流。
func hideControlPanel() {
    setPanelVisible(false)
    panelWindow?.orderOut(nil)
    let receiverWinVisible = (macReceiverWindow?.window.isVisible == true)
    if !receiverWinVisible {
        NSApp.setActivationPolicy(.accessory)
    }
    Log.info("面板已隐藏")
}

/// 把面板固定放到内建主屏，不跟随鼠标所在屏。
/// 用 NSEvent.mouseLocation 选屏时，一旦光标被输入回放 warp 到虚拟屏，
/// 面板就会跟着跑到扩展桌面那侧，用户在 Mac 上根本看不到。
private func placeOnUserScreen(_ w: NSWindow) {
    let screen = NSScreen.screens.first { s in
        // 主屏：frame 原点在 (0,0)。虚拟屏 origin.x 通常 > 0，Sidecar 在负 x。
        abs(s.frame.origin.x) < 1 && abs(s.frame.origin.y) < 1
    } ?? NSScreen.screens.first
    guard let s = screen else { w.center(); return }
    let vf = s.visibleFrame
    let size = w.frame.size
    w.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                             y: vf.midY - size.height / 2))
}

/// 打开/前置控制面板
func showControlPanel() {
    ensurePasteKeyMonitor()
    // 平时以 .accessory 常驻菜单栏；打开面板时切成 .regular 让 App 可成为前台，
    // 并在下一个主循环轮次补一次 activate，等 WindowServer 完成策略切换后再聚焦。
    Log.info("打开控制面板请求")
    setPanelVisible(true)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let targetWindow: NSWindow
    if let w = panelWindow {
        placeOnUserScreen(w)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        targetWindow = w
        Log.info("面板已前置 key=\(w.isKeyWindow) visible=\(w.isVisible) frame=\(w.frame)")
    } else {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        w.title = appRole == .receiver ? "SecDisplay 控制面板 (Mac 当副屏)" : "SecDisplay 控制面板"
        w.minSize = NSSize(width: 420, height: 560)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.delegate = panelWindowDelegate
        // 标题栏遮挡高度按窗口实际布局算，不写死 28pt。
        // fullSizeContentView 下 contentView 铺满整个窗口，contentLayoutRect
        // 才是扣掉标题栏之后的可布局区域，两者之差就是需要让出的高度。
        let topInset = max(0, w.frame.height - w.contentLayoutRect.height)
        Log.info(String(format: "面板顶部让位 %.0fpt（窗口 %.0f / 可布局 %.0f）",
                        topInset, w.frame.height, w.contentLayoutRect.height))
        let host = NSHostingView(rootView: StatusView(topInset: topInset))
        w.contentView = host
        placeOnUserScreen(w)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        panelWindow = w
        targetWindow = w
        Log.info("面板已创建 frame=\(w.frame) key=\(w.isKeyWindow) visible=\(w.isVisible)")
    }
    AppModel.shared.refresh()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard isControlPanelVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        targetWindow.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 悬浮文件投递盒（ArcZip Box 风格）

private func openTransferFilePicker() {
    let wasAccessory = NSApp.activationPolicy() == .accessory
    let runPicker = {
        let panel = NSOpenPanel()
        panel.title = "选择要发送到 Windows 的文件"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            transferService.enqueue(urls: panel.urls)
        }
        if wasAccessory && !isControlPanelVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    if wasAccessory {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { runPicker() }
    } else {
        NSApp.activate(ignoringOtherApps: true)
        runPicker()
    }
}

/// 粘贴剪贴板中的文件或截图（Cmd+V 或按钮触发）直传到 Windows
func pasteClipboardToTransfer() {
    let pb = NSPasteboard.general
    if let urls = pb.readObjects(forClasses: [NSURL.self],
                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
        transferService.enqueue(urls: urls)
        Log.info("剪贴板粘贴文件: \(urls.count) 个")
        return
    }
    if let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String],
       !paths.isEmpty {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        transferService.enqueue(urls: urls)
        Log.info("剪贴板粘贴文件(NSFilenames): \(urls.count) 个")
        return
    }
    if let png = pb.data(forType: .png),
       png.count >= 8,
       png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
        transferService.enqueueClipboardImageData(png)
        Log.info("剪贴板粘贴 PNG 截图 (\(png.count) B)")
        return
    }
    let encodeImageToPng: (NSImage) -> Data? = { img in
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        var r = NSRect(origin: .zero, size: img.size)
        if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cg)
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }
    let imageTypes: [NSPasteboard.PasteboardType] = [
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.webp"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        .pdf,
    ]
    for tp in imageTypes {
        if let data = pb.data(forType: tp) {
            if let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                transferService.enqueueClipboardImageData(png)
                Log.info("剪贴板粘贴图片(\(tp.rawValue)) 转 PNG (\(png.count) B)")
                return
            }
            if let src = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let rep = NSBitmapImageRep(cgImage: cg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    transferService.enqueueClipboardImageData(png)
                    Log.info("剪贴板粘贴图片(\(tp.rawValue)) ImageIO 转 PNG (\(png.count) B)")
                    return
                }
            }
        }
    }
    if let img = NSImage(pasteboard: pb), let png = encodeImageToPng(img) {
        transferService.enqueueClipboardImageData(png)
        Log.info("剪贴板粘贴 NSImage 截图 (\(png.count) B)")
        return
    }
    if let text = pb.string(forType: .string), !text.isEmpty {
        transferService.enqueueClipboardText(text)
        Log.info("剪贴板粘贴文本 (\(text.utf8.count) B)")
        return
    }
    let avail = pb.types?.map(\.rawValue).joined(separator: ", ") ?? "空"
    Log.info("剪贴板粘贴无可用内容，当前类型: [\(avail)]")
    transferService.showFeedback(kind: -1, title: "剪贴板无内容", detail: "请先复制文件、截图或文字")
}

private var pasteKeyMonitor: Any?

private func ensurePasteKeyMonitor() {
    guard pasteKeyMonitor == nil else { return }
    pasteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isEditingText = (panelWindow?.isKeyWindow == true) && (panelWindow?.firstResponder is NSTextView)
        if mods == .command, ev.charactersIgnoringModifiers?.lowercased() == "v" {
            if isEditingText {
                return ev
            }
            let panelActive = (panelWindow?.isKeyWindow == true) || (dropBoxPanel?.isKeyWindow == true)
            if panelActive {
                pasteClipboardToTransfer()
                return nil
            }
        }
        // 非文本编辑状态下按 Esc 隐藏控制面板，避免输入 IP 时误关面板丢失草稿
        if mods.isEmpty, ev.keyCode == 53, panelWindow?.isKeyWindow == true, !isEditingText {
            hideControlPanel()
            return nil
        }
        return ev
    }
}

struct DropBoxView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            // 顶部柔和冷紫灰标题栏
            HStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "display")
                        .font(.system(size: 16, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SecDisplay")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.14, green: 0.14, blue: 0.18))
                    HStack(spacing: 4) {
                        Text("Box")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.32))
                        Circle()
                            .fill(model.transferConnected ? Color.green : Color.gray.opacity(0.6))
                            .frame(width: 5, height: 5)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.65)))
                }
                Spacer()
                Button(action: { pasteClipboardToTransfer() }) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.32))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("粘贴剪贴板文件/截图/文字发送 (⌘V)")

                Button(action: { toggleDropBoxPin() }) {
                    Image(systemName: model.dropBoxPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.dropBoxPinned
                                         ? Color(red: 0.15, green: 0.35, blue: 0.85)
                                         : Color(red: 0.25, green: 0.25, blue: 0.32))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help(model.dropBoxPinned ? "取消置顶" : "置顶悬浮")

                Button(action: { hideDropBoxPanel() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.20, green: 0.20, blue: 0.25))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .help("关闭投递盒")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(red: 0.70, green: 0.68, blue: 0.80))

            // 下半部分白色拖放投递区
            VStack(spacing: 8) {
                Button(action: { openTransferFilePicker() }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(dropBoxZoneFill)
                            .shadow(color: dropBoxZoneGlow, radius: 10, x: 0, y: 2)
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(dropBoxZoneStroke, lineWidth: 1.5)

                        if model.transferBusy {
                            VStack(spacing: 6) {
                                ProgressView(value: model.transferProgress)
                                    .progressViewStyle(.circular)
                                ProgressView(value: model.transferProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 96)
                                Text(String(format: "%.0f%%  %@", model.transferProgress * 100.0, model.transferSpeed))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.15, green: 0.35, blue: 0.85))
                            }
                        } else if model.transferFeedbackKind != 0 {
                            VStack(spacing: 5) {
                                Image(systemName: model.transferFeedbackKind > 0
                                      ? "checkmark.circle.fill"
                                      : "xmark.circle.fill")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundStyle(model.transferFeedbackKind > 0
                                                     ? Color(red: 0.12, green: 0.65, blue: 0.34)
                                                     : Color(red: 0.85, green: 0.22, blue: 0.22))
                                Text(model.transferFeedbackTitle)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(model.transferFeedbackKind > 0
                                                     ? Color(red: 0.08, green: 0.50, blue: 0.24)
                                                     : Color(red: 0.72, green: 0.15, blue: 0.15))
                                if !model.transferFeedbackDetail.isEmpty {
                                    Text(model.transferFeedbackDetail)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.horizontal, 10)
                                }
                            }
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "tray.and.arrow.down")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(model.dropBoxHoverTargeted
                                                     ? Color.blue
                                                     : Color(red: 0.48, green: 0.50, blue: 0.56))
                                Text("拖入或点击发送")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(red: 0.48, green: 0.50, blue: 0.56))
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.18), value: model.transferFeedbackKind)
                    .animation(.easeInOut(duration: 0.18), value: model.transferBusy)
                    .frame(width: 152, height: 118)
                }
                .buttonStyle(.plain)
                // 仅在投递区接收拖放，避免从下方已收文件胶囊拖出未出窗口时被自身误接回传
                .onDrop(of: [.fileURL], isTargeted: $model.dropBoxHoverTargeted) { providers in
                    var accepted = false
                    for p in providers where p.canLoadObject(ofClass: URL.self) {
                        accepted = true
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { transferService.enqueue(urls: [url]) }
                        }
                    }
                    return accepted
                }

                if let recvURL = model.transferLastRecvURL, !model.transferLastRecvName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        Text(model.transferLastRecvName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.15, green: 0.20, blue: 0.28))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.93, green: 0.96, blue: 0.94)))
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting([recvURL])
                    }
                    .onDrag {
                        NSItemProvider(object: recvURL as NSURL)
                    }
                    .help("点击在 Finder 中定位，或直接拖出到其他应用")
                } else {
                    Text((model.transferConnected && model.transferStatus.hasPrefix("已连接"))
                         ? "⌃⌥B 呼出 · ⌘V 粘贴截图/文字"
                         : model.transferStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        }
        .frame(width: 244, height: 256)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .help("按住空白处可自由拖动位置 · ⌃⌥B 一键呼出/隐藏")
    }

    private var dropBoxZoneFill: Color {
        if model.dropBoxHoverTargeted || model.transferBusy {
            return Color(red: 0.88, green: 0.93, blue: 1.0)
        }
        if model.transferFeedbackKind > 0 {
            return Color(red: 0.91, green: 0.98, blue: 0.94)
        }
        if model.transferFeedbackKind < 0 {
            return Color(red: 0.99, green: 0.93, blue: 0.93)
        }
        return Color(red: 0.91, green: 0.92, blue: 0.94)
    }

    private var dropBoxZoneStroke: Color {
        if model.dropBoxHoverTargeted || model.transferBusy {
            return Color.blue.opacity(0.7)
        }
        if model.transferFeedbackKind > 0 {
            return Color.green.opacity(0.65)
        }
        if model.transferFeedbackKind < 0 {
            return Color.red.opacity(0.65)
        }
        return Color.clear
    }

    private var dropBoxZoneGlow: Color {
        if model.dropBoxHoverTargeted || model.transferBusy {
            return Color.blue.opacity(0.22)
        }
        if model.transferFeedbackKind > 0 {
            return Color.green.opacity(0.20)
        }
        if model.transferFeedbackKind < 0 {
            return Color.red.opacity(0.20)
        }
        return Color.black.opacity(0.05)
    }
}

private final class DropBoxPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private var dropBoxPanel: NSPanel?

func toggleDropBoxPin() {
    let next = !AppModel.shared.dropBoxPinned
    AppModel.shared.dropBoxPinned = next
    dropBoxPanel?.isFloatingPanel = next
    dropBoxPanel?.level = next ? .floating : .normal
    Log.info("Mac 投递盒置顶: \(next ? "开" : "关")")
}

func hideDropBoxPanel() {
    dropBoxPanel?.orderOut(nil)
    Log.info("Mac 投递盒已隐藏")
}

func toggleDropBoxPanel() {
    if let p = dropBoxPanel, p.isVisible {
        hideDropBoxPanel()
    } else {
        showDropBoxPanel()
    }
}

func showDropBoxPanel() {
    ensurePasteKeyMonitor()
    if let p = dropBoxPanel {
        // 若此前所在副屏已断开导致窗口跑出所有屏幕，自动拉回主屏右下角；否则保留用户拖动的位置
        let onAnyScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(p.frame) }
        if !onAnyScreen {
            let screen = NSScreen.screens.first { s in
                abs(s.frame.origin.x) < 1 && abs(s.frame.origin.y) < 1
            } ?? NSScreen.screens.first
            if let s = screen {
                let vf = s.visibleFrame
                p.setFrameOrigin(NSPoint(x: vf.maxX - 244 - 28, y: vf.minY + 28))
            }
        }
        p.level = AppModel.shared.dropBoxPinned ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        return
    }
    let host = NSHostingView(rootView: DropBoxView())
    let p = DropBoxPanel(
        contentRect: NSRect(x: 0, y: 0, width: 244, height: 256),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    p.isFloatingPanel = true
    p.level = AppModel.shared.dropBoxPinned ? .floating : .normal
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.isMovableByWindowBackground = true
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.contentView = host

    let screen = NSScreen.screens.first { s in
        abs(s.frame.origin.x) < 1 && abs(s.frame.origin.y) < 1
    } ?? NSScreen.screens.first
    if let s = screen {
        let vf = s.visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.maxX - 244 - 28, y: vf.minY + 28))
    } else {
        p.center()
    }
    NSApp.activate(ignoringOtherApps: true)
    p.makeKeyAndOrderFront(nil)
    p.orderFrontRegardless()
    dropBoxPanel = p
    Log.info("Mac 文件投递盒已打开")
}

// MARK: - 连接引导动画

/// 副屏连上时，在「主屏 → 副屏」之间来回飞一个光标并标出副屏位置。
/// 用户第一次连上时常常不知道画面去哪了，这个动画直接告诉他「副屏在这里」，
/// 以及光标可以在两块屏之间来回移动。
/// 不抢焦点、不成为 key window 的引导层窗口。
/// 普通 borderless NSWindow 在部分 macOS 版本上会被提升为 key window，
/// 抢走用户当前正在输入的窗口焦点，也会挡住 TCC 授权弹窗。
final class GuideOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ConnectionGuideOverlay {
    static let shared = ConnectionGuideOverlay()
    private init() {}

    private var window: NSWindow?
    private var canvas: GuideCanvasView?
    private var timer: Timer?
    private var startedAt: CFAbsoluteTime = 0
    private var fadeStartedAt: CFAbsoluteTime = 0
    private var cyclesLeft = 0
    private var fading = false

    private let legSeconds: Double = 0.90      // 单程
    private let pauseSeconds: Double = 0.22    // 到端点停顿
    private let fadeSeconds: Double = 0.40

    struct Layout {
        let union: CGRect
        let main: CGRect   // 主屏（主显示器）在 union 内的坐标
        let vd: CGRect     // 副屏在 union 内的坐标
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "SecDisplayShowGuide") as? Bool) ?? true
    }

    /// 把 AppKit 全局屏幕坐标转成 union 内的窗口坐标（窗口 y 轴向上，与 AppKit 一致）。
    static func makeLayout(vdID: CGDirectDisplayID) -> Layout? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let mainScreen = screens.first { abs($0.frame.origin.x) < 1 && abs($0.frame.origin.y) < 1 } ?? screens[0]
        let vdScreen = screens.first { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vdID
        }
        var union = mainScreen.frame
        for s in screens { union = union.union(s.frame) }
        func local(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX - union.minX, y: r.minY - union.minY, width: r.width, height: r.height)
        }
        var vdRect: CGRect
        if let v = vdScreen {
            vdRect = v.frame
        } else {
            // 找不到副屏（例如还在建屏）：假设它在主屏右侧
            vdRect = CGRect(x: mainScreen.frame.maxX, y: mainScreen.frame.minY,
                            width: mainScreen.frame.width, height: mainScreen.frame.height)
            union = union.union(vdRect)
        }
        return Layout(union: union, main: local(mainScreen.frame), vd: local(vdRect))
    }

    private var lastAutoShowAt: CFAbsoluteTime = 0

    /// 自动播放（连接建立时）。限频：10 分钟内最多一次，避免网络抖动重连时反复弹动画。
    /// 只有动画真正开始才消耗配额，否则手动重播被挡掉时也会白白吃掉这次自动播放。
    func showIfEnabled(vdID: CGDirectDisplayID) {
        guard Self.isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if lastAutoShowAt > 0, now - lastAutoShowAt < 600 { return }
        if show(vdID: vdID) { lastAutoShowAt = now }
    }

    /// 返回是否真的开始了动画（窗口已存在或布局不可用时返回 false）。
    @discardableResult
    func show(vdID: CGDirectDisplayID, cycles: Int = 3) -> Bool {
        guard window == nil else { return false }
        guard let layout = Self.makeLayout(vdID: vdID) else { return false }
        let w = GuideOverlayWindow(contentRect: layout.union,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .screenSaver
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isReleasedWhenClosed = false
        let v = GuideCanvasView(frame: CGRect(origin: .zero, size: layout.union.size))
        v.mainRect = layout.main
        v.vdRect = layout.vd
        w.contentView = v
        w.orderFrontRegardless()

        window = w
        canvas = v
        cyclesLeft = max(1, cycles)
        startedAt = CFAbsoluteTimeGetCurrent()
        fadeStartedAt = 0
        fading = false
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("连接引导动画: 主屏 → 副屏（id=\(vdID)）")
        return true
    }

    private func tick() {
        guard let canvas, let win = window else { finish(); return }
        let now = CFAbsoluteTimeGetCurrent()

        // 淡出必须先处理：早期实现在这里复用了 startedAt，导致 elapsed 每帧归零，
        // 淡出分支永远不可达，动画会重播一轮再突然消失（实际停留 13 秒以上）。
        if fading {
            let f = (now - fadeStartedAt) / fadeSeconds
            if f >= 1.0 {
                finish()
                return
            }
            win.alphaValue = CGFloat(1.0 - f)
            return
        }

        let elapsed = now - startedAt
        let perCycle = legSeconds * 2 + pauseSeconds * 2
        let total = perCycle * Double(cyclesLeft)

        if elapsed < total {
            let t = elapsed.truncatingRemainder(dividingBy: perCycle)
            var p: CGFloat
            if t < legSeconds {
                p = CGFloat(t / legSeconds)
            } else if t < legSeconds + pauseSeconds {
                p = 1
            } else if t < legSeconds * 2 + pauseSeconds {
                p = CGFloat(1 - (t - legSeconds - pauseSeconds) / legSeconds)
            } else {
                p = 0
            }
            canvas.progress = max(0, min(1, p))
            canvas.dashPhase = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.2) / 1.2)
            canvas.pulse = CGFloat(elapsed.truncatingRemainder(dividingBy: 1.4) / 1.4)
            win.alphaValue = 1
            canvas.needsDisplay = true
        } else {
            fading = true
            fadeStartedAt = now
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        canvas = nil
        fading = false
    }

    /// 无人值守验证：把动画在 3 个进度点渲染成 PNG，返回文件路径。
    static func dumpFrames(to dir: String) -> [String] {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var layout = makeLayout(vdID: 0)
        if layout == nil || layout!.vd.width <= 0 {
            let f = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
            let vd = CGRect(x: f.maxX, y: f.minY, width: f.width, height: f.height)
            let union = f.union(vd)
            layout = Layout(union: union,
                            main: CGRect(x: f.minX - union.minX, y: f.minY - union.minY, width: f.width, height: f.height),
                            vd: CGRect(x: vd.minX - union.minX, y: vd.minY - union.minY, width: vd.width, height: vd.height))
        }
        guard let l = layout else { return [] }
        let v = GuideCanvasView(frame: CGRect(origin: .zero, size: l.union.size))
        v.mainRect = l.main
        v.vdRect = l.vd
        v.opaqueBackdrop = true
        var paths: [String] = []
        for (i, p) in [0.2, 0.55, 0.92].enumerated() {
            v.progress = CGFloat(p)
            v.dashPhase = CGFloat(0.18 + Double(i) * 0.3)
            v.pulse = CGFloat(i == 2 ? 0.35 : 0.7)
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let path = "\(dir)/guide_\(i).png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                paths.append(path)   // 只有真正写成功才追加，避免日志谎报「已导出」
            } catch {
                Log.info("引导动画导图写入失败: \(error.localizedDescription)")
            }
        }
        return paths
    }
}

/// 引导动画画布：虚线路径 + 副屏高亮框 + 飞行的光标。
final class GuideCanvasView: NSView {
    var progress: CGFloat = 0
    var mainRect: CGRect = .zero
    var vdRect: CGRect = .zero
    /// 虚线流动相位（0..1），让连线看起来在「流动」
    var dashPhase: CGFloat = 0
    /// 终点脉冲（0..1 循环），用于扩散光环
    var pulse: CGFloat = 0
    /// 导出 PNG 时铺一层不透明底，模拟真实桌面，便于离线审阅
    var opaqueBackdrop = false
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor

        // 导出时铺一层不透明底，避免透明背景让画面看起来发白
        if opaqueBackdrop {
            ctx.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1).cgColor)
            ctx.fill(bounds)
        }
        // 轻微压暗（比上一版更淡，避免整屏发灰）
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        ctx.fill(bounds)

        // 端点取「屏幕中部偏内」而不是紧贴接缝：两块屏相邻时接缝处两点只有一百多像素，
        // 光标几乎不动，完全没有「从左屏飞到右屏」的观感。
        let a = CGPoint(x: mainRect.minX + mainRect.width * 0.62, y: mainRect.midY)
        let b = CGPoint(x: vdRect.minX + vdRect.width * 0.38, y: vdRect.midY)
        let ctrl = CGPoint(x: (a.x + b.x) * 0.5,
                           y: max(a.y, b.y) + min(210, max(mainRect.height, vdRect.height) * 0.22))

        // ---- 副屏高亮框：宽描边 + 外发光 ----
        let highlight = vdRect.insetBy(dx: 10, dy: 10)
        let hlPath = CGPath(roundedRect: highlight, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 26,
                      color: accent.withAlphaComponent(0.75).cgColor)
        ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(5)
        ctx.addPath(hlPath)
        ctx.strokePath()
        ctx.restoreGState()

        // 终点扩散光环（两圈，错相位）
        for k in 0..<2 {
            let ph = (pulse + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1.0)
            let r = 26 + ph * 70
            ctx.setStrokeColor(accent.withAlphaComponent(Double(0.55 * (1 - ph))).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2))
        }

        // ---- 连线：底层粗光晕 + 上层流动虚线 ----
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: ctrl)

        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(3.6)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: dashPhase * 27, lengths: [15, 12])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        // 端点
        drawDot(ctx, at: a, radius: 7, color: accent)
        drawDot(ctx, at: b, radius: 8, color: accent)

        // ---- 文案板 ----
        drawPill(ctx, text: "主屏", at: CGPoint(x: a.x - 96, y: a.y), small: true)
        drawPill(ctx, text: "副屏在这里", at: CGPoint(x: vdRect.midX, y: vdRect.midY + 46), small: false)
        drawPill(ctx, text: "把窗口拖过来，鼠标可来回移动",
                 at: CGPoint(x: vdRect.midX, y: vdRect.midY - 46), small: true)

        // ---- 飞行光标 + 拖尾 ----
        for i in stride(from: 6, through: 1, by: -1) {
            let tp = max(0, progress - CGFloat(i) * 0.035)
            let pos = quadPoint(a, ctrl, b, tp)
            let alpha = 0.10 * CGFloat(7 - i) / 6.0
            ctx.setFillColor(accent.withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: pos.x - 5, y: pos.y - 5, width: 10, height: 10))
        }
        let pos = quadPoint(a, ctrl, b, progress)
        drawCursor(ctx, at: pos)
    }

    private func quadPoint(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(x: mt * mt * a.x + 2 * mt * t * c.x + t * t * b.x,
                       y: mt * mt * a.y + 2 * mt * t * c.y + t * t * b.y)
    }

    private func drawDot(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, color: NSColor) {
        ctx.setFillColor(color.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawLabel(_ text: String, centeredAt p: CGPoint, small: Bool = false) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 13 : 17, weight: small ? .medium : .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.55),
            .strokeWidth: -2.0,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
        return size
    }

    /// 圆角胶囊文案板：深色底 + 主题色描边，比纯文字更醒目。
    private func drawPill(_ ctx: CGContext, text: String, at p: CGPoint, small: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 13 : 20, weight: small ? .medium : .bold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let textSize = s.size()
        let padX: CGFloat = small ? 12 : 16
        let padY: CGFloat = small ? 6 : 8
        let boxSize = CGSize(width: textSize.width + padX * 2, height: textSize.height + padY * 2)
        let box = CGRect(x: p.x - boxSize.width / 2, y: p.y - boxSize.height / 2,
                         width: boxSize.width, height: boxSize.height)
        let rr = CGPath(roundedRect: box, cornerWidth: boxSize.height / 2,
                        cornerHeight: boxSize.height / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 18,
                      color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        ctx.addPath(rr)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.6)
        ctx.addPath(rr)
        ctx.strokePath()
        ctx.restoreGState()
        s.draw(at: CGPoint(x: p.x - textSize.width / 2, y: p.y - textSize.height / 2))
    }

    private func drawCursor(_ ctx: CGContext, at p: CGPoint) {
        // 手绘箭头：白色填充 + 黑色描边 + 主题色外发光，尺寸放大到 44pt。
        let h: CGFloat = 52
        let pts: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: -h),
            CGPoint(x: h * 0.30, y: -h * 0.68),
            CGPoint(x: h * 0.50, y: -h * 0.96),
            CGPoint(x: h * 0.68, y: -h * 0.86),
            CGPoint(x: h * 0.50, y: -h * 0.58),
            CGPoint(x: h * 0.84, y: -h * 0.58),
        ]
        let arrow = CGMutablePath()
        arrow.move(to: pts[0])
        for q in pts.dropFirst() { arrow.addLine(to: q) }
        arrow.closeSubpath()

        // 外发光
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.setShadow(offset: .zero, blur: 22,
                      color: NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor)
        ctx.addPath(arrow)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 主体 + 描边
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.addPath(arrow)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(arrow)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2.2)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
