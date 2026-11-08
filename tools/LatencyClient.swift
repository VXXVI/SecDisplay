// LatencyClient.swift
// 独立接收端：连到正在运行的发送端，解码并测量端到端延迟。
// 用于在不动 Windows 的情况下验证当前代码的管线表现。
//
// 编译: swiftc -O LatencyClient.swift -o latencyclient
// 运行: ./latencyclient [秒] [主机]

import Foundation
import CoreVideo
import VideoToolbox
import Darwin

setvbuf(stderr, nil, _IONBF, 0)
enum L { static func e(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

let args = CommandLine.arguments
let secs = args.count > 1 ? Double(args[1])! : 10
let host = args.count > 2 ? args[2] : "127.0.0.1"
let port: UInt16 = 9922

// MARK: - 统计

final class Stats {
    let lock = NSLock()
    var latencies: [Double] = []
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var decodeFail = 0
    var duplicates = 0
    var intervals: [Double] = []
    var lastArrival: Double = 0
    func add(_ ms: Double) { lock.lock(); latencies.append(ms); frames += 1; lock.unlock() }
    func report(_ elapsed: Double) {
        lock.lock()
        let l = latencies.sorted()
        let n = l.count
        lock.unlock()
        guard n > 0 else { L.e("没有解出任何帧"); return }
        func pct(_ p: Double) -> Double { l[min(n - 1, Int(Double(n) * p))] }
        L.e("")
        L.e("===== 端到端延迟（编码输出 → 解码完成）=====")
        L.e(String(format: "样本 %d 帧  用时 %.1fs  帧率 %.1f fps", n, elapsed, Double(n) / elapsed))
        L.e(String(format: "最小 %.2f ms", l[0]))
        L.e(String(format: "中位 %.2f ms", pct(0.5)))
        L.e(String(format: "p95  %.2f ms", pct(0.95)))
        L.e(String(format: "最大 %.2f ms", l[n - 1]))
        L.e(String(format: "码率 %.1f Mbps  关键帧 %d  解码失败 %d  重复帧(保活) %d",
                   Double(bytes) * 8 / elapsed / 1e6, keyframes, decodeFail, duplicates))

        // 帧间隔抖动：平均帧率看不出的问题，这里能看出来
        lock.lock()
        let iv = intervals.sorted()
        lock.unlock()
        if iv.count > 5 {
            func ip(_ q: Double) -> Double { iv[min(iv.count - 1, Int(Double(iv.count) * q))] }
            let mean = iv.reduce(0, +) / Double(iv.count)
            L.e("")
            L.e("===== 帧间隔（到达节奏）=====")
            L.e(String(format: "样本 %d  平均 %.1f ms (约 %.0f fps)", iv.count, mean, 1000.0 / max(mean, 0.001)))
            L.e(String(format: "最小 %.1f  p50 %.1f  p95 %.1f  最大 %.1f ms",
                       iv[0], ip(0.5), ip(0.95), iv[iv.count - 1]))
            // 超过平均间隔 2 倍视为一次卡顿
            let stalls = iv.filter { $0 > mean * 2 && $0 > 40 }.count
            L.e(String(format: "明显停顿(>2倍平均且>40ms) %d 次，占比 %.1f%%",
                       stalls, Double(stalls) * 100 / Double(iv.count)))
        }
    }
}

let stats = Stats()

// MARK: - 解码器

final class Decoder {
    var session: VTDecompressionSession?
    var fmt: CMVideoFormatDescription?
    var sawKeyframe = false

    func decode(_ data: [UInt8], ts: UInt64) {
        // AVCC: [4字节长度][NAL]...
        var nals: [[UInt8]] = []
        var i = 0
        while i + 4 <= data.count {
            let n = (Int(data[i]) << 24) | (Int(data[i+1]) << 16) | (Int(data[i+2]) << 8) | Int(data[i+3])
            i += 4
            guard n > 0, i + n <= data.count else { break }
            nals.append(Array(data[i..<(i+n)]))
            i += n
        }
        guard !nals.isEmpty else { return }

        var sps: [UInt8] = [], pps: [UInt8] = []
        for nal in nals {
            switch nal[0] & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            default: break
            }
        }

        if !sps.isEmpty, !pps.isEmpty, fmt == nil {
            sps.withUnsafeBufferPointer { sb in
                pps.withUnsafeBufferPointer { pb in
                    var f: CMVideoFormatDescription?
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: [sb.baseAddress!, pb.baseAddress!],
                        parameterSetSizes: [sps.count, pps.count],
                        nalUnitHeaderLength: 4, formatDescriptionOut: &f)
                    fmt = f
                }
            }
            if let f = fmt {
                let attrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                ]
                var s: VTDecompressionSession?
                let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: f,
                    decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: nil, decompressionSessionOut: &s)
                session = s
                L.e("解码器就绪 status=\(st)")
            }
        }

        guard let f = fmt, let s = session else { return }

        // 只把 VCL 拼回 AVCC
        var avcc = Data()
        for nal in nals {
            let t = nal[0] & 0x1F
            if t == 7 || t == 8 { continue }
            var l = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &l) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty else { return }

        var bb: CMBlockBuffer?
        avcc.withUnsafeBytes { raw in
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
                blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &bb)
            if let bb {
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
            }
        }
        guard let bb else { return }

        var sb: CMSampleBuffer?
        var sizeArr = [avcc.count]
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: f,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sb)
        guard let sb else { return }

        var flags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [],
            infoFlagsOut: &flags) { status, _, _, _, _, _ in
            if status == noErr {
                let now = CFAbsoluteTimeGetCurrent()
                let sent = Double(ts) / 1_000_000
                if now > sent { stats.add((now - sent) * 1000) }
            } else {
                stats.lock.lock(); stats.decodeFail += 1; stats.lock.unlock()
            }
        }
    }
}

