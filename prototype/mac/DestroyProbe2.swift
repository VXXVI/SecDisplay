// DestroyProbe2.swift
// 继续排查：找到 CGVirtualDisplay 内部持有的 VirtualDisplayClient，并调用正确的销毁。
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
d.setValue("DestroyTest2", forKey: "name")
d.setValue(NSNumber(value: 1600), forKey: "maxPixelsWide")
d.setValue(NSNumber(value: 1000), forKey: "maxPixelsHigh")
d.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
d.setValue(DispatchQueue(label: "dp2"), forKey: "queue")

let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)!.takeUnretainedValue() as! NSObject

let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let msel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let mfn = unsafeBitCast(modeAlloc.method(for: msel), to: ModeInit.self)
let mode = mfn(modeAlloc, msel, 1600, 1000, 60.0) as! NSObject
let st = setCls.init()
st.setValue(false, forKey: "hiDPI")
st.setValue([mode], forKey: "modes")
let aSel = NSSelectorFromString("applySettings:")
typealias AFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(disp.method(for: aSel), to: AFn.self)(disp, aSel, st)

let id = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
usleep(300_000)
print("创建后: \(online()) id=\(id)")

// 列出 CGVirtualDisplay 对象的所有实例变量
print("\n=== CGVirtualDisplay 实例变量")
if let cls = NSClassFromString("CGVirtualDisplay") {
    var count: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &count) {
        for i in 0..<Int(count) {
            let iv = ivars[i]
            let name = String(cString: ivar_getName(iv)!)
            let type = String(cString: ivar_getTypeEncoding(iv)!)
            print("  \(name)  type=\(type)")
        }
        free(ivars)
    }
}

// 用 object_getIvar 或 KVC 找内部 client
print("\n=== 尝试读取内部对象")
for key in ["client", "_client", "proxy", "_proxy", "virtualClient"] {
    if let v = disp.value(forKey: key) {
        print("  \(key) -> \(type(of: v)): \(v)")
    }
}

// 尝试 KVO 列出所有可读 key
print("\n=== 尝试通过 runtime 读 ivar 值")
if let cls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type {
    _ = cls
    var count: UInt32 = 0
    if let ivars = class_copyIvarList(NSClassFromString("CGVirtualDisplay"), &count) {
        for i in 0..<Int(count) {
            let iv = ivars[i]
            let name = String(cString: ivar_getName(iv)!)
            if let p = object_getIvar(disp, iv) as? NSObject {
                print("  \(name) -> \(type(of: p))")
            }
        }
        free(ivars)
    }
}

print("\n结束，当前: \(online())")
exit(0)
