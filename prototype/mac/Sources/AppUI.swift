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
    @Published var cursorHz: Double = 0
    @Published var presetName = "-"
    @Published var cursorImageOn = true
    @Published var logLine = ""
    @Published var resolutionIndex = 0
    /// 刷新时置位，避免程序化改选中项触发重启
    var suppressResolutionChange = false

    static let resolutions: [(label: String, w: Int, h: Int, lw: Int, lh: Int)] = [
        ("1600 × 1000", 1600, 1000, 1600, 1000),
        ("1920 × 1200", 1920, 1200, 1920, 1200),
        ("2240 × 1400", 2240, 1400, 2240, 1400),
        ("2560 × 1600", 2560, 1600, 2560, 1600),
        ("2880 × 1800", 2880, 1800, 2880, 1800),
        // 2880×1800 像素 + 1440×900 逻辑 = 标准 2x HiDPI。
        // Windows 200% 缩放的 2880×1800 屏用这一档文字最锐，桌面布局也正常。
        ("2880 × 1800 @ 2x", 2880, 1800, 1440, 900),
        // 16:9 档位：Windows 显示器主流比例，选对了接收端全屏才能 1:1 不缩放
        ("1920 × 1080", 1920, 1080, 1920, 1080),
        ("2560 × 1440", 2560, 1440, 2560, 1440),
        ("3840 × 2160", 3840, 2160, 3840, 2160),
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
        cursorHz = cursor.targetHz
        cursorImageOn = !disableCursorImage
        presetName = ProcessInfo.processInfo.environment["SECDISPLAY_PRESET"] ?? "自定义"
        logLine = Log.currentPath
        suppressResolutionChange = true
        resolutionIndex = AppModel.resolutions.firstIndex { $0.w == cfg.width && $0.h == cfg.height && $0.lw == cfg.logicalWidth && $0.lh == cfg.logicalHeight } ?? -1
        suppressResolutionChange = false
    }
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
                Text("\(model.width)×\(model.height)")
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

/// 关闭面板但保留进程。面板只是个查看窗口，关掉不该影响推流。
func hideControlPanel() {
    guard let p = panelPopover else { return }
    p.performClose(nil)
    Log.info("面板已关闭")
}

private var panelPopover: NSPopover?

/// 控制面板做成挂在菜单栏图标上的 popover。
///
/// 之前用的是独立 NSWindow：这个进程是 .accessory，窗口要先激活 App 才能拿到 key，
/// 而在这台机器上激活一直被别的进程抢走，结果窗口画得出来、所有按钮点不动。
/// popover 由状态栏按钮托管，激活和事件路由都走系统那条成熟路径，不靠我们自己抢焦点。
/// .transient 让点外面就自动收起，正好符合「不挡工作」。
func showControlPanel() {
    Log.info("打开控制面板请求")

    if let p = panelPopover, p.isShown {
        p.performClose(nil)
        Log.info("面板已收起")
        return
    }

    guard let button = statusItem?.button else {
        Log.info("面板打开失败: 菜单栏按钮不存在")
        return
    }

    let p = NSPopover()
    p.behavior = .transient
    p.animates = true
    p.contentSize = NSSize(width: 380, height: 520)
    p.contentViewController = NSHostingController(rootView: StatusView())
    panelPopover = p

    NSApp.activate(ignoringOtherApps: true)
    p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    Log.info("面板已弹出 shown=\(p.isShown)")
}
