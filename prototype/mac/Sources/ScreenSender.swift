// ============================================================================
// ScreenSender —— Mac 端主程序
//
// 管线: CGVirtualDisplay 建屏 → ScreenCaptureKit 抓帧 → VideoToolbox 低延迟硬编
//       → TCP_NODELAY 发送 → 接收端控制消息回传
//
// 关键设计（每一项都是为了压延迟，对应开源方案做砸的地方）:
//   1. 虚拟屏像素 = 接收端屏幕物理像素，1:1，不做缩放
//   2. VideoToolbox 开低延迟模式，禁 B 帧，保证一进一出
//   3. TCP_NODELAY，禁止 Nagle 攒包
//   4. 在途帧数上限 2，缓冲满时丢新帧而不是排队（防延迟堆积）
//   5. 每个包头带采集时间戳，接收端可据此丢弃过期帧
//
// 协议（每帧）:
//   [4 字节大端长度][1 字节类型][8 字节采集时间戳 us][载荷]
//   长度字段 = 1 + 8 + 载荷长度，不含长度字段自身
//   类型 0x01 = 视频帧，载荷为 AVCC（[4 字节大端长度][NAL] 重复）
//               关键帧开头由本端拼上 SPS/PPS（VT 输出不含参数集）
//   类型 0x02 = 请求关键帧（接收端 → 本端，1 字节）
// ============================================================================

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import Network
import ObjectiveC.runtime
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 配置

struct Config {
    // 对应 Lenovo Yoga Slim 7 Pro 14IHU5（82NC）2880x1800 高刷版，
    // 系统 200% 缩放：物理 2880x1800，逻辑 1440x900。
    // 背板 = 物理像素，逻辑 = 一半，这样是 2x Retina，文字最锐利。
    var width = 2880
    var height = 1800
    var logicalWidth = 1440
    var logicalHeight = 900
    var refreshRate = 90.0     // 虚拟屏刷新率

    /// 采集帧率上限。
    ///
    /// 关键参数：VideoToolbox 的 H.264 硬编在 2880x1800 上大约只能稳定 46fps。
    /// 采集喂得更快，帧就堆在编码器内部，延迟从 25ms 一路涨到 90ms，
    /// 表现为「越用越卡」。压到 45fps 以下后延迟稳定在 25ms 左右。
    ///
    /// 实测（2880x1800，M1 Pro）：
    ///   采集 60Hz → 55fps, 中位 67ms
    ///   采集 50Hz → 46fps, 中位 28ms
    ///   采集 45Hz → 43fps, 中位 26ms   ← 默认
    ///   采集 40Hz → 39fps, 中位 27ms
    ///   采集 30Hz → 29fps, 中位 24ms
    var captureHz = 45.0
    // 2.2K 桌面文字需要足够码率才清晰。千兆网给到 120 仍有余量。
    var bitrateMbps = 180      // 2880x1800 码率要比 2.2K 更高
    var port: UInt16 = 9922
    // 静止画面保活间隔（秒）。ScreenCaptureKit 画面不动就不出帧，
    // 超过这个间隔没有新帧就重发最后一帧；设 0 关闭。
    var keepAliveGap = 0.5
}

// MARK: - 虚拟屏

final class VirtualDisplayManager {
    private(set) var object: NSObject?
    private(set) var displayID: CGDirectDisplayID = 0

    func create(_ cfg: Config) throws {
        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let dispCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let setCls  = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else { throw Err.classesMissing }

        let queue = DispatchQueue(label: "SecDisplay.vd")
        let d = descCls.init()
        d.setValue(NSNumber(value: 0x2B3), forKey: "vendorID")
        d.setValue(NSNumber(value: 0x1000), forKey: "productID")
        d.setValue(NSNumber(value: 1), forKey: "serialNum")
        d.setValue("SecDisplay", forKey: "name")
        d.setValue(NSNumber(value: cfg.width), forKey: "maxPixelsWide")
        d.setValue(NSNumber(value: cfg.height), forKey: "maxPixelsHigh")
        d.setValue(NSValue(size: NSSize(width: 25.4 * Double(cfg.width) / 110.0,
                                        height: 25.4 * Double(cfg.height) / 110.0)),
                   forKey: "sizeInMillimeters")
        d.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        d.setValue(queue, forKey: "queue")

        let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        guard let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?
                .takeUnretainedValue() as? NSObject else { throw Err.initFailed }

        let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeInit = unsafeBitCast(modeAlloc.method(for: modeSel), to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeSel,
                                  UInt(cfg.logicalWidth), UInt(cfg.logicalHeight),
                                  cfg.refreshRate) as? NSObject else { throw Err.modeFailed }

        let settings = setCls.init()
        settings.setValue(cfg.logicalWidth * 2 <= cfg.width, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        // BOOL 返回值必须直接调用
        let applySel = NSSelectorFromString("applySettings:")
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)(disp, applySel, settings) else {
            throw Err.applyFailed
        }

        object = disp
        displayID = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)

