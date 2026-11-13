// ============================================================================
// ScreenSender —— Mac 端主程序
//
// 管线: CGVirtualDisplay 建屏 → ScreenCaptureKit 抓帧 → VideoToolbox 低延迟硬编
//       → TCP_NODELAY 发送 → 接收端控制消息回传
//
// 关键设计（每一项都是为了压延迟，对应开源方案做砸的地方）:
//   1. 虚拟屏像素 = 接收端屏幕物理像素，1:1，不做缩放
//   2. VideoToolbox 开低延迟模式，禁 B 帧，保证一进一出
//   3. TCP_NODELAY，禁止 Nagle 攒包
//   4. 在途帧数上限 2，缓冲满时丢新帧而不是排队（防延迟堆积）
//   5. 每个包头带采集时间戳，接收端可据此丢弃过期帧
//
// 协议（每帧）:
//   [4 字节大端长度][1 字节类型][8 字节采集时间戳 us][载荷]
//   长度字段 = 1 + 8 + 载荷长度，不含长度字段自身
//   类型 0x01 = 视频帧，载荷为 AVCC（[4 字节大端长度][NAL] 重复）
//               关键帧开头由本端拼上 SPS/PPS（VT 输出不含参数集）
//   类型 0x02 = 请求关键帧（接收端 → 本端，1 字节）
// ============================================================================

import Foundation
import CoreGraphics
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import Network
import ObjectiveC.runtime
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 虚拟屏身份
//
// 用一组独占领地的 EDID 身份号来锚定「这块屏是我们建的」。
// CGDisplayVendorNumber/ModelNumber/SerialNumber 能原样读回这三个值（已实测）。
// 避开系统保留号：内建屏 vendor=0x0610(Apple)，Sidecar/AirPlay 是
// vendor=0x6161706c('aapl') / product=0x69506164('iPad')。
// 旧值 0x2B3 来历不明，且与某些虚拟适配器可能重叠，改用自定义号。
// CGVirtualDisplay 与 AirPlay/Sidecar 共用同一套私有 API，displayID 会随
// Sidecar 插拔漂移或复用，只有 EDID 三元组稳定可靠。
let kVDVendorID: UInt32  = 0xEEEE
let kVDProductID: UInt32 = 0x5344   // 'SD'
let kVDSerialNum: UInt32 = 0x0001

// 升级前的旧身份（0x2B3/0x1000/1）。异常退出可能留下这种残留屏，
// 仅用于残留检测与告警，绝不作为采集目标，避免把旧残留当成自己的屏抓进去。
let kOldVDVendorID: UInt32  = 0x02B3
let kOldVDProductID: UInt32 = 0x1000
let kOldVDSerialNum: UInt32 = 0x0001

/// 判断某块显示器是不是 SecDisplay 自己建的虚拟屏（当前身份）。
func isOurVirtualDisplay(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(id) == kVDVendorID &&
    CGDisplayModelNumber(id) == kVDProductID &&
    CGDisplaySerialNumber(id) == kVDSerialNum
}

/// 是否 SecDisplay 建的屏（含升级前旧身份），仅用于残留告警。
func isAnySecDisplay(_ id: CGDirectDisplayID) -> Bool {
    isOurVirtualDisplay(id) ||
    (CGDisplayVendorNumber(id) == kOldVDVendorID &&
     CGDisplayModelNumber(id) == kOldVDProductID &&
     CGDisplaySerialNumber(id) == kOldVDSerialNum)
}

/// 枚举当前所有 SecDisplay 虚拟屏，返回 (displayID, 是否旧身份)。
func listSecDisplays() -> [(id: CGDirectDisplayID, old: Bool)] {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.prefix(Int(n)).compactMap { id -> (id: CGDirectDisplayID, old: Bool)? in
        guard isAnySecDisplay(id) else { return nil }
        return (id, !isOurVirtualDisplay(id))
    }
}

// MARK: - 配置

struct Config {
    // 对应 Lenovo Yoga Slim 7 Pro 14IHU5（82NC）2880x1800 高刷版，
    // 系统 200% 缩放：物理 2880x1800，逻辑 1440x900。
    // 背板 = 物理像素，逻辑 = 一半，这样是 2x Retina，文字最锐利。
    var width = 2880
    var height = 1800
    var logicalWidth = 1440
    var logicalHeight = 900
    var refreshRate = 90.0     // 虚拟屏刷新率

    /// 采集帧率上限。
    ///
    /// 关键参数：VideoToolbox 的 H.264 硬编在 2880x1800 上大约只能稳定 46fps。
    /// 采集喂得更快，帧就堆在编码器内部，延迟从 25ms 一路涨到 90ms，
    /// 表现为「越用越卡」。压到 45fps 以下后延迟稳定在 25ms 左右。
    ///
    /// 实测（2880x1800，M1 Pro）：
    ///   采集 60Hz → 55fps, 中位 67ms
    ///   采集 50Hz → 46fps, 中位 28ms
    ///   采集 45Hz → 43fps, 中位 26ms   ← 默认
    ///   采集 40Hz → 39fps, 中位 27ms
    ///   采集 30Hz → 29fps, 中位 24ms
    var captureHz = 45.0
    // 2.2K 桌面文字需要足够码率才清晰。千兆网给到 120 仍有余量。
    var bitrateMbps = 180      // 2880x1800 码率要比 2.2K 更高
    var port: UInt16 = 9922
    // 静止画面保活间隔（秒）。ScreenCaptureKit 画面不动就不出帧，
    // 超过这个间隔没有新帧就重发最后一帧；设 0 关闭。
    var keepAliveGap = 0.5
}

// MARK: - 虚拟屏

final class VirtualDisplayManager {
    private(set) var object: NSObject?
    private(set) var displayID: CGDirectDisplayID = 0

    func create(_ cfg: Config) throws {
        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let dispCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let setCls  = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else { throw Err.classesMissing }

        let queue = DispatchQueue(label: "SecDisplay.vd")
        let d = descCls.init()
        d.setValue(NSNumber(value: kVDVendorID), forKey: "vendorID")
        d.setValue(NSNumber(value: kVDProductID), forKey: "productID")
        d.setValue(NSNumber(value: kVDSerialNum), forKey: "serialNum")
        d.setValue("SecDisplay", forKey: "name")
        d.setValue(NSNumber(value: cfg.width), forKey: "maxPixelsWide")
        d.setValue(NSNumber(value: cfg.height), forKey: "maxPixelsHigh")
        d.setValue(NSValue(size: NSSize(width: 25.4 * Double(cfg.width) / 110.0,
                                        height: 25.4 * Double(cfg.height) / 110.0)),
                   forKey: "sizeInMillimeters")
        d.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        d.setValue(queue, forKey: "queue")

        let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        guard let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?
                .takeUnretainedValue() as? NSObject else { throw Err.initFailed }

        let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeInit = unsafeBitCast(modeAlloc.method(for: modeSel), to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeSel,
                                  UInt(cfg.logicalWidth), UInt(cfg.logicalHeight),
                                  cfg.refreshRate) as? NSObject else { throw Err.modeFailed }

        let settings = setCls.init()
        settings.setValue(cfg.logicalWidth * 2 <= cfg.width, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        // BOOL 返回值必须直接调用
        let applySel = NSSelectorFromString("applySettings:")
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)(disp, applySel, settings) else {
            throw Err.applyFailed
        }

        object = disp
        displayID = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)

        var waited = 0.0
        while waited < 2.0 {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(32, nil, &n)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &ids, &n)
            if ids.contains(displayID) { break }
            usleep(20_000); waited += 0.02
        }
        Log.info("虚拟屏就绪 id=\(displayID) \(cfg.width)x\(cfg.height)")
    }

    /// 正确销毁：取出 CGVirtualDisplay 内部的 _client 指针，交给 CDVirtualDisplayDestroy。
    ///
    /// 实测（2026-11-11）：曾尝试「复用残留屏」方案——同身份残留屏能被 CG 枚举到、
    /// SCK 也报「抓屏已启动」，但采集 0 帧、空闲 0。孤儿屏的 owner 进程已死，
    /// WindowServer 不再向它合成新内容，SCK 拿不到帧。故 adopt 方案不可行，已放弃。
    /// 传对象本身会触发 CoreDisplay 内部断言；只释放引用屏不会消失。
    func destroy() {
        guard let obj = object else { return }
        if let cls = NSClassFromString("CGVirtualDisplay"),
           let ivar = class_getInstanceVariable(cls, "_client") {
            let raw = UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
                .advanced(by: ivar_getOffset(ivar))
            if let clientPtr = raw.load(as: UnsafeMutableRawPointer?.self),
               let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
               let sym = dlsym(h, "CDVirtualDisplayDestroy") {
                typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer) -> Void
                unsafeBitCast(sym, to: DestroyFn.self)(clientPtr)
                Log.info("虚拟屏已销毁")
            }
        }
        object = nil
    }

    enum Err: Error { case classesMissing, initFailed, modeFailed, applyFailed }
}

// MARK: - 退出清理

/// 信号处理器里只置标志位。真正的清理在主循环里做，
/// 因为 signal handler 中调用 ObjC runtime / dlopen 属于 async-signal-unsafe。
enum VirtualDisplayGuard {
    nonisolated(unsafe) static var pendingSignal: Int32 = 0

    static func install() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { s in VirtualDisplayGuard.pendingSignal = s }
        }
    }
}

// MARK: - 日志

enum Log {
    static let fmt = DateFormatter()
    private static let lock = NSLock()

    /// 可选日志文件。
    /// 命令行运行由 run.sh 重定向 stderr，不需要这里写文件；
    /// 打成 .app 后由 LaunchServices 启动，stderr 看不到，默认写到
    /// ~/Library/Logs/SecDisplay/sender.log，也允许用 SECDISPLAY_LOG 覆盖。
    private static let fileHandle: FileHandle? = {
        var path = ProcessInfo.processInfo.environment["SECDISPLAY_LOG"]
        if path == nil, Bundle.main.bundleIdentifier != nil {
            let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/SecDisplay")
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            path = (dir as NSString).appendingPathComponent("sender.log")
        }
        guard let p = path, !p.isEmpty else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: p) { fm.createFile(atPath: p, contents: nil) }
        return FileHandle(forWritingAtPath: p)
    }()

    static func info(_ s: String) {
        let t = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 100000))
        let line = "[\(t)] \(s)\n"
        let data = line.data(using: .utf8)!
        FileHandle.standardError.write(data)
        lock.lock()
        fileHandle?.seekToEndOfFile()
        fileHandle?.write(data)
        lock.unlock()
    }

    /// 当前日志文件路径，面板「打开日志」用
    static var currentPath: String {
        if let p = ProcessInfo.processInfo.environment["SECDISPLAY_LOG"], !p.isEmpty { return p }
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/SecDisplay/sender.log")
    }
}

