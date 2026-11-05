// CaptureBench2.swift
// 让窗口真正在虚拟屏上持续动画，测出「有内容变化」时的采集→编码帧率上限。
// 关键：窗口必须用 orderFront 显示且所在屏幕是虚拟屏，还要用 layer-backed 加速重绘。
import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 6
let PX_W = 2560, PX_H = 1600

let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeCls = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let setCls  = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type
let dsc = descCls.init()
dsc.setValue(NSNumber(value: 1), forKey: "vendorID")
dsc.setValue(NSNumber(value: 1), forKey: "productID")
dsc.setValue(NSNumber(value: 1), forKey: "serialNum")
dsc.setValue("SecDisplay", forKey: "name")
dsc.setValue(NSNumber(value: PX_W), forKey: "maxPixelsWide")
dsc.setValue(NSNumber(value: PX_H), forKey: "maxPixelsHigh")
dsc.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
dsc.setValue(DispatchQueue(label: "vd"), forKey: "queue")
let al = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let vd = al.perform(NSSelectorFromString("initWithDescriptor:"), with: dsc)!.takeUnretainedValue() as! NSObject
let ma = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias MI = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let mSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let md = unsafeBitCast(ma.method(for: mSel), to: MI.self)(ma, mSel, UInt(PX_W), UInt(PX_H), 60.0) as! NSObject
let sf = setCls.init()
sf.setValue(false, forKey: "hiDPI")
sf.setValue([md], forKey: "modes")
let apSel = NSSelectorFromString("applySettings:")
typealias AF = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(vd.method(for: apSel), to: AF.self)(vd, apSel, sf)
let vdID = CGDirectDisplayID((vd.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
print("虚拟屏 id=\(vdID)")

final class Enc {
    var s: VTCompressionSession?
    var frames = 0, bytes = 0
    let lk = NSLock()
    func start() -> Bool {
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true]
        let at: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: PX_W,
            kCVPixelBufferHeightKey as String: PX_H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] ]
        let cb: VTCompressionOutputCallback = { r, _, st, _, smp in
            guard st == noErr, let smp, let r else { return }
            let e = Unmanaged<Enc>.fromOpaque(r).takeUnretainedValue()
            e.lk.lock(); e.frames += 1; e.bytes += CMSampleBufferGetTotalSampleSize(smp); e.lk.unlock()
        }
        let r = VTCompressionSessionCreate(allocator: nil, width: Int32(PX_W), height: Int32(PX_H),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: at as CFDictionary, compressedDataAllocator: nil,
            outputCallback: cb, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &s)
        guard r == noErr, let ss = s else { return false }
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
        VTSessionSetProperty(ss, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(ss)
        return true
    }
}

final class Cap: NSObject, SCStreamOutput {
    let e: Enc
    var s: SCStream?
    var n = 0
    init(_ e: Enc) { self.e = e }
    func start(_ id: CGDirectDisplayID) async throws {
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = c.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "x", code: 1) }
        let f = SCContentFilter(display: d, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = PX_W; cfg.height = PX_H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let st = SCStream(filter: f, configuration: cfg, delegate: nil)
        try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "c"))
        try await st.startCapture()
        s = st
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let i = arr.first, let r = i[.status] as? Int, SCFrameStatus(rawValue: r) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        n += 1
        var fl: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(e.s!, imageBuffer: pb,
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        duration: .invalid, frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &fl)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let enc = Enc()
_ = enc.start()
let cap = Cap(enc)

// 用 CALayer 动画：由 Core Animation 直接驱动，保证真在动
let vb = CGDisplayBounds(vdID)
let win = NSWindow(contentRect: vb, styleMask: [.borderless], backing: .buffered, defer: false)
win.backgroundColor = .black
let host = NSView(frame: NSRect(origin: .zero, size: vb.size))
host.wantsLayer = true
host.layer?.backgroundColor = CGColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1)

let box = CALayer()
box.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
box.backgroundColor = CGColor(red: 0.2, green: 0.8, blue: 1, alpha: 1)
host.layer?.addSublayer(box)

let move = CABasicAnimation(keyPath: "position")
move.fromValue = NSValue(point: CGPoint(x: 200, y: 200))
move.toValue = NSValue(point: CGPoint(x: Double(PX_W) - 200, y: Double(PX_H) - 200))
move.duration = 1.0
move.autoreverses = true
move.repeatCount = .infinity
box.position = CGPoint(x: 200, y: 200)
box.add(move, forKey: "move")

let pulse = CABasicAnimation(keyPath: "opacity")
pulse.fromValue = 0.3
pulse.toValue = 1.0
pulse.duration = 0.5
pulse.autoreverses = true
pulse.repeatCount = .infinity
box.add(pulse, forKey: "pulse")

win.contentView = host
if let scr = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vdID }) {
    win.setFrame(scr.frame, display: true)
}
win.orderFrontRegardless()
print("动画窗口已显示在虚拟屏")

Task {
    do {
        try await cap.start(vdID)
        let t0 = CFAbsoluteTimeGetCurrent()
        try await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
        try await cap.s?.stopCapture()
        enc.lk.lock(); let f = enc.frames, b = enc.bytes; enc.lk.unlock()
        let el = CFAbsoluteTimeGetCurrent() - t0
        print("\n===== 有内容变化时 =====")
        print(String(format: "采集 %d 帧  编码 %d 帧", cap.n, f))
        print(String(format: "帧率 %.1f fps", Double(f) / el))
        print(String(format: "码率 %.1f Mbps", Double(b) * 8 / el / 1e6))
        exit(0)
    } catch { print("失败: \(error)"); exit(3) }
}
app.run()