        var waited = 0.0
        while waited < 2.0 {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(32, nil, &n)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &ids, &n)
            if ids.contains(displayID) { break }
            usleep(20_000); waited += 0.02
        }
        Log.info("虚拟屏就绪 id=\(displayID) \(cfg.width)x\(cfg.height)")
    }

    /// 正确销毁：取出 CGVirtualDisplay 内部的 _client 指针，交给 CDVirtualDisplayDestroy。
    /// 传对象本身会触发 CoreDisplay 内部断言；只释放引用屏不会消失。
    func destroy() {
        guard let obj = object else { return }
        if let cls = NSClassFromString("CGVirtualDisplay"),
           let ivar = class_getInstanceVariable(cls, "_client") {
            let raw = UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
                .advanced(by: ivar_getOffset(ivar))
            if let clientPtr = raw.load(as: UnsafeMutableRawPointer?.self),
               let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
               let sym = dlsym(h, "CDVirtualDisplayDestroy") {
                typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer) -> Void
                unsafeBitCast(sym, to: DestroyFn.self)(clientPtr)
                Log.info("虚拟屏已销毁")
            }
        }
        object = nil
    }

    enum Err: Error { case classesMissing, initFailed, modeFailed, applyFailed }
}

// MARK: - 退出清理

/// 信号处理器里只置标志位。真正的清理在主循环里做，
/// 因为 signal handler 中调用 ObjC runtime / dlopen 属于 async-signal-unsafe。
enum VirtualDisplayGuard {
    nonisolated(unsafe) static var pendingSignal: Int32 = 0

    static func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { s in VirtualDisplayGuard.pendingSignal = s }
        }
    }
}

// MARK: - 日志

enum Log {
    static let fmt = DateFormatter()
    static func info(_ s: String) {
        let t = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 100000))
        FileHandle.standardError.write("[\(t)] \(s)\n".data(using: .utf8)!)
    }
}

// MARK: - 编码器

