// ============================================================================
// LoopbackTest.swift
// Mac 端自环测试：发送端 → 本地回环 → 接收端解码，测出端到端延迟。
// 不需要 Windows 机器就能验证整条管线是否成立。
//
// 原理:
//   1. 建虚拟屏，在上面跑一个带水平滚动条纹的动画窗口（编码器友好且能检测延迟）
//   2. 源端: SCK 抓屏 → VT 编码 → 打时间戳 → 发送
//   3. 接收端（同进程另一线程）: 收包 → VT 解码 → 读出时间戳算延迟
//   4. 因为抓屏和显示在同一台机器，测得的是「采集+编码+传输+解码」的真实耗时
//
// 编译: swiftc -O LoopbackTest.swift -o loopback
// 运行: ./loopback [秒]
// ============================================================================

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import Network
import AppKit
import Darwin

setvbuf(stderr, nil, _IONBF, 0)
enum Log {
    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 8
let PX_W = 1920, PX_H = 1200
let PORT: UInt16 = 9933

// MARK: - 虚拟屏

/// 全局持有，防止被 ARC 回收导致屏消失
var vdHolder: NSObject?

func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids
}

func makeVirtualDisplay() -> CGDirectDisplayID {
    let dC = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
    let vC = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
    let mC = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
    let sC = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type
    let d = dC.init()
    d.setValue(NSNumber(value: 1), forKey: "vendorID")
    d.setValue(NSNumber(value: 1), forKey: "productID")
    d.setValue(NSNumber(value: 1), forKey: "serialNum")
    d.setValue("LoopTest", forKey: "name")
    d.setValue(NSNumber(value: PX_W), forKey: "maxPixelsWide")
    d.setValue(NSNumber(value: PX_H), forKey: "maxPixelsHigh")
    d.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
    d.setValue(DispatchQueue(label: "loop.vd"), forKey: "queue")
    let al = vC.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    guard let v = al.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?.takeUnretainedValue() as? NSObject else {
        Log.err("initWithDescriptor 返回 nil —— 可能有上次崩溃残留的虚拟屏占位")
        Log.err("当前在线显示器: \(onlineDisplayIDs())")
        Log.err("处理办法: 注销并重新登录，或重启")
        exit(9)
    }
    let ma = mC.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    typealias MI = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
    let ms = NSSelectorFromString("initWithWidth:height:refreshRate:")
    let md = unsafeBitCast(ma.method(for: ms), to: MI.self)(ma, ms, UInt(PX_W), UInt(PX_H), 60.0) as! NSObject
    let sf = sC.init()
    sf.setValue(false, forKey: "hiDPI")
    sf.setValue([md], forKey: "modes")
    let asel = NSSelectorFromString("applySettings:")
    typealias AF = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    _ = unsafeBitCast(v.method(for: asel), to: AF.self)(v, asel, sf)
    vdHolder = v
    return CGDirectDisplayID((v.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
}

// MARK: - 统计

final class Stats {
    let lock = NSLock()
    var latencies: [Double] = []
    var decoded = 0
    var bytes = 0
    var keyframes = 0
    func add(_ ms: Double) { lock.lock(); latencies.append(ms); decoded += 1; lock.unlock() }
    func report(_ elapsed: Double) {
        lock.lock()
        let l = latencies.sorted()
        let n = l.count
        lock.unlock()
        guard n > 0 else { Log.err("无样本"); return }
        func pct(_ p: Double) -> Double { l[min(n - 1, Int(Double(n) * p))] }
        Log.err("\n===== 自环端到端延迟 =====")
        Log.err(String(format: "样本 %d  解码 %d 帧  用时 %.1fs  帧率 %.1f fps",
                     n, decoded, elapsed, Double(n) / elapsed))
        Log.err(String(format: "最小 %.2f ms", l[0]))
        Log.err(String(format: "中位 %.2f ms", pct(0.5)))
        Log.err(String(format: "p95  %.2f ms", pct(0.95)))
        Log.err(String(format: "最大 %.2f ms", l[n - 1]))
    }
}

let stats = Stats()

enum LoopLog {
    static var missFmt = 0
    static var emptyAvcc = 0
    static var decodeFail = 0
}

// MARK: - 编码

final class Sender {
    var session: VTCompressionSession?
    var conn: NWConnection?
    let q = DispatchQueue(label: "send")
    func startEncoder(bitrate: Int) -> Bool {
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true]
        let at: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: PX_W,
            kCVPixelBufferHeightKey as String: PX_H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] ]
        let cb: VTCompressionOutputCallback = { r, _, st, _, smp in
            guard st == noErr, let smp, let r else { return }
            Unmanaged<Sender>.fromOpaque(r).takeUnretainedValue().emit(smp)
        }
        let s = VTCompressionSessionCreate(allocator: nil, width: Int32(PX_W), height: Int32(PX_H),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: at as CFDictionary, compressedDataAllocator: nil,
            outputCallback: cb, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard s == noErr, let ss = session else { return false }
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(ss)
        Log.err("编码器就绪")
        return true
    }
    func listen() {
        let p = NWParameters.tcp
        if let t = p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { t.noDelay = true }
        let l = try! NWListener(using: p, on: NWEndpoint.Port(rawValue: PORT)!)
        l.newConnectionHandler = { [weak self] c in
            Log.err("接收端已连入")
            self?.conn = c
            c.start(queue: self!.q)
        }
        l.start(queue: q)
        Log.err("监听 \(PORT)")
    }
    func emit(_ sample: CMSampleBuffer) {
        guard let conn, let bb = CMSampleBufferGetDataBuffer(sample) else { return }
        var len = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        guard let ptr, len > 0 else { return }
        var isKey = false
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let f = arr.first { isKey = !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) }
        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var cnt = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &cnt, nalUnitHeaderLengthOut: nil)
            for i in 0..<cnt {
                var pp: UnsafePointer<UInt8>?; var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &pp,
                    parameterSetSizeOut: &sz, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pp, sz > 0 { out.append(contentsOf: [0,0,0,1]); out.append(pp, count: sz) }
            }
            stats.lock.lock(); stats.keyframes += 1; stats.lock.unlock()
        }
        let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var off = 0
        while off + 4 <= len {
            let n = (Int(raw[off]) << 24) | (Int(raw[off+1]) << 16) | (Int(raw[off+2]) << 8) | Int(raw[off+3])
            off += 4
            guard n > 0, off + n <= len else { break }
            out.append(contentsOf: [0,0,0,1]); out.append(raw + off, count: n); off += n
        }
        let ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
        var pkt = Data()
        var l32 = UInt32(out.count + 9).bigEndian
        withUnsafeBytes(of: &l32) { pkt.append(contentsOf: $0) }
        pkt.append(0x01)
        var t64 = ts.bigEndian
        withUnsafeBytes(of: &t64) { pkt.append(contentsOf: $0) }
        pkt.append(out)
        stats.lock.lock(); stats.bytes += pkt.count; stats.lock.unlock()
        conn.send(content: pkt, completion: .contentProcessed { _ in })
    }
}

