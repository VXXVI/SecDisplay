// DestroyProbe.swift
// 找出让虚拟屏真正从系统消失的方法。
//
// 候选:
//   A. 释放对象引用（ARC dealloc）
//   B. 调用 unplug 选择器
//   C. CDVirtualDisplayDestroy（CoreDisplay 的 C 接口）
//   D. 把对象放到自动释放池外并置空
//
// 编译: swiftc -O DestroyProbe.swift -o destroyprobe
// 运行: ./destroyprobe <方式 A|B|C|D>

import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let method = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "A"

func online() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids
}

func makeDisplay() -> (NSObject, CGDirectDisplayID) {
    let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
    let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
    let modeCls = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
    let setCls  = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

    let d = descCls.init()
    d.setValue(NSNumber(value: 1), forKey: "vendorID")
    d.setValue(NSNumber(value: 1), forKey: "productID")
    d.setValue(NSNumber(value: 1), forKey: "serialNum")
    d.setValue("DestroyTest", forKey: "name")
    d.setValue(NSNumber(value: 1600), forKey: "maxPixelsWide")
    d.setValue(NSNumber(value: 1000), forKey: "maxPixelsHigh")
    d.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
    d.setValue(DispatchQueue(label: "dp.\(UUID())"), forKey: "queue")

    let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)!
        .takeUnretainedValue() as! NSObject

    let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
    let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    let fn = unsafeBitCast(modeAlloc.method(for: sel), to: ModeInit.self)
    let mode = fn(modeAlloc, sel, 1600, 1000, 60.0) as! NSObject

    let st = setCls.init()
    st.setValue(false, forKey: "hiDPI")
    st.setValue([mode], forKey: "modes")
    let aSel = NSSelectorFromString("applySettings:")
    typealias AFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    _ = unsafeBitCast(disp.method(for: aSel), to: AFn.self)(disp, aSel, st)

    let id = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
    return (disp, id)
}

print("创建前: \(online())")
var (disp, id) = makeDisplay()
usleep(300_000)
print("创建后: \(online())  新屏 id=\(id)")

switch method {
case "B":
    print("方式 B: 调用 unplug")
    let s = NSSelectorFromString("unplug")
    if disp.responds(to: s) {
        typealias V = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(disp.method(for: s), to: V.self)(disp, s)
        print("  unplug 已调用")
    } else {
        print("  对象没有 unplug 方法")
    }

case "C":
    print("方式 C: CDVirtualDisplayDestroy")
    if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
       let p = dlsym(h, "CDVirtualDisplayDestroy") {
        // 尝试当作对象指针
        typealias F = @convention(c) (UnsafeMutableRawPointer) -> Void
        let fn = unsafeBitCast(p, to: F.self)
        let ptr = Unmanaged.passUnretained(disp).toOpaque()
        fn(ptr)
        print("  已调用")
    }

default:
    print("方式 A: 释放引用")
    withExtendedLifetime(disp) { }
    disp = NSObject()
}

// 等待系统处理
for i in 1...10 {
    usleep(200_000)
    let still = online().contains(id)
    if !still {
        print("  第 \(i*200) ms: 已消失 ✓")
        exit(0)
    }
}
print("结果: 仍然在线 \(online())")
exit(1)