final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let bitrate: Int
    var onFrame: ((Data, Bool, UInt64) -> Void)?

    private(set) var encoded = 0
    private(set) var keyframeCount = 0
    private(set) var bytes = 0
    private(set) var lastKeyframeCheck = 0

    init(width: Int, height: Int, bitrateMbps: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrateMbps * 1_000_000
        self.currentMbps = bitrateMbps
    }

    func start() -> Bool {
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
        ]
        let attrs: [String: Any] = [
            // 用原生 YUV 而不是 BGRA：SCK 直接给 YUV，编码器也直接吃 YUV，
            // 省掉两次全画面色彩转换。2880x1800 下 BGRA 每帧 20MB，
            // YUV420 只有 7.8MB，内存带宽少 60%。
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let cb: VTCompressionOutputCallback = { ref, sourceFrameRefcon, status, _, sample in
            guard let ref else {
                // 回调仍会到来，必须释放 box 防止泄漏
                if let sourceFrameRefcon { UnsafeMutablePointer<UInt64>(OpaquePointer(sourceFrameRefcon)).deallocate() }
                return
            }
            let enc = Unmanaged<Encoder>.fromOpaque(ref).takeUnretainedValue()
            guard status == noErr, let sample else {
                if let sourceFrameRefcon { UnsafeMutablePointer<UInt64>(OpaquePointer(sourceFrameRefcon)).deallocate() }
                return
            }
            enc.emit(sample, refcon: sourceFrameRefcon)
        }
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: cb,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard st == noErr, let s = session else {
            Log.info("编码器创建失败 \(st)"); return false
        }
        let env = ProcessInfo.processInfo.environment
        let variant = env["SECDISPLAY_ENC"] ?? "A"

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)

        switch variant {
        case "B":
            // 不设码率与帧延迟，交给低延迟 rate control
            break
        case "C":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        case "D":
            // 用 DataRateLimits 代替 AverageBitRate
            let limits: [NSNumber] = [NSNumber(value: bitrate / 8), NSNumber(value: 1.0)]
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        case "E":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        default:  // A：原样
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        }

        VTCompressionSessionPrepareToEncodeFrames(s)
        Log.info("编码参数方案 \(variant)")
        return true
    }

    /// 自增帧序号，用作编码 PTS。
    /// 采集帧和保活帧的时间基准不同，混用会让 PTS 非单调，编码器可能报错。
    /// 真正的端到端时间戳走 captureTimeMicros，与 PTS 无关。
    private var frameSeq: Int64 = 0

    /// 最近一帧的输入画面。屏幕完全静止时没有新帧可编，
    /// 收到关键帧请求需要用它临时补一个 IDR，否则接收端一直黑屏。
    private var lastPixelBuffer: CVPixelBuffer?
    private let lastBufferLock = NSLock()

    func encode(_ pb: CVPixelBuffer, pts: CMTime, captureTimeMicros: UInt64) {
        lastBufferLock.lock()
        lastPixelBuffer = pb
        lastBufferLock.unlock()
        encodeInternal(pb, captureTimeMicros: captureTimeMicros)
    }

    /// 串行化编码调用。采集线程和关键帧补发可能并发进来，
    /// frameSeq 自增不是原子的，并发会产出重复 PTS。
    private let encodeLock = NSLock()

    private func encodeInternal(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let s = session else { return }
        // 时间戳随帧走：经 sourceFrameRefcon 传给输出回调，避免跨线程共享变量。
        // 堆上分配一个 box，由 emit 负责释放；即使帧被编码器丢弃也不会泄漏
        //（VT 保证每个 refcon 都会在输出或丢弃时被回调一次）。
        let box = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        box.pointee = captureTimeMicros

        // 接收端请求关键帧时，这一帧强制 IDR
        wantKeyframeLock.lock()
        let forceKey = wantKeyframe
        wantKeyframe = false
        wantKeyframeLock.unlock()
        let props: CFDictionary? = forceKey
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary)
            : nil

        frameSeq += 1
        let monotonicPTS = CMTime(value: frameSeq, timescale: CMTimeScale(max(1, Int(60))))

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pb, presentationTimeStamp: monotonicPTS,
            duration: CMTime(value: 1, timescale: 60), frameProperties: props,
            sourceFrameRefcon: UnsafeMutableRawPointer(box), infoFlagsOut: &flags)
        if status != noErr { box.deallocate() }
    }

    /// 动态调整码率。按接收端反馈或本地丢帧情况调用。
    /// - Parameter mbps: 目标码率（Mbps）
    func setBitrate(_ mbps: Int) {
        guard let s = session, mbps > 0 else { return }
        let clamped = max(8, min(mbps, 300))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: (clamped * 1_000_000) as CFNumber)
        currentMbps = clamped
    }

    private(set) var currentMbps = 0

    /// 请求下一帧编码为 IDR。由接收端 0x02 控制消息触发。
    private let wantKeyframeLock = NSLock()
    private var wantKeyframe = false

    func requestKeyframe() {
        wantKeyframeLock.lock()
        wantKeyframe = true
        wantKeyframeLock.unlock()
    }

    func stop() {
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }

    /// 编码管线延迟统计：从采集时间戳到编码输出回调
    var encLatSum: Double = 0
    var encLatMax: Double = 0
    var encLatCount = 0

    private func emit(_ sample: CMSampleBuffer, refcon: UnsafeMutableRawPointer?) {
        // 取出并释放时间戳 box
        var captureTime: UInt64 = 0
        if let refcon {
            let box = refcon.assumingMemoryBound(to: UInt64.self)
            captureTime = box.pointee
            box.deallocate()
        }
        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr, length > 0 else { return }

        var isKey = false
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first {
            isKey = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        // 实测结论（见 research/BENCH-03-latency.md 坑 1、坑 2）：
        //   1. VT 输出的 AVCC 里不含 SPS/PPS，参数集只在 formatDescription 中，
        //      关键帧必须自己按 AVCC 长度前缀补上，不能用 Annex-B 起始码。
        //   2. 全程保持 AVCC，绝不转 Annex-B：H.264 码流内部天然会出现 00 00 00 01，
        //      用起始码扫描切分会切错位置。
        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                              parameterSetPointerOut: nil,
                                                              parameterSetSizeOut: nil,
                                                              parameterSetCountOut: &count,
                                                              nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                                                                  parameterSetPointerOut: &p,
                                                                  parameterSetSizeOut: &sz,
                                                                  parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil)
                if let p, sz > 0 {
                    var l = UInt32(sz).bigEndian
                    withUnsafeBytes(of: &l) { out.append(contentsOf: $0) }
                    out.append(p, count: sz)
                }
            }
        }
        // 编码器输出的视频数据本身就是 AVCC，原样追加
        out.append(Data(bytes: ptr, count: length))

        if captureTime > 0 {
            let latMs = (CFAbsoluteTimeGetCurrent() - Double(captureTime) / 1_000_000) * 1000
            if latMs >= 0 && latMs < 5000 {
                encLatSum += latMs
                encLatCount += 1
                if latMs > encLatMax { encLatMax = latMs }
            }
        }

        if isKey { keyframeCount += 1 }
        encoded += 1
        bytes += out.count
        onFrame?(out, isKey, captureTime)
    }

}