// MARK: - 解码

final class Receiver {
    var session: VTDecompressionSession?
    var fmt: CMVideoFormatDescription?
    /// 一个完整的读循环：先读 4 字节长度，再读 4+N 字节，处理粘包与拆包。
    func start(_ c: NWConnection) {
        c.start(queue: DispatchQueue(label: "recv"))
        readLoop(c)
    }

    func readLoop(_ c: NWConnection) {
        // 只读 4 字节长度
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, done, err in
            guard let self, let head = d, head.count == 4, err == nil else { return }
            let n = Int(head.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard n > 9, n < 32 * 1024 * 1024 else { return }
            // 再把整包读完（可能分多次到达）
            self.readBody(c, need: n, buf: Data())
            _ = done
        }
    }

    func readBody(_ c: NWConnection, need: Int, buf: Data) {
        guard buf.count < need else {
            handle(buf, conn: c)
            readLoop(c)
            return
        }
        let want = need - buf.count
        c.receive(minimumIncompleteLength: 1, maximumLength: want) { [weak self] d, _, done, err in
            guard let self, let d, err == nil else { return }
            var nb = buf
            nb.append(d)
            if nb.count >= need {
                self.handle(nb, conn: c)
                self.readLoop(c)
            } else {
                self.readBody(c, need: need, buf: nb)
            }
            _ = done
        }
    }

    func handle(_ body: Data, conn: NWConnection) {
        guard body.count > 9, body[0] == 0x01 else { return }
        var ts: UInt64 = 0
        for i in 0..<8 { ts = (ts << 8) | UInt64(body[1 + i]) }
        let data = body.subdata(in: 9..<body.count)
        decode(data, ts: ts)
    }

    func decode(_ data: Data, ts: UInt64) {
        // 找 SPS/PPS
        var sps: [UInt8] = [], pps: [UInt8] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 4 < bytes.count {
            if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 {
                let s = i + 4
                var e = s
                while e + 3 < bytes.count {
                    if bytes[e] == 0, bytes[e+1] == 0, bytes[e+2] == 0, bytes[e+3] == 1 { break }
                    e += 1
                }
                let nal = Array(bytes[s..<min(e, bytes.count)])
                if let h = nal.first {
                    let t = h & 0x1F
                    if t == 7 { sps = nal } else if t == 8 { pps = nal }
                }
                i = e
            } else { i += 1 }
        }
        if !sps.isEmpty, !pps.isEmpty, fmt == nil {
            sps.withUnsafeBufferPointer { sb in
                pps.withUnsafeBufferPointer { pb in
                    var f: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                        parameterSetCount: 2,
                        parameterSetPointers: [sb.baseAddress!, pb.baseAddress!],
                        parameterSetSizes: [sps.count, pps.count],
                        nalUnitHeaderLength: 4, formatDescriptionOut: &f)
                    fmt = f
                }
            }
            if let f = fmt {
                let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                var s: VTDecompressionSession?
                VTDecompressionSessionCreate(allocator: nil, formatDescription: f,
                    decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: nil, decompressionSessionOut: &s)
                session = s
                Log.err("解码器就绪")
            }
        }
        guard let f = fmt, let s = session else {
            LoopLog.missFmt += 1
            return
        }

