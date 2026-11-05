// DestroyProbe3.swift
// 通过 _client 实例变量拿到内部 VirtualDisplayClient，调用 CDVirtualDisplayDestroy。
import Foundation
import CoreGraphics
import AppKit
import Darwin
import ObjectiveC.runtime

setvbuf(stdout, nil, _IONBF, 0)

func online() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids
}

let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeCls = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let setCls  = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

let d = descCls.init()
d.setValue(NSNumber(value: 1), forKey: "vendorID")
d.setValue(NSNumber(value: 1), forKey: "productID")
d.setValue(NSNumber(value: 1), forKey: "serialNum")
d.setValue("DestroyTest3", forKey: "name")
d.setValue(NSNumber(value: 1600), forKey: "maxPixelsWide")
d.setValue(NSNumber(value: 1000), forKey: "maxPixelsHigh")
d.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
d.setValue(DispatchQueue(label: "dp3"), forKey: "queue")

let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)!.takeUnretainedValue() as! NSObject

let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let msel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let mode = unsafeBitCast(modeAlloc.method(for: msel), to: ModeInit.self)(modeAlloc, msel, 1600, 1000, 60.0) as! NSObject
let st = setCls.init()
st.setValue(false, forKey: "hiDPI")
st.setValue([mode], forKey: "modes")
let aSel = NSSelectorFromString("applySettings:")
typealias AFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(disp.method(for: aSel), to: AFn.self)(disp, aSel, st)

let id = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
usleep(300_000)
print("创建后: \(online()) id=\(id)")

// 读取 _client 指针
let clientIvar = class_getInstanceVariable(NSClassFromString("CGVirtualDisplay"), "_client")!
let raw = UnsafeRawPointer(Unmanaged.passUnretained(disp).toOpaque()).advanced(by: ivar_getOffset(clientIvar))
let clientPtr = raw.load(as: UnsafeMutableRawPointer?.self)
print("_client = \(String(describing: clientPtr))")

if let clientPtr {
    let obj = Unmanaged<AnyObject>.fromOpaque(clientPtr).takeUnretainedValue()
    print("_client 实际类型: \(type(of: obj))")

    // 尝试 CDVirtualDisplayDestroy
    if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
       let p = dlsym(h, "CDVirtualDisplayDestroy") {
        typealias F = @convention(c) (UnsafeMutableRawPointer) -> Void
        print("调用 CDVirtualDisplayDestroy(_client) ...")
        unsafeBitCast(p, to: F.self)(clientPtr)
        print("已调用")
    }
}

for i in 1...10 {
    usleep(200_000)
    if !online().contains(id) {
        print("✓ 第 \(i*200) ms 已消失")
        exit(0)
    }
}
print("✗ 仍然在线: \(online())")
exit(1)