// MARK: - 抓屏

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let encoder: Encoder
    private let cfg: Config
    /// 虚拟屏 id 可能变化（重建虚拟屏后），每次重建流都重新问一次
    private let displayIDProvider: () -> CGDirectDisplayID

    var stream: SCStream?
    var captured = 0
    /// 采集段延迟：系统合成完成 → 我们拿到帧
    var capLatSum: Double = 0
    var capLatCount = 0
    var capLatMax: Double = 0
    var lastFrameTime: CFAbsoluteTime = 0
    var idleFrames = 0

    // --- 自愈 ---
    private let ctl = DispatchQueue(label: "SecDisplay.capture.ctl")
    private var watchdog: DispatchSourceTimer?
    private var lastSeenCount = 0
    /// 任何类型的回调都计数，用来区分「流死了」和「画面静止」
    private var progressCount = 0
    private(set) var idleFrameCount = 0
    private var lastProgressAt = CFAbsoluteTimeGetCurrent()
    private var needsRestart = false
    private var restarting = false
    private var restartCount = 0
    /// 超过这个秒数没有新帧就认为流死了
    private let stallTimeout: CFAbsoluteTime = 10.0   // 只作兜底，主要靠 didStopWithError

    init(encoder: Encoder, cfg: Config, displayID: @escaping () -> CGDirectDisplayID) {
        self.encoder = encoder
        self.cfg = cfg
        self.displayIDProvider = displayID
        super.init()
    }

    /// 首次启动：失败会抛出，由调用方提示权限问题
    func start() async throws {
        try await buildStream()
        startWatchdog()
    }

    private func buildStream() async throws {
        let wantID = displayIDProvider()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // 优先按 id 找；找不到就按名字找（虚拟屏重建后 id 会变）
        var target = content.displays.first(where: { $0.displayID == wantID })
        if target == nil {
            target = content.displays.first(where: { $0.displayID != CGMainDisplayID() && $0.width == cfg.width })
        }
        guard let display = target else {
            throw NSError(domain: "Capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到虚拟屏（期望 id=\(wantID)，可用 \(content.displays.map { $0.displayID })）"
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = cfg.width
        c.height = cfg.height
        // 采集帧率。编码器在 2880x1800 上大约只能稳定 45fps，
        // 采集喂得更快只会在 VideoToolbox 内部堆积，延迟从 40ms 涨到 90ms。
        // 用 SECDISPLAY_HZ 可以试不同档位。
        let capHz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] ?? "") ?? cfg.captureHz
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(capHz))
        // 队列深度直接决定 SCK 内部的缓冲帧数，也就直接决定延迟。
        // 3 帧在 60fps 下约 50ms；越深越不容易丢帧，但延迟越高。
        c.queueDepth = Int(ProcessInfo.processInfo.environment["SECDISPLAY_QD"] ?? "") ?? 3
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // 光标不画进视频：视频帧率只有 45fps，指针会把延迟放大成拖影。
        // 指针位置改由独立的轻量消息高频发送，客户端本地绘制。
        c.showsCursor = false
        c.scalesToFit = false
        c.capturesAudio = false
        c.preservesAspectRatio = true

        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "SecDisplay.capture"))
        try await s.startCapture()

        stream = s
        lastProgressAt = CFAbsoluteTimeGetCurrent()
        lastSeenCount = progressCount
        Log.info("抓屏已启动 displayID=\(display.displayID) \(cfg.width)x\(cfg.height)，采集上限 \(Int(capHz))fps")
    }

    // MARK: 看门狗

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: ctl)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func tick() {
        if restarting { return }
        let now = CFAbsoluteTimeGetCurrent()
        if progressCount != lastSeenCount {
            lastSeenCount = progressCount
            lastProgressAt = now
        }
        let stalled = now - lastProgressAt > stallTimeout
        guard needsRestart || stalled else { return }
        if needsRestart {
            Log.info("抓屏流已停止，准备重建")
        } else {
            Log.info("抓屏 \(Int(stallTimeout)) 秒无新帧，准备重建流")
        }
        needsRestart = false
        restartStream()
    }

    /// 重建采集流。停旧的、重新取显示器、重新建流。
    func restartStream() {
        ctl.async { [weak self] in
            guard let self, !self.restarting else { return }
            self.restarting = true
            self.restartCount += 1
            let n = self.restartCount

            let old = self.stream
            self.stream = nil
            Task {
                if let old { try? await old.stopCapture() }
                // 给系统一点时间释放对旧流的引用
                try? await Task.sleep(nanoseconds: 300_000_000)
                do {
                    try await self.buildStream()
                    Log.info("抓屏流重建成功（第 \(n) 次）")
                } catch {
                    Log.info("抓屏流重建失败（第 \(n) 次）: \(error)")
                    // 下次 tick 会再试
                    self.lastProgressAt = CFAbsoluteTimeGetCurrent()
                    self.needsRestart = true
                }
                self.restarting = false
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        // 任何回调都说明流还活着，包括画面没变化时的 idle 帧。
        // 只把 complete 帧送去编码，避免重复编码同一画面。
        progressCount += 1

        if status == .stopped {
            Log.info("SCK 报告流已停止，触发重建")
            needsRestart = true
            return
        }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else {
            idleFrameCount += 1
            return
        }

        captured += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()

        // 采集段延迟：样本 PTS 与主机时钟的差值。
        // SCK 的 PTS 走主机时钟（mach 时基），不能直接和 CFAbsoluteTime 相减。
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let deltaSec = CMTimeGetSeconds(CMTimeSubtract(hostNow, pts))
        if deltaSec.isFinite && deltaSec >= 0 && deltaSec < 2 {
            let delayMs = deltaSec * 1000
            capLatSum += delayMs
            capLatCount += 1
            if delayMs > capLatMax { capLatMax = delayMs }
        }
        let nowMicros = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
        encoder.encode(pb, pts: pts, captureTimeMicros: nowMicros)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("抓屏停止: \(error)")
        // ScreenCaptureKit 不会自己恢复，交给看门狗重建
        ctl.async { [weak self] in self?.needsRestart = true }
    }
}

// MARK: - 网络发送

final class Sender {
    private(set) var conn: NWConnection?
    /// 连接代数，用于识别陈旧回调
    private var connEpoch: Int = 0
    private let queue = DispatchQueue(label: "SecDisplay.net")
    private(set) var inFlight = 0
    private let maxInFlight = 2
    var dropped = 0
    var sent = 0
    var sentBytes = 0
    var connected = false

    func listen(port: UInt16) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 关闭 Nagle
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 3
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Log.info("端口 \(port) 监听失败（可能被占用）: \(error)")
            exit(6)
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            Log.info("接收端已连接: \(String(describing: c.endpoint))")

            // 连接代数：只有"当前"连接的回调才能改动共享状态。
            // 否则旧连接被 cancel 后异步回调 .cancelled，会把刚建立的新连接
            // 误标成断开，表现为连上后一帧都发不出去。
            self.connEpoch &+= 1
            let epoch = self.connEpoch

            let old = self.conn
            self.conn = c
            self.connected = true
            self.resetInFlight()          // 上一轮可能残留未完成的发送，必须清零
            // 丢掉上个连接的残留帧：那可能是依赖旧参考帧的 P 帧，
            // 新接收端没有参考帧，解出来是花的。等新的 IDR。
            self.counterLock.lock()
            self.lastPayload = nil
            self.lastSendAt = CFAbsoluteTimeGetCurrent()
            self.counterLock.unlock()
            old?.cancel()

            c.stateUpdateHandler = { [weak self] st in
                guard let self, self.connEpoch == epoch else { return }   // 陈旧连接，忽略
                switch st {
                case .failed(let e):
                    Log.info("连接失败: \(e)")
                    self.connected = false
                case .cancelled:
                    self.connected = false
                case .ready:
                    Log.info("连接就绪")
                default:
                    break
                }
            }
            c.start(queue: self.queue)
            // 新连接一上来就准备关键帧，不依赖对端是否及时发 0x02。
            self.onKeyframeRequest?()
            self.receiveLoop(epoch: epoch)
        }
        listener.stateUpdateHandler = { st in
            if case .ready = st { Log.info("监听端口 \(port)，等待接收端连接") }
            if case .failed(let e) = st { Log.info("监听失败: \(e)") }
        }
        listener.start(queue: queue)
        startKeepAlive()
    }

    /// 控制通道缓冲。0x02 是 1 字节，0x04 输入事件是固定 12 字节，
    /// 必须按帧解析，不能逐字节扫描——否则二进制里的 0x02 会被误判。
    private var ctrlBuf = Data()

    private func receiveLoop(epoch: Int) {
        guard connEpoch == epoch, let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, self.connEpoch == epoch else { return }
            if let data, !data.isEmpty {
                self.ctrlBuf.append(data)
                self.drainControl()
            }
            if done || err != nil { self.connected = false; return }
            self.receiveLoop(epoch: epoch)
        }
    }

    private func drainControl() {
        while !ctrlBuf.isEmpty {
            let t = ctrlBuf[ctrlBuf.startIndex]
            if t == 0x02 {
                Log.info("收到关键帧请求，下一帧强制 IDR")
                onKeyframeRequest?()
                ctrlBuf.removeFirst(1)
            } else if t == 0x04 {
                // [0x04][float32 x][float32 y][uint8 buttons][int16 wheel] = 12 字节
                guard ctrlBuf.count >= 12 else { return }
                let b = ctrlBuf
                let o = b.startIndex
                func rdF(_ off: Int) -> Float {
                    var u: UInt32 = 0
                    for i in 0..<4 { u = (u << 8) | UInt32(b[o + off + i]) }
                    return Float(bitPattern: u)
                }
                let x = rdF(1)
                let y = rdF(5)
                let buttons = b[o + 9]
                let wheel = Int16(bitPattern: (UInt16(b[o + 10]) << 8) | UInt16(b[o + 11]))
                onInput?(x, y, buttons, wheel)
                ctrlBuf.removeFirst(12)
            } else {
                // 未知字节，丢掉，避免卡死
                ctrlBuf.removeFirst(1)
            }
            if ctrlBuf.count > 65536 { ctrlBuf.removeAll() }
        }
    }

    /// 收到对端 0x02 时回调，由外部接到编码器
    var onKeyframeRequest: (() -> Void)?
    /// 收到对端 0x04 输入事件：(x, y, buttons, wheel)
    var onInput: ((Float, Float, UInt8, Int16) -> Void)?

    private let counterLock = NSLock()

    /// 新连接建立时清零在途计数。
    /// 旧连接被重置时，未完成的 send 完成回调可能不再触发，
    /// inFlight 会永久停在 2，导致之后所有帧都被判为"拥塞"而丢弃。
    func resetInFlight() {
        counterLock.lock()
        inFlight = 0
        counterLock.unlock()
    }

    // --- 静止画面保活 ---
    // ScreenCaptureKit 是变化驱动的：画面不动就完全不出帧，接收端会长时间没有数据，
    // 表现为「连上了但不动」或统计里 Mbps 掉到 0。
    // 这里记住最后一帧的编码数据，空闲超时后重发它（重打时间戳，避免延迟统计虚高）。
    // 同一个 access unit 重复解码是安全的，解出来还是同一张图。
    private var lastPayload: Data?
    private var lastSendAt: CFAbsoluteTime = 0
    private var keepAliveTimer: DispatchSourceTimer?
    /// 超过这么久没有新帧就补一帧；设为 0 可关闭保活
    var keepAliveGap: CFAbsoluteTime = 0.08

    /// 光标位置。不走视频帧，独立小包，不占用在途帧配额。
    /// 坐标是相对虚拟屏左上角的像素值。
    func sendCursor(x: Float, y: Float, visible: Bool) {
        guard connected, let c = conn else { return }
        var packet = Data(capacity: 19)
        // 长度 = 1 类型 + 8 时间戳 + 9 载荷 = 18
        var len = UInt32(18).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x03)                  // 光标类型
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        var fx = x.bitPattern.bigEndian
        withUnsafeBytes(of: &fx) { packet.append(contentsOf: $0) }
        var fy = y.bitPattern.bigEndian
        withUnsafeBytes(of: &fy) { packet.append(contentsOf: $0) }
        packet.append(visible ? 1 : 0)
        c.send(content: packet, completion: .contentProcessed { _ in })
    }

    func send(frame: Data, captureTimeMicros: UInt64) {
        guard connected else { return }
        counterLock.lock()
        lastPayload = frame
        counterLock.unlock()
        transmit(frame, captureTimeMicros: captureTimeMicros)
    }

    private func transmit(_ frame: Data, captureTimeMicros: UInt64) {
        guard connected, let c = conn else { return }
        // 在途帧数超限：丢这一帧，保住实时性
        counterLock.lock()
        if inFlight >= maxInFlight {
            dropped += 1
            counterLock.unlock()
            return
        }
        inFlight += 1
        lastSendAt = CFAbsoluteTimeGetCurrent()
        counterLock.unlock()

        var packet = Data(capacity: frame.count + 13)
        var len = UInt32(frame.count + 9).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x01)
        var ts = captureTimeMicros.bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(frame)

        sent += 1
        sentBytes += packet.count
        c.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.counterLock.lock()
            self.inFlight = max(0, self.inFlight - 1)
            self.counterLock.unlock()
            if err != nil { self.connected = false }
        })
    }

    private func startKeepAlive() {
        guard keepAliveGap > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepAliveGap, repeating: keepAliveGap / 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.connected else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.counterLock.lock()
            let since = now - self.lastSendAt
            let payload = self.lastPayload
            self.counterLock.unlock()
            guard since >= self.keepAliveGap, let payload = payload else { return }
            // 时间戳用当前时刻：接收端按「本地时刻 - 远端时刻」算延迟，
            // 沿用旧时间戳会让延迟越算越大。
            self.transmit(payload, captureTimeMicros: UInt64(now * 1_000_000))
        }
        timer.resume()
        keepAliveTimer = timer
    }
}

