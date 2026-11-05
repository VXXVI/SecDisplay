// EncodeBench2.swift
// 用接近真实桌面的内容测编码：大块文字、窗口、渐变、动态元素。
// 这是决定「60fps 能不能稳住」的真实数据。
//
// 编译: swiftc -O EncodeBench2.swift -o encodebench2
// 运行: ./encodebench2 [宽] [高] [秒] [码率Mbps]

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
let bitrate = a.count > 4 ? Int(a[4])! : 80

// MARK: - 生成桌面样张

func makeDesktopFrame(_ seed: Int) -> [UInt8] {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // 背景渐变
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1),
        CGColor(red: 0.20, green: 0.22, blue: 0.28, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: W, y: H), options: [])

    // 模拟窗口
    for i in 0..<4 {
        let x = 80 + i * 120
        let y = 100 + i * 90
        let w = 900 - i * 60
        let h = 620 - i * 40
        ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.75, green: 0.75, blue: 0.78, alpha: 1))
        // 文字行，模拟终端输出
        for line in 0..<28 {
            let ly = y + h - 40 - line * 19
            let lw = 200 + ((line * 137 + seed * 7) % 500)
            ctx.fill(CGRect(x: x + 20, y: ly, width: lw, height: 9))
        }
    }
    // 真实动态：整块画面滚动（模拟网页/视频/拖窗口），迫使编码器处理大部分宏块
    let cx = CGFloat((seed * 37) % max(W - 400, 1))
    let cy = CGFloat((seed * 53) % max(H - 400, 1))
    ctx.setFillColor(CGColor(red: 0.3, green: 0.8, blue: 1.0, alpha: 1))
    ctx.fill(CGRect(x: cx, y: cy, width: 400, height: 300))
    // 大量随机小块，模拟文字密集变化的界面
    for k in 0..<300 {
        let rx = CGFloat(((seed * 17 + k * 131) % max(W - 20, 1)))
        let ry = CGFloat(((seed * 29 + k * 197) % max(H - 20, 1)))
        let g = CGFloat((k * 37 + seed * 11) % 255) / 255.0
        ctx.setFillColor(CGColor(red: g, green: 0.6, blue: 1 - g, alpha: 1))
        ctx.fill(CGRect(x: rx, y: ry, width: 60, height: 14))
    }

    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let bpr = ctx.bytesPerRow
    var out = [UInt8](repeating: 0, count: W * H * 4)
    for y in 0..<H {
        let src = data + y * bpr
        let dstOff = (H - 1 - y) * W * 4
        out.withUnsafeMutableBytes { dst in
            memcpy(dst.baseAddress!.advanced(by: dstOff), src, W * 4)
        }
    }
    return out
}

// MARK: - 编码器

final class Bench {
    var session: VTCompressionSession?
    var frames = 0
    var bytes = 0
    var keyframes = 0
    var latencies: [Double] = []
    var lock = NSLock()

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
        let cb: VTCompressionOutputCallback = { ref, _, status, _, sample in
            guard status == noErr, let sample, let ref else { return }
            Unmanaged<Bench>.fromOpaque(ref).takeUnretainedValue().output(sample)
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
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: (bitrate * 1_000_000) as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)

        var p: CFTypeRef?
        VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: nil, valueOut: &p)
        print("使用硬件编码器: \(String(describing: p))")
        return true
    }

    func output(_ sample: CMSampleBuffer) {
        lock.lock()
        frames += 1
        bytes += CMSampleBufferGetTotalSampleSize(sample)
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let f = arr.first, !(f[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) {
            keyframes += 1
        }
        lock.unlock()
    }
}

// MARK: - 主流程

let bench = Bench()
guard bench.start() else { exit(2) }

var pb: CVPixelBuffer?
CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
guard let pixelBuffer = pb else { print("像素缓冲失败"); exit(3) }

print("开始 \(W)x\(H) @60fps, 目标码率 \(bitrate) Mbps, 持续 \(Int(secs))s")
let t0 = CFAbsoluteTimeGetCurrent()
var submitted = 0
var next = t0
var encodeCallTotal = 0.0

while CFAbsoluteTimeGetCurrent() - t0 < secs {
    next += 1.0 / 60.0
    let frameData = makeDesktopFrame(submitted)

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    memcpy(CVPixelBufferGetBaseAddress(pixelBuffer), frameData, frameData.count)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    let te = CFAbsoluteTimeGetCurrent()
    var flags: VTEncodeInfoFlags = []
    VTCompressionSessionEncodeFrame(bench.session!, imageBuffer: pixelBuffer,
                                    presentationTimeStamp: CMTime(value: Int64(submitted), timescale: 60),
                                    duration: CMTime(value: 1, timescale: 60),
                                    frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
    encodeCallTotal += (CFAbsoluteTimeGetCurrent() - te) * 1000
    submitted += 1

    let sleep = next - CFAbsoluteTimeGetCurrent()
    if sleep > 0 { usleep(useconds_t(sleep * 1_000_000)) }
}

VTCompressionSessionCompleteFrames(bench.session!, untilPresentationTimeStamp: .invalid)
let elapsed = CFAbsoluteTimeGetCurrent() - t0

bench.lock.lock()
let f = bench.frames, by = bench.bytes, kf = bench.keyframes
bench.lock.unlock()

print("\n===== 桌面内容编码性能 =====")
print(String(format: "提交 %d 帧  编码 %d 帧  用时 %.2fs", submitted, f, elapsed))
print(String(format: "帧率 %.1f fps", Double(f) / elapsed))
print(String(format: "实际码率 %.1f Mbps", Double(by) * 8 / elapsed / 1e6))
print(String(format: "关键帧 %d", kf))
print(String(format: "编码调用平均耗时 %.3f ms", encodeCallTotal / Double(max(submitted, 1))))
print(String(format: "平均每帧 %d 字节", by / max(f, 1)))
exit(0)
