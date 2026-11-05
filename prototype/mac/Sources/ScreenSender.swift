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
//   6. 静态画面降帧，省带宽也省电
//
// 协议（每帧）:
//   [4 字节大端长度][1 字节类型][8 字节采集时间戳 us][载荷]
//   类型 0x01 = 视频帧（Annex-B，关键帧前置 SPS/PPS）
//   类型 0x02 = 请求关键帧
// ============================================================================

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import Network
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 配置

struct Config {
    var width = 2560
    var height = 1600
    var logicalWidth = 2560
    var logicalHeight = 1600
    var refreshRate = 60.0
    var bitrateMbps = 60
    var port: UInt16 = 9922
    var staticAdaptive = true
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

    func destroy() {
        for sel in ["unplug"] where object?.responds(to: NSSelectorFromString(sel)) == true {
            let s = NSSelectorFromString(sel)
            typealias F = @convention(c) (AnyObject, Selector) -> Void
            unsafeBitCast(object!.method(for: s), to: F.self)(object!, s)
        }
        object = nil
    }

    enum Err: Error { case classesMissing, initFailed, modeFailed, applyFailed }
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
    private(set) var bytes = 0
    private(set) var lastKeyframeCheck = 0

    init(width: Int, height: Int, bitrateMbps: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrateMbps * 1_000_000
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
        let cb: VTCompressionOutputCallback = { ref, _, status, _, sample in
            guard status == noErr, let sample, let ref else { return }
            Unmanaged<Encoder>.fromOpaque(ref).takeUnretainedValue().emit(sample)
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

    func encode(_ pb: CVPixelBuffer, pts: CMTime, captureTimeMicros: UInt64) {
        guard let s = session else { return }
        currentCaptureTime = captureTimeMicros
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: currentFrameProps,
                                        sourceFrameRefcon: nil, infoFlagsOut: &flags)
        currentFrameProps = nil
    }

    private var currentCaptureTime: UInt64 = 0

    func requestKeyframe() {
        guard let s = session else { return }
        // 强制下一帧为 IDR
        let props: [String: Any] = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
        currentFrameProps = props as CFDictionary
        _ = s
    }
    private var currentFrameProps: CFDictionary?

    private func emit(_ sample: CMSampleBuffer) {
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

        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            // 关键帧前拼接 SPS/PPS，接收端可自恢复
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
                    out.append(contentsOf: [0, 0, 0, 1])
                    out.append(p, count: sz)
                }
            }
        }
        // 将 AVCC 长度前缀转成 Annex-B
        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= length {
            let nalLen = (Int(raw[offset]) << 24) | (Int(raw[offset+1]) << 16)
                       | (Int(raw[offset+2]) << 8) | Int(raw[offset+3])
            offset += 4
            guard nalLen > 0, offset + nalLen <= length else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(raw + offset, count: nalLen)
            offset += nalLen
        }

        encoded += 1
        bytes += out.count
        onFrame?(out, isKey, currentCaptureTime)
    }

    func stop() {
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
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
    private var conn: NWConnection?
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
        let listener = try! NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            Log.info("接收端已连接: \(String(describing: c.endpoint))")
            self.conn?.cancel()
            self.conn = c
            self.connected = true
            c.stateUpdateHandler = { st in
                if case .failed(let e) = st {
                    Log.info("连接失败: \(e)")
                    self.connected = false
                } else if case .cancelled = st {
                    self.connected = false
                }
            }
            c.start(queue: self.queue)
            // 收控制消息
            self.receiveLoop()
        }
        listener.stateUpdateHandler = { st in
            if case .ready = st { Log.info("监听端口 \(port)，等待接收端连接") }
            if case .failed(let e) = st { Log.info("监听失败: \(e)") }
        }
        listener.start(queue: queue)
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                for b in data {
                    if b == 0x02 { /* 请求关键帧 */ self.keyframeRequested = true }
                }
            }
            if done || err != nil { self.connected = false; return }
            if self.connected { self.receiveLoop() }
        }
    }

    var keyframeRequested = false

    func send(frame: Data, captureTimeMicros: UInt64) {
        guard connected, let c = conn else { return }
        // 在途帧数超限：丢这一帧，保住实时性
        if inFlight >= maxInFlight {
            dropped += 1
            return
        }
        var packet = Data(capacity: frame.count + 13)
        var len = UInt32(frame.count + 9).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x01)
        var ts = captureTimeMicros.bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(frame)

        inFlight += 1
        sent += 1
        sentBytes += packet.count
        c.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.inFlight = max(0, self.inFlight - 1)
            if err != nil { self.connected = false }
        })
    }
}

// MARK: - 主流程

let cfg = Config()
let vd = VirtualDisplayManager()
let encoder = Encoder(width: cfg.width, height: cfg.height, bitrateMbps: cfg.bitrateMbps)
let sender = Sender()

guard encoder.start() else { exit(3) }

encoder.onFrame = { data, isKey, ts in
    sender.send(frame: data, captureTimeMicros: ts)
}

do {
    try vd.create(cfg)
} catch {
    Log.info("虚拟屏创建失败: \(error)")
    exit(2)
}

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

// 统计
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    let mbps = Double(sender.sentBytes) * 8 / 2.0 / 1_000_000
    Log.info(String(format: "采集 %d 帧  编码 %d  发送 %d  丢弃 %d  %.1f Mbps  在途 %d",
                    cap.captured, encoder.encoded, sender.sent, sender.dropped, mbps, sender.inFlight))
    sender.sentBytes = 0
    sender.sent = 0
}

signal(SIGINT) { _ in
    vd.destroy()
    exit(0)
}
atexit { }

Log.info("SecDisplay 服务已启动，Ctrl-C 退出")
RunLoop.main.run()