// MARK: - 输入回传
//
// 副屏要能真正操作，必须把 Windows 侧的鼠标事件回放到 Mac 上。
// 否则用户在 Windows 屏幕上的点击对 Mac 毫无作用，或者和本机光标互相抢位置。
//
// 需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能。
final class InputInjector {
    private var lastButtons: UInt8 = 0
    private(set) var eventCount = 0

    /// - Parameters:
    ///   - x/y: 相对虚拟屏左上角的像素坐标
    ///   - buttons: bit0 左键，bit1 右键，bit2 中键
    ///   - wheel: 滚动量，正数向下
    func handle(x: Float, y: Float, buttons: UInt8, wheel: Int16, bounds: CGRect) {
        let p = CGPoint(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y))

        // 先移动指针，再处理按键，保证点击落在正确位置
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left) {
            mv.post(tap: .cghidEventTap)
        }

        // 按下 / 抬起
        let pairs: [(UInt8, CGEventType, CGEventType, CGMouseButton)] = [
            (0x1, .leftMouseDown,  .leftMouseUp,  .left),
            (0x2, .rightMouseDown, .rightMouseUp, .right),
            (0x4, .otherMouseDown, .otherMouseUp, .center),
        ]
        for (bit, downType, upType, btn) in pairs {
            let was = (lastButtons & bit) != 0
            let now = (buttons & bit) != 0
            if now && !was {
                CGEvent(mouseEventSource: nil, mouseType: downType,
                        mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
            } else if !now && was {
                CGEvent(mouseEventSource: nil, mouseType: upType,
                        mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
            }
        }
        lastButtons = buttons

        // 滚轮
        if wheel != 0 {
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: Int32(wheel), wheel2: 0, wheel3: 0) {
                e.location = p
                e.post(tap: .cghidEventTap)
            }
        }
        eventCount += 1
    }
}

