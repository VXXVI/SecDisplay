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

private var panelWindow: NSWindow?

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

/// 打开/前置控制面板
func showControlPanel() {
    // .accessory 进程不会自动激活，窗口只 makeKeyAndOrderFront 有可能被别的 App
    // 压在后面，看起来像「点了没反应」。先激活，再置前，最后兜底 orderFrontRegardless。
    Log.info("打开控制面板请求")
    NSApp.activate(ignoringOtherApps: true)

    if let w = panelWindow {
        Log.info("复用已有面板 isVisible=\(w.isVisible)")
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        Log.info("面板已前置 key=\(w.isKeyWindow) visible=\(w.isVisible)")
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
    w.center()
    w.makeKeyAndOrderFront(nil)
    w.orderFrontRegardless()
    panelWindow = w
    Log.info("面板已创建 frame=\(w.frame) key=\(w.isKeyWindow) visible=\(w.isVisible)")
}
