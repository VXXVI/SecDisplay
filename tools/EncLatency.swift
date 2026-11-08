// EncLatency.swift
// 隔离测试 VideoToolbox 编码器本身的「提交 → 输出」延迟。
// 不走 ScreenCaptureKit，不走网络，只测编码器内部缓冲。
//
// 编译: swiftc -O EncLatency.swift -o enclatency
// 运行: ./enclatency [宽] [高] [fps] [秒]

import Foundation
import CoreVideo
import VideoToolbox
import Darwin

setvbuf(stderr, nil, _IONBF, 0)
func E(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let a = CommandLine.arguments
let W = a.count > 1 ? Int(a[1])! : 2880
let H = a.count > 2 ? Int(a[2])! : 1800
let FPS = a.count > 3 ? Double(a[3])! : 55
let SECS = a.count > 4 ? Double(a[4])! : 6

final class Box { let t: UInt64; init(_ t: UInt64) { self.t = t } }

var latencies: [Double] = []
let lock = NSLock()

let spec: [String: Any] = [
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
]
let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    kCVPixelBufferWidthKey as String: W,
    kCVPixelBufferHeightKey as String: H,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
]

let cb: VTCompressionOutputCallback = { _, refcon, status, _, _ in
    guard status == noErr, let refcon else { return }
    let box = Unmanaged<Box>.fromOpaque(refcon).takeRetainedValue()
    let ms = (CFAbsoluteTimeGetCurrent() - Double(box.t) / 1_000_000) * 1000
    lock.lock(); latencies.append(ms); lock.unlock()
}

var session: VTCompressionSession?
let st = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H),
    codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
    imageBufferAttributes: attrs as CFDictionary, compressedDataAllocator: nil,
    outputCallback: cb, refcon: nil, compressionSessionOut: &session)
guard st == noErr, let s = session else { E("创建失败 \(st)"); exit(2) }

VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: FPS as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 100_000_000 as CFNumber)
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
VTCompressionSessionPrepareToEncodeFrames(s)

var p: CFTypeRef?
VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                      allocator: nil, valueOut: &p)
E("硬件编码: \(String(describing: p))")

// 造一个 YUV420 像素缓冲
var pb: CVPixelBuffer?
CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
guard let pix = pb else { E("像素缓冲失败"); exit(3) }

E("提交 \(Int(FPS))fps × \(Int(SECS))s  \(W)x\(H)")
let t0 = CFAbsoluteTimeGetCurrent()
var n = 0
var next = t0
while CFAbsoluteTimeGetCurrent() - t0 < SECS {
    next += 1.0 / FPS
    CVPixelBufferLockBaseAddress(pix, [])
    // 让内容每帧变化，避免编码器走静止优化
    if let base = CVPixelBufferGetBaseAddress(pix) {
        let b = base.assumingMemoryBound(to: UInt8.self)
        let off = (n * 997) % (W * H)
        b[off] = UInt8(truncatingIfNeeded: n)
    }
    CVPixelBufferUnlockBaseAddress(pix, [])

    let box = Box(UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000))
    let ref = Unmanaged.passRetained(box).toOpaque()
    var flags: VTEncodeInfoFlags = []
    let r = VTCompressionSessionEncodeFrame(s, imageBuffer: pix,
        presentationTimeStamp: CMTime(value: Int64(n), timescale: Int32(FPS)),
        duration: CMTime(value: 1, timescale: Int32(FPS)),
        frameProperties: nil, sourceFrameRefcon: ref, infoFlagsOut: &flags)
    if r != noErr { Unmanaged<Box>.fromOpaque(ref).release() }
    n += 1

    let sleep = next - CFAbsoluteTimeGetCurrent()
    if sleep > 0 { usleep(useconds_t(sleep * 1_000_000)) }
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
usleep(300_000)

lock.lock()
let l = latencies.sorted()
lock.unlock()
let el = CFAbsoluteTimeGetCurrent() - t0
guard !l.isEmpty else { E("没有输出"); exit(4) }
func pct(_ q: Double) -> Double { l[min(l.count - 1, Int(Double(l.count) * q))] }
E("输出 \(l.count) 帧  实际 \(String(format: "%.1f", Double(l.count) / el)) fps")
E(String(format: "提交→输出延迟  最小 %.2f  中位 %.2f  p95 %.2f  最大 %.2f ms",
         l[0], pct(0.5), pct(0.95), l[l.count - 1]))