// MARK: - 光标转发
//
// 视频帧只有 45fps，把指针画进画面会让它每 22ms 才动一次，观感是拖影。
// 这里把指针位置单独以高频小包发出去，客户端本地绘制，指针几乎零延迟。
final class CursorTracker {
    private let sender: Sender
    private let bounds: () -> CGRect
    private let queue = DispatchQueue(label: "SecDisplay.cursor")
    private var timer: DispatchSourceTimer?
    private var lastX: Float = .nan
    private var lastY: Float = .nan
    private var lastVisible = false
    /// 累计发出的光标包数量，用于统计展示
    private(set) var sentCount = 0

    init(sender: Sender, bounds: @escaping () -> CGRect) {
        self.sender = sender
        self.bounds = bounds
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 120Hz 轮询。只在位置变化超过 0.5px 时才发包，
        // 静止时几乎不产生流量。
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        // 没有连接时不记录位置，否则连上之后要等指针再次移动才会发第一包
        guard sender.connected else {
            lastX = .nan; lastY = .nan; lastVisible = false
            return
        }
        guard let ev = CGEvent(source: nil) else { return }
        let p = ev.location                 // 全局坐标，原点在主屏左上，y 向下
        let b = bounds()
        let rx = Float(p.x - b.minX)
        let ry = Float(p.y - b.minY)
        let inside = rx >= 0 && ry >= 0 && rx < Float(b.width) && ry < Float(b.height)

        let moved = !(abs(rx - lastX) < 0.5 && abs(ry - lastY) < 0.5)
        guard moved || inside != lastVisible else { return }

        lastX = rx; lastY = ry; lastVisible = inside
        sentCount += 1
        sender.sendCursor(x: rx, y: ry, visible: inside)
    }
}