// MARK: - 编码器

final class Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let bitrate: Int
    private let captureHz: Double
    var onFrame: ((Data, Bool, UInt64) -> Void)?

    private(set) var encoded = 0
    private(set) var keyframeCount = 0
    private(set) var bytes = 0
    private(set) var lastKeyframeCheck = 0

    init(width: Int, height: Int, bitrateMbps: Int, captureHz: Double = 60) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.bitrate = bitrateMbps * 1_000_000
        self.captureHz = max(1, captureHz)
        self.currentMbps = bitrateMbps
    }

    func start() -> Bool {
        // EnableLowLatencyRateControl 并非恒优。实测（tools/EncLatency.swift，M1 Pro）：
        //   2240x1400@60  开=34~37ms 关=21~23ms（关更好）
        //   2880x1800@45  开=44~50ms 关=35~36ms（关更好）
        //   1920x1200@60  开=9ms     关=14ms   （开更好）
        // 规律：分辨率接近编码器吞吐上限时该开关反而拖慢（同 Sunshine #5814）。
        // 默认保持开启（低分辨率/未知场景收益确定）；高分辨率档可用
        // SECDISPLAY_NOLOWLAT=1 关闭，供真机 A/B。
        var spec: [String: Any] = [:]
        let noLowLat = ProcessInfo.processInfo.environment["SECDISPLAY_NOLOWLAT"] == "1"
        if !noLowLat {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
        }
        let attrs: [String: Any] = [
            // 用原生 YUV 而不是 BGRA：SCK 直接给 YUV，编码器也直接吃 YUV，
            // 省掉两次全画面色彩转换。2880x1800 下 BGRA 每帧 20MB，
            // YUV420 只有 7.8MB，内存带宽少 60%。
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let cb: VTCompressionOutputCallback = { ref, sourceFrameRefcon, status, _, sample in
            guard let ref else {
                // 回调仍会到来，必须释放 box 防止泄漏
                if let sourceFrameRefcon { UnsafeMutablePointer<UInt64>(OpaquePointer(sourceFrameRefcon)).deallocate() }
                return
            }
            let enc = Unmanaged<Encoder>.fromOpaque(ref).takeUnretainedValue()
            guard status == noErr, let sample else {
                if let sourceFrameRefcon { UnsafeMutablePointer<UInt64>(OpaquePointer(sourceFrameRefcon)).deallocate() }
                return
            }
            enc.emit(sample, refcon: sourceFrameRefcon)
        }
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: width, height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: cb,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session)
        guard st == noErr, let s = session else {
            Log.info("编码器创建失败 \(st)"); return false
        }
        let env = ProcessInfo.processInfo.environment
        let variant = env["SECDISPLAY_ENC"] ?? "A"

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: captureHz))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)

        switch variant {
        case "B":
            // 不设码率与帧延迟，交给低延迟 rate control
            break
        case "C":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        case "D":
            // 用 DataRateLimits 代替 AverageBitRate
            let limits: [NSNumber] = [NSNumber(value: bitrate / 8), NSNumber(value: 1.0)]
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        case "E":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        default:  // A：原样
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        }

        VTCompressionSessionPrepareToEncodeFrames(s)
        Log.info("编码参数方案 \(variant)")
        return true
    }

    /// 自增帧序号，用作编码 PTS。
    /// 采集帧和保活帧的时间基准不同，混用会让 PTS 非单调，编码器可能报错。
    /// 真正的端到端时间戳走 captureTimeMicros，与 PTS 无关。
    private var frameSeq: Int64 = 0

    /// 最近一帧的输入画面。屏幕完全静止时没有新帧可编，
    /// 收到关键帧请求需要用它临时补一个 IDR，否则接收端一直黑屏。
    private var lastPixelBuffer: CVPixelBuffer?
    private let lastBufferLock = NSLock()

    func encode(_ pb: CVPixelBuffer, pts: CMTime, captureTimeMicros: UInt64) {
        lastBufferLock.lock()
        lastPixelBuffer = pb
        lastBufferLock.unlock()
        encodeInternal(pb, captureTimeMicros: captureTimeMicros)
    }

    /// 用最后一帧强制补一个 IDR。
    ///
    /// 屏幕静止时 ScreenCaptureKit 不出帧，接收端新连上会拿不到任何首帧
    ///（旧实现只置 wantKeyframe 标志，但要等下一帧采集才生效，静止时永远等不到），
    /// 表现为接收端黑屏 / 报解码失败。这里直接用 lastPixelBuffer 编一帧发出去。
    /// 若连最后一帧都还没有（刚启动、尚未采集到），就只置标志，等首帧到来再补。
    func forceEncodeLastFrame() {
        lastBufferLock.lock()
        let pb = lastPixelBuffer
        lastBufferLock.unlock()
        guard let pb else {
            requestKeyframe()
            return
        }
        requestKeyframe()   // 让 encodeInternal 把这一帧编成 IDR
        encodeInternal(pb, captureTimeMicros: UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000))
    }

    /// 串行化编码调用。采集线程和关键帧补发可能并发进来，
    /// frameSeq 自增不是原子的，并发会产出重复 PTS。
    private let encodeLock = NSLock()

    private func encodeInternal(_ pb: CVPixelBuffer, captureTimeMicros: UInt64) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let s = session else { return }
        // 时间戳随帧走：经 sourceFrameRefcon 传给输出回调，避免跨线程共享变量。
        // 堆上分配一个 box，由 emit 负责释放；即使帧被编码器丢弃也不会泄漏
        //（VT 保证每个 refcon 都会在输出或丢弃时被回调一次）。
        let box = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        box.pointee = captureTimeMicros

        // 接收端请求关键帧时，这一帧强制 IDR
        wantKeyframeLock.lock()
        let forceKey = wantKeyframe
        wantKeyframe = false
        wantKeyframeLock.unlock()
        let props: CFDictionary? = forceKey
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary)
            : nil

        frameSeq += 1
        let monotonicPTS = CMTime(value: frameSeq, timescale: CMTimeScale(max(1, Int(60))))

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            s, imageBuffer: pb, presentationTimeStamp: monotonicPTS,
            duration: CMTime(value: 1, timescale: 60), frameProperties: props,
            sourceFrameRefcon: UnsafeMutableRawPointer(box), infoFlagsOut: &flags)
        if status != noErr { box.deallocate() }
    }

    /// 动态调整码率。按接收端反馈或本地丢帧情况调用。
    /// - Parameter mbps: 目标码率（Mbps）
    func setBitrate(_ mbps: Int) {
        guard let s = session, mbps > 0 else { return }
        let clamped = max(8, min(mbps, 300))
        let stAvg = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                                         value: (clamped * 1_000_000) as CFNumber)
        if stAvg != noErr {
            Log.info("AverageBitRate 设置失败: \(stAvg)")
        }
        // 同步硬上限：只改 AverageBitRate 时，DataRateLimits 可能仍停在初始化值，
        // 导致「码率降了但编码延迟没降」。方案 B 若不接受这两个属性，失败只记日志。
        let limits: [NSNumber] = [NSNumber(value: clamped * 1_000_000 / 8), NSNumber(value: 1.0)]
        let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                                      value: limits as CFArray)
        if st != noErr {
            Log.info("DataRateLimits 设置失败: \(st)")
        }
        currentMbps = clamped
    }

    private(set) var currentMbps = 0

    /// 请求下一帧编码为 IDR。由接收端 0x02 控制消息触发。
    private let wantKeyframeLock = NSLock()
    private var wantKeyframe = false

    func requestKeyframe() {
        wantKeyframeLock.lock()
        wantKeyframe = true
        wantKeyframeLock.unlock()
    }

    func stop() {
        if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }

    /// 编码管线延迟统计：从采集时间戳到编码输出回调
    var encLatSum: Double = 0
    var encLatMax: Double = 0
    var encLatCount = 0

    private func emit(_ sample: CMSampleBuffer, refcon: UnsafeMutableRawPointer?) {
        // 取出并释放时间戳 box
        var captureTime: UInt64 = 0
        if let refcon {
            let box = refcon.assumingMemoryBound(to: UInt64.self)
            captureTime = box.pointee
            box.deallocate()
        }
        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr, length > 0 else { return }

        var isKey = false
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first {
            isKey = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        // 实测结论（见 research/BENCH-03-latency.md 坑 1、坑 2）：
        //   1. VT 输出的 AVCC 里不含 SPS/PPS，参数集只在 formatDescription 中，
        //      关键帧必须自己按 AVCC 长度前缀补上，不能用 Annex-B 起始码。
        //   2. 全程保持 AVCC，绝不转 Annex-B：H.264 码流内部天然会出现 00 00 00 01，
        //      用起始码扫描切分会切错位置。
        var out = Data()
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0,
                                                              parameterSetPointerOut: nil,
                                                              parameterSetSizeOut: nil,
                                                              parameterSetCountOut: &count,
                                                              nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                                                                  parameterSetPointerOut: &p,
                                                                  parameterSetSizeOut: &sz,
                                                                  parameterSetCountOut: nil,
                                                                  nalUnitHeaderLengthOut: nil)
                if let p, sz > 0 {
                    var l = UInt32(sz).bigEndian
                    withUnsafeBytes(of: &l) { out.append(contentsOf: $0) }
                    out.append(p, count: sz)
                }
            }
        }
        // 编码器输出的视频数据本身就是 AVCC，原样追加
        out.append(Data(bytes: ptr, count: length))

        if captureTime > 0 {
            let latMs = (CFAbsoluteTimeGetCurrent() - Double(captureTime) / 1_000_000) * 1000
            if latMs >= 0 && latMs < 5000 {
                encLatSum += latMs
                encLatCount += 1
                if latMs > encLatMax { encLatMax = latMs }
            }
        }

        if isKey { keyframeCount += 1 }
        encoded += 1
        bytes += out.count
        onFrame?(out, isKey, captureTime)
    }

}

