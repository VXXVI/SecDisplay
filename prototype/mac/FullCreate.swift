// FullCreate.swift
// 完整走标准 CGVirtualDisplay 路径：descriptor -> init -> settings -> apply -> 轮询上线。
import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
let pxW = UInt32(args.count > 1 ? Int(args[1])! : 2560)
let pxH = UInt32(args.count > 2 ? Int(args[2])! : 1600)
let hz = args.count > 3 ? Double(args[3])! : 60

print("创建 \(pxW)x\(pxH) @\(hz)Hz")

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
d.setValue(NSValue(size: NSSize(width: 25.4 * Double(pxW) / 110.0,
                                height: 25.4 * Double(pxH) / 110.0)),
            forKey: "sizeInMillimeters")
d.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
d.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
d.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
d.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
d.setValue(DispatchQueue(label: "SecDisplay.full"), forKey: "queue")

let alloc = displayClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
guard let disp = alloc.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?.takeUnretainedValue() as? NSObject else {
    print("init 失败"); exit(2)
}
print("init 成功, displayID 属性 = \(disp.value(forKey: "displayID") ?? "nil")")

// 构造模式
let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let fn = unsafeBitCast(modeAlloc.method(for: sel), to: ModeInit.self)
let logicalW = UInt(pxW / 2), logicalH = UInt(pxH / 2)
guard let mode = fn(modeAlloc, sel, logicalW, logicalH, hz) as? NSObject else {
    print("模式创建失败"); exit(3)
}
print("模式: \(mode.value(forKey: "width") ?? "?")x\(mode.value(forKey: "height") ?? "?") @\(mode.value(forKey: "refreshRate") ?? "?")")

let settings = settingsClass.init()
settings.setValue(true, forKey: "hiDPI")
settings.setValue([mode], forKey: "modes")

let appliedSel = NSSelectorFromString("applySettings:")
typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
let appliedFn = unsafeBitCast(disp.method(for: appliedSel), to: ApplyFn.self)
let applied = appliedFn(disp, appliedSel, settings)
print("applySettings -> \(applied)")

let did = (disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
print("displayID = \(did)")

var waited = 0.0
var online = false
while waited < 3.0 {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(16, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    if ids.contains(CGDirectDisplayID(did)) { online = true; break }
    usleep(50_000); waited += 0.05
}
print("上线: \(online) 等待 \(Int(waited * 1000)) ms")
if online {
    print("  bounds \(CGDisplayBounds(CGDirectDisplayID(did)))")
    print("  像素 \(CGDisplayPixelsWide(CGDirectDisplayID(did)))x\(CGDisplayPixelsHigh(CGDirectDisplayID(did)))")
    for s in NSScreen.screens {
        let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        print("  NSScreen \(s.localizedName) id=\(num?.uint32Value ?? 0) frame=\(s.frame) scale=\(s.backingScaleFactor)")
    }
    Thread.sleep(forTimeInterval: 3.0)
}
exit(online ? 0 : 4)