// MARK: - 主流程

var cfg = Config()

// 预设档位：不同分辨率与采集帧率组合，用于对比流畅度与清晰度
// 用 SECDISPLAY_PRESET 选择：sharp / balanced / smooth / fast
if let preset = ProcessInfo.processInfo.environment["SECDISPLAY_PRESET"] {
    switch preset {
    case "sharp":       // 最清晰，帧率最低
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 40
    case "balanced":    // 默认
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 45
    case "smooth":      // 降分辨率换帧率
        cfg.width = 2240; cfg.height = 1400
        cfg.logicalWidth = 1120; cfg.logicalHeight = 700
        cfg.captureHz = 60
    case "fast":        // 最流畅，清晰度最差
        cfg.width = 1920; cfg.height = 1200
        cfg.logicalWidth = 960; cfg.logicalHeight = 600
        cfg.captureHz = 60
    default:
        break
    }
    Log.info("使用预设档位: \(preset)")
}

// 单项覆盖，优先级高于预设
if let w = Int(ProcessInfo.processInfo.environment["SECDISPLAY_W"] ?? ""),
   let h = Int(ProcessInfo.processInfo.environment["SECDISPLAY_H"] ?? "") {
    cfg.width = w; cfg.height = h
    cfg.logicalWidth = w / 2; cfg.logicalHeight = h / 2
}
if let hz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] ?? "") {
    cfg.captureHz = hz
}
let vd = VirtualDisplayManager()
let encoder = Encoder(width: cfg.width, height: cfg.height, bitrateMbps: cfg.bitrateMbps)
let sender = Sender()
sender.keepAliveGap = cfg.keepAliveGap

guard encoder.start() else { exit(3) }

encoder.onFrame = { data, isKey, ts in
    sender.send(frame: data, captureTimeMicros: ts)
}

do {
    try vd.create(cfg)
} catch VirtualDisplayManager.Err.initFailed {
    // 系统里已有残留虚拟屏占位时，新建会被拒绝
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    Log.info("虚拟屏创建被拒绝（initWithDescriptor 返回 nil）")
    Log.info("当前在线显示器: \(ids)")
    if ids.count > 1 {
        Log.info("原因：上一次运行异常退出，留下了残留虚拟屏占住了位置")
        Log.info("处理：注销并重新登录（或重启）后再运行")
    } else {
        Log.info("原因不明，请检查系统日志")
    }
    exit(2)
} catch {
    Log.info("虚拟屏创建失败: \(error)")
    exit(2)
}

// 接收端的 0x02 控制消息 → 让编码器下一帧强制 IDR
sender.onKeyframeRequest = { encoder.requestKeyframe() }
sender.listen(port: cfg.port)

// 输入回传：Windows 侧的鼠标事件在 Mac 上重放
// 需要「辅助功能」权限，没有的话事件会被系统静默丢弃
if !AXIsProcessTrusted() {
    Log.info("警告: 未获得辅助功能权限，副屏上的点击/滚轮无法生效")
    Log.info("      系统设置 → 隐私与安全性 → 辅助功能，勾选运行本程序的终端")
}
let injector = InputInjector()
sender.onInput = { x, y, buttons, wheel in
    injector.handle(x: x, y: y, buttons: buttons, wheel: wheel,
                    bounds: CGDisplayBounds(vd.displayID))
}

// 光标转发：坐标是相对虚拟屏的像素值，虚拟屏重建后 id 变了也能拿到新 bounds
let cursor = CursorTracker(sender: sender, bounds: { CGDisplayBounds(vd.displayID) })
cursor.start()

