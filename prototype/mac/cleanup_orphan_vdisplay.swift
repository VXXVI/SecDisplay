// cleanup_orphan_vdisplay.swift
// 清理 WindowServer 中残留的孤儿虚拟显示器（owner 进程已死但显示条目仍在）。
//
// 原理（2026-11-12 在 macOS 27.2 (26B123) / M1 Pro 真机验证）：
//   孤儿虚拟屏无法通过任何导出 API 按 displayID 移除：
//     - CDVirtualDisplayDestroy / SL2CDVirtualDisplayDestroy 只操作本进程的
//       CGXVirtualDisplay 表，找不到孤儿 displayID，直接 no-op。
//     - CGVirtualDisplay initWithDescriptor: 对同 vendor/product 身份被 WindowServer 拒绝
//       （连不同 serial 都拒绝），无法借重建覆盖。
//   唯一有效的不注入销路径：让 WindowServer 走一轮完整的显示重配置。
//   `pmset displaysleepnow` + 屏幕唤醒会触发该重配置，WindowServer 在其中
//   清掉 owner 已死的虚拟显示设备。已三次端到端复现，用户会话不受影响。
//
// 用法：
//   cleanup_orphan_vdisplay                 # dry-run：只列出疑似孤儿，不执行清理
//   cleanup_orphan_vdisplay --vendor 0xEEEE --product 0x5344   # 指定身份过滤
//   cleanup_orphan_vdisplay --apply         # 实际执行清理（休眠+唤醒）
//   cleanup_orphan_vdisplay --apply --verify # 清理后再验证同身份可重建（会短暂创建并销毁）
//
// 退出码：0 无孤儿或已清理；1 发现孤儿但未清理（dry-run）；2 清理后孤儿仍在；3 参数错误。

import AppKit
import CoreGraphics
import Darwin
import Foundation

// ---- 参数 ----
var apply = false
var verify = false
var vendorFilter: UInt32?
var productFilter: UInt32?