// MARK: - 抓屏

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    let encoder: Encoder
    private let cfg: Config
    /// 虚拟屏 id 可能变化（重建虚拟屏后），每次重建流都重新问一次
    private let displayIDProvider: () -> CGDirectDisplayID

    var stream: SCStream?
    var captured = 0
    /// 采集段延迟：系统合成完成 → 我们拿到帧
    var capLatSum: Double = 0
    var capLatCount = 0
    var capLatMax: Double = 0
    var lastFrameTime: CFAbsoluteTime = 0
    var idleFrames = 0

    // --- 自愈 ---
    private let ctl = DispatchQueue(label: "SecDisplay.capture.ctl")
    private var watchdog: DispatchSourceTimer?
    private var lastSeenCount = 0
    /// 任何类型的回调都计数，用来区分「流死了」和「画面静止」
    private var progressCount = 0
    private(set) var idleFrameCount = 0
    // --- 静止帧去重 ---
    // 虚拟屏不会报 idle：静止桌面也按满帧率送 complete（实测 1 秒内只有
    // 0.004% 像素变化，采集却跑 58fps）。编码器因此全速空转，白烧 CPU 和
    // 带宽，视频帧还会把光标小包堵在 socket 后面。这里用步进采样对比上一帧，
    // 差异极小时跳过编码。最长 0.5s 必编码一次，慢变化不会被永久压住。
    private var prevSamples: [UInt8] = []
    private var prevSampleKey = 0
    private var lastEncodeAt: CFAbsoluteTime = 0
    private(set) var staticSkipCount = 0
    private var lastProgressAt = CFAbsoluteTimeGetCurrent()
    private var needsRestart = false
    private var restarting = false
    private var restartCount = 0
    // 说明：不再用「无帧超时」判断流故障，理由见 tick()。

    init(encoder: Encoder, cfg: Config, displayID: @escaping () -> CGDirectDisplayID) {
        self.encoder = encoder
        self.cfg = cfg
        self.displayIDProvider = displayID
        super.init()
    }

    /// 首次启动：失败会抛出，由调用方提示权限问题
    func start() async throws {
        try await buildStream()
        startWatchdog()
    }

    private func buildStream() async throws {
        let wantID = displayIDProvider()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // 选屏只认 EDID 三元组身份，不信易变的 displayID。
        // Sidecar 接入/断开会让系统重新分配 CGDirectDisplayID，旧 id 可能失效
        // 或被 AirPlay 屏复用；单靠 id 或「非主屏 + 宽度相等」会抓到 iPad / 别的虚拟屏。
        // isOurVirtualDisplay 用 vendor/product/serial 精确锚定我们自己建的屏，
        // 内建(0x610)、Sidecar(aapl/iPad)、GameViewer、Duet 都不会误命中。
        var target = content.displays.first(where: { isOurVirtualDisplay($0.displayID) })
        // 兜底：极少数情况下三元组尚未就绪，再按创建时记下的 id 找一次。
        if target == nil {
            target = content.displays.first(where: { $0.displayID == wantID })
        }
        guard let display = target else {
            let avail = content.displays.map { d -> String in
                String(format: "id=%u vendor=0x%x model=0x%x",
                       d.displayID,
                       CGDisplayVendorNumber(d.displayID),
                       CGDisplayModelNumber(d.displayID))
            }
            throw NSError(domain: "Capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到 SecDisplay 虚拟屏（期望身份 vendor=0x\(String(kVDVendorID, radix:16))，" +
                    "创建时 id=\(wantID)，当前可用: \(avail.joined(separator: ", "))）"
            ])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.width = cfg.width
        c.height = cfg.height
        // 采集帧率。编码器在 2880x1800 上大约只能稳定 45fps，
        // 采集喂得更快只会在 VideoToolbox 内部堆积，延迟从 40ms 涨到 90ms。
        // 用 SECDISPLAY_HZ 可以试不同档位。
        let capHz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] ?? "") ?? cfg.captureHz
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(capHz))
        // 队列深度直接决定 SCK 内部的缓冲帧数，也就直接决定延迟。
        // 3 帧在 60fps 下约 50ms；越深越不容易丢帧，但延迟越高。
        c.queueDepth = Int(ProcessInfo.processInfo.environment["SECDISPLAY_QD"] ?? "") ?? 3
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // 光标不画进视频：视频帧率只有 45fps，指针会把延迟放大成拖影。
        // 指针位置改由独立的轻量消息高频发送，客户端本地绘制。
        c.showsCursor = false
        c.scalesToFit = false
        c.capturesAudio = false
        c.preservesAspectRatio = true

        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "SecDisplay.capture"))
        try await s.startCapture()

        stream = s
        lastProgressAt = CFAbsoluteTimeGetCurrent()
        lastSeenCount = progressCount
        Log.info("抓屏已启动 displayID=\(display.displayID) \(cfg.width)x\(cfg.height)，采集上限 \(Int(capHz))fps")
    }

    // MARK: 看门狗

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: ctl)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        watchdog = t
    }

    private func tick() {
        if restarting { return }
        let now = CFAbsoluteTimeGetCurrent()
        if progressCount != lastSeenCount {
            lastSeenCount = progressCount
            lastProgressAt = now
        }
        // 只在 ScreenCaptureKit 明确报告停止时重建。
        // 虚拟屏空桌面时 SCK 可能完全不发回调（连 idle 帧都没有），
        // 用「无帧超时」判断会把静止画面误杀；重建过程会让 WindowServer
        // 重配置显示，反而把虚拟屏踢掉，实测 17 秒内必现。
        guard needsRestart else { return }
        Log.info("抓屏流已停止，准备重建")
        needsRestart = false
        restartStream()
    }

    /// 重建采集流。停旧的、重新取显示器、重新建流。
    func restartStream() {
        ctl.async { [weak self] in
            guard let self, !self.restarting else { return }
            self.restarting = true
            self.restartCount += 1
            let n = self.restartCount

            let old = self.stream
            self.stream = nil
            Task {
                if let old { try? await old.stopCapture() }
                // 给系统一点时间释放对旧流的引用
                try? await Task.sleep(nanoseconds: 300_000_000)
                do {
                    try await self.buildStream()
                    Log.info("抓屏流重建成功（第 \(n) 次）")
                } catch {
                    Log.info("抓屏流重建失败（第 \(n) 次）: \(error)")
                    // 下次 tick 会再试
                    self.lastProgressAt = CFAbsoluteTimeGetCurrent()
                    self.needsRestart = true
                }
                self.restarting = false
            }
        }
    }

    /// 与上一帧做步进采样对比，返回 true 表示这一帧可以跳过编码。
    private func shouldSkipStatic(_ pb: CVPixelBuffer) -> Bool {
        // 兜底：最长 0.5s 一定编码一次，避免慢变化（光标闪烁、进度条）被压死。
        if CFAbsoluteTimeGetCurrent() - lastEncodeAt >= 0.5 { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let stepX = max(1, w / 96)
        let stepY = max(1, h / 60)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var cur = [UInt8]()
        cur.reserveCapacity(96 * 60 * 3)
        var y = 0
        while y < h {
            let row = p + y * bpr
            var x = 0
            while x < w {
                let o = x * 4
                cur.append(row[o]); cur.append(row[o + 1]); cur.append(row[o + 2])
                x += stepX
            }
            y += stepY
        }
        let key = w * 10_000 + h
        let prev = prevSamples
        let sameSize = prevSampleKey == key && prev.count == cur.count
        prevSamples = cur
        prevSampleKey = key
        guard sameSize else { return false }
        var changed = 0
        var i = 0
        while i < cur.count {
            let d = abs(Int(cur[i]) - Int(prev[i]))
                + abs(Int(cur[i + 1]) - Int(prev[i + 1]))
                + abs(Int(cur[i + 2]) - Int(prev[i + 2]))
            if d > 9 { changed += 1 }
            i += 3
        }
        let total = cur.count / 3
        return changed <= max(3, total / 500)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        // 任何回调都说明流还活着，包括画面没变化时的 idle 帧。
        // 只把 complete 帧送去编码，避免重复编码同一画面。
        progressCount += 1

        if status == .stopped {
            Log.info("SCK 报告流已停止，触发重建")
            needsRestart = true
            return
        }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else {
            idleFrameCount += 1
            return
        }

        captured += 1
        lastFrameTime = CFAbsoluteTimeGetCurrent()

        // 采集段延迟：样本 PTS 与主机时钟的差值。
        // SCK 的 PTS 走主机时钟（mach 时基），不能直接和 CFAbsoluteTime 相减。
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let deltaSec = CMTimeGetSeconds(CMTimeSubtract(hostNow, pts))
        if deltaSec.isFinite && deltaSec >= 0 && deltaSec < 2 {
            let delayMs = deltaSec * 1000
            capLatSum += delayMs
            capLatCount += 1
            if delayMs > capLatMax { capLatMax = delayMs }
        }
        let nowMicros = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000)
        if shouldSkipStatic(pb) {
            staticSkipCount += 1
            return
        }
        lastEncodeAt = CFAbsoluteTimeGetCurrent()
        encoder.encode(pb, pts: pts, captureTimeMicros: nowMicros)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("抓屏停止: \(error)")
        // ScreenCaptureKit 不会自己恢复，交给看门狗重建
        ctl.async { [weak self] in self?.needsRestart = true }
    }
}

// MARK: - 网络发送

final class Sender {
    private(set) var conn: NWConnection?
    /// 连接代数，用于识别陈旧回调
    private var connEpoch: Int = 0
    /// 只读暴露给 CursorImageTracker，用于连接重建时强制重发光标图像
    var currentEpoch: Int { queue.sync { connEpoch } }
    private let queue = DispatchQueue(label: "SecDisplay.net")
    /// 监听器必须由 Sender 强引用持有。之前是 listen(port:) 里的局部变量，
    /// 启动后可能被运行时释放，端口随之消失，但进程、采集、编码都还活着，
    /// Windows 侧看到的就是「主机能 ping 通、9922 却 WSAECONNREFUSED」。
    private var listener: NWListener?
    private var listenPort: UInt16 = 0
    private var listenerWatchdog: DispatchSourceTimer?
    private var listenerRestartScheduled = false
    private(set) var inFlight = 0
    private let maxInFlight = 2
    var dropped = 0
    var sent = 0
    var sentBytes = 0
    var connected = false

