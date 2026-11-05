// VDCreate.swift
// 生产可用的虚拟屏创建模块（独立验证版）。
//
// 用法:
//   ./vdcreate <像素宽> <像素高> <刷新率> <hiDPI 0|1> <保持秒数>
// 例:
//   ./vdcreate 2560 1600 60 1 5     # 2560x1600 背板，1280x800 逻辑（Retina）
//   ./vdcreate 2560 1600 60 0 5     # 2560x1600 1:1，逻辑即像素（与 Windows 屏对齐用这个）

import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

struct VD {
    let obj: NSObject
    let id: CGDirectDisplayID
}

enum VDError: Error {
    case classesMissing
    case initFailed
    case modeFailed
}

/// 创建一块虚拟显示器。hiDPI=true 时逻辑尺寸为像素的一半。
func createVirtualDisplay(pixelWidth: UInt32, pixelHeight: UInt32,
                          refreshRate: Double, hiDPI: Bool,
                          name: String = "SecDisplay") throws -> VD {
    guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
          let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
          let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
          let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
    else { throw VDError.classesMissing }

    let d = descClass.init()
    d.setValue(NSNumber(value: 1), forKey: "vendorID")
    d.setValue(NSNumber(value: 1), forKey: "productID")
    d.setValue(NSNumber(value: 1), forKey: "serialNum")
    d.setValue(name, forKey: "name")
    d.setValue(NSNumber(value: pixelWidth), forKey: "maxPixelsWide")
    d.setValue(NSNumber(value: pixelHeight), forKey: "maxPixelsHigh")
    // 物理尺寸按 110 ppi 折算
    d.setValue(NSValue(size: NSSize(width: 25.4 * Double(pixelWidth) / 110.0,
                                    height: 25.4 * Double(pixelHeight) / 110.0)),
               forKey: "sizeInMillimeters")
    d.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
    d.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
    d.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
    d.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
    // 必须非零，否则 macOS 会判定无效
    d.setValue(DispatchQueue(label: "SecDisplay.vd.\(name)"), forKey: "queue")

    let alloc = displayClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    guard let disp = alloc.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?
            .takeUnretainedValue() as? NSObject else { throw VDError.initFailed }

    let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
    let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    let modeInit = unsafeBitCast(modeAlloc.method(for: modeSel), to: ModeInit.self)
    let logicalW = hiDPI ? UInt(pixelWidth / 2) : UInt(pixelWidth)
    let logicalH = hiDPI ? UInt(pixelHeight / 2) : UInt(pixelHeight)
    guard let mode = modeInit(modeAlloc, modeSel, logicalW, logicalH, refreshRate) as? NSObject else {
        throw VDError.modeFailed
    }

    let settings = settingsClass.init()
    settings.setValue(hiDPI, forKey: "hiDPI")
    settings.setValue([mode], forKey: "modes")

    // 注意：返回值是 BOOL，必须用 @convention(c) 直接调用。
    // 用 perform(...)?.takeUnretainedValue() as? Bool 会拿到错误指针导致崩溃。
    let applySel = NSSelectorFromString("applySettings:")
    typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
    let applyFn = unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)
    let ok = applyFn(disp, applySel, settings)
    guard ok else { throw VDError.modeFailed }

    let id = (disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
    return VD(obj: disp, id: CGDirectDisplayID(id))
}

// MARK: - 主流程

let a = CommandLine.arguments
let pxW = UInt32(a.count > 1 ? Int(a[1])! : 2560)
let pxH = UInt32(a.count > 2 ? Int(a[2])! : 1600)
let hz = a.count > 3 ? Double(a[3])! : 60
let hidpi = a.count > 4 ? (a[4] == "1") : true
let holdSeconds = a.count > 5 ? Double(a[5])! : 5

do {
    let t0 = CFAbsoluteTimeGetCurrent()
    let vd = try createVirtualDisplay(pixelWidth: pxW, pixelHeight: pxH,
                                      refreshRate: hz, hiDPI: hidpi)
    let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000

    var online = false
    var waited = 0.0
    while waited < 2.0 {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        if ids.contains(vd.id) { online = true; break }
        usleep(20_000); waited += 0.02
    }

    print(String(format: "创建耗时 %.2f ms  displayID=%u  上线=%@  上线等待=%.0f ms",
                 dt, vd.id, online ? "是" : "否", waited * 1000))
    if online {
        print("  背板像素: \(CGDisplayPixelsWide(vd.id))x\(CGDisplayPixelsHigh(vd.id))")
        print("  逻辑尺寸: \(CGDisplayBounds(vd.id).width)x\(CGDisplayBounds(vd.id).height)")
        if let modes = CGDisplayCopyAllDisplayModes(vd.id, nil) as? [CGDisplayMode] {
            print("  模式数: \(modes.count)")
            for m in modes.prefix(6) {
                let h = m.pixelWidth > m.width ? " HiDPI" : ""
                print("    \(m.width)x\(m.height)@\(Int(m.refreshRate))\(h) 背板 \(m.pixelWidth)x\(m.pixelHeight)")
            }
        }
        for s in NSScreen.screens {
            let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            print("  NSScreen \(s.localizedName) id=\(n?.uint32Value ?? 0) 逻辑=\(Int(s.frame.width))x\(Int(s.frame.height)) scale=\(s.backingScaleFactor)")
        }
    }

    if holdSeconds > 0 { Thread.sleep(forTimeInterval: holdSeconds) }
    exit(online ? 0 : 4)
} catch {
    print("失败: \(error)")
    exit(2)
}