// MARK: - 主流程

signal(SIGPIPE, SIG_IGN)

let sock = socket(AF_INET, SOCK_STREAM, 0)
var nodelay: Int32 = 1
setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
inet_pton(AF_INET, host, &addr.sin_addr)

L.e("连接 \(host):\(port)")
let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard rc == 0 else { L.e("连接失败"); exit(2) }
L.e("已连接")

var req: UInt8 = 0x02
_ = send(sock, &req, 1, 0)
L.e("已请求关键帧")

let dec = Decoder()
var lastHash = 0
let t0 = CFAbsoluteTimeGetCurrent()
var buf = [UInt8]()
let chunk = [UInt8](repeating: 0, count: 65536)

func readExactly(_ n: Int) -> [UInt8]? {
    var out = [UInt8]()
    out.reserveCapacity(n)
    while out.count < n {
        let want = n - out.count
        var tmp = [UInt8](repeating: 0, count: min(want, 1 << 20))
        let r = tmp.withUnsafeMutableBytes { recv(sock, $0.baseAddress, min(want, 1 << 20), 0) }
        if r <= 0 { return nil }
        out.append(contentsOf: tmp[0..<r])
    }
    return out
}

while CFAbsoluteTimeGetCurrent() - t0 < secs {
    guard let hdr = readExactly(4) else { L.e("对端关闭"); break }
    let len = (Int(hdr[0]) << 24) | (Int(hdr[1]) << 16) | (Int(hdr[2]) << 8) | Int(hdr[3])
    guard len > 9, len < 64 << 20 else { L.e("长度异常 \(len)"); break }
    guard let body = readExactly(len) else { L.e("读包失败"); break }

    guard body[0] == 0x01 else { continue }
    var ts: UInt64 = 0
    for i in 0..<8 { ts = (ts << 8) | UInt64(body[1 + i]) }
    let nowArr = CFAbsoluteTimeGetCurrent()
    stats.lock.lock()
    stats.bytes += len
    if stats.lastArrival > 0 { stats.intervals.append((nowArr - stats.lastArrival) * 1000) }
    stats.lastArrival = nowArr
    stats.lock.unlock()

    let payload = Array(body[9..<len])
    let h = payload.withUnsafeBufferPointer { p -> Int in
        guard let base = p.baseAddress else { return 0 }
        var x = 0
        let n = min(p.count, 512)
        for k in 0..<n { x = x &* 31 &+ Int(base[k]) }
        return x &+ p.count
    }
    if h == lastHash {
        stats.lock.lock(); stats.duplicates += 1; stats.lock.unlock()
        continue   // 保活重发的同一帧，不计入延迟
    }
    lastHash = h
    dec.decode(payload, ts: ts)
}

stats.report(CFAbsoluteTimeGetCurrent() - t0)
close(sock)
