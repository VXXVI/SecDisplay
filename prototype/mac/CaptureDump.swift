// CaptureDump.swift
// 把 SCK 抓到的虚拟屏画面存成 PNG，确认到底抓到了什么。
import Foundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import AppKit
import Darwin
import ImageIO
import UniformTypeIdentifiers

setvbuf(stdout, nil, _IONBF, 0)
let PX_W = 2560, PX_H = 1600

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
print("虚拟屏 id=\(vdID)")


// 用 SCK 抓一帧
final class One: NSObject, SCStreamOutput {
    var done = false
    var path: String
    init(path: String) { self.path = path }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !done, type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        done = true
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg)
        if let cg {
            let url = URL(fileURLWithPath: path)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
                print("SCK 已保存 \(path)  \(cg.width)x\(cg.height)")
            }
        }
    }
}

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        print("可抓显示器: \(content.displays.map { "\($0.displayID):\($0.width)x\($0.height)" })")
        guard let d = content.displays.first(where: { $0.displayID == vdID }) else { print("找不到"); exit(1) }
        let filter = SCContentFilter(display: d, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = PX_W; c.height = PX_H
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.queueDepth = 3
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = true
        let out = One(path: "/tmp/vd_sck.png")
        let s = SCStream(filter: filter, configuration: c, delegate: nil)
        try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await s.stopCapture()
        exit(out.done ? 0 : 2)
    } catch {
        print("失败: \(error)"); exit(3)
    }
}
RunLoop.main.run()
