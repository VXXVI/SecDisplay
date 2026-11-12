// MouseProbe.swift
// 鼠标速率探针 + 轨迹模拟器。
//
// 采样：8ms 读一次全局鼠标位置，算瞬时速度和每秒移动事件数。
// 模拟：用 CGWarpMouseCursorPosition 沿预设轨迹移动光标，用于可重复验收。
//
// 编译: swiftc -O tools/MouseProbe.swift -o tools/mouseprobe
// 用法:
//   ./tools/mouseprobe                         CSV 输出到 stdout
//   ./tools/mouseprobe --simulate circle      边采样边画圆
//   ./tools/mouseprobe --simulate line --seconds 10
//   ./tools/mouseprobe --simulate saw --speed 900
//
// 输出列: t_ms,x,y,speed_px_s,moves_per_s,inside
// inside=1 表示光标落在 SecDisplay 虚拟屏内。

import Foundation
import CoreGraphics
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

var simMode = "none"
var seconds = 0.0
var speed = 600.0
var radius = 160.0

var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--simulate":
        simMode = args.next() ?? "circle"
    case "--seconds":
        seconds = Double(args.next() ?? "10") ?? 10
    case "--speed":
        speed = Double(args.next() ?? "600") ?? 600
    case "--radius":
        radius = Double(args.next() ?? "160") ?? 160
    default:
        break
    }
}

// 虚拟屏范围：按 EDID 三元组识别，避免误伤 Sidecar
func secDisplayBounds() -> CGRect? {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    for id in ids.prefix(Int(n)) where CGDisplayVendorNumber(id) == 0xEEEE
        && CGDisplayModelNumber(id) == 0x5344 {
        return CGDisplayBounds(id)
    }
    return nil
}

let vdBounds = secDisplayBounds()
let vdCenter = vdBounds.map { CGPoint(x: $0.midX, y: $0.midY) }

let start = DispatchTime.now()
var lastPoint = CGEvent(source: nil)?.location ?? .zero
var lastMoveAt = start.uptimeNanoseconds
var moveCount = 0
var windowStart = start.uptimeNanoseconds
var windowMoves = 0
let sampleQueue = DispatchQueue(label: "mouseprobe.sample")

func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
}

// 模拟器：每 8ms 推进一步
func startSimulator() {
    guard simMode != "none", let center = vdCenter else { return }
    let q = DispatchQueue(label: "mouseprobe.sim")
    let t0 = DispatchTime.now().uptimeNanoseconds
    let stepNs: UInt64 = 8_000_000
    var lastWarp = t0
    q.async {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - t0 >= UInt64(max(0, seconds) * 1_000_000_000) { break }
            if now - lastWarp < stepNs { usleep(2_000); continue }
            lastWarp = now
            let t = Double(now - t0) / 1_000_000_000.0
            var p = center
            switch simMode {
            case "circle":
                let a = t * 2.0 * .pi * 0.5
                p.x = center.x + cos(a) * radius
                p.y = center.y + sin(a) * radius
            case "line":
                let phase = (t * speed / 400.0).truncatingRemainder(dividingBy: 2.0)
                let k = phase < 1.0 ? phase : 2.0 - phase
                p.x = center.x - radius + k * radius * 2.0
            case "saw":
                let phase = (t * 0.7).truncatingRemainder(dividingBy: 1.0)
                p.x = center.x - radius + phase * radius * 2.0
            default:
                break
            }
            p.x = min(max(p.x, center.x - radius), center.x + radius)
            p.y = min(max(p.y, center.y - radius), center.y + radius)
            CGWarpMouseCursorPosition(p)
        }
    }
}

let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
timer.setEventHandler {
    let now = DispatchTime.now().uptimeNanoseconds
    let p = CGEvent(source: nil)?.location ?? lastPoint
    let dt = Double(now - lastMoveAt) / 1_000_000_000.0
    let dx = Double(p.x - lastPoint.x)
    let dy = Double(p.y - lastPoint.y)
    let dist = (dx * dx + dy * dy).squareRoot()
    if dist > 0.5 {
        moveCount += 1
        windowMoves += 1
    }
    let inst = dt > 0 ? dist / dt : 0
    lastPoint = p
    lastMoveAt = now

    // 每 500ms 输出一行，避免刷爆管道
    if now - windowStart >= 500_000_000 {
        let winSec = Double(now - windowStart) / 1_000_000_000.0
        let eps = Double(windowMoves) / max(winSec, 0.001)
        let inside = vdBounds.map { $0.contains(p) } ?? false
        print(String(format: "%.1f,%.1f,%.1f,%.1f,%.1f,%d",
                     nowMs(), p.x, p.y, inst, eps, inside ? 1 : 0))
        windowMoves = 0
        windowStart = now
    }
}
timer.resume()

if simMode != "none" {
    FileHandle.standardError.write(
        "模拟 \(simMode)，半径 \(Int(radius))px，速度 \(Int(speed))px/s\n".data(using: .utf8)!)
    startSimulator()
}

DispatchQueue.global().asyncAfter(deadline: .now() + seconds + 0.5) {
    if seconds > 0 { exit(0) }
}
dispatchMain()