    /// 会话头里通告的虚拟屏参数，由 main 在启动时写入。
    /// 接收端据此自动调整窗口尺寸与坐标基准，两端不再手工对齐分辨率。
    var sessionWidth = 0
    var sessionHeight = 0
    var sessionFps = 0
    private var lastSessionSent: CFAbsoluteTime = 0

    // 0x07 反馈快照。drainControl 在 net queue 写，Timer 在 main queue 读。
    private let feedbackLock = NSLock()
    private var feedback = FeedbackSignals()

    func latestFeedback() -> FeedbackSignals {
        feedbackLock.lock()
        defer { feedbackLock.unlock() }
        return feedback
    }

    func listen(port: UInt16) {
        listenPort = port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 关闭 Nagle
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 3
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            Log.info("端口 \(port) 监听失败（可能被占用）: \(error)")
            // 自愈路径里不要直接退出进程：端口还被上一次监听占着是暂时的，
            // 交给看门狗重试。只有首次启动失败才退出。
            if listenerRestartScheduled || self.listener != nil {
                scheduleListenerRestart("创建监听器失败")
                return
            }
            exit(6)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            Log.info("接收端已连接: \(String(describing: c.endpoint))")

            // 连接代数：只有"当前"连接的回调才能改动共享状态。
            // 否则旧连接被 cancel 后异步回调 .cancelled，会把刚建立的新连接
            // 误标成断开，表现为连上后一帧都发不出去。
            self.connEpoch &+= 1
            let epoch = self.connEpoch

            let old = self.conn
            self.conn = c
            self.connected = true
            self.resetInFlight()          // 上一轮可能残留未完成的发送，必须清零
            // 旧连接可能留下半个控制包，新连接数据接在残包后会把 0x07 误解析成 0x04。
            self.ctrlBuf.removeAll()
            // 丢掉上个连接的残留帧：那可能是依赖旧参考帧的 P 帧，
            // 新接收端没有参考帧，解出来是花的。等新的 IDR。
            self.counterLock.lock()
            self.lastPayload = nil
            self.lastSendAt = CFAbsoluteTimeGetCurrent()
            self.counterLock.unlock()
            old?.cancel()

            c.stateUpdateHandler = { [weak self] st in
                guard let self, self.connEpoch == epoch else { return }   // 陈旧连接，忽略
                switch st {
                case .failed(let e):
                    Log.info("连接失败: \(e)")
                    self.connected = false
                case .cancelled:
                    Log.info("连接已取消（cancelled）")
                    self.connected = false
                case .ready:
                    Log.info("连接就绪")
                default:
                    break
                }
            }
            c.start(queue: self.queue)
            // 连接必须先 start 才能发；会话头紧跟在 start 之后，早于视频帧
            self.sendSessionInfo()
            // 新连接一上来就准备关键帧，不依赖对端是否及时发 0x02。
            self.onKeyframeRequest?()
            self.receiveLoop(epoch: epoch)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] st in
            // 旧 listener 的回调可能晚到，只认当前持有的那个
            guard let self, let l = listener, self.listener === l else { return }
            switch st {
            case .ready:
                Log.info("监听端口 \(port)，等待接收端连接")
                self.listenerRestartScheduled = false
            case .failed(let e):
                Log.info("监听失败: \(e)")
                self.scheduleListenerRestart("failed")
            case .cancelled:
                Log.info("监听已取消")
                self.scheduleListenerRestart("cancelled")
            default:
                break
            }
        }
        listener.start(queue: queue)
        startKeepAlive()
        startListenerWatchdog()
    }

    /// 监听器重建：先 cancel 旧实例，1 秒后重新 listen。
    /// 不动 connEpoch、编码器和现有连接，避免重建监听把正在传输的链路打断。
    private func scheduleListenerRestart(_ reason: String) {
        guard !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        Log.info("监听自愈：\(reason)，1 秒后重建端口 \(listenPort)")
        listener?.cancel()
        listener = nil
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            self.listen(port: self.listenPort)
        }
    }

    /// 看门狗：stateUpdateHandler 在对象被释放等场景下可能漏报，
    /// 每 5 秒自己查一次状态，不在 ready 就重建。
    private func startListenerWatchdog() {
        guard listenerWatchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.listener?.state != .ready {
                self.scheduleListenerRestart("看门狗检测到监听不在 ready")
            }
        }
        timer.resume()
        listenerWatchdog = timer
    }

    /// 控制通道缓冲。0x02 是 1 字节，0x04 输入事件是固定 12 字节，
    /// 必须按帧解析，不能逐字节扫描——否则二进制里的 0x02 会被误判。
    private var ctrlBuf = Data()

    private func receiveLoop(epoch: Int) {
        guard connEpoch == epoch, let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, err in
            guard let self, self.connEpoch == epoch else { return }
            if let data, !data.isEmpty {
                self.ctrlBuf.append(data)
                self.drainControl()
            }
            if done || err != nil {
                // 注意：这里不能把 connected 置 false。
                // 接收侧 EOF/出错只代表「对端不再发数据」（可能是半关闭），
                // 发送方向仍可能可用。之前一置 false 就彻底停止发视频，
                // 表现为「画面冻结、发送 0、直到对端重连」。
                // 真正的断开交给发送完成回调（transmit 里 err）来判定。
                Log.info("接收循环结束: done=\(done) err=\(String(describing: err))；继续尝试发送")
                return
            }
            self.receiveLoop(epoch: epoch)
        }
    }

    private func drainControl() {
        while !ctrlBuf.isEmpty {
            let t = ctrlBuf[ctrlBuf.startIndex]
            if t == 0x02 {
                Log.info("收到关键帧请求，下一帧强制 IDR")
                onKeyframeRequest?()
                ctrlBuf.removeFirst(1)
            } else if t == 0x04 {
                // [0x04][float32 x][float32 y][uint8 buttons][int16 wheel] = 12 字节
                guard ctrlBuf.count >= 12 else { return }
                let b = ctrlBuf
                let o = b.startIndex
                func rdF(_ off: Int) -> Float {
                    var u: UInt32 = 0
                    for i in 0..<4 { u = (u << 8) | UInt32(b[o + off + i]) }
                    return Float(bitPattern: u)
                }
                let x = rdF(1)
                let y = rdF(5)
                let buttons = b[o + 9]
                let wheel = Int16(bitPattern: (UInt16(b[o + 10]) << 8) | UInt16(b[o + 11]))
                onInput?(x, y, buttons, wheel)
                ctrlBuf.removeFirst(12)
            } else if t == 0x07 {
                // [0x07][presentP95 u16][sourceP95 u16][decodeFps*10 u16]
                // [presentDrop u16][pacedDrop u16][reserved u16] = 13 字节，全大端
                guard ctrlBuf.count >= 13 else { return }
                let b = ctrlBuf
                let o = b.startIndex
                func rd16(_ off: Int) -> UInt16 {
                    (UInt16(b[o + off]) << 8) | UInt16(b[o + off + 1])
                }
                let fb = FeedbackSignals(
                    presentP95: Double(rd16(1)),
                    sourceP95: Double(rd16(3)),
                    decodeFps: Double(rd16(5)) / 10.0,
                    presentDrop: Int(rd16(7)),
                    pacedDrop: Int(rd16(9))
                )
                feedbackLock.lock()
                feedback = fb
                feedbackLock.unlock()
                // 每 2 秒至多一条（Windows 发送节奏），用于确认反馈链路活着与字段值
                Log.info(String(format: "0x07 反馈: presentP95 %.0fms  sourceP95 %.0fms  decodeFps %.1f  presentDrop %d  pacedDrop %d",
                                fb.presentP95, fb.sourceP95, fb.decodeFps, fb.presentDrop, fb.pacedDrop))
                ctrlBuf.removeFirst(13)
            } else {
                // 未知字节，丢掉，避免卡死
                ctrlBuf.removeFirst(1)
            }
            if ctrlBuf.count > 65536 { ctrlBuf.removeAll() }
        }
    }

    /// 收到对端 0x02 时回调，由外部接到编码器
    var onKeyframeRequest: (() -> Void)?
    /// 收到对端 0x04 输入事件：(x, y, buttons, wheel)
    var onInput: ((Float, Float, UInt8, Int16) -> Void)?

    private let counterLock = NSLock()

    /// 新连接建立时清零在途计数。
    /// 旧连接被重置时，未完成的 send 完成回调可能不再触发，
    /// inFlight 会永久停在 2，导致之后所有帧都被判为"拥塞"而丢弃。
    func resetInFlight() {
        counterLock.lock()
        inFlight = 0
        counterLock.unlock()
    }

    // --- 静止画面保活 ---
    // ScreenCaptureKit 是变化驱动的：画面不动就完全不出帧，接收端会长时间没有数据，
    // 表现为「连上了但不动」或统计里 Mbps 掉到 0。
    // 这里记住最后一帧的编码数据，空闲超时后重发它（重打时间戳，避免延迟统计虚高）。
    // 同一个 access unit 重复解码是安全的，解出来还是同一张图。
    private var lastPayload: Data?
    private var lastSendAt: CFAbsoluteTime = 0
    private var keepAliveTimer: DispatchSourceTimer?
    /// 超过这么久没有新帧就补一帧；设为 0 可关闭保活
    var keepAliveGap: CFAbsoluteTime = 0.08

    /// 光标位置。不走视频帧，独立小包，不占用在途帧配额。
    /// 坐标是相对虚拟屏左上角的逻辑点值（与 CGDisplayBounds / CGEvent.location 同基准）。
    func sendCursor(x: Float, y: Float, visible: Bool) {
        guard connected, let c = conn else { return }
        var packet = Data(capacity: 19)
        // 长度 = 1 类型 + 8 时间戳 + 9 载荷 = 18
        var len = UInt32(18).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x03)                  // 光标类型
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        var fx = x.bitPattern.bigEndian
        withUnsafeBytes(of: &fx) { packet.append(contentsOf: $0) }
        var fy = y.bitPattern.bigEndian
        withUnsafeBytes(of: &fy) { packet.append(contentsOf: $0) }
        packet.append(visible ? 1 : 0)
        c.send(content: packet, completion: .contentProcessed { _ in })
    }

    /// 发送真实系统光标图像。独立类型 0x05，不动 0x03 位置链路，
    /// 这样两端版本错配时最多是没有自定义光标，位置转发仍正常。
    /// 载荷(全大端): [u16 w][u16 h][u16 hotX][u16 hotY][u32 nBytes][BGRA 像素...]
    /// BGRA 是 Windows DIB(32bpp BI_RGB) 直接可用的排布。
    func sendCursorImage(width: Int, height: Int,
                         hotX: Int, hotY: Int, bgra: Data) {
        guard connected, let c = conn else { return }
        let headerBytes = 12
        let payloadLen = headerBytes + bgra.count
        let total = 1 + 8 + payloadLen          // type + ts + payload
        var packet = Data(capacity: 4 + total)
        var len = UInt32(total).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x05)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        func put16(_ v: UInt16) { var x = v.bigEndian; withUnsafeBytes(of: &x) { packet.append(contentsOf: $0) } }
        func put32(_ v: UInt32) { var x = v.bigEndian; withUnsafeBytes(of: &x) { packet.append(contentsOf: $0) } }
        put16(UInt16(width)); put16(UInt16(height))
        put16(UInt16(hotX));  put16(UInt16(hotY))
        put32(UInt32(bgra.count))
        packet.append(bgra)
        c.send(content: packet, completion: .contentProcessed { _ in })
    }

    /// 链路心跳。静止桌面下 SCK 不出帧，lastPayload 可能为 nil，
    /// 旧保活逻辑会因「没有可重发的帧」一个字节都不发，连接静默到
    /// 被对端/系统按空闲超时回收(实测 120s 收到 ECONNRESET)。
    /// 发一个只有包头、无载荷的 0x06 包，让 TCP 有数据流动即可。
    /// 接收端对非视频包直接忽略，无需理解它。
    func sendHeartbeat() {
        guard connected, let c = conn else { return }
        var packet = Data(capacity: 13)
        var len = UInt32(9).bigEndian        // 1 类型 + 8 时间戳 = 9，无载荷
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x06)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        c.send(content: packet, completion: .contentProcessed { _ in })
    }

    /// 会话头：把当前虚拟屏尺寸与采集帧率告诉接收端。
    /// 与空载荷心跳同为 0x06，靠长度区分：旧接收端只认 9 字节心跳，
    /// 多出来的载荷会被直接忽略，所以两端版本错配不会断流。
    ///
    /// 载荷（全大端）：[version u8][width u16][height u16][fps u8][reserved u8]
    func sendSessionInfo() {
        guard connected, let c = conn else { return }
        guard sessionWidth > 0, sessionHeight > 0 else { return }

        var packet = Data(capacity: 20)
        var len = UInt32(16).bigEndian       // 1 类型 + 8 时间戳 + 7 载荷
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x06)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(1)                     // 协议版本
        var w = UInt16(clamping: sessionWidth).bigEndian
        withUnsafeBytes(of: &w) { packet.append(contentsOf: $0) }
        var h = UInt16(clamping: sessionHeight).bigEndian
        withUnsafeBytes(of: &h) { packet.append(contentsOf: $0) }
        packet.append(UInt8(clamping: sessionFps))
        packet.append(0)                     // 保留
        c.send(content: packet, completion: .contentProcessed { _ in })
        lastSessionSent = CFAbsoluteTimeGetCurrent()
    }

    func send(frame: Data, captureTimeMicros: UInt64) {
        guard connected else { return }
        counterLock.lock()
        lastPayload = frame
        counterLock.unlock()
        transmit(frame, captureTimeMicros: captureTimeMicros)
    }

    private func transmit(_ frame: Data, captureTimeMicros: UInt64) {
        guard connected, let c = conn else { return }
        // 在途帧数超限：丢这一帧，保住实时性
        counterLock.lock()
        if inFlight >= maxInFlight {
            dropped += 1
            counterLock.unlock()
            return
        }
        inFlight += 1
        lastSendAt = CFAbsoluteTimeGetCurrent()
        counterLock.unlock()

        var packet = Data(capacity: frame.count + 13)
        var len = UInt32(frame.count + 9).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x01)
        var ts = captureTimeMicros.bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(frame)

        sent += 1
        sentBytes += packet.count
        // 捕获发起时的连接代数。重连时新连接先把 connected 置 true，
        // 旧连接上未完成的 send 随后会以错误回调；若不区分代数，这个迟到的
        // 错误会把新连接的 connected 打回 false，之后所有帧被 guard 静默丢弃，
        // 表现为「连着却永久黑屏、且不会自愈重连」。
        let epoch = connEpoch
        c.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.counterLock.lock()
            // 陈旧连接的回调不计入新连接的在途数（新连接已 resetInFlight）
            if self.connEpoch == epoch {
                self.inFlight = max(0, self.inFlight - 1)
            }
            self.counterLock.unlock()
            if err != nil && self.connEpoch == epoch {
                Log.info("发送失败，判定断开: \(err!)")
                self.connected = false
            }
        })
    }

    private func startKeepAlive() {
        guard keepAliveGap > 0 else { return }
        // 监听自愈会重新调用本函数，先取消旧定时器，避免重复保活与泄漏
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepAliveGap, repeating: keepAliveGap / 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.connected else { return }
            let now = CFAbsoluteTimeGetCurrent()
            // 会话头每 5 秒补发一次：切档、重连、接收端重启都能自动收敛
            if now - self.lastSessionSent >= 5.0 { self.sendSessionInfo() }
            self.counterLock.lock()
            let since = now - self.lastSendAt
            let payload = self.lastPayload
            self.counterLock.unlock()
            guard since >= self.keepAliveGap else { return }
            if let payload = payload {
                // 有上一帧就重发它，保持画面（时间戳用当前时刻，避免延迟越算越大）
                self.transmit(payload, captureTimeMicros: UInt64(now * 1_000_000))
            } else {
                // 还没有任何帧(新连接 + 静止桌面)：发心跳维持链路。
                // 旧逻辑在这里直接 return，导致连接静默 120s 被 RST。
                self.sendHeartbeat()
            }
        }
        timer.resume()
        keepAliveTimer = timer
    }
}