        // 转 AVCC
        var avcc = Data()
        var idx = 0
        while idx + 4 < bytes.count {
            if bytes[idx] == 0, bytes[idx+1] == 0, bytes[idx+2] == 0, bytes[idx+3] == 1 {
                let st = idx + 4
                var en = st
                while en + 3 < bytes.count {
                    if bytes[en] == 0, bytes[en+1] == 0, bytes[en+2] == 0, bytes[en+3] == 1 { break }
                    en += 1
                }
                let nal = bytes[st..<min(en, bytes.count)]
                if let h = nal.first, (h & 0x1F) != 7, (h & 0x1F) != 8 {
                    var l = UInt32(nal.count).bigEndian
                    withUnsafeBytes(of: &l) { avcc.append(contentsOf: $0) }
                    avcc.append(contentsOf: nal)
                }
                idx = en
            } else { idx += 1 }
        }
        guard !avcc.isEmpty else {
            LoopLog.emptyAvcc += 1
            return
        }

        var bb: CMBlockBuffer?
        avcc.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &bb)
            if let bb { CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: avcc.count) }
        }
        guard let bb else { return }
        var sb: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: f,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sb)
        guard let sb else { return }

        let recvTime = CFAbsoluteTimeGetCurrent()
        var flags = VTDecodeInfoFlags()
        let now = CFAbsoluteTimeGetCurrent()
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [],
            infoFlagsOut: &flags) { status, _, _, _, _, _ in
                if status != noErr { LoopLog.decodeFail += 1 }
                if status == noErr {
                    let lat = (CFAbsoluteTimeGetCurrent() - Double(ts) / 1_000_000) * 1000
                    _ = recvTime; _ = now
                    stats.add(lat)
                }
            }
    }
}

// MARK: - 动画

final class ScrollView: NSView {
    var phase: CGFloat = 0
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        ctx.fill(bounds)
        for i in 0..<40 {
            let y = CGFloat(i) * 30
            let x = (phase + CGFloat(i) * 47).truncatingRemainder(dividingBy: bounds.width)
            ctx.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: 200, height: 20))
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for i in 0..<50 {
            let lw = CGFloat(100 + ((i * 97 + Int(phase)) % 1200))
            ctx.fill(CGRect(x: 40, y: CGFloat(400 + i * 15), width: lw, height: 8))
        }
    }
}

// MARK: - 主

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let vdID = makeVirtualDisplay()
Log.err("虚拟屏 id=\(vdID)")

let sender = Sender()
guard sender.startEncoder(bitrate: 60_000_000) else { Log.err("编码器失败"); exit(2) }
sender.listen()

let vb = CGDisplayBounds(vdID)
let win = NSWindow(contentRect: vb, styleMask: [.borderless], backing: .buffered, defer: false)
let view = ScrollView(frame: NSRect(origin: .zero, size: vb.size))
win.contentView = view
if let scr = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vdID }) {
    win.setFrame(scr.frame, display: true)
}
win.orderFrontRegardless()

final class Cap: NSObject, SCStreamOutput {
    var stream: SCStream?
    func start(_ id: CGDirectDisplayID, sink: Sender) async throws {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = c.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "x", code: 1) }
        let cfg = SCStreamConfiguration()
        cfg.width = PX_W; cfg.height = PX_H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        stream = s
        _ = sink
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let i = arr.first, let r = i[.status] as? Int, SCFrameStatus(rawValue: r) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        var fl: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(sender.session!, imageBuffer: pb,
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: &fl)
    }
}
let cap = Cap()
var receiver: Receiver?

Task {
    do {
        try await cap.start(vdID, sink: sender)
        Log.err("采集启动")

        // 自环：自己连自己，同时承担发送端和接收端
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: PORT)!, using: .tcp)
        let r = Receiver()
        receiver = r
        r.start(client)

        // 等发送端 accept 到这条连接
        var waited = 0.0
        while sender.conn == nil && waited < 5 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 0.1 }
        guard sender.conn != nil else { Log.err("自环连接失败"); exit(4) }
        Log.err("自环已建立")
        try? await Task.sleep(nanoseconds: 500_000_000)

        let t0 = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - t0 < secs {
            view.phase += 9
            view.needsDisplay = true
            try? await Task.sleep(nanoseconds: 16_666_000)
        }
        try await cap.stream?.stopCapture()
        Log.err("诊断: 缺格式 \(LoopLog.missFmt)  空AVCC \(LoopLog.emptyAvcc)  解码失败 \(LoopLog.decodeFail)")
        stats.report(CFAbsoluteTimeGetCurrent() - t0)
        exit(0)
    } catch { Log.err("失败: \(error)"); exit(5) }
}

app.run()
