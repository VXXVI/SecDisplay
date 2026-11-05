// EncodeBench.swift
// 不依赖屏幕录制权限，直接合成画面跑编码器，测出 M1 Pro 上的真实编码性能。
// 这是判断"能不能 60fps 低延迟"的关键数据。
//
// 编译: swiftc -O EncodeBench.swift -o encodebench
// 运行: ./encodebench [宽] [高] [秒]

import Foundation
import CoreVideo
import VideoToolbox
import CoreGraphics
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let a = CommandLine.arguments
let W = a.count > 1 ? Int(a[1])! : 2560
let H = a.count > 2 ? Int(a[2])! : 1600
let secs = a.count > 3 ? Double(a[3])! : 5

final class Bench {
    var session: VTCompressionSession?
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var maxLatency: Double = 0
    var sumLatency: Double = 0
    var submitTime: [Int64: Double] = [:]
    var lock = NSLock()
    var firstOutput: Double = 0

    func start() -> Bool {
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
        ]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W,
            kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let cb: VTCompressionOutputCallback = { ref, src, status, flags, sample in
            guard status == noErr, let sample, let ref else { return }
            Unmanaged<Bench>.fromOpaque(ref).takeUnretainedValue().output(sample, src)
        }
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(W), height: Int32(H),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: cb,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard st == noErr, let s = session else { print("创建失败 \(st)"); return false }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 80_000_000 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)

        // 打印实际选中的编码器
        if let props: CFDictionary = {
            var p: CFDictionary?
            VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as CFString,
                                  allocator: nil, valueOut: &p)
            return p
        }() {
            print("硬件加速: \(props)")
        }
        return true
    }

    func output(_ sample: CMSampleBuffer, _ src: UnsafeMutableRawPointer?) {
        lock.lock()
        frames += 1
        bytes += CMSampleBufferGetTotalSampleSize(sample)
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let now = CFAbsoluteTimeGetCurrent()
        if firstOutput == 0 { firstOutput = now }
        let lat = (now - firstOutput - pts) * 1000
        sumLatency += lat
        maxLatency = max(maxLatency, lat)
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let f = arr.first, !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) {
            keyframes += 1
        }
        lock.unlock()
    }
}

let bench = Bench()
guard bench.start() else { exit(2) }

// 合成一帧带动态内容的 BGRA 图，模拟桌面变化
let bpr = W * 4
var buf = [UInt8](repeating: 0, count: bpr * H)
for y in 0..<H {
    for x in 0..<W {
        let i = y * bpr + x * 4
        let v = UInt8(clamping: (x * 255 / W + y * 255 / H) / 2)
        buf[i] = v; buf[i+1] = v; buf[i+2] = v; buf[i+3] = 255
    }
}

var pb: CVPixelBuffer?
CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
guard let pixelBuffer = pb else { print("像素缓冲创建失败"); exit(3) }

CVPixelBufferLockBaseAddress(pixelBuffer, [])
let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
memcpy(base, buf, buf.count)
CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

print("开始编码 \(W)x\(H) 持续 \(Int(secs))s ...")
let t0 = CFAbsoluteTimeGetCurrent()
var submitted = 0
let interval = 1.0 / 60.0

// 精确 60fps 提交
var next = t0
while CFAbsoluteTimeGetCurrent() - t0 < secs {
    next += interval
    // 每帧轻微改动，防止编码器把静止画面优化掉
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let p = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let off = (submitted * 13) % (bpr * H - 4)
    p[off] = UInt8(submitted & 0xFF)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    var flags: VTEncodeInfoFlags = []
    VTCompressionSessionEncodeFrame(bench.session!, imageBuffer: pixelBuffer,
                                    presentationTimeStamp: CMTime(value: Int64(submitted), timescale: 60),
                                    duration: CMTime(value: 1, timescale: 60),
                                    frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    if flags.contains(.frameDropped) { }
    submitted += 1

    let sleep = next - CFAbsoluteTimeGetCurrent()
    if sleep > 0 { usleep(useconds_t(sleep * 1_000_000)) }
}

VTCompressionSessionCompleteFrames(bench.session!, untilPresentationTimeStamp: .invalid)
let elapsed = CFAbsoluteTimeGetCurrent() - t0

bench.lock.lock()
let f = bench.frames, by = bench.bytes, kf = bench.keyframes
let lat = bench.sumLatency / Double(max(f, 1))
let mx = bench.maxLatency
bench.lock.unlock()

print("\n===== 编码性能 =====")
print(String(format: "提交 %d 帧，实际编码 %d 帧，用时 %.2fs", submitted, f, elapsed))
print(String(format: "实际帧率 %.1f fps", Double(f) / elapsed))
print(String(format: "码率 %.1f Mbps", Double(by) * 8 / elapsed / 1e6))
print(String(format: "关键帧 %d 个", kf))
print(String(format: "编码管线延迟 平均 %.2f ms  最大 %.2f ms", lat, mx))
print(String(format: "每帧平均码流 %d 字节", by / max(f, 1)))
exit(0)