// MARK: - 输入回传
//
// 副屏要能真正操作，必须把 Windows 侧的鼠标事件回放到 Mac 上。
// 否则用户在 Windows 屏幕上的点击对 Mac 毫无作用，或者和本机光标互相抢位置。
//
// 需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能。
final class InputInjector {
    private var lastButtons: UInt8 = 0
    private(set) var eventCount = 0

    /// - Parameters:
    ///   - x/y: 相对虚拟屏左上角的逻辑点坐标（Windows 端用逻辑尺寸换算后发来）
    ///   - buttons: bit0 左键，bit1 右键，bit2 中键
    ///   - wheel: 滚动量，正数向下
    func handle(x: Float, y: Float, buttons: UInt8, wheel: Int16, bounds: CGRect) {
        let p = CGPoint(x: bounds.minX + CGFloat(x), y: bounds.minY + CGFloat(y))

        // 先移动指针，再处理按键，保证点击落在正确位置
        if let mv = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: p, mouseButton: .left) {
            mv.post(tap: .cghidEventTap)
        }

        // 按下 / 抬起
        let pairs: [(UInt8, CGEventType, CGEventType, CGMouseButton)] = [
            (0x1, .leftMouseDown,  .leftMouseUp,  .left),
            (0x2, .rightMouseDown, .rightMouseUp, .right),
            (0x4, .otherMouseDown, .otherMouseUp, .center),
        ]
        for (bit, downType, upType, btn) in pairs {
            let was = (lastButtons & bit) != 0
            let now = (buttons & bit) != 0
            if now && !was {
                CGEvent(mouseEventSource: nil, mouseType: downType,
                        mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
            } else if !now && was {
                CGEvent(mouseEventSource: nil, mouseType: upType,
                        mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
            }
        }
        lastButtons = buttons

        // 滚轮
        if wheel != 0 {
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: Int32(wheel), wheel2: 0, wheel3: 0) {
                e.location = p
                e.post(tap: .cghidEventTap)
            }
        }
        eventCount += 1
    }
}

