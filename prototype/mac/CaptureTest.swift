// CaptureTest.swift
// 在虚拟屏上真实放一个动画窗口，测出「有内容变化时」的采集帧率与抓屏→编码延迟。
//
// 编译: swiftc -O CaptureTest.swift -o capturetest
// 运行: ./capturetest [秒]

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 8

// MARK: - 虚拟屏

let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeCls = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let setCls  = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

let PX_W = 2560, PX_H = 1600

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
print("虚拟屏 id=\(vdID)")

// MARK: - 编码器

final class Enc {
    var session: VTCompressionSession?
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var latencies: [Double] = []
    var lock = NSLock()

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
            e.lock.lock()
            e.frames += 1
            e.bytes += CMSampleBufferGetTotalSampleSize(sample)
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
               let f = arr.first, !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) {
                e.keyframes += 1
            }
            e.lock.unlock()
        }
        let s = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(PX_W), height: Int32(PX_H),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
            outputCallback: cb, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard s == noErr, let sess = session else { return false }
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(sess)
        return true
    }
}

// MARK: - 采集

final class Cap: NSObject, SCStreamOutput, SCStreamDelegate {
    let enc: Enc
    var stream: SCStream?
    var captured = 0
    var captureToEncode: [Double] = []
    var lastCaptureTime = 0.0

    init(enc: Enc) { self.enc = enc }

    func start(id: CGDirectDisplayID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let d = content.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "x", code: 1) }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = PX_W; c.height = PX_H
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.queueDepth = 3
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = true
        c.scalesToFit = false
        let s = SCStream(filter: filter, configuration: c, delegate: self)
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(enc.session!, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: &flags)
    }
}

// MARK: - 在虚拟屏上画动画

final class AnimView: NSView {
    var tick = 0
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.17, alpha: 1))
        ctx.fill(bounds)
        // 移动的方块
        let x = CGFloat(tick * 23 % Int(bounds.width - 200))
        let y = CGFloat((tick * 17) % Int(bounds.height - 200))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: 160, height: 160))
        // 密集文字块，制造真实负载
        ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1))
        for i in 0..<60 {
            let lw = CGFloat(200 + ((i * 137 + tick * 11) % 900))
            ctx.fill(CGRect(x: 40, y: CGFloat(40 + i * 22), width: lw, height: 10))
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let enc = Enc()
guard enc.start() else { print("编码器失败"); exit(2) }

let cap = Cap(enc: enc)

// 把窗口放到虚拟屏区域
let vdBounds = CGDisplayBounds(vdID)
let win = NSWindow(contentRect: NSRect(x: vdBounds.minX, y: vdBounds.minY,
                                       width: CGFloat(PX_W), height: CGFloat(PX_H)),
                   styleMask: [.borderless], backing: .buffered, defer: false)
let view = AnimView(frame: NSRect(x: 0, y: 0, width: PX_W, height: PX_H))
win.contentView = view
win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
win.orderFrontRegardless()

Task {
    do {
        try await cap.start(id: vdID)
        print("采集已启动，\(Int(secs)) 秒")
        let t0 = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - t0 < secs {
            view.tick += 1
            view.needsDisplay = true
            try? await Task.sleep(nanoseconds: 16_666_000)
        }
        try await cap.stream?.stopCapture()
        enc.lock.lock()
        let f = enc.frames, by = enc.bytes, kf = enc.keyframes
        enc.lock.unlock()
        let el = CFAbsoluteTimeGetCurrent() - t0
        print("\n===== 真实采集结果 =====")
        print(String(format: "采集帧 %d  编码帧 %d  关键帧 %d", cap.captured, f, kf))
        print(String(format: "帧率 %.1f fps", Double(f) / el))
        print(String(format: "码率 %.1f Mbps", Double(by) * 8 / el / 1e6))
        win.orderOut(nil)
        exit(0)
    } catch {
        print("失败: \(error)")
        exit(3)
    }
}

app.run()