var args = Array(CommandLine.arguments.dropFirst())
while let a = args.first {
    args.removeFirst()
    switch a {
    case "--apply": apply = true
    case "--verify": verify = true
    case "--vendor":
        guard let s = args.first else { print("missing value for --vendor"); exit(3) }
        args.removeFirst()
        vendorFilter = UInt32(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
    case "--product":
        guard let s = args.first else { print("missing value for --product"); exit(3) }
        args.removeFirst()
        productFilter = UInt32(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
    case "--help", "-h":
        print("usage: cleanup_orphan_vdisplay [--vendor 0xEEEE] [--product 0x5344] [--apply] [--verify]")
        exit(0)
    default:
        print("unknown arg: \(a)"); exit(3)
    }
}

// ---- 显示列表工具 ----
func onlineList() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(64, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids
}

struct DisplayInfo {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let width: Int
    let height: Int
    let active: Bool
    let main: Bool
    let builtin: Bool
}

func displayInfos() -> [DisplayInfo] {
    onlineList().map {
        DisplayInfo(id: $0,
                    vendor: CGDisplayVendorNumber($0),
                    model: CGDisplayModelNumber($0),
                    serial: CGDisplaySerialNumber($0),
                    width: CGDisplayPixelsWide($0),
                    height: CGDisplayPixelsHigh($0),
                    active: CGDisplayIsActive($0) != 0,
                    main: CGDisplayIsMain($0) != 0,
                    builtin: CGDisplayIsBuiltin($0) != 0)
    }
}

func matches(_ d: DisplayInfo) -> Bool {
    if let v = vendorFilter, d.vendor != v { return false }
    if let p = productFilter, d.model != p { return false }
    return !d.builtin
}

func printInfos(_ list: [DisplayInfo], header: String) {
    print("[\(header)]")
    for d in list {
        print(String(format: "  id=%u vendor=0x%04X model=0x%04X serial=%u %dx%d active=%d main=%d",
                     d.id, d.vendor, d.model, d.serial, d.width, d.height,
                     d.active ? 1 : 0, d.main ? 1 : 0))
    }
}

// ---- 主流程 ----
let before = displayInfos().filter(matches)
printInfos(displayInfos(), header: "当前在线显示列表")

guard !before.isEmpty else {
    print("没有匹配过滤条件的非内建虚拟屏，无事可做。")
    exit(0)
}

print("")
print("疑似孤儿（非内建、按过滤条件命中）：")
for d in before {
    print(String(format: "  id=%u vendor=0x%04X model=0x%04X serial=%u", d.id, d.vendor, d.model, d.serial))
}
print("")
print("注意：本工具无法直接判定 owner 进程是否存活（WindowServer 不导出该信息）。")
print("请自行确认没有其它发送端进程正在使用这些屏幕，例如：")
print("  pgrep -fl <发送端程序名>")
print("")

if !apply {
    print("dry-run 结束，未做任何变更。加 --apply 执行清理。")
    exit(1)
}

// ---- 清理：休眠 + 唤醒，触发 WindowServer 显示重配置 ----
print("执行清理：pmset displaysleepnow + caffeinate 唤醒 ...")
let t1 = Process()
t1.launchPath = "/usr/bin/pmset"
t1.arguments = ["displaysleepnow"]
t1.standardOutput = FileHandle.nullDevice
t1.standardError = FileHandle.nullDevice
t1.launch()
t1.waitUntilExit()

sleep(6)   // 等屏幕进入休眠，WindowServer 冻结合成

let t2 = Process()
t2.launchPath = "/usr/bin/caffeinate"
t2.arguments = ["-u", "-t", "3"]
t2.standardOutput = FileHandle.nullDevice
t2.standardError = FileHandle.nullDevice
t2.launch()
t2.waitUntilExit()
sleep(3)   // 等唤醒后的显示重配置完成

let after = displayInfos().filter(matches)
if after.isEmpty {
    print("清理成功：孤儿虚拟屏已从在线列表消失。")
} else {
    printInfos(after, header: "清理后仍在线（未清掉）")
    print("清理失败，孤儿仍在线。剩余手段只有注销重登或重启（本工具不做）。")
    exit(2)
}

// ---- 可选验证：同身份重建是否解除阻塞 ----
if verify, let v = vendorFilter, let p = productFilter {
    print("验证同身份重建 ...")
    let d = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
    let dispCls = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
    let desc = d.init()
    desc.setValue(NSNumber(value: v), forKey: "vendorID")
    desc.setValue(NSNumber(value: p), forKey: "productID")
    desc.setValue(NSNumber(value: UInt32.random(in: 900...999)), forKey: "serialNum")
    desc.setValue("cleanup-verify", forKey: "name")
    desc.setValue(NSNumber(value: 1600), forKey: "maxPixelsWide")
    desc.setValue(NSNumber(value: 1000), forKey: "maxPixelsHigh")
    desc.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
    desc.setValue(DispatchQueue(label: "cleanup-verify"), forKey: "queue")
    let a = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let disp = a.perform(NSSelectorFromString("initWithDescriptor:"), with: desc)?.takeUnretainedValue() as? NSObject
    if disp == nil {
        print("验证失败：同身份创建仍被拒。")
        exit(2)
    }
    print("同身份创建已恢复，验证通过，正在销毁验证屏 ...")
    usleep(300_000)
    let iv = class_getInstanceVariable(NSClassFromString("CGVirtualDisplay"), "_client")!
    let raw = UnsafeRawPointer(Unmanaged.passUnretained(disp!).toOpaque())
        .advanced(by: ivar_getOffset(iv))
    if let cp = raw.load(as: UnsafeMutableRawPointer?.self),
       let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
       let sym = dlsym(h, "CDVirtualDisplayDestroy") {
        typealias F = @convention(c) (UnsafeMutableRawPointer) -> Void
        unsafeBitCast(sym, to: F.self)(cp)
    }
    usleep(1_000_000)
    print("验证屏已销毁。")
}

exit(0)