// MARK: - 光标转发
//
// 视频帧只有 45fps，把指针画进画面会让它每 22ms 才动一次，观感是拖影。
// 这里把指针位置单独以高频小包发出去，客户端本地绘制，指针几乎零延迟。
final class CursorTracker {
    private let sender: Sender
    private let bounds: () -> CGRect
    // userInteractive：光标发送是延迟敏感路径，默认 QoS 在系统负载高时
    // 会被调度器推迟。
    private let queue = DispatchQueue(label: "SecDisplay.cursor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var eventMonitor: Any?
    private let lock = NSLock()
    private var pendingPoint: CGPoint?
    private var lastEmitAt: CFAbsoluteTime = 0
    private let minInterval: CFAbsoluteTime
    let targetHz: Double
    private var lastX: Float = .nan
    private var lastY: Float = .nan
    private var lastVisible = false
    /// 累计发出的光标包数量，用于统计展示
    private(set) var sentCount = 0

    init(sender: Sender, bounds: @escaping () -> CGRect) {
        self.sender = sender
        self.bounds = bounds
        // 目标发送频率。默认 90：接收端物理屏是 89Hz，光标若只按 60Hz 更新，
        // 每个位置会在屏上停留 1~2 个刷新周期，肉眼就是「鼠标一跳一跳」。
        // 与 89Hz 接近的 90Hz 基本一更新一刷新，光标跟手。用 SECDISPLAY_CURSOR_HZ 覆盖。
        let hz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_CURSOR_HZ"] ?? "") ?? 90
        self.targetHz = max(30.0, min(240.0, hz))
        self.minInterval = 1.0 / self.targetHz
    }

    func start() {
        // 事件驱动：鼠标移动事件到达即记位置，按目标频率限流后立即发。
        // 8ms 轮询在系统负载下实际只跑到 40Hz 左右，光标看着一跳一跳。
        // 全局监视器需要辅助功能权限，screensender 已有该授权。
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            self?.onMouseEvent()
        }
        let eventDriven = eventMonitor != nil
        Log.info("光标通道: \(eventDriven ? "事件驱动" : "定时轮询")，目标 \(Int(targetHz)) Hz")

        // 事件驱动时定时器做「保底节拍」：系统在锁屏/高负载下会把 mouseMoved
        // 事件节流到 ~40Hz，只靠事件光标会掉到 40Hz 以下。9ms 轮询配合实时位置读取，
        // 即使事件被压也能维持接近目标频率。emitIfDue 内部按 minInterval 限流，
        // 事件与轮询叠加不会超频。
        let ms = eventDriven ? 9 : 8
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(ms),
                   leeway: .microseconds(eventDriven ? 2000 : 500))
        t.setEventHandler { [weak self] in self?.emitIfDue() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func onMouseEvent() {
        guard sender.connected, let ev = CGEvent(source: nil) else { return }
        lock.lock()
        pendingPoint = ev.location
        lock.unlock()
        queue.async { [weak self] in self?.emitIfDue() }
    }

    private func emitIfDue() {
        // 没有连接时不记录位置，否则连上之后要等指针再次移动才会发第一包
        guard sender.connected else {
            lastX = .nan; lastY = .nan; lastVisible = false
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastEmitAt >= minInterval else { return }
        // 优先读当前指针实时位置：事件监视器在系统负载/锁屏时会被节流到 ~40Hz，
        // 只靠 pendingPoint 会漏更新；这里用 CGEvent 实时位置兜底，保证光标不落后。
        let cur = CGEvent(source: nil)?.location
        lock.lock()
        let pp = pendingPoint
        lock.unlock()
        guard let p = cur ?? pp else { return }
        lastEmitAt = now
        emit(p)
    }

    private func emit(_ p: CGPoint) {
        let b = bounds()
        let rx = Float(p.x - b.minX)
        let ry = Float(p.y - b.minY)
        let inside = rx >= 0 && ry >= 0 && rx < Float(b.width) && ry < Float(b.height)

        let moved = !(abs(rx - lastX) < 0.5 && abs(ry - lastY) < 0.5)
        guard moved || inside != lastVisible else { return }

        lastX = rx; lastY = ry; lastVisible = inside
        sentCount += 1
        sender.sendCursor(x: rx, y: ry, visible: inside)
    }
}

/// 真实系统光标图像转发。
///
/// 用 NSCursor.currentSystem(本 SDK 名称，旧名 currentSystemCursor) 拿到当前
/// 系统光标的位图与热点，转成 BGRA 后走 0x05 发给 Windows，由它本地绘制，
/// 让副屏显示 Mac 的真实光标（I 型、手型等），不再是固定 Windows 箭头。
/// 只在「形状变化」或「连接刚建立」时发，正常移动不发，流量可忽略。
final class CursorImageTracker {
    private let sender: Sender
    private let queue = DispatchQueue(label: "SecDisplay.cursorImage")
    private var timer: DispatchSourceTimer?
    /// 上次发送的图像指纹，用于检测形状变化
    private var lastFingerprint: UInt64 = 0
    /// 上次观察到的连接代数，用于连接重建时强制重发
    private var lastEpoch = -1
    private let maxDim = 128       // 光标不会超过 128 像素，超出则截断保护
    /// 上次实际发送时刻，用于限流：光标形状在移动中可能在箭头/I型/手型间频繁切换，
    /// 每切一次就让接收端重建一次 HCURSOR，会造成光标卡顿。限制最小间隔。
    private var lastSendAt: CFAbsoluteTime = 0
    private let minSendGap: CFAbsoluteTime = 0.25
    /// 累计发送次数，供统计展示，便于判断是否在频繁重发
    private(set) var sentCount = 0

    init(sender: Sender) { self.sender = sender }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 100ms 轮询足够跟上光标形状切换(箭头<->I型<->手型)，又不浪费 CPU
        t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        guard sender.connected else {
            // 断开时清指纹，下次连上强制重发（新接收端没有旧光标）
            lastFingerprint = 0
            return
        }
        guard let cur = NSCursor.currentSystem,
              let cg = cur.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // 统一按 1x 逻辑尺寸发送：NSCursor.size 是点，hotSpot 也是点。
        // 直接送 cgImage 会把当前屏的 backing scale 带进来（内建屏 2x、
        // 虚拟屏 1x），热点也按点算，2x 位图下只剩一半，落点会偏半个光标。
        // 接收端再按画面/逻辑尺寸的比例放大，视觉比例才和桌面元素一致。
        let targetW = Int(cur.image.size.width.rounded())
        let targetH = Int(cur.image.size.height.rounded())
        let w = targetW > 0 ? min(targetW, maxDim) : min(cg.width, maxDim)
        let h = targetH > 0 ? min(targetH, maxDim) : min(cg.height, maxDim)
        guard w > 0, h > 0 else { return }
        let scaleX = targetW > 0 ? Double(w) / Double(targetW) : 1.0
        let scaleY = targetH > 0 ? Double(h) / Double(targetH) : 1.0
        let hotX = Int((cur.hotSpot.x * scaleX).rounded())
        let hotY = Int((cur.hotSpot.y * scaleY).rounded())

        // 绘制到 BGRA 缓冲。用 kCGBitmapByteOrder32Little + premultipliedFirst
        // 在 little-endian 上得到 BGRA 排布，正是 Windows DIB 需要的。
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bgra, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: cs, bitmapInfo: bitmapInfo) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 指纹：尺寸 + 热点 + 抽样像素，足以区分不同光标形状
        var fp: UInt64 = UInt64(w) << 48
        fp |= UInt64(h) << 32
        fp |= UInt64(hotX & 0xff) << 24
        fp |= UInt64(hotY & 0xff) << 16
        var hash: UInt64 = 1469598103934665603
        let step = max(1, bgra.count / 256)
        var i = 0
        while i < bgra.count {
            hash = (hash ^ UInt64(bgra[i])) &* 1099511628211
            i += step
        }
        fp ^= hash & 0xffff

        // 连接代数变化(重连)也要重发
        let epoch = sender.currentEpoch
        let force = epoch != lastEpoch
        lastEpoch = epoch
        guard force || fp != lastFingerprint else { return }
        // 非强制（仅形状变化）时限流，避免移动中形状频繁切换导致接收端反复重建光标
        if !force, CFAbsoluteTimeGetCurrent() - lastSendAt < minSendGap { return }
        lastSendAt = CFAbsoluteTimeGetCurrent()
        lastFingerprint = fp
        sentCount += 1
        if force {
            Log.info("光标图像 \(w)x\(h) hot=(\(hotX),\(hotY))")
        }

        sender.sendCursorImage(width: w, height: h, hotX: hotX, hotY: hotY,
                               bgra: Data(bgra))
    }
}

// MARK: - 孤儿虚拟屏清理

/// 触发 WindowServer 做一轮完整显示重配置，清掉 owner 已死的虚拟屏。
/// 依据 research/RESULT-orphan-vdisplay-2026-11-12.md：显示器休眠再唤醒即可，
/// 不注销、不重启 WindowServer。代价是屏幕会短暂黑一下，所以只在显式要求时执行。
func reconfigureDisplays() {
    func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
    run("/usr/bin/pmset", ["displaysleepnow"])
    sleep(6)
    run("/usr/bin/caffeinate", ["-u", "-t", "3"])
    sleep(3)
}

// MARK: - 主流程

var cfg = Config()

// 预设档位：不同分辨率与采集帧率组合，用于对比流畅度与清晰度
// 用 SECDISPLAY_PRESET 选择：sharp / balanced / smooth / fast
if let preset = ProcessInfo.processInfo.environment["SECDISPLAY_PRESET"] {
    switch preset {
    case "sharp":       // 最清晰，帧率最低
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 40
    case "balanced":    // 默认
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 45
    case "smooth":      // 降分辨率换帧率
        cfg.width = 2240; cfg.height = 1400
        cfg.logicalWidth = 1120; cfg.logicalHeight = 700
        cfg.captureHz = 60
    case "fast":        // 最流畅，清晰度最差
        cfg.width = 1920; cfg.height = 1200
        cfg.logicalWidth = 960; cfg.logicalHeight = 600
        cfg.captureHz = 60
    default:
        break
    }
    Log.info("使用预设档位: \(preset)")
}

// 单项覆盖，优先级高于预设
if let w = Int(ProcessInfo.processInfo.environment["SECDISPLAY_W"] ?? ""),
   let h = Int(ProcessInfo.processInfo.environment["SECDISPLAY_H"] ?? "") {
    cfg.width = w; cfg.height = h
    cfg.logicalWidth = w / 2; cfg.logicalHeight = h / 2
    // 显式指定逻辑分辨率，绕开「逻辑 = 物理 / 2」的固定 2x 假设。
    //
    // 背景：macOS 27 上 CGVirtualDisplay 的 hiDPI 对虚拟屏不生效，
    // 实测 NSScreen 与 CGDisplayMode 报的都是「逻辑 = 物理」，也就是 1x，
    // 于是 2240x1400 的桌面元素偏小。把 LOGICAL 设成与 W/H 相同，
    // 得到干净的 1x：物理 1600x1000、逻辑 1600x1000，元素随之变大。
    if let lw = Int(ProcessInfo.processInfo.environment["SECDISPLAY_LOGICAL_W"] ?? ""),
       let lh = Int(ProcessInfo.processInfo.environment["SECDISPLAY_LOGICAL_H"] ?? ""),
       lw > 0, lh > 0 {
        cfg.logicalWidth = lw; cfg.logicalHeight = lh
    }
}
if let hz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] ?? "") {
    cfg.captureHz = hz
}
// 虚拟屏刷新率默认跟随采集上限，默认 60。
// 内建屏 120Hz 与 90Hz 虚拟屏同时在线时，WindowServer 要给两套不整除的
// 节拍排帧，合成开销和光标抖动都会放大。显式指定用 SECDISPLAY_REFRESH。
if let r = Double(ProcessInfo.processInfo.environment["SECDISPLAY_REFRESH"] ?? ""), r >= 24 {
    cfg.refreshRate = r
} else {
    cfg.refreshRate = cfg.captureHz
}
// 码率：默认按像素率估算，约 0.35 bit/pixel/frame。
// 1600x1000@60 约 34 Mbps，2240x1400@60 约 66 Mbps，2880x1800@45 约 82 Mbps。
// 原先固定 180 Mbps 对多数档位都偏富余，除了压编码器，也会让自适应码率的
// 下调幅度显得突兀（一降就是几十 Mbps）。需要更高画质时用 SECDISPLAY_MBPS 覆盖。
if let mbps = Int(ProcessInfo.processInfo.environment["SECDISPLAY_MBPS"] ?? ""),
   mbps >= 10, mbps <= 1000 {
    cfg.bitrateMbps = mbps
} else {
    let pixelsPerSec = Double(cfg.width * cfg.height) * cfg.captureHz
    cfg.bitrateMbps = max(20, min(200, Int(pixelsPerSec * 0.35 / 1_000_000)))
}
let vd = VirtualDisplayManager()
let encoder = Encoder(width: cfg.width, height: cfg.height, bitrateMbps: cfg.bitrateMbps, captureHz: cfg.captureHz)
let sender = Sender()
sender.keepAliveGap = cfg.keepAliveGap
sender.sessionWidth = cfg.width
sender.sessionHeight = cfg.height
sender.sessionFps = Int(cfg.captureHz.rounded())

