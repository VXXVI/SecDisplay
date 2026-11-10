// MotionLoader.swift
// 在虚拟屏上播放动画，制造真实办公负载。
// 用 CALayer 动画由 Core Animation 直接驱动，避免 CPU 光栅化成瓶颈。
//
// 编译: swiftc -O MotionLoader.swift -o motionloader
// 运行: ./motionloader [秒]

import Foundation
import AppKit
import CoreGraphics
import Darwin
import QuartzCore

setvbuf(stderr, nil, _IONBF, 0)
let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 20

var n: UInt32 = 0
CGGetOnlineDisplayList(16, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &ids, &n)
// 用与主程序一致的 EDID 身份识别 SecDisplay 虚拟屏，
// 不要用「非主屏/fixed id」判断：在线可能还有 Sidecar、外接屏，会选错。
func isSecDisplay(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == 0xEEEE && CGDisplayModelNumber(id) == 0x5344
}
guard let vdID = ids.first(where: { isSecDisplay($0) }) else {
    FileHandle.standardError.write("找不到 SecDisplay 虚拟屏，先启动发送端\n".data(using: .utf8)!)
    exit(2)
}
FileHandle.standardError.write("目标虚拟屏 \(vdID)\n".data(using: .utf8)!)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var rect = CGDisplayBounds(vdID)
let win = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
win.backgroundColor = .black

if let scr = NSScreen.screens.first(where: {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == vdID }) {
    win.setFrame(scr.frame, display: true)
    rect = scr.frame
}

let host = NSView(frame: NSRect(origin: .zero, size: rect.size))
host.wantsLayer = true
host.layer?.backgroundColor = CGColor(red: 0.10, green: 0.11, blue: 0.15, alpha: 1)
host.layerContentsRedrawPolicy = .never

let W = rect.width, H = rect.height

// 大面积滚动条带：模拟网页滚动，整屏大面积变化
for i in 0..<6 {
    let band = CALayer()
    band.frame = CGRect(x: 0, y: CGFloat(i) * H / 6, width: W, height: H / 6 - 8)
    band.backgroundColor = CGColor(red: 0.16 + CGFloat(i) * 0.03,
                                   green: 0.17, blue: 0.22, alpha: 1)
    host.layer?.addSublayer(band)

    // 子层左右平移，制造横跨整屏的变化
    let chip = CALayer()
    chip.frame = CGRect(x: 0, y: CGFloat(i) * H / 6 + 20, width: W / 3, height: H / 6 - 48)
    chip.backgroundColor = CGColor(red: 0.25, green: 0.7, blue: 1.0, alpha: 1)
    host.layer?.addSublayer(chip)

    let move = CABasicAnimation(keyPath: "position.x")
    move.fromValue = W / 6
    move.toValue = W * 5 / 6
    move.duration = 1.2 + Double(i) * 0.25
    move.autoreverses = true
    move.repeatCount = .infinity
    chip.position = CGPoint(x: W / 6, y: chip.position.y)
    chip.add(move, forKey: "move")
}

// 一个大方块上下移动，模拟拖动窗口
let box = CALayer()
box.frame = CGRect(x: W / 8, y: 0, width: W / 4, height: H / 4)
box.backgroundColor = CGColor(red: 1.0, green: 0.75, blue: 0.2, alpha: 1)
host.layer?.addSublayer(box)

let moveY = CABasicAnimation(keyPath: "position.y")
moveY.fromValue = H / 8
moveY.toValue = H * 7 / 8
moveY.duration = 0.9
moveY.autoreverses = true
moveY.repeatCount = .infinity
box.position = CGPoint(x: box.position.x, y: H / 8)
box.add(moveY, forKey: "moveY")

// 透明度脉动，逼编码器持续重编
let fade = CABasicAnimation(keyPath: "opacity")
fade.fromValue = 0.35
fade.toValue = 1.0
fade.duration = 0.6
fade.autoreverses = true
fade.repeatCount = .infinity
box.add(fade, forKey: "fade")

win.contentView = host
win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)))
win.orderFrontRegardless()
FileHandle.standardError.write("CALayer 动画已显示，\(Int(secs)) 秒\n".data(using: .utf8)!)

DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    win.orderOut(nil)
    FileHandle.standardError.write("结束\n".data(using: .utf8)!)
    exit(0)
}
app.run()
