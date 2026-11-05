// PipeProbe.swift
// 验证「虚拟屏 → ScreenCaptureKit → VideoToolbox 低延迟硬编」这一段管线的可行性，
// 并实测编码耗时、码率、帧率。这是决定体感的第一段，也是开源方案最容易做砸的地方。
//
// 编译: swiftc -O PipeProbe.swift -o pipeprobe
// 运行: ./pipeprobe [保持秒数]

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

let keepSeconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 10

// MARK: - 1. 建虚拟屏

let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as! NSObject.Type
let displayClass = NSClassFromString("CGVirtualDisplay") as! NSObject.Type
let modeClass = NSClassFromString("CGVirtualDisplayMode") as! NSObject.Type
let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as! NSObject.Type

let PX_W: UInt32 = 2560
let PX_H: UInt32 = 1600
let HZ = 60.0

let desc = descClass.init()
desc.setValue(NSNumber(value: 1), forKey: "vendorID")
desc.setValue(NSNumber(value: 1), forKey: "productID")
desc.setValue(NSNumber(value: 1), forKey: "serialNum")
desc.setValue("SecDisplay", forKey: "name")
desc.setValue(NSNumber(value: PX_W), forKey: "maxPixelsWide")
desc.setValue(NSNumber(value: PX_H), forKey: "maxPixelsHigh")
desc.setValue(NSValue(size: NSSize(width: 400, height: 250)), forKey: "sizeInMillimeters")
desc.setValue(DispatchQueue(label: "SecDisplay.pipe"), forKey: "queue")

let alloc = displayClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
let vdisp = alloc.perform(NSSelectorFromString("initWithDescriptor:"), with: desc)!.takeUnretainedValue() as! NSObject

let modeAlloc = modeClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
let modeInit = unsafeBitCast(modeAlloc.method(for: modeSel), to: ModeInit.self)
let mode = modeInit(modeAlloc, modeSel, UInt(PX_W), UInt(PX_H), HZ) as! NSObject

let vsettings = settingsClass.init()
vsettings.setValue(false, forKey: "hiDPI")
vsettings.setValue([mode], forKey: "modes")
let applySel = NSSelectorFromString("applySettings:")
typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
_ = unsafeBitCast(vdisp.method(for: applySel), to: ApplyFn.self)(vdisp, applySel, vsettings)

let vdID = CGDirectDisplayID((vdisp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
print("虚拟屏 displayID = \(vdID)  \(PX_W)x\(PX_H)@\(Int(HZ))")

// MARK: - 2. VideoToolbox 低延迟编码器

final class Encoder {
    private var session: VTCompressionSession?
    private(set) var frames = 0
    private(set) var bytes = 0
    private(set) var encodeMsSum = 0.0
    private(set) var latencySum = 0.0
    private(set) var keyframes = 0
    private let width: Int32
    private let height: Int32
    private let bitrate: Int

    init(width: Int, height: Int, bitrate: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrate
    }

    func start() -> Bool {
        // 关键：EnableLowLatencyRateControl 消除帧重排，一路进一路出
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
        ]
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]

        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sample in
            guard status == noErr, let sample, let refcon else { return }
            let enc = Unmanaged<Encoder>.fromOpaque(refcon).takeUnretainedValue()
            enc.handle(sample)
        }

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard status == noErr, let s = session else {
            print("VTCompressionSessionCreate 失败: \(status)")
            return false
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 300 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        return true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, captureTime: Double) {
        guard let s = session else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(s, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: nil,
                                        sourceFrameRefcon: nil, infoFlagsOut: &flags)
        encodeMsSum += (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    func handle(_ sample: CMSampleBuffer) {
        frames += 1
        bytes += CMSampleBufferGetTotalSampleSize(sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ptsSec = CMTimeGetSeconds(pts)
        // 用输出时刻 - 显示时间戳，近似编码管线延迟
        latencySum += (CFAbsoluteTimeGetCurrent() - ptsSec)
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool, !notSync {
            keyframes += 1
        }
    }

    func stop() {
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }
}

// MARK: - 3. ScreenCaptureKit 抓虚拟屏

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let encoder: Encoder
    var stream: SCStream?
    var count = 0
    var lastReport: CFAbsoluteTime = 0

    init(encoder: Encoder) { self.encoder = encoder }

    func start(display: SCDisplay) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = Int(PX_W)
        cfg.height = Int(PX_H)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(HZ))
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true
        cfg.scalesToFit = false
        cfg.capturesAudio = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete else { return }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        count += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder.encode(pb, pts: pts, captureTime: CFAbsoluteTimeGetCurrent())
    }
}

// MARK: - 主流程

Task {
    let enc = Encoder(width: Int(PX_W), height: Int(PX_H), bitrate: 40_000_000)
    guard enc.start() else { exit(3) }
    print("编码器已就绪（H.264 High，低延迟模式，无 B 帧，目标 40 Mbps）")

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.displays.first(where: { $0.displayID == vdID }) else {
            print("SCShareableContent 里找不到虚拟屏 \(vdID)，可用的有：\(content.displays.map { $0.displayID })")
            exit(4)
        }
        print("找到虚拟屏: \(target.width)x\(target.height)")

        let cap = Capture(encoder: enc)
        try await cap.start(display: target)
        print("采集已启动，运行 \(Int(keepSeconds)) 秒...")

        // 往虚拟屏上画点东西，制造画面变化
        DispatchQueue.global().async {
            var i = 0
            while true {
                i += 1
                usleep(16_666)
                if i > Int(keepSeconds * 60) { break }
            }
        }

        try await Task.sleep(nanoseconds: UInt64(keepSeconds * 1_000_000_000))
        try await cap.stream?.stopCapture()

        let secs = keepSeconds
        let mbps = Double(enc.bytes) * 8 / secs / 1_000_000
        print("\n===== 结果 =====")
        print(String(format: "采集帧数 %d  编码帧数 %d  关键帧 %d", cap.count, enc.frames, enc.keyframes))
        print(String(format: "码率 %.1f Mbps", mbps))
        print(String(format: "每帧编码调用耗时 %.2f ms", enc.encodeMsSum / Double(max(enc.frames, 1))))
        print(String(format: "样本平均延迟 %.2f ms", enc.latencySum / Double(max(enc.frames, 1)) * 1000))
        print(String(format: "实际帧率 %.1f fps", Double(enc.frames) / secs))
        exit(0)
    } catch {
        print("失败: \(error)")
        exit(5)
    }
}

RunLoop.main.run()
