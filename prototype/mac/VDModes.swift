// VDModes.swift
// 打印某次创建后该虚拟屏的全部可用模式，用于判断 HiDPI 变体是否被系统生成。
import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
let a = CommandLine.arguments
let pxW = UInt32(a[1])!, pxH = UInt32(a[2])!, hz = Double(a[3])!
let hiDPI = a[4] == "1"
let logicalW = UInt(a[5])!, logicalH = UInt(a[6])!

let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let displayClass = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeClass = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

let d = descClass.init()
d.setValue(NSNumber(value: 1), forKey: "vendorID")
d.setValue(NSNumber(value: 1), forKey: "productID")
d.setValue(NSNumber(value: 1), forKey: "serialNum")
d.setValue("SecDisplay", forKey: "name")
d.setValue(NSNumber(value: pxW), forKey: "maxPixelsWide")
d.setValue(NSNumber(value: pxH), forKey: "maxPixelsHigh")
d.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
d.setValue(DispatchQueue(label: "SecDisplay.modes"), forKey: "queue")

let alloc = displayClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let disp = alloc.perform(NSSelectorFromString("initWithDescriptor:"), with: d)!.takeUnretainedValue() as! NSObject

let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let fn = unsafeBitCast(modeAlloc.method(for: sel), to: ModeInit.self)
let mode = fn(modeAlloc, sel, logicalW, logicalH, hz) as! NSObject

let settings = settingsClass.init()
settings.setValue(hiDPI, forKey: "hiDPI")
settings.setValue([mode], forKey: "modes")
let applySel = NSSelectorFromString("applySettings:")
typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)(disp, applySel, settings)
let id = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)

usleep(400_000)
print("displayID=\(id)  请求 \(logicalW)x\(logicalH) 背板 \(pxW)x\(pxH) hiDPI=\(hiDPI)")
if let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
    for m in modes {
        let mark = m.pixelWidth > m.width ? "  <== HiDPI" : ""
        print("  \(m.width)x\(m.height)@\(Int(m.refreshRate)) 背板 \(m.pixelWidth)x\(m.pixelHeight) flags=\(m.ioFlags)\(mark)")
    }
}
if let cur = CGDisplayCopyDisplayMode(id) {
    print("当前: \(cur.width)x\(cur.height) 背板 \(cur.pixelWidth)x\(cur.pixelHeight)")
}
exit(0)
