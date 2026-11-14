// AppUI.swift —— 菜单栏面板（SwiftUI）
//
// 只做展示与控制，不碰采集/编码/网络。所有数据来自引擎全局量，
// 由主线程每秒刷新一次，避免 UI 线程和采集线程互相阻塞。

import SwiftUI
import AppKit

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
    @Published var skipped = 0
    @Published var width = 0
    @Published var height = 0
    @Published var scale: Double = 1.0
    @Published var cursorHz: Double = 0
    @Published var presetName = "-"
    @Published var cursorImageOn = true
    @Published var logLine = ""
    @Published var resolutionIndex = 0
    /// 刷新时置位，避免程序化改选中项触发重启
    var suppressResolutionChange = false

    static let resolutions: [(label: String, w: Int, h: Int, lw: Int, lh: Int)] = [
        ("1600 × 1000 (1x)", 1600, 1000, 1600, 1000),
        ("1920 × 1200 (2x Retina)", 1920, 1200, 960, 600),
        ("2240 × 1400 (2x Retina)", 2240, 1400, 1120, 700),
        ("2560 × 1600 (2x Retina)", 2560, 1600, 1280, 800),
        // 真 2x Retina（1440×900 逻辑 / 2880×1800 物理）：
        // 与 Windows 2880×1800 物理屏 1:1 像素对齐，同时 Mac 端按 2x 渲染字体与正常桌面比例。
        ("2880 × 1800 (2x Retina · 推荐)", 2880, 1800, 1440, 900),
        ("2880 × 1800 (1x)", 2880, 1800, 2880, 1800),
        // 16:9 档位：Windows 显示器为 16:9 时选对应的，全屏才能 1:1
        ("1920 × 1080 (1x)", 1920, 1080, 1920, 1080),
        ("2560 × 1440 (2x Retina)", 2560, 1440, 1280, 720),
        ("3840 × 2160 (2x Retina)", 3840, 2160, 1920, 1080),
    ]

    private init() {}

    /// 主线程每秒调用
    func refresh() {
        connected = sender.connected
        fps = peakFps
        encMs = lastEncAvgMs
        capMs = lastCapAvgMs
        mbps = lastMbps
        inFlight = sender.inFlight
        dropped = sender.dropped
        skipped = cap.staticSkipCount
        width = cfg.width
        height = cfg.height
        scale = vdBackingScale
        cursorHz = cursor.targetHz
        cursorImageOn = !disableCursorImage
        presetName = mainPresetLabel()
        logLine = Log.currentPath
        suppressResolutionChange = true
        resolutionIndex = AppModel.resolutions.firstIndex { $0.w == cfg.width && $0.h == cfg.height && $0.lw == cfg.logicalWidth && $0.lh == cfg.logicalHeight } ?? -1
        suppressResolutionChange = false
    }
}

private func mainPresetLabel() -> String {
    if ProcessInfo.processInfo.environment["SECDISPLAY_W"] != nil {
        return "自定义"
    }
    return presetName ?? "自定义"
}

private let accent = Color(red: 0.22, green: 0.55, blue: 0.96)

private struct StatRow: View {
    let label: String
    let value: String
    var mono = true
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.primary)
        }
    }
}

