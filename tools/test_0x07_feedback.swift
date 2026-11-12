// 0x07 反馈包解析的单元级验证。
// 不连生产端口：把 drainControl 的解析逻辑对拍成可直调的最小复刻，
// 用同一组字节流验证字段解码、粘包、半包、载荷含 0x04、未知类型字节五个场景。
//
// 用法: swift tools/test_0x07_feedback.swift
// 说明: drainControl 是 Sender 私有方法且依赖 Network 连接状态，
//       这里按 ScreenSender.swift 中 0x07 分支逐行复刻 rd16 与 removeFirst(13)，
//       若该分支改动，需同步此脚本。

import Foundation

// 与 ScreenSender.swift FeedbackSignals 同构
struct FB {
    var presentP95: Double = 0
    var sourceP95: Double = 0
    var decodeFps: Double = 0
    var presentDrop: Int = 0
    var pacedDrop: Int = 0
}

// 复刻 Sender.drainControl 中 0x07 分支（含粘包循环与未知字节跳过）。
// 输入: ctrlBuf 等价字节序列；输出: (解析出的包列表, 剩余未消费字节, 崩溃即失败)
func drain(_ input: [UInt8]) -> ([FB], [UInt8]) {
    var ctrlBuf = input
    var out: [FB] = []
    while !ctrlBuf.isEmpty {
        let t = ctrlBuf[ctrlBuf.startIndex]
        if t == 0x07 {
            guard ctrlBuf.count >= 13 else { return (out, ctrlBuf) }   // 半包，等更多数据
            let o = ctrlBuf.startIndex
            func rd16(_ off: Int) -> UInt16 {
                (UInt16(ctrlBuf[o + off]) << 8) | UInt16(ctrlBuf[o + off + 1])
            }
            out.append(FB(
                presentP95: Double(rd16(1)),
                sourceP95: Double(rd16(3)),
                decodeFps: Double(rd16(5)) / 10.0,
                presentDrop: Int(rd16(7)),
                pacedDrop: Int(rd16(9))
            ))
            ctrlBuf.removeFirst(13)
        } else if t == 0x02 || t == 0x04 {
            // 其他已知控制包按其定长消费：0x02 占 1 字节，0x04 占 12 字节
            let n = t == 0x02 ? 1 : 12
            guard ctrlBuf.count >= n else { return (out, ctrlBuf) }
            ctrlBuf.removeFirst(n)
        } else {
            ctrlBuf.removeFirst(1)   // 未知字节，丢掉
        }
        if ctrlBuf.count > 65536 { ctrlBuf.removeAll() }
    }
    return (out, ctrlBuf)
}

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }

func pack(presentP95: UInt16, sourceP95: UInt16, decodeFps10: UInt16,
          presentDrop: UInt16, pacedDrop: UInt16) -> [UInt8] {
    [0x07] + be16(presentP95) + be16(sourceP95) + be16(decodeFps10)
          + be16(presentDrop) + be16(pacedDrop) + [0x00, 0x00]   // reserved
}

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    let mark = cond ? "PASS" : "FAIL"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : "  \(detail)")")
    if !cond { failures += 1 }
}

// 1. 正常单包：presentP95=33ms sourceP95=20ms decodeFps=59.7 presentDrop=2 pacedDrop=1
let p1 = pack(presentP95: 33, sourceP95: 20, decodeFps10: 597, presentDrop: 2, pacedDrop: 1)
let (r1, rest1) = drain(p1)
check("单包字段", r1.count == 1
      && r1[0].presentP95 == 33 && r1[0].sourceP95 == 20
      && abs(r1[0].decodeFps - 59.7) < 1e-9
      && r1[0].presentDrop == 2 && r1[0].pacedDrop == 1,
      "got \(r1)")
check("单包无残留", rest1.isEmpty)

// 2. 粘包：三个包连发，一次 drain 全部解析
let (r2, rest2) = drain(p1 + p1 + p1)
check("三连包", r2.count == 3 && rest2.isEmpty)

// 3. 半包：先给 8 字节，应原样等待；补齐后应解析出 1 包
let (r3a, rest3a) = drain(Array(p1.prefix(8)))
check("半包等待", r3a.isEmpty && rest3a.count == 8)
let (r3b, rest3b) = drain(Array(p1.prefix(8)) + Array(p1.suffix(from: 8)))
check("半包补齐", r3b.count == 1 && rest3b.isEmpty)

// 4. 载荷含 0x04 字节：sourceP95=0x0404。旧 Mac 会把第二个字节 0x04 当输入包
//    吞掉后续 11 字节；新解析必须完整消费 13 字节且字段正确。
let p4 = pack(presentP95: 10, sourceP95: 0x0404, decodeFps10: 600, presentDrop: 0, pacedDrop: 0)
let (r4, rest4) = drain(p4 + p1)
check("载荷含0x04不串包", r4.count == 2
      && r4[0].sourceP95 == 0x0404 && r4[1].presentP95 == 33,
      "got \(r4), rest=\(rest4)")

// 5. 未知类型字节混入：0x99 被逐字节跳过，随后 0x07 正常解析
let (r5, rest5) = drain([0x99, 0x98] + p1)
check("未知字节跳过", r5.count == 1 && rest5.isEmpty)

// 6. 0x02 关键帧请求与 0x07 混排
let (r6, rest6) = drain([0x02] + p1)
check("0x02与0x07混排", r6.count == 1 && rest6.isEmpty)

print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
