// main.swift —— 验证严格生命周期管理的虚拟屏模块
//
// 用法: ./vdtest <像素W> <像素H> <逻辑W> <逻辑H> <Hz> <保持秒>
// 例:   ./vdtest 2560 1600 2560 1600 60 3     # 1:1
//       ./vdtest 5120 3200 2560 1600 60 3     # 2x Retina
//
// 测试点:
//   1. 创建成功且上线
//   2. 对象在被引用期间不消失（保持 3 秒后仍在）
//   3. 调用 destroy 后立刻消失

import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
VirtualDisplayGuard.install()

let a = CommandLine.arguments
let pxW = a.count > 1 ? Int(a[1])! : 2560
let pxH = a.count > 2 ? Int(a[2])! : 1600
let lW  = a.count > 3 ? Int(a[3])! : 2560
let lH  = a.count > 4 ? Int(a[4])! : 1600
let hz  = a.count > 5 ? Double(a[5])! : 60
let hold = a.count > 6 ? Double(a[6])! : 3

func onlineIDs() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids
}

print("当前在线显示器: \(onlineIDs())")

do {
    let t0 = CFAbsoluteTimeGetCurrent()
    let vd = try VirtualDisplay.create(pixelWidth: pxW, pixelHeight: pxH,
                                       logicalWidth: lW, logicalHeight: lH,
                                       refreshRate: hz)
    let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000

    print(String(format: "[1] 创建成功 %.1f ms  %@", dt, vd.description))
    if let cur = CGDisplayCopyDisplayMode(vd.displayID) {
        let hidpi = cur.pixelWidth > cur.width ? "  (HiDPI 2x)" : "  (1:1)"
        print("    当前模式 \(cur.width)x\(cur.height) 背板 \(cur.pixelWidth)x\(cur.pixelHeight)\(hidpi)")
    }

    // 测试点 2：持续存在
    Thread.sleep(forTimeInterval: hold)
    let stillThere = onlineIDs().contains(vd.displayID)
    print("[2] 保持 \(Int(hold))s 后仍在: \(stillThere ? "是" : "否（对象被回收了）")")

    // 测试点 3：销毁
    vd.destroy()
    Thread.sleep(forTimeInterval: 0.3)
    let gone = !onlineIDs().contains(vd.displayID)
    print("[3] destroy 后已消失: \(gone ? "是" : "否")")
    print("最终在线显示器: \(onlineIDs())")

    exit(stillThere && gone ? 0 : 1)
} catch {
    print("创建失败: \(error)")
    exit(2)
}