struct StatusView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部
            HStack(spacing: 10) {
                Circle()
                    .fill(model.connected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(model.connected ? "已连接" : "等待接收端")
                    .font(.headline)
                Spacer()
                Text(model.scale > 1.5
                     ? "\(model.width)×\(model.height) · 2x"
                     : "\(model.width)×\(model.height) · 1x")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 实时指标
            VStack(spacing: 8) {
                StatRow(label: "帧率", value: String(format: "%.0f fps", model.fps))
                StatRow(label: "编码延迟", value: String(format: "%.1f ms", model.encMs))
                StatRow(label: "采集延迟", value: String(format: "%.1f ms", model.capMs))
                StatRow(label: "码率", value: String(format: "%.1f Mbps", model.mbps))
                StatRow(label: "在途 / 丢弃", value: "\(model.inFlight) / \(model.dropped)")
                StatRow(label: "静止跳过", value: "\(model.skipped)")
                StatRow(label: "光标频率", value: String(format: "%.0f Hz", model.cursorHz))
                StatRow(label: "画质档位", value: model.presetName)

                HStack {
                    Text("切换分辨率").foregroundStyle(.secondary)
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
                    .frame(width: 160)
                }
            }

            Divider()

            // 控制
            VStack(spacing: 10) {
                Toggle("发送真实光标图像", isOn: Binding(
                    get: { model.cursorImageOn },
                    set: { on in
                        disableCursorImage = !on
                        Log.info(on ? "面板开启光标图像(0x05)" : "面板关闭光标图像(0x05)")
                    }))
                    .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button("强制关键帧") {
                        encoder.forceEncodeLastFrame()
                        Log.info("面板请求强制关键帧")
                    }
                    Button("打开日志") {
                        openLogsFolder()
                    }
                    Spacer()
                    Button("隐藏") {
                        hideControlPanel()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("退出") {
                        // 退出清理里有嵌套 RunLoop 等待，放回主队列执行，避免卡在动画/事件循环里
                        DispatchQueue.main.async { shutdown(signal: SIGTERM) }
                    }
                    .keyboardShortcut("q")
                }
            }

            if !model.logLine.isEmpty {
                Text(model.logLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// 切换分辨率：虚拟屏和编码器都在启动时按尺寸建好，改尺寸只能重建进程。
/// 命令行启动走 run.sh restart；.app 启动时没有 run.sh，直接重启自身。
func restartWithResolution(_ w: Int, _ h: Int, _ lw: Int, _ lh: Int) {
    let dir = FileManager.default.currentDirectoryPath
    Log.info("面板切换分辨率 \(w)x\(h)，准备重启")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    if FileManager.default.fileExists(atPath: dir + "/run.sh") {
        p.arguments = ["-c", "sleep 9; cd \"\(dir)\" && SECDISPLAY_W=\(w) SECDISPLAY_H=\(h) SECDISPLAY_LOGICAL_W=\(lw) SECDISPLAY_LOGICAL_H=\(lh) ./run.sh restart"]
    } else {
        // .app 场景：用 open 重新拉起 bundle，保持 TCC 归属在 bundle 上。
        // 直接跑 Contents/MacOS/SecDisplay 会被当成裸二进制，权限可能对不上。
        let appPath = Bundle.main.bundlePath
        p.arguments = ["-c", "sleep 9; open -n \"\(appPath)\" --env SECDISPLAY_W=\(w) --env SECDISPLAY_H=\(h) --env SECDISPLAY_LOGICAL_W=\(lw) --env SECDISPLAY_LOGICAL_H=\(lh)"]
    }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
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

/// 隐藏面板但保留进程。面板只是个查看窗口，关掉不该影响推流。
func hideControlPanel() {
    panelWindow?.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
    Log.info("面板已隐藏")
}
private var panelWindow: NSWindow?

/// 面板可见期间暂停 Windows 输入回放。
///
/// InputInjector.handle 每个输入包都会 post 一个 .mouseMoved，把 Mac 光标
/// warp 到虚拟屏坐标。Windows 端持续发包时，用户去点本机面板的鼠标会被
/// 瞬间拽走，表现为「面板画得出来、所有按钮点不动」。
/// 用显式开关而不是「判断当前光标位置」：后者一旦光标被拽进虚拟屏就会
/// 自我放行、把光标钉死，且会在副屏操作时误丢事件。
var isControlPanelVisible: Bool {
    (panelWindow?.isVisible ?? false)
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
    // 这个进程平时是 .accessory（LSUIElement），菜单栏常驻、不进 Dock。
    // 但 LSUIElement 应用里 activate(ignoringOtherApps:) 通常不会让它真正 active，
    // 面板窗口能画出来、按钮却收不到鼠标事件，表现就是「全都点不动」。
    // 显示面板时临时切成 .regular 让 App 能拿到前台与 key；关面板再切回去。
    Log.info("打开控制面板请求")
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    if let w = panelWindow {
        placeOnUserScreen(w)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        Log.info("面板已前置 key=\(w.isKeyWindow) visible=\(w.isVisible) frame=\(w.frame)")
        return
    }

    let host = NSHostingView(rootView: StatusView())
    let w = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
        styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
        backing: .buffered,
        defer: false)
    w.title = "SecDisplay 发送端"
    w.titlebarAppearsTransparent = true
    w.isReleasedWhenClosed = false
    w.hidesOnDeactivate = false
    w.contentView = host
    placeOnUserScreen(w)
    w.makeKeyAndOrderFront(nil)
    w.orderFrontRegardless()
    panelWindow = w
    Log.info("面板已创建 frame=\(w.frame) key=\(w.isKeyWindow) visible=\(w.isVisible)")
}
