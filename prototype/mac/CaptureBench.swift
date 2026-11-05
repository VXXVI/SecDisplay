// CaptureBench.swift
// 把动画窗口强制显示在虚拟屏上，测真实的采集→编码链路帧率。
//
// 做法：把窗口的所在屏幕设为目标虚拟屏，用 screen 参数指定窗口显示在哪个屏。
//
// 编译: swiftc -O CaptureBench.swift -o capturebench
// 运行: ./capturebench [秒]

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 8
let PX_W = 2560, PX_H = 1600

// ---------- 虚拟屏 ----------
let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeCls = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let setCls  = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

let desc = descCls.init()
desc.setValue(NSNumber(value: 1), forKey: "vendorID")
desc.setValue(NSNumber(value: 1), forKey: "productID")
desc.setValue(NSNumber(value: 1), forKey: "serialNum")
desc.setValue("SecDisplay", forKey: "name")
desc.setValue(NSNumber(value: PX_W), forKey: "maxPixelsWide")
desc.setValue(NSNumber(value: PX_H), forKey: "maxPixelsHigh")
desc.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
desc.setValue(DispatchQueue(label: "vd"), forKey: "queue")

let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let vdisp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: desc)!.takeUnretainedValue() as! NSObject
let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let msel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let mode = unsafeBitCast(modeAlloc.method(for: msel), to: ModeInit.self)(modeAlloc, msel, UInt(PX_W), UInt(PX_H), 60.0) as! NSObject
let st = setCls.init()
st.setValue(false, forKey: "hiDPI")
st.setValue([mode], forKey: "modes")
let aSel = NSSelectorFromString("applySettings:")
typealias AFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(vdisp.method(for: aSel), to: AFn.self)(vdisp, aSel, st)
let vdID = CGDirectDisplayID((vdisp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
print("虚拟屏 id=\(vdID)  bounds=\(CGDisplayBounds(vdID))")

// ---------- 编码器 ----------
final class Enc {
    var session: VTCompressionSession?
    var frames = 0, bytes = 0, keyframes = 0
    let lock = NSLock()
    func start() -> Bool {
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: PX_W,
            kCVPixelBufferHeightKey as String: PX_H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let cb: VTCompressionOutputCallback = { ref, _, status, _, sample in
            guard status == noErr, let sample, let ref else { return }
            let e = Unmanaged<Enc>.fromOpaque(ref).takeUnretainedValue()
            e.lock.lock(); e.frames += 1
            e.bytes += CMSampleBufferGetTotalSampleSize(sample)
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
               let f = arr.first, !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) { e.keyframes += 1 }
            e.lock.unlock()
        }
        let r = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(PX_W), height: Int32(PX_H),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: cb, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard r == noErr, let s = session else { return false }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }
}

// ---------- 采集 ----------
final class Cap: NSObject, SCStreamOutput {
    let enc: Enc
    var stream: SCStream?
    var captured = 0
    init(enc: Enc) { self.enc = enc }

    func start(id: CGDirectDisplayID, w: Int, h: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = content.displays.first(where: { $0.displayID == id }) else {
            throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "无此显示器"])
        }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = w; c.height = h
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.queueDepth = 3
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = true
        c.scalesToFit = false
        let s = SCStream(filter: filter, configuration: c, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first, let raw = info[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        captured += 1
        var fl: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(enc.session!, imageBuffer: pb,
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb),
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: &fl)
    }
}

// ---------- 动画窗口 ----------
final class AnimView: NSView {
    var tick = 0
    override var isOpaque: Bool { true }
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1))
        ctx.fill(bounds)
        let x = CGFloat((tick * 37) % (Int(bounds.width) - 300))
        let y = CGFloat((tick * 29) % (Int(bounds.height) - 300))
        ctx.setFillColor(CGColor(red: 0.25, green: 0.75, blue: 1.0, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: 280, height: 280))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.85, blue: 0.88, alpha: 1))
        for i in 0..<80 {
            let lw = CGFloat(150 + ((i * 173 + tick * 13) % 1400))
            ctx.fill(CGRect(x: 30, y: CGFloat(30 + i * 18), width: lw, height: 9))
        }
        ctx.setStrokeColor(CGColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1))
        ctx.setLineWidth(3)
        ctx.stroke(CGRect(x: 10, y: 10, width: bounds.width - 20, height: bounds.height - 20))
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let enc = Enc()
guard enc.start() else { print("编码器失败"); exit(2) }
let cap = Cap(enc: enc)
let vb = CGDisplayBounds(vdID)
let win = NSWindow(contentRect: vb, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = AnimView(frame: NSRect(origin: .zero, size: vb.size))
win.setFrame(vb, display: true)
// 强制放到虚拟屏上
if let target = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vdID
}) {
    print("找到 NSScreen: \(target.localizedName) frame=\(target.frame)")
    win.setFrame(target.frame, display: true)
} else {
    print("警告：NSScreen 里没找到虚拟屏")
}
win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
win.ignoresMouseEvents = true
win.orderFrontRegardless()
print("窗口已显示")

Task {
    do {
        try await cap.start(id: vdID, w: PX_W, h: PX_H)
        print("采集启动")
        let t0 = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - t0 < secs {
            if let v = win.contentView as? AnimView { v.tick += 1; v.needsDisplay = true }
            try? await Task.sleep(nanoseconds: 16_666_000)
        }
        try await cap.stream?.stopCapture()
        enc.lock.lock(); let f = enc.frames, by = enc.bytes, kf = enc.keyframes; enc.lock.unlock()
        let el = CFAbsoluteTimeGetCurrent() - t0
        print("\n===== 采集→编码 实测 =====")
        print(String(format: "采集 %d 帧  编码 %d 帧  关键帧 %d", cap.captured, f, kf))
        print(String(format: "帧率 %.1f fps", Double(f) / el))
        print(String(format: "码率 %.1f Mbps", Double(by) * 8 / el / 1e6))
        win.orderOut(nil)
        exit(0)
    } catch {
        print("失败: \(error)"); exit(3)
    }
}
app.run()