// 传入 id 获取闭包：虚拟屏重建后 id 会变，采集侧每次重建流都重新问
let cap = Capture(encoder: encoder, cfg: cfg, displayID: { vd.displayID })
Task {
    do {
        try await cap.start()
    } catch {
        Log.info("抓屏失败: \(error)")
        Log.info("需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制")
        vd.destroy()
        exit(4)
    }
}

// MARK: - 自适应码率
//
// 原则：宁可降码率保流畅。画面糊一点还能办公，卡住没法用。
//   - 连续丢帧 → 码率下调（检测到拥塞）
//   - 长时间无丢帧 → 缓慢上调（回到目标值，但不超上限）
final class RateController {
    let encoder: Encoder
    let targetMbps: Int
    private var current: Int
    private var lastDropped = 0
    private var cleanRounds = 0

    init(encoder: Encoder, targetMbps: Int) {
        self.encoder = encoder
        self.targetMbps = targetMbps
        self.current = targetMbps
    }

    /// 每 2 秒调用一次，参数是本轮丢帧数
    func tick(dropped: Int) {
        let delta = dropped - lastDropped
        lastDropped = dropped

        if delta > 0 {
            // 有丢帧说明拥塞：一次下调 20%，最少 15 Mbps
            cleanRounds = 0
            let next = max(15, Int(Double(current) * 0.8))
            if next != current {
                current = next
                encoder.setBitrate(current)
                Log.info("网络拥塞，码率下调至 \(current) Mbps")
            }
        } else if current < targetMbps {
            // 连续 3 轮（约 6 秒）无丢帧才回升，避免来回抖
            cleanRounds += 1
            if cleanRounds >= 3 {
                cleanRounds = 0
                let next = min(targetMbps, Int(Double(current) * 1.15) + 1)
                if next != current {
                    current = next
                    encoder.setBitrate(current)
                    Log.info("网络良好，码率回升至 \(current) Mbps")
                }
            }
        }
    }
}

let rateCtl = RateController(encoder: encoder, targetMbps: cfg.bitrateMbps)

// 帧率峰值跟踪：每秒采一次完整帧数，保留最近 10 秒的最大值。
// 用户操作往往很短暂，只看 2 秒瞬时值容易错过。
var fpsWindow: [(Double, Int)] = []
var lastCapCount = 0
var lastCapTime = CFAbsoluteTimeGetCurrent()
var peakFps: Double = 0
var lastCursorCount = 0

Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let now = CFAbsoluteTimeGetCurrent()
    let dt = now - lastCapTime
    guard dt > 0.5 else { return }
    let delta = cap.captured - lastCapCount
    lastCapCount = cap.captured
    lastCapTime = now
    let fps = Double(delta) / dt
    fpsWindow.append((now, delta))
    fpsWindow.removeAll { now - $0.0 > 10 }
    peakFps = Double(fpsWindow.map { $0.1 }.max() ?? 0)
}

// 统计
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    let mbps = Double(sender.sentBytes) * 8 / 2.0 / 1_000_000
    rateCtl.tick(dropped: sender.dropped)
    let encAvg = encoder.encLatCount > 0 ? encoder.encLatSum / Double(encoder.encLatCount) : 0
    let capAvg = cap.capLatCount > 0 ? cap.capLatSum / Double(cap.capLatCount) : 0
    let cursorDelta = cursor.sentCount - lastCursorCount
    lastCursorCount = cursor.sentCount
    Log.info(String(format: "采集 %d  峰值 %.0ffps  空闲 %d  发送 %d  光标+%d  输入 %d  丢弃 %d  %.1f Mbps  在途 %d  采集延迟 %.1f  编码延迟 %.1f ms",
                    cap.captured, peakFps, cap.idleFrameCount, sender.sent, cursorDelta,
                    injector.eventCount, sender.dropped, mbps, sender.inFlight, capAvg, encAvg))
    cap.capLatSum = 0; cap.capLatCount = 0; cap.capLatMax = 0
    encoder.encLatSum = 0; encoder.encLatCount = 0; encoder.encLatMax = 0
    sender.sentBytes = 0
    sender.sent = 0
}

// 信号处理只置标志位，实际清理在主循环里做
VirtualDisplayGuard.install()

/// 有序退出：先停采集并断开连接，再销毁虚拟屏。
/// 采集流还连着显示器时直接销毁，系统会拒绝移除，留下残影。
func shutdown(signal sig: Int32) -> Never {
    Log.info("收到信号 \(sig)，开始清理")
    var finished = false
    Task {
        try? await cap.stream?.stopCapture()
        sender.conn?.cancel()
        // 给系统一点时间释放采集管线
        try? await Task.sleep(nanoseconds: 300_000_000)
        vd.destroy()
        finished = true
    }
    let deadline = Date().addingTimeInterval(2.0)
    while !finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    vd.destroy()   // 幂等，兜底
    exit(128 + sig)
}

// 每 100ms 检查一次退出信号
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let sig = VirtualDisplayGuard.pendingSignal
    guard sig != 0 else { return }
    VirtualDisplayGuard.pendingSignal = 0
    shutdown(signal: sig)
}

Log.info("SecDisplay 服务已启动，Ctrl-C 退出")
RunLoop.main.run()