guard encoder.start() else { exit(3) }

encoder.onFrame = { data, isKey, ts in
    sender.send(frame: data, captureTimeMicros: ts)
}

// 启动前检查残留虚拟屏。只有显式要求时才自动清理，避免每次启动都黑屏一下。
if CommandLine.arguments.contains("--cleanup-orphan")
    || ProcessInfo.processInfo.environment["SECDISPLAY_CLEANUP_ORPHAN"] == "1" {
    let residual = listSecDisplays()
    if !residual.isEmpty {
        Log.info("启动前发现残留虚拟屏 \(residual.count) 块，执行显示重配置清理")
        reconfigureDisplays()
    }
}

do {
    try vd.create(cfg)
} catch VirtualDisplayManager.Err.initFailed {
    // 用身份三元组精确判断残留。不能再用「在线显示器 > 1」：
    // Sidecar / 外接屏在线时本来就有多块屏，会被误报成残留虚拟屏。
    Log.info("虚拟屏创建被拒绝（initWithDescriptor 返回 nil）")
    let ours = listSecDisplays()
    if !ours.isEmpty {
        let desc = ours.map { "id=\($0.id)\($0.old ? "(旧身份)" : "")" }.joined(separator: " ")
        Log.info("检测到残留的 SecDisplay 虚拟屏: \(desc)")
        Log.info("原因：上一次运行异常退出，留下了虚拟屏占住了位置（Sidecar 共存不受影响）")
        Log.info("处理：加 --cleanup-orphan 重启可自动清理；或注销重登")
    } else {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        Log.info("当前在线显示器: \(ids)（其中无 SecDisplay 残留屏）")
        Log.info("原因不明，请检查系统日志")
    }
    exit(2)
} catch {
    Log.info("虚拟屏创建失败: \(error)")
    exit(2)
}

// 打印在线显示器身份，便于现场确认选屏锚定命中正确、且 Sidecar 被正确排除
var onN: UInt32 = 0
CGGetOnlineDisplayList(32, nil, &onN)
var onIDs = [CGDirectDisplayID](repeating: 0, count: Int(onN))
CGGetOnlineDisplayList(onN, &onIDs, &onN)
let idList = onIDs.prefix(Int(onN)).map { id -> String in
    String(format: "id=%u:vendor=0x%x:model=0x%x%@",
           id, CGDisplayVendorNumber(id), CGDisplayModelNumber(id),
           isOurVirtualDisplay(id) ? "[SELF]" : "")
}
Log.info("在线显示器身份: \(idList.joined(separator: "  "))")

// 接收端的 0x02 控制消息 → 让编码器下一帧强制 IDR
// 接收端连上 / 请求关键帧时，用最后一帧强制补 IDR。
// 不能只 requestKeyframe：静止画面没有下一帧，标志永远消费不掉，接收端一直黑屏。
sender.onKeyframeRequest = { encoder.forceEncodeLastFrame() }
sender.listen(port: cfg.port)

// 输入回传：Windows 侧的鼠标事件在 Mac 上重放
// 需要「辅助功能」权限，没有的话事件会被系统静默丢弃
if !AXIsProcessTrusted() {
    Log.info("警告: 未获得辅助功能权限，副屏上的点击/滚轮无法生效")
    Log.info("      系统设置 → 隐私与安全性 → 辅助功能，勾选运行本程序的终端")
}
let injector = InputInjector()
sender.onInput = { x, y, buttons, wheel in
    injector.handle(x: x, y: y, buttons: buttons, wheel: wheel,
                    bounds: CGDisplayBounds(vd.displayID))
}

// 光标转发：坐标是相对虚拟屏的值，与 CGEvent.location 同基准（实测
// CGDisplayBounds 返回物理像素尺寸，随档位变化，如 2880x1800 / 2240x1400）。
// 直接相减即可。Windows 端坐标基准必须与之相同（见接收端 g_coordW/H）。
let vb = CGDisplayBounds(vd.displayID)
Log.info("坐标基准: 逻辑点 \(Int(vb.width))x\(Int(vb.height))，原点 (\(Int(vb.minX)), \(Int(vb.minY)))")
let cursor = CursorTracker(sender: sender, bounds: { CGDisplayBounds(vd.displayID) })
cursor.start()
// 真实光标图像：形状变化时才发，让副屏显示 Mac 的光标而非固定 Windows 箭头
// 真实光标图像（0x05）。SECDISPLAY_NOCURSORIMG=1 可整体关闭，
// 用于 A/B 判断「光标卡顿是否由接收端反复重建光标引起」——关掉后回退 Windows 标准箭头。
let cursorImage = CursorImageTracker(sender: sender)
var disableCursorImage = ProcessInfo.processInfo.environment["SECDISPLAY_NOCURSORIMG"] == "1"
if disableCursorImage {
    Log.info("已关闭真实光标图像(0x05)，使用接收端标准箭头（SECDISPLAY_NOCURSORIMG=1）")
} else {
    cursorImage.start()
}

// 传入 id 获取闭包：虚拟屏重建后 id 会变，采集侧每次重建流都重新问
let cap = Capture(encoder: encoder, cfg: cfg, displayID: { vd.displayID })
Task {
    do {
        try await cap.start()
    } catch {
        Log.info("抓屏失败: \(error)")
        Log.info("需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制")
        vd.destroy()
        exit(4)
    }
}

// MARK: - 自适应码率
//
// 原则：宁可降码率保流畅。画面糊一点还能办公，卡住没法用。
//   - 连续丢帧 → 码率下调（检测到拥塞）
//   - 长时间无丢帧 → 缓慢上调（回到目标值，但不超上限）
/// 接收端 0x07 反馈快照。没有收到反馈时各字段为 0，控制律退回本地判断。
struct FeedbackSignals {
    var presentP95: Double = 0
    var sourceP95: Double = 0
    var decodeFps: Double = 0
    var presentDrop: Int = 0
    var pacedDrop: Int = 0
}

/// 码率控制信号。Phase 1 用 Mac 本地可见的量，Phase 2 加入 Windows 0x07 反馈。
/// `encodeMs` 仍用均值，p95 留到后续。
struct RateSignals {
    var droppedDelta: Int     // 本轮在途丢帧增量
    var inFlight: Int         // 本轮观察到的在途帧数
    var encodeMs: Double      // 本轮平均编码耗时
    var sentMbps: Double      // 本轮实际发送码率
    var captureFps: Double    // 本轮采集帧率
    var winQueueMs: Double = 0  // Windows 侧额外排队：presentP95 - sourceP95
    var presentDrop: Int = 0    // 非节拍丢帧
    var pacedDrop: Int = 0      // 节拍主动丢帧，不参与判断
    var clientFps: Double = 0   // Windows 解码呈现 fps（0x07 decodeFps/10），仅观测
}

/// 健康度驱动的码率控制。健康度取「编码负载 / 在途负载 / 丢帧」三者最大值：
/// 超过 1.0 连续两轮降码率，低于 0.7 连续三轮缓慢回升，中间区间不动。
/// 目标是压住编码与队列积压，不是盲目降带宽。
final class RateController {
    let encoder: Encoder
    let targetMbps: Int
    let captureHz: Double
    private var current: Int
    private var highRounds = 0
    private var lowRounds = 0
    private var idleRounds = 0
    private var lastDownAt: CFAbsoluteTime = 0
    /// 降档冷却：Duet 的做法是 10 秒防抖，避免一次负载抖动就连环下调
    private let downCooldown: CFAbsoluteTime = 10
    /// 试探回退：降档后观察两轮，健康度没有改善 10% 就回退并冷却 60 秒，
    /// 避免 Phase 1 实测里 180Mbps 一路滑到 17Mbps 的情况。
    private var probeMbps: Int? = nil
    private var probeHealth: Double = 0
    private var probeMinHealth: Double = 0
    private var probeAt: CFAbsoluteTime = 0
    private var revertCooldownUntil: CFAbsoluteTime = 0

    init(encoder: Encoder, targetMbps: Int, captureHz: Double) {
        self.encoder = encoder
        self.targetMbps = targetMbps
        self.captureHz = max(1, captureHz)
        self.current = targetMbps
    }

