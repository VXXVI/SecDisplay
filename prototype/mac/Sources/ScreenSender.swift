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
    var refreshRate = 90.0     // 这块屏是 90Hz
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    /// 自增帧序号，用作编码 PTS。
    /// 采集帧和保活帧的时间基准不同，混用会让 PTS 非单调，编码器可能报错。
    /// 真正的端到端时间戳走 captureTimeMicros，与 PTS 无关。
    private var frameSeq: Int64 = 0

    func encode(_ pb: CVPixelBuffer, pts: CMTime, captureTimeMicros: UInt64) {
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

        if isKey { keyframeCount += 1 }
        encoded += 1
        bytes += out.count
        onFrame?(out, isKey, captureTime)
    }

}

// MARK: - 抓屏

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let encoder: Encoder
    var stream: SCStream?
    var captured = 0
    var lastFrameTime: CFAbsoluteTime = 0
    var idleFrames = 0

    init(encoder: Encoder) { self.encoder = encoder }

    func start(displayID: CGDirectDisplayID, cfg: Config) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到虚拟屏 \(displayID)"])
        }
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = cfg.width
        c.height = cfg.height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.refreshRate))
        c.queueDepth = 3          // 队列浅，满了丢旧帧
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = true
        c.scalesToFit = false
        c.capturesAudio = false
        c.preservesAspectRatio = true

        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "SecDisplay.capture"))
        try await s.startCapture()
        stream = s
        Log.info("抓屏已启动 \(cfg.width)x\(cfg.height)@\(Int(cfg.refreshRate))")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        captured += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let nowMicros = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
        encoder.encode(pb, pts: pts, captureTimeMicros: nowMicros)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("抓屏停止: \(error)")
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

    private func receiveLoop(epoch: Int) {
        guard connEpoch == epoch, let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, self.connEpoch == epoch else { return }
            if let data, !data.isEmpty {
                for b in data {
                    if b == 0x02 {
                        // 接收端请求关键帧（连接建立时、或丢帧后自愈）
                        Log.info("收到关键帧请求，下一帧强制 IDR")
                        self.onKeyframeRequest?()
                    }
                }
            }
            if done || err != nil { self.connected = false; return }
            self.receiveLoop(epoch: epoch)
        }
    }

    /// 收到对端 0x02 时回调，由外部接到编码器
    var onKeyframeRequest: (() -> Void)?

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

// MARK: - 主流程

let cfg = Config()
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

let cap = Capture(encoder: encoder)
Task {
    do {
        try await cap.start(displayID: vd.displayID, cfg: cfg)
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

// 统计
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    let mbps = Double(sender.sentBytes) * 8 / 2.0 / 1_000_000
    rateCtl.tick(dropped: sender.dropped)
    Log.info(String(format: "采集 %d  编码 %d  关键帧 %d  发送 %d  丢弃 %d  %.1f Mbps  目标 %d  在途 %d",
                    cap.captured, encoder.encoded, encoder.keyframeCount, sender.sent,
                    sender.dropped, mbps, encoder.currentMbps, sender.inFlight))
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