    /// 每 2 秒调用一次
    func tick(_ s: RateSignals) {
        let now = CFAbsoluteTimeGetCurrent()

        // 静态桌面不发帧，健康度不可信。但也不能一直停在低码率，
        // 静止恰恰说明带宽充裕，允许每 3 轮（约 6 秒）小幅回升。
        if s.captureFps < 10 {
            highRounds = 0
            lowRounds = 0
            // 静止时链路仍可能拥塞：在途积压或有丢帧就先不回升
            if s.inFlight >= 2 || s.droppedDelta > 0 {
                idleRounds = 0
                return
            }
            guard current < targetMbps else {
                idleRounds = 0
                return
            }
            idleRounds += 1
            guard idleRounds >= 3 else { return }
            idleRounds = 0
            let next = min(targetMbps, Int(Double(current) * 1.10) + 1)
            guard abs(next - current) >= max(2, Int(Double(current) * 0.05)) else {
                idleRounds = 0
                return
            }
            current = next
            encoder.setBitrate(current)
            Log.info("静止回升，码率上调至 \(current) Mbps")
            return
        }
        idleRounds = 0

        let budgetMs = 1000.0 / captureHz
        let encodeLoad = s.encodeMs / budgetMs
        let inflightLoad = Double(s.inFlight) / 2.0      // maxInFlight = 2
        let winQueueLoad = s.winQueueMs / 15.0           // Windows 侧额外排队，15ms 警戒
        let dropLoad = (s.presentDrop + s.droppedDelta) >= 2 ? 1.5 : 0.0
        // 编码延迟只在明显超标时参与，避免 1.1 这种噪声反复触发
        let encodeGuard = encodeLoad > 1.5 ? encodeLoad : 0.0
        let health = max(max(winQueueLoad, dropLoad), max(inflightLoad, encodeGuard))

        // 降档观察期：队列排空需要时间，给 8 秒；窗口内取最低健康度判断。
        if let pm = probeMbps {
            if now - probeAt < 8.0 {
                if health < probeHealth * 0.90 {
                    probeMbps = nil          // 降档有效，提前结束观察
                } else {
                    probeMinHealth = min(probeMinHealth, health)
                }
                return
            }
            let improved = probeMinHealth < probeHealth * 0.90
            probeMbps = nil
            if !improved {
                current = pm
                encoder.setBitrate(current)
                revertCooldownUntil = now + 60
                Log.info(String(format: "降档无效，回退至 %d Mbps（health %.2f -> %.2f）",
                                current, probeHealth, probeMinHealth))
            }
            return
        }

        if health > 1.15, now >= revertCooldownUntil {
            highRounds += 1
            lowRounds = 0
            // 连续两轮确认，且距上次下调超过冷却时间才动手
            guard highRounds >= 2, now - lastDownAt >= downCooldown else { return }
            highRounds = 0
            lastDownAt = now
            let floor = max(15, targetMbps / 3)
            let next = max(floor, Int(Double(current) * 0.90))
            guard abs(next - current) >= max(2, Int(Double(current) * 0.05)) else { return }
            let prev = current
            probeMbps = prev
            probeHealth = health
            probeMinHealth = health
            probeAt = now
            current = next
            encoder.setBitrate(current)
            Log.info(String(format: "码率 %d -> %d Mbps  health %.2f（winQ %.0fms presentDrop %d 编码 %.0f%% 在途 %.0f%%）",
                            prev, current, health, s.winQueueMs, s.presentDrop,
                            encodeLoad * 100, inflightLoad * 100))
        } else if health < 0.70 {
            lowRounds += 1
            highRounds = 0
            guard lowRounds >= 3, current < targetMbps else { return }
            lowRounds = 0
            let next = min(targetMbps, Int(Double(current) * 1.10) + 1)
            guard abs(next - current) >= max(2, Int(Double(current) * 0.05)) else { return }
            current = next
            encoder.setBitrate(current)
            Log.info(String(format: "健康度 %.2f，码率回升至 %d Mbps", health, current))
        } else {
            highRounds = 0
            lowRounds = 0
        }
    }
}

let rateCtl = RateController(encoder: encoder, targetMbps: cfg.bitrateMbps, captureHz: cfg.captureHz)

// 帧率峰值跟踪：每秒采一次完整帧数，保留最近 10 秒的最大值。
// 用户操作往往很短暂，只看 2 秒瞬时值容易错过。
var fpsWindow: [(Double, Int)] = []
var lastCapCount = 0
var lastCapTime = CFAbsoluteTimeGetCurrent()
var peakFps: Double = 0
var lastCursorCount = 0
var lastCursorImageCount = 0

Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let now = CFAbsoluteTimeGetCurrent()
    let dt = now - lastCapTime
    guard dt > 0.5 else { return }
    let delta = cap.captured - lastCapCount
    lastCapCount = cap.captured
    lastCapTime = now
    let fps = Double(delta) / dt
    fpsWindow.append((now, delta))
    fpsWindow.removeAll { now - $0.0 > 10 }
    peakFps = Double(fpsWindow.map { $0.1 }.max() ?? 0)
}

// 统计
var lastDroppedCount = 0
var lastCapturedCount = 0
/// 面板展示用的最近一轮统计
var lastEncAvgMs: Double = 0
var lastCapAvgMs: Double = 0
var lastMbps: Double = 0
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    let mbps = Double(sender.sentBytes) * 8 / 2.0 / 1_000_000
    let encAvg = encoder.encLatCount > 0 ? encoder.encLatSum / Double(encoder.encLatCount) : 0
    let capAvg = cap.capLatCount > 0 ? cap.capLatSum / Double(cap.capLatCount) : 0
    lastEncAvgMs = encAvg
    lastCapAvgMs = capAvg
    lastMbps = mbps
    let droppedDelta = sender.dropped - lastDroppedCount
    lastDroppedCount = sender.dropped
    let capturedDelta = cap.captured - lastCapturedCount
    lastCapturedCount = cap.captured
    let fb = sender.latestFeedback()
    let winQueueMs = max(0, fb.presentP95 - fb.sourceP95)
    rateCtl.tick(RateSignals(droppedDelta: droppedDelta,
                             inFlight: sender.inFlight,
                             encodeMs: encAvg,
                             sentMbps: mbps,
                             captureFps: Double(capturedDelta) / 2.0,
                             winQueueMs: winQueueMs,
                             presentDrop: fb.presentDrop,
                             pacedDrop: fb.pacedDrop,
                             clientFps: fb.decodeFps))
    let cursorDelta = cursor.sentCount - lastCursorCount
    lastCursorCount = cursor.sentCount
    let imgDelta = cursorImage.sentCount - lastCursorImageCount
    lastCursorImageCount = cursorImage.sentCount
    Log.info(String(format: "采集 %d  峰值 %.0ffps  空闲 %d  静跳 %d  发送 %d  光标+%d  图像+%d  输入 %d  丢弃 %d  %.1f Mbps  在途 %d  采集延迟 %.1f  编码延迟 %.1f ms",
                    cap.captured, peakFps, cap.idleFrameCount, cap.staticSkipCount, sender.sent, cursorDelta, imgDelta,
                    injector.eventCount, sender.dropped, mbps, sender.inFlight, capAvg, encAvg))
    cap.capLatSum = 0; cap.capLatCount = 0; cap.capLatMax = 0
    encoder.encLatSum = 0; encoder.encLatCount = 0; encoder.encLatMax = 0
    sender.sentBytes = 0
    sender.sent = 0
}

// 信号处理只置标志位，实际清理在主循环里做
VirtualDisplayGuard.install()

/// 虚拟屏是否仍在线（按 EDID 三元组识别，不误伤 Sidecar）。
func vdStillOnline() -> Bool {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.prefix(Int(n)).contains {
        CGDisplayVendorNumber($0) == kVDVendorID && CGDisplayModelNumber($0) == kVDProductID
    }
}

/// 有序退出：先停采集并断开连接，再销毁虚拟屏。
///
/// 关键教训：destroy 只能调一次、且只在主线程调。旧代码在 Task 线程和主线程各调
/// 一次，而 destroy 第一次就把 object 置 nil，第二次及所有「重试」都变成空操作，
/// 实际根本没重试；一旦首次 destroy 被 WindowServer 拒绝（采集未完全停），就留残影。
///
/// 现在改为：Task 只负责停采集/断连；主线程等采集停稳 + 额外缓冲后再 destroy 一次，
/// 给 WindowServer 足够时间异步移除，最后只做「检查并报告」，不做危险的重复销毁。
func shutdown(signal sig: Int32) -> Never {
    Log.info("收到信号 \(sig)，开始清理")
    var stopped = false
    Task {
        try? await cap.stream?.stopCapture()
        sender.conn?.cancel()
        stopped = true
    }
    // 等采集停止，最多 5 秒（SCK 重建失败时 stopCapture 偶尔会很慢）
    let stopDeadline = Date().addingTimeInterval(5.0)
    while !stopped && Date() < stopDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    // 采集停稳后再多等 1.2 秒，让 WindowServer 释放该虚拟屏的采集关联。
    // 这步是必须的：采集还挂着时 CDVirtualDisplayDestroy 会被静默拒绝。
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.2))
    vd.destroy()
    // 等 WindowServer 完成异步移除（不重复 destroy，避免对同一 client 二次释放）。
    // 这里给足 5 秒：只等 2 秒时实测会误判「已清理」，随后留下孤儿屏。
    var waited = 0.0
    while vdStillOnline() && waited < 5.0 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        usleep(100_000); waited += 0.1
    }
    if vdStillOnline() {
        Log.info("警告: 虚拟屏疑似未清理干净，下次启动可能被拒；可注销重登清除")
    }
    exit(128 + sig)
}

// 每 100ms 检查一次退出信号
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
    let sig = VirtualDisplayGuard.pendingSignal
    guard sig != 0 else { return }
    VirtualDisplayGuard.pendingSignal = 0
    shutdown(signal: sig)
}

// MARK: - 菜单栏图标
//
// 命令行程序没有 bundle，也没有窗口，退出只能靠 Ctrl-C 或 kill。
// 这里挂一个 NSStatusItem，给出可视入口：实时状态 + 一键退出。
// 退出仍走 shutdown(signal:)，保证虚拟屏按正常时序销毁。

final class StatusMenuTarget: NSObject {
    @objc func quit() {
        Log.info("菜单栏请求退出")
        shutdown(signal: SIGTERM)
    }
    @objc func openPanel() {
        showControlPanel()
    }
}

let statusMenuTarget = StatusMenuTarget()
var statusItem: NSStatusItem?
var statusInfoItem: NSMenuItem?

func setupStatusBar() -> NSApplication {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "SecDisplay")
        button.image?.isTemplate = true
        button.toolTip = "SecDisplay 发送端"
    }

    let menu = NSMenu()
    let info = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    menu.addItem(.separator())

    let open = NSMenuItem(title: "打开面板…", action: #selector(StatusMenuTarget.openPanel), keyEquivalent: "o")
    open.target = statusMenuTarget
    menu.addItem(open)
    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 SecDisplay", action: #selector(StatusMenuTarget.quit), keyEquivalent: "q")
    quit.target = statusMenuTarget
    menu.addItem(quit)

    item.menu = menu
    statusItem = item
    statusInfoItem = info
    if item.button != nil {
        Log.info("菜单栏图标已创建（右侧菜单栏，可点开退出）")
    } else {
        Log.info("警告: 菜单栏按钮创建失败，退出仍需 Ctrl-C")
    }
    return app
}

let statusApp = setupStatusBar()

// 每秒刷新菜单栏文字：连接状态、帧率、编码延迟、在途
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    if let info = statusInfoItem {
        let enc = encoder.encLatCount > 0 ? encoder.encLatSum / Double(encoder.encLatCount) : 0
        let conn = sender.connected ? "已连接" : "等待连接"
        info.title = String(format: "%@ · %.0f fps · 编码 %.0f ms · %d 在途",
                            conn, peakFps, enc, sender.inFlight)
    }
    AppModel.shared.refresh()
}

Log.info("SecDisplay 服务已启动，菜单栏可退出")
statusApp.run()
