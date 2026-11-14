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
import Accelerate
import CoreVideo
import VideoToolbox
import ScreenCaptureKit
import Network
import ObjectiveC.runtime
import AppKit
import Darwin
import ImageIO
import CoreImage
import UniformTypeIdentifiers

/// 调试用：把采集到的 CVPixelBuffer 落盘成 PNG，用来核对「发送端到底抓了什么」。
/// SCK 可能给 BGRA 也可能给 YUV，走 CoreImage 转换最稳。
func dumpPixelBuffer(_ pb: CVPixelBuffer, to path: String) {
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    let fourcc = String(format: "%c%c%c%c",
                        (fmt >> 24) & 0xff, (fmt >> 16) & 0xff, (fmt >> 8) & 0xff, fmt & 0xff)
    let ci = CIImage(cvPixelBuffer: pb)
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    let url = URL(fileURLWithPath: path)
    do {
        try ctx.writePNGRepresentation(of: ci, to: url, format: .RGBA8,
                                       colorSpace: CGColorSpaceCreateDeviceRGB())
        Log.info("落盘成功 \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) fmt=\(fourcc)")
    } catch {
        Log.info("落盘失败 fmt=\(fourcc): \(error)")
    }
}

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

/// 虚拟屏建屏后实测的 backing scale。2x HiDPI 生效时为 2.0，否则 1.0。
/// 坐标链路用它把「逻辑点坐标」和「线上物理像素坐标」互相换算。
/// 放在全局是因为 CursorTracker / InputInjector 是各自独立的闭包，
/// 由建屏处统一写入一次即可。
nonisolated(unsafe) var vdBackingScale: Double = 1.0

/// 键盘注入器。连接重建时从这里 reset，避免 Ctrl/Cmd 卡在按下态。
nonisolated(unsafe) var gKeyboard: KeyboardInjector?
/// 鼠标注入器。断连时同样要清，否则按住左键时对端消失会让 Mac 一直保持按下态。
nonisolated(unsafe) var gMouse: InputInjector?

/// 清空输入注入状态并补发残留的 keyUp / mouseUp。
/// 连接建立与断开都要调：事件是投到 .cghidEventTap 的，系统 HID 层的
/// 按下状态由投出去的事件驱动，只清内部记账等于一直按着。
func resetInjectionState() {
    gKeyboard?.reset()
    gMouse?.resetButtons()
}

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
        // 关键：macOS 按 EDID 物理尺寸算 PPI，约 192~200 PPI 以上才默认为 Retina 2x。
        // 110 PPI 虽然也会在后台合成 HiDPI 模式，但系统默认挑 1x 原生模式跑。
        // 2x 档位设 220 PPI，让系统首次上线即默认选中 2x Retina 模式；1x 档位保持 110 PPI。
        let wantHiDPI = cfg.logicalWidth * 2 <= cfg.width
        let ppi = wantHiDPI ? 220.0 : 110.0
        d.setValue(NSValue(size: NSSize(width: 25.4 * Double(cfg.width) / ppi,
                                        height: 25.4 * Double(cfg.height) / ppi)),
                   forKey: "sizeInMillimeters")
        d.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        d.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        d.setValue(queue, forKey: "queue")

        let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        guard let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: d)?
                .takeUnretainedValue() as? NSObject else { throw Err.initFailed }

        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        func makeMode(_ w: Int, _ h: Int) -> NSObject? {
            let a = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
            let imp = unsafeBitCast(a.method(for: modeSel), to: ModeInit.self)
            return imp(a, modeSel, UInt(w), UInt(h), cfg.refreshRate) as? NSObject
        }

        // HiDPI 需先声明物理背板模式让系统知道高密度面板能力，再列出逻辑模式与缩放档位；
        // 非 HiDPI 声明单个 1x 模式即可。
        var rawPairs: [(Int, Int)] = []
        if wantHiDPI {
            rawPairs.append((cfg.width, cfg.height))
            rawPairs.append((cfg.logicalWidth, cfg.logicalHeight))
            rawPairs.append((cfg.logicalWidth / 2, cfg.logicalHeight / 2))
        } else {
            rawPairs.append((cfg.logicalWidth, cfg.logicalHeight))
        }
        var modes: [NSObject] = []
        var seenPairs = Set<String>()
        for (mw, mh) in rawPairs where mw > 0 && mh > 0 {
            let key = "\(mw)x\(mh)"
            guard seenPairs.insert(key).inserted else { continue }
            guard let m = makeMode(mw, mh) else { throw Err.modeFailed }
            modes.append(m)
        }

        let settings = setCls.init()
        settings.setValue(wantHiDPI, forKey: "hiDPI")
        settings.setValue(modes, forKey: "modes")

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
        // 刚上线时 CGDisplayCopyDisplayMode 可能短暂返回 nil，等模式表就绪再自检/切换
        var modeWait = 0.0
        while modeWait < 1.5 {
            if CGDisplayCopyDisplayMode(displayID) != nil { break }
            usleep(20_000); modeWait += 0.02
        }

        // 若系统缓存的偏好（比如之前选过 1x）导致当前模式没落到目标 (logical, physical)，
        // 主动切一次：先走公开 CGConfigureDisplayWithDisplayMode，不成再走 CGS 私有兜底。
        enforceTargetModeIfNeeded(cfg)

        // HiDPI 自检：不能用 CGDisplayPixelsWide！
        // macOS 27 上 CGDisplayPixelsWide 连内建 Retina 屏都返回逻辑点宽（1512 而非 3024），
        // 之前拿 CGDisplayPixelsWide / CGDisplayBounds 算 scale 永远得到 1.00 是误判。
        // 真正反映背板与缩放的是 CGDisplayCopyDisplayMode 的 pixelWidth/width，
        // 以及带 kCGDisplayShowDuplicateLowResolutionModes=true 的模式枚举。
        let cur = CGDisplayCopyDisplayMode(displayID)
        let pw = cur?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID))
        let ph = cur?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID))
        let lw = cur?.width ?? Int(CGDisplayBounds(displayID).width)
        let lh = cur?.height ?? Int(CGDisplayBounds(displayID).height)
        let s = (lw > 0 && pw > 0) ? Double(pw) / Double(lw) : 1.0
        vdBackingScale = s
        Log.info("HiDPI 自检: 背板 \(pw)x\(ph) 逻辑 \(lw)x\(lh)@\(Int(cur?.refreshRate ?? 0))Hz scale=\(String(format: "%.2f", s)) 期望=\(wantHiDPI ? 2.0 : 1.0)")
        if wantHiDPI && abs(s - 2.0) > 0.1 {
            Log.info("警告: 期望 2x HiDPI 但当前 scale=\(String(format: "%.2f", s))，坐标仍按 cfg.width/bounds 比例对齐")
        }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        if let all = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] {
            let hi = all.filter { $0.pixelWidth > $0.width }
            Log.info("HiDPI 自检: 模式 \(all.count) 个，其中 HiDPI \(hi.count) 个")
            for m in all.filter({ $0.width == lw && $0.height == lh }).prefix(4) {
                Log.info("   匹配模式 \(m.width)x\(m.height) 背板 \(m.pixelWidth)x\(m.pixelHeight)@\(Int(m.refreshRate))Hz\(m.pixelWidth > m.width ? " [HiDPI]" : "")")
            }
        }
        Log.info("虚拟屏就绪 id=\(displayID) \(cfg.width)x\(cfg.height) 逻辑=\(lw)x\(lh) scale=\(String(format: "%.2f", s))")
    }

    /// 当系统默认模式与配置期望 (logicalWidth/Height, width/height) 不一致时强制切换。
    /// macOS 会按 vendor+product id 记住上次模式偏好，如果之前在同 ID 上用过 1x，
    /// 再切回 2x 时就需要主动把模式拨正。
    private func enforceTargetModeIfNeeded(_ cfg: Config) {
        func matches(_ m: CGDisplayMode) -> Bool {
            m.width == cfg.logicalWidth && m.height == cfg.logicalHeight
                && m.pixelWidth == cfg.width && m.pixelHeight == cfg.height
        }
        if let cur = CGDisplayCopyDisplayMode(displayID), matches(cur) {
            return
        }

        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        if let all = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] {
            let target = all.first(where: { matches($0) && abs($0.refreshRate - cfg.refreshRate) < 1.0 })
                ?? all.first(where: matches)
            if let target {
                var c: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&c) == .success, let cfgRef = c {
                    let rc = CGConfigureDisplayWithDisplayMode(cfgRef, displayID, target, nil)
                    if rc != .success {
                        CGCancelDisplayConfiguration(cfgRef)
                        Log.info("公开 API 配置虚拟屏模式失败: \(rc.rawValue)")
                    } else {
                        let done = CGCompleteDisplayConfiguration(cfgRef, .forSession)
                        if done == .success {
                            usleep(250_000)
                            if let cur = CGDisplayCopyDisplayMode(displayID), matches(cur) {
                                Log.info("公开 API 已纠正虚拟屏模式为 \(cur.width)x\(cur.height) (背板 \(cur.pixelWidth)x\(cur.pixelHeight))")
                                return
                            }
                        } else {
                            Log.info("公开 API 提交虚拟屏模式失败: \(done.rawValue)")
                        }
                    }
                }
            }
        }

        // 兜底：公开枚举漏掉的 GPU 缩放 HiDPI 模式，通过 CGS 私有模式表按 modeNumber 切换。
        // 全部走 dlsym 弱查找，不依赖编译期私有符号。
        let rtld = UnsafeMutableRawPointer(bitPattern: -2)
        typealias CGSGetNumFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError
        typealias CGSGetDescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> CGError
        typealias CGSConfigFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> CGError
        guard let gnSym = dlsym(rtld, "CGSGetNumberOfDisplayModes"),
              let gdSym = dlsym(rtld, "CGSGetDisplayModeDescriptionOfLength"),
              let cmSym = dlsym(rtld, "CGSConfigureDisplayMode") else {
            Log.info("CGS 私有模式符号不可用，跳过兜底切换")
            return
        }
        let getNum = unsafeBitCast(gnSym, to: CGSGetNumFn.self)
        let getDesc = unsafeBitCast(gdSym, to: CGSGetDescFn.self)
        let cfgMode = unsafeBitCast(cmSym, to: CGSConfigFn.self)

        var cnt: Int32 = 0
        guard getNum(displayID, &cnt) == .success, cnt > 0 else { return }
        let wantDensity = Float(cfg.width) / Float(max(1, cfg.logicalWidth))
        var buf = [UInt8](repeating: 0, count: 256)
        var picked: Int32? = nil
        var bestDiff = Double.greatestFiniteMagnitude
        for idx in 0..<cnt {
            buf.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress,
                      getDesc(displayID, idx, base, 212) == .success else { return }
                let modeNum = base.load(fromByteOffset: 0, as: UInt32.self)
                let flags = base.load(fromByteOffset: 4, as: UInt32.self)
                let w = Int(base.load(fromByteOffset: 8, as: UInt32.self))
                let h = Int(base.load(fromByteOffset: 12, as: UInt32.self))
                let freq = Int(base.load(fromByteOffset: 190, as: UInt16.self))
                let density = base.load(fromByteOffset: 208, as: Float.self)
                let unusable = (flags & 0x4000_0000) != 0
                if !unusable && w == cfg.logicalWidth && h == cfg.logicalHeight && abs(density - wantDensity) < 0.1 {
                    let diff = abs(Double(freq) - cfg.refreshRate)
                    if picked == nil || diff < bestDiff {
                        bestDiff = diff
                        picked = Int32(bitPattern: modeNum)
                    }
                }
            }
        }
        guard let targetMode = picked else {
            Log.info("CGS 模式表未找到匹配模式 \(cfg.logicalWidth)x\(cfg.logicalHeight) density=\(wantDensity)")
            return
        }
        var c: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&c) == .success, let cfgRef = c else {
            Log.info("CGS 兜底: 无法开始显示配置，跳过模式切换")
            return
        }
        let rc = cfgMode(cfgRef, displayID, targetMode)
        if rc != .success {
            CGCancelDisplayConfiguration(cfgRef)
            Log.info("CGS 私有模式切换失败: \(rc.rawValue)")
            return
        }
        let done = CGCompleteDisplayConfiguration(cfgRef, .forSession)
        if done == .success {
            usleep(250_000)
            Log.info("CGS 私有模式已切换到 modeNumber=\(targetMode)")
        } else {
            Log.info("CGS 私有模式提交失败: \(done.rawValue)")
        }
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

// MARK: - 解除镜像
//
// Sidecar 会把自己镜像到「当前可用的外接屏」，虚拟屏一上线就可能被抢去当镜像目标：
// iPad 上出现一块空桌面，Mac 的显示器排列里多一块没人用的屏。
// 两处兜底：建屏后主动解一次；系统重配置回调里再检查一次。
// 注意：重配置回调里不能直接改显示配置（CG 会拒绝），必须丢回主队列再改。
enum MirrorGuard {
    nonisolated(unsafe) private static var target: CGDirectDisplayID = 0
    nonisolated(unsafe) private static var registered = false
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var lastAttempt: CFAbsoluteTime = 0

    /// 记下要守护的虚拟屏，并挂上显示重配置回调（只挂一次）。
    static func install(_ id: CGDirectDisplayID) {
        target = id
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback(mirrorReconfigCallback, nil)
        Log.info("镜像守护: 已接管虚拟屏 id=\(id)，建屏后与每次显示重配置都会检查镜像关系")
    }

    /// 解除与虚拟屏相关的镜像关系：
    ///   a) 虚拟屏自己是 slave（CGDisplayMirrorsDisplay(vd) != 0）
    ///   b) 别的屏镜像到虚拟屏（Sidecar 抢镜像目标的典型形态）
    /// 只在真的存在镜像关系时才动配置，避免无谓的显示重配置造成闪烁。
    static func release(_ reason: String) {
        let id = target
        guard id != 0, !busy else { return }

        // 屏已经不在线（退出清理途中）就别再改配置了
        let online = onlineDisplayIDs()
        guard online.contains(id) else { return }

        let master = CGDisplayMirrorsDisplay(id)
        let slaves = online.filter { $0 != id && CGDisplayMirrorsDisplay($0) == id }
        guard master != kCGNullDirectDisplay || !slaves.isEmpty else { return }

        // 节流只对「真的要改配置」生效。放前面会把空转回调的时间戳一起推后，
        // 真正的镜像事件反而被饿掉。
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAttempt >= 0.5 else { return }
        lastAttempt = now
        busy = true
        defer { busy = false }

        var cfgRef: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&cfgRef)
        guard begin == .success, let cfg = cfgRef else {
            Log.info("解除镜像失败(\(reason)): 无法开始显示配置 err=\(begin.rawValue)")
            return
        }
        if master != kCGNullDirectDisplay {
            let e = CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
            Log.info("解除镜像(\(reason)): 虚拟屏 id=\(id) 原镜像源=\(master)，改为独立 err=\(e.rawValue)")
        }
        for s in slaves {
            let e = CGConfigureDisplayMirrorOfDisplay(cfg, s, kCGNullDirectDisplay)
            Log.info("解除镜像(\(reason)): id=\(s) 原镜像到虚拟屏 id=\(id)，改为独立 err=\(e.rawValue)")
        }
        let done = CGCompleteDisplayConfiguration(cfg, .permanently)
        if done != .success {
            Log.info("解除镜像未生效(\(reason)): CGCompleteDisplayConfiguration err=\(done.rawValue)")
        } else {
            // 解镜像后必须让采集侧丢掉旧的 SCDisplay 绑定，否则流仍绑在镜像源上，
            // 画面继续是旧内容（这是「先开 SecDisplay 再连 Sidecar 被镜像」的直接原因之一）。
            gCaptureRebuildRequested = true
        }
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(32, nil, &n)
        guard n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
}

/// C 回调：只处理「配置已完成」的那一轮（begin 标志清零），丢回主队列再改配置。
nonisolated(unsafe) var gCaptureRebuildRequested = false

private func mirrorReconfigCallback(_ display: CGDirectDisplayID,
                                    _ flags: CGDisplayChangeSummaryFlags,
                                    _ userInfo: UnsafeMutableRawPointer?) {
    // 屏增删标志可能只出现在 begin 回调里，先置位再过滤 begin。
    if flags.contains(.addFlag) || flags.contains(.removeFlag) {
        gCaptureRebuildRequested = true
    }
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async { MirrorGuard.release("显示重配置") }
}

// MARK: - 雷雳链路检测
//
// 拔线后 TCP 往往不会立刻报错（对端没发 FIN，要等下一次写满重传超时），
// 只看 sender.connected 会拖十几秒。这里直接读链路层 carrier：
// SIOCGIFMEDIA 的 ifm_status，与 `ifconfig bridge0` 的 `status: active` 同源。
// 不用 IFF_RUNNING 判：实测 bridge0 的成员口 en1/en2 没插线也带 RUNNING 标志，
// 只有 media 状态反映真实 carrier。
// 也不向 10.10.10.2:9922 发探测连接——那会顶掉接收端的真实连接。
enum LinkMonitor {
    /// 默认雷雳网桥。换接口用 SECDISPLAY_LINK_IF 覆盖。
    static let ifName = ProcessInfo.processInfo.environment["SECDISPLAY_LINK_IF"] ?? "bridge0"

    /// true=有 carrier，false=接口在但链路断，nil=接口不存在或不支持（不做链路加速）
    static func probe() -> Bool? {
        if let active = mediaActive(ifName) { return active }
        return flagsRunning(ifName)
    }

    /// struct ifmediareq（Darwin）: name[16] + 5×int32 + int*，按 4 字节对齐合计 44 字节。
    /// Swift 没导出这个结构，也没有 SIOCGIFMEDIA 常量，按 _IOWR('i',56,size) 自己算。
    private struct MediaReq {
        var ifm_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                       CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var ifm_current: Int32 = 0
        var ifm_mask: Int32 = 0
        var ifm_status: Int32 = 0
        var ifm_active: Int32 = 0
        var ifm_count: Int32 = 0
        var ifm_ulist: (Int32, Int32) = (0, 0)
    }
    private static let siocgifmedia: UInt =
        0xC0000000 | (UInt(MemoryLayout<MediaReq>.size & 0x1fff) << 16)
        | (UInt(UInt8(ascii: "i")) << 8) | 56
    private static let ifmAValid: Int32 = 0x1
    private static let ifmActive: Int32 = 0x2

    private static func mediaActive(_ name: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var req = MediaReq()
        let rc = withUnsafeMutablePointer(to: &req) { p -> Int32 in
            let raw = UnsafeMutableRawPointer(p)
            name.withCString { _ = strlcpy(raw.assumingMemoryBound(to: CChar.self), $0, 16) }
            return ioctl(fd, siocgifmedia, p)
        }
        guard rc == 0, (req.ifm_status & ifmAValid) != 0 else { return nil }
        return (req.ifm_status & ifmActive) != 0
    }

    /// 兜底：少数接口不支持 SIOCGIFMEDIA，退回 ifaddrs 的 UP+RUNNING。
    private static func flagsRunning(_ name: String) -> Bool? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var found = false
        var running = false
        var cur = ifap
        while let p = cur {
            if String(cString: p.pointee.ifa_name) == name {
                found = true
                let f = Int32(bitPattern: p.pointee.ifa_flags)
                if (f & IFF_UP) != 0 && (f & IFF_RUNNING) != 0 { running = true }
            }
            cur = p.pointee.ifa_next
        }
        return found ? running : nil
    }
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
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
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
        // GOP 长度。600 帧在 55fps 下约 11 秒，实测每 12 秒一次编码延迟尖峰
        // (38~70ms)，表现为「间歇性卡一下」。TCP 不丢包，关键帧只在
        // 新客户端连上时按 0x02 请求补发，所以可以拉长。用 SECDISPLAY_GOP 覆盖。
        let gop = Int(ProcessInfo.processInfo.environment["SECDISPLAY_GOP"] ?? "") ?? 3000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop as CFNumber)

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

        if isKey {
            keyframeCount += 1
            // 关键帧编码明显更贵，打一行便于把「间歇性卡顿」和 GOP 对上。
            Log.info("编码关键帧 #\(keyframeCount)")
        }
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
    /// 调试落盘只做一次
    private var dumpedOnce = false
    /// 调试落盘节流
    private var lastDumpAt: CFAbsoluteTime = 0
    private var dumpSeq = 0
    private var lastProgressAt = CFAbsoluteTimeGetCurrent()
    private var needsRestart = false
    private var didStartupRebuild = false
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
        if isCompositeMode {
            startCompositeCapture()
            return
        }
        let wantID = displayIDProvider()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // 选屏只认 EDID 三元组身份，不信易变的 displayID。
        // Sidecar 接入/断开会让系统重新分配 CGDirectDisplayID，旧 id 可能失效
        // 或被 AirPlay 屏复用；单靠 id 或「非主屏 + 宽度相等」会抓到 iPad / 别的虚拟屏。
        // isOurVirtualDisplay 用 vendor/product/serial 精确锚定我们自己建的屏，
        // 内建(0x610)、Sidecar(aapl/iPad)、GameViewer、Duet 都不会误命中。
        let sckList = content.displays.map { d -> String in
            String(format: "id=%u frame=(%.0f,%.0f %.0fx%.0f)", d.displayID,
                   d.frame.origin.x, d.frame.origin.y, d.frame.width, d.frame.height)
        }.joined(separator: " | ")
        Log.info("SCK 显示列表: \(sckList)")

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

        // 记录 SCK 实际拿到的 SCDisplay 身份。历史上出现过「displayID 说是虚拟屏，
        // 抓出来的却是 Sidecar 内容」的情况，这行日志能直接把两者对上。
        Log.info(String(format: "采集目标 SCDisplay id=%u vendor=0x%x model=0x%x %dx%d",
                        display.displayID,
                        CGDisplayVendorNumber(display.displayID),
                        CGDisplayModelNumber(display.displayID),
                        display.width, display.height))
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
        c.pixelFormat = kCVPixelFormatType_32BGRA
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

        // 虚拟屏刚上线时 SCK 的显示列表可能还没刷新，displayID 会映射到
        // 内建屏的 IOSurface，导致送出去的是内建内容。启动 2 秒后再重建一次，
        // 此时 WindowServer 已稳定，重新取 SCShareableContent 才能绑对屏。
        if !didStartupRebuild {
            didStartupRebuild = true
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.ctl.async { self.needsRestart = true }
                Log.info("启动 2 秒后重建采集流，刷新显示列表")
            }
        }
    }

    // MARK: - 合成抓屏（绕开虚拟屏显示管道）

    // macOS 在 Sidecar 接入后会把虚拟屏的显示管道接到内建屏：
    // CGDisplayMirrorsDisplay 报 0、排列文件也是扩展，但 SCK 抓
    // displayID 拿到的就是内建画面。窗口服务器的合成层却是正确的
    // （screencapture -R 能抓到虚拟屏自己的壁纸），所以直接抓虚拟屏
    // 所在矩形的合成结果，完全绕开显示管道。
    private var compositeTimer: DispatchSourceTimer?
    private var compositeSeq: Int64 = 0
    private let compositeQueue = DispatchQueue(label: "SecDisplay.capture.composite")

    /// 默认走合成抓屏；SECDISPLAY_CAPTURE=sck 可退回 ScreenCaptureKit。
    private var isCompositeMode: Bool {
        ProcessInfo.processInfo.environment["SECDISPLAY_CAPTURE"] != "sck"
    }

    private func startCompositeCapture() {
        compositeTimer?.cancel()
        let hz = Double(ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] ?? "") ?? cfg.captureHz
        let fps = max(1.0, hz)
        let t = DispatchSource.makeTimerSource(queue: compositeQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / fps, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.captureCompositeFrame() }
        t.resume()
        compositeTimer = t
        lastProgressAt = CFAbsoluteTimeGetCurrent()
        Log.info("合成抓屏已启动，虚拟屏 id=\(displayIDProvider())，目标 \(Int(fps))fps")
    }

    // SDK 把 CGWindowListCreateImage 标成 unavailable，但符号还在，运行时取。
    private typealias WindowImageFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowImageFn: WindowImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: WindowImageFn.self)
    }()

    private func captureCompositeFrame() {
        let vd = displayIDProvider()
        let rect = CGDisplayBounds(vd)
        guard rect.width > 1, rect.height > 1 else { return }
        let onScreen = CGWindowListOption.optionOnScreenOnly.rawValue
        let imgOpts = CGWindowImageOption.bestResolution.rawValue | CGWindowImageOption.boundsIgnoreFraming.rawValue
        guard let fn = Self.windowImageFn,
              let cg = fn(rect, onScreen, 0, imgOpts)?.takeRetainedValue() else { return }
        guard let pb = makeVideoFrame(from: cg, width: cfg.width, height: cfg.height) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        captured += 1
        progressCount += 1
        lastFrameTime = now
        lastEncodeAt = now
        let nowMicros = UInt64(now * 1_000_000)
        compositeSeq += 1
        let hz = CMTimeScale(max(1.0, Double(cfg.captureHz)))
        encoder.encode(pb, pts: CMTime(value: compositeSeq, timescale: hz), captureTimeMicros: nowMicros)
    }

    /// CGImage -> 420v CVPixelBuffer。先画进 BGRA，再用 vImage 转 YUV，
    /// 编码器保持只吃 420v，不用改编码链路。
    private func makeVideoFrame(from cg: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var bgra: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &bgra) == kCVReturnSuccess,
              let src = bgra else { return nil }
        CVPixelBufferLockBaseAddress(src, [])
        defer { CVPixelBufferUnlockBaseAddress(src, []) }
        guard let base = CVPixelBufferGetBaseAddress(src) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(src),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        return src
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
        if gCaptureRebuildRequested {
            gCaptureRebuildRequested = false
            needsRestart = true
            Log.info("显示重配置，请求重建采集流")
        }
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
            self.compositeTimer?.cancel()
            self.compositeTimer = nil
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
        // 用户要求满帧率：不再跳过静止帧。
        // 之前的 0.5 秒兜底 + 96x60 采样会让静止桌面只有 2fps，
        // 计数器、光标、小动画看起来一跳一跳。直连带宽和 M1 Pro 硬编都够，
        // 改为全量编码，SCK 送多少帧就编多少帧。
        return false
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
        if let dumpPath = ProcessInfo.processInfo.environment["SECDISPLAY_DUMP_FRAME"],
           !dumpPath.isEmpty,
           CFAbsoluteTimeGetCurrent() - lastDumpAt >= 5.0 {
            lastDumpAt = CFAbsoluteTimeGetCurrent()
            dumpSeq += 1
            let p = dumpPath.replacingOccurrences(of: ".png", with: "_\(dumpSeq).png")
            dumpPixelBuffer(pb, to: p)
            Log.info("已落盘采集帧 #\(dumpSeq) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) -> \(p)")
        }
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

// MARK: - 采集（截图轮询）
//
// 背景：macOS 27 上 ScreenCaptureKit 的 SCStream 无法正确采集 CGVirtualDisplay。
// 实测过滤器指向虚拟屏（SCDisplay id=54 vendor=0xeeee 与身份日志一致），
// 但回调里拿到的却是主屏画面；同一时刻 SCScreenshotManager 抓同一块屏是正确的。
// 落盘对比过：SCStream 帧是主屏 Chrome，SCScreenshotManager 帧是虚拟屏空桌面。
// 所以这里改用 SCScreenshotManager 轮询：单次约 35ms，4 路并发实测约 45fps。
final class ScreenshotCapture {
    let encoder: Encoder
    private let cfg: Config
    private let displayIDProvider: () -> CGDirectDisplayID

    var captured = 0
    var capLatSum: Double = 0
    var capLatCount = 0
    var capLatMax: Double = 0
    var lastFrameTime: CFAbsoluteTime = 0
    private(set) var idleFrameCount = 0
    private(set) var staticSkipCount = 0

    private let encodeQueue = DispatchQueue(label: "SecDisplay.encode")
    private var running = false
    private var cachedContent: SCShareableContent?
    private var cachedAt: CFAbsoluteTime = 0
    private var lastDumpAt: CFAbsoluteTime = 0
    private var dumpSeq = 0
    private var lastErrorLogAt: CFAbsoluteTime = 0
    private var supervisor: DispatchSourceTimer?
    private var lastSupervisorCount = -1
    private var lastSupervisorAt: CFAbsoluteTime = 0
    private var loggedFirstFrame = false
    private var lastSizeWarnAt: CFAbsoluteTime = 0

    init(encoder: Encoder, cfg: Config, displayID: @escaping () -> CGDirectDisplayID) {
        self.encoder = encoder
        self.cfg = cfg
        self.displayIDProvider = displayID
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard content.displays.contains(where: { isOurVirtualDisplay($0.displayID) }) else {
            let avail = content.displays.map {
                String(format: "id=%u vendor=0x%x", $0.displayID, CGDisplayVendorNumber($0.displayID))
            }
            throw NSError(domain: "Capture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "找不到 SecDisplay 虚拟屏，当前: \(avail.joined(separator: ", "))"
            ])
        }
        cachedContent = content
        cachedAt = CFAbsoluteTimeGetCurrent()
        running = true
        spawnWorkers()
        // 看护：并发调用 SCScreenshotManager 偶尔会整体卡住（实测跑约 26 秒后
        // 采集数不再增长，CPU 掉到 1%）。发现 3 秒没新帧就重新拉起工作线程。
        supervisor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SecDisplay.capture.sup"))
        supervisor?.schedule(deadline: .now() + 3, repeating: 3)
        supervisor?.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if self.captured == self.lastSupervisorCount && now - self.lastSupervisorAt > 3.0 {
                Log.info("截图采集停滞（\(Int(now - self.lastSupervisorAt))s 无新帧），重启工作线程")
                self.spawnWorkers()
            }
            if self.captured != self.lastSupervisorCount {
                self.lastSupervisorCount = self.captured
                self.lastSupervisorAt = now
            }
        }
        supervisor?.resume()
    }

    private func spawnWorkers() {
        let workers = 4
        lastSupervisorAt = CFAbsoluteTimeGetCurrent()
        Log.info("采集通道: SCScreenshotManager 轮询，\(workers) 路并发")
        for i in 0..<workers {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop(index: i)
            }
        }
    }

    func stop() { running = false }

    private func loop(index: Int) async {
        while running {
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                let content = try await currentContent()
                guard let d = content.displays.first(where: { isOurVirtualDisplay($0.displayID) }) else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                let filter = SCContentFilter(display: d, excludingWindows: [])
                let c = SCStreamConfiguration()
                c.width = cfg.width
                c.height = cfg.height
                c.showsCursor = false
                // 2x HiDPI 下显式要最高清晰度采样，避免 automatic 在负载时降到逻辑分辨率放大
                if #available(macOS 14.0, *) {
                    c.captureResolution = .best
                }
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
                guard let pb = makePixelBuffer(from: img) else { continue }
                let now = CFAbsoluteTimeGetCurrent()
                encodeQueue.sync {
                    if !loggedFirstFrame {
                        loggedFirstFrame = true
                        Log.info("采集首帧实测: \(img.width)x\(img.height) (期望 \(cfg.width)x\(cfg.height))")
                    } else if (img.width != cfg.width || img.height != cfg.height)
                                && now - lastSizeWarnAt > 2.0 {
                        // 限流：尺寸偏移时每帧都打会淹日志并拖慢 encodeQueue 临界区
                        lastSizeWarnAt = now
                        Log.info("警告: 采集帧尺寸偏移 \(img.width)x\(img.height) != \(cfg.width)x\(cfg.height)")
                    }
                    captured += 1
                    lastFrameTime = now
                    let delay = (now - t0) * 1000
                    capLatSum += delay
                    capLatCount += 1
                    if delay > capLatMax { capLatMax = delay }
                    if let dumpPath = ProcessInfo.processInfo.environment["SECDISPLAY_DUMP_FRAME"],
                       !dumpPath.isEmpty, now - lastDumpAt >= 5.0 {
                        lastDumpAt = now
                        dumpSeq += 1
                        let p = dumpPath.replacingOccurrences(of: ".png", with: "_\(dumpSeq).png")
                        dumpPixelBuffer(pb, to: p)
                        Log.info("已落盘采集帧 #\(dumpSeq) -> \(p)")
                    }
                    // PTS 用当前主机时钟，保证进编码器的顺序单调
                    let pts = CMClockGetTime(CMClockGetHostTimeClock())
                    encoder.encode(pb, pts: pts, captureTimeMicros: UInt64(now * 1_000_000))
                }
            } catch {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastErrorLogAt > 2.0 {
                    lastErrorLogAt = now
                    Log.info("截图采集失败: \(error)")
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func currentContent() async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        // 显示排列变化（Sidecar 接入/拔线、镜像关系变动）时强制刷新一次共享内容，
        // 否则会继续用旧的 SCDisplay 绑定，抓到的是镜像源画面。
        if gCaptureRebuildRequested {
            gCaptureRebuildRequested = false
            cachedContent = nil
            cachedAt = 0
            Log.info("显示排列变化，刷新采集共享内容")
        }
        if let c = cachedContent, now - cachedAt < 2.0 { return c }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        cachedContent = c
        cachedAt = now
        return c
    }
}

/// CGImage → CVPixelBuffer(BGRA)，VideoToolbox 直接吃这个格式。
func makePixelBuffer(from img: CGImage) -> CVPixelBuffer? {
    let w = img.width, h = img.height
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    ]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return pb
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
            // 新连接可能换了接收端，旧的修饰键/按键状态必须清掉，否则 Cmd/Ctrl 会卡住
            resetInjectionState()
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
                    // 对端可能是直接退出/拔线，此时用户手上可能正按着 Ctrl 或左键。
                    // 不在这里补发抬起事件，Mac 会一直保持按下态直到下次连上。
                    resetInjectionState()
                case .cancelled:
                    Log.info("连接已取消（cancelled）")
                    self.connected = false
                    resetInjectionState()
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
            } else if t == 0x09 {
                // [0x09][vk u16][scan u16][down u8][flags u8] = 7 字节，全大端
                guard ctrlBuf.count >= 7 else { return }
                let b = ctrlBuf
                let o = b.startIndex
                let vk = (UInt16(b[o + 1]) << 8) | UInt16(b[o + 2])
                let scan = (UInt16(b[o + 3]) << 8) | UInt16(b[o + 4])
                let down = b[o + 5] != 0
                let flags = b[o + 6]
                onKey?(vk, scan, down, flags)
                ctrlBuf.removeFirst(7)
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
    /// 收到对端 0x09 键盘事件：(vk, scan, down, flags)
    var onKey: ((UInt16, UInt16, Bool, UInt8) -> Void)?

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
    /// 坐标是相对虚拟屏左上角的视频像素基准（cfg.width x cfg.height，与 Windows g_coordW/H 对齐）。
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

    /// 断连时补发残留的 mouseUp。
    /// 只清 lastButtons 是不够的：事件投到 .cghidEventTap 后 HID 层的按下状态
    /// 由投出去的事件驱动，按住左键时对端消失会让 Mac 一直保持按下态。
    func resetButtons() {
        let held = lastButtons
        lastButtons = 0
        guard held != 0 else { return }
        let p = CGEvent(source: nil)?.location ?? .zero
        let ups: [(UInt8, CGEventType, CGMouseButton)] = [
            (0x1, .leftMouseUp, .left),
            (0x2, .rightMouseUp, .right),
            (0x4, .otherMouseUp, .center),
        ]
        for (bit, upType, btn) in ups where (held & bit) != 0 {
            CGEvent(mouseEventSource: nil, mouseType: upType,
                    mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        }
    }

    /// - Parameters:
    ///   - x/y: Windows 回传的坐标，基准是「物理像素」（= 视频帧尺寸 cfg.width x cfg.height）。
    ///          按 cfg / CGDisplayBounds 比例换算到逻辑点空间，即便模式偏好未拨正也保持对齐。
    ///   - buttons: bit0 左键，bit1 右键，bit2 中键
    ///   - wheel: 滚动量，正数向下
    func handle(x: Float, y: Float, buttons: UInt8, wheel: Int16, bounds: CGRect, videoW: Int, videoH: Int) {
        let sx = bounds.width > 0 ? CGFloat(videoW) / bounds.width : 1.0
        let sy = bounds.height > 0 ? CGFloat(videoH) / bounds.height : 1.0
        let p = CGPoint(x: bounds.minX + CGFloat(x) / sx, y: bounds.minY + CGFloat(y) / sy)
        // 复用键盘注入器维护的修饰键状态，让 Ctrl+点击、Shift+点击、Cmd+点击生效。
        // 不设置 flags 时这些组合键在 Mac 上只会被当成普通单击。
        let mods = gKeyboard?.currentFlags() ?? []

        // 先移动指针，再处理按键，保证点击落在正确位置。
        // 按住键时必须投 *MouseDragged 而不是 mouseMoved：选文字、拖滑块、
        // 拖窗口内容这些操作在 Mac 上只认 drag 类型，moved 会被当成纯移动。
        // 判定用 lastButtons（本次之前的已按下态），这样事件顺序是原生顺序：
        // 按下那一帧投 moved → down，抬起那一帧投 drag → up。
        // 用 buttons 判定的话按下帧会先投一个 HID 侧还没按下的 drag。
        let drag: (CGEventType, CGMouseButton)? =
            (lastButtons & 0x1) != 0 ? (.leftMouseDragged, .left) :
            (lastButtons & 0x2) != 0 ? (.rightMouseDragged, .right) :
            (lastButtons & 0x4) != 0 ? (.otherMouseDragged, .center) : nil
        if let mv = CGEvent(mouseEventSource: nil, mouseType: drag?.0 ?? .mouseMoved,
                            mouseCursorPosition: p, mouseButton: drag?.1 ?? .left) {
            mv.flags = mods
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
                if let e = CGEvent(mouseEventSource: nil, mouseType: downType,
                                   mouseCursorPosition: p, mouseButton: btn) {
                    e.flags = mods
                    e.post(tap: .cghidEventTap)
                }
            } else if !now && was {
                if let e = CGEvent(mouseEventSource: nil, mouseType: upType,
                                   mouseCursorPosition: p, mouseButton: btn) {
                    e.flags = mods
                    e.post(tap: .cghidEventTap)
                }
            }
        }
        lastButtons = buttons

        // 滚轮
        if wheel != 0 {
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 1, wheel1: Int32(wheel), wheel2: 0, wheel3: 0) {
                e.location = p
                e.flags = mods
                e.post(tap: .cghidEventTap)
            }
        }
        eventCount += 1
    }
}

// MARK: - 键盘回放
//
// Windows 侧 0x09 包带来虚拟键码 + 扫描码 + 按下/抬起 + 修饰键标志。
// 这里映射到 macOS 虚拟键码后用 CGEvent 注入。
// 同样需要「辅助功能」权限，未授权时事件被系统静默丢弃。
final class KeyboardInjector {
    private var flags: CGEventFlags = []
    /// 按下中的键，按 macOS 虚拟键码记录。
    /// 用 keyCode 而不是 Windows VK：左右 Shift 在 VK 上都是 0x10，
    /// 按 VK 去重会把两个物理键当成同一个，松开一个就整体抬起。
    private var pressed: Set<CGKeyCode> = []
    /// 按下中的修饰键 keyCode → 对应 mask。flags 由它取并集算出。
    private var heldModifiers: [CGKeyCode: CGEventFlags] = [:]
    /// 按下时的 Windows VK → 该 VK 下按住的按键栈（含 scan/扩展位）。
    /// 左右 Ctrl/Shift 与两个 Enter 在 VK 上相同，只靠 keyCode 区分；
    /// 用单值映射会在「同时按住左右键、先松先按的那个」时配错并留下卡死的修饰键。
    /// 抬起时优先按 keyCode+scan+扩展位精确匹配，扩展位丢失时退回栈顶。
    private struct HeldKey {
        let keyCode: CGKeyCode
        let scan: UInt16
        let extended: Bool
    }
    private var pressedVK: [UInt16: [HeldKey]] = [:]
    private let lock = NSLock()
    private(set) var eventCount = 0

    /// 重置所有按键状态，并补发 keyUp。
    /// 只清内部记账是不够的：事件投到 .cghidEventTap 后系统 HID 层的按键状态
    /// 由投出去的事件驱动，不补 keyUp 的话断连后 Ctrl/Cmd 会一直卡在按下态。
    func reset() {
        lock.lock()
        let stuck = pressed
        pressed.removeAll()
        pressedVK.removeAll()
        heldModifiers.removeAll()
        flags = []
        lock.unlock()

        // 在锁外补发，避免与 handle 的锁重入
        guard !stuck.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for keyCode in stuck {
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
                ev.flags = []
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    /// 当前修饰键状态，供鼠标事件复用（Ctrl+点击、Shift+点击等组合键）。
    func currentFlags() -> CGEventFlags {
        lock.lock()
        defer { lock.unlock() }
        return flags
    }

    func handle(vk: UInt16, scan: UInt16, down: Bool, keyFlags: UInt8) {
        lock.lock()
        defer { lock.unlock() }

        let extended = (keyFlags & 0x01) != 0
        guard let keyCode = Self.keyCode(forVK: vk, extended: extended, scan: scan) else { return }
        let mask = Self.modifierMask(forVK: vk)

        if down {
            // 长按重复必须继续投递：Windows 会把系统自动重复的 keyDown 一并转发，
            // 而注入的 CGEvent 不会自己产生重复，直接 return 会让按住退格/方向键
            // 只生效一次。这里只在首次按下时改修饰键记账，重复事件照常投递。
            let isRepeat = pressed.contains(keyCode)
            if !isRepeat {
                pressed.insert(keyCode)
                pressedVK[vk, default: []].append(
                    HeldKey(keyCode: keyCode, scan: scan, extended: extended))
                if let mask {
                    heldModifiers[keyCode] = mask
                    rebuildFlags()
                }
            }
            post(keyCode: keyCode, down: true, isRepeat: isRepeat)
        } else {
            // 抬起优先按 VK 查回按下时的按键。
            // down/up 两次报文的 scan 或扩展位未必一致（KVM、注入式输入把 scan 报成 0、
            // 某些远程栈丢扩展位），只按 keyCode 配对会配不上，keyUp 被吞掉键就粘住了。
            // 匹配顺序：完整三元组 → 同 keyCode 的栈顶 → 栈顶。
            var stack = pressedVK[vk] ?? []
            let kc: CGKeyCode
            var matched: Int?
            if let idx = stack.firstIndex(where: {
                $0.keyCode == keyCode && $0.scan == scan && $0.extended == extended
            }) {
                matched = idx
                kc = stack[idx].keyCode
            } else if let idx = stack.lastIndex(where: { $0.keyCode == keyCode }) {
                // 扩展位丢失时同 keyCode 可能对应两个物理键，取最近按下的那个。
                matched = idx
                kc = stack[idx].keyCode
            } else if !stack.isEmpty {
                matched = stack.count - 1
                kc = stack[stack.count - 1].keyCode
            } else {
                kc = keyCode
            }

            // 先确认这个键确实处于按下态，再消费栈条目，
            // 避免 guard 失败时白掉一条记账、三张表不同步。
            guard pressed.remove(kc) != nil else { return }
            if let idx = matched { stack.remove(at: idx) }
            if stack.isEmpty { pressedVK.removeValue(forKey: vk) } else { pressedVK[vk] = stack }

            // 按真正抬起的 keyCode 清理修饰键，不用 up 报文里的 mask：
            // 左右修饰键 VK 相同，靠报文分不出清哪一侧。
            if heldModifiers.removeValue(forKey: kc) != nil {
                rebuildFlags()
            }
            post(keyCode: kc, down: false, isRepeat: false)
        }
    }

    private func post(keyCode: CGKeyCode, down: Bool, isRepeat: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: down) else { return }
        ev.flags = flags
        if isRepeat {
            ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        ev.post(tap: .cghidEventTap)
        eventCount += 1
    }

    /// flags 取所有按下中修饰键的并集。
    /// 按 mask 计数在「同一 mask 有左右两个物理键」和「重复 keydown」两种情况下
    /// 都会算错，改成按 keyCode 记账后两个问题都不存在。
    private func rebuildFlags() {
        var f: CGEventFlags = []
        for (_, m) in heldModifiers { f.insert(m) }
        flags = f
    }

    /// 修饰键 → CGEventFlags。返回 nil 表示不是修饰键。
    static func modifierMask(forVK vk: UInt16) -> CGEventFlags? {
        switch vk {
        case 0x10, 0xA0, 0xA1: return .maskShift
        case 0x11, 0xA2, 0xA3: return .maskControl
        case 0x12, 0xA4, 0xA5: return .maskAlternate
        case 0x5B, 0x5C:       return .maskCommand
        default:               return nil
        }
    }

    /// 左右修饰键在 Windows 的 wParam 里是同一个 generic VK（0x10/0x11/0x12），
    /// 只能靠扫描码与扩展位区分。
    static func keyCode(forVK vk: UInt16, extended: Bool, scan: UInt16) -> CGKeyCode? {
        switch vk {
        case 0x10: return scan == 0x36 ? 0x3C : 0x38   // 右 Shift 扫描码 0x36
        case 0x11: return extended ? 0x3E : 0x3B       // 右 Ctrl 带扩展位
        case 0x12: return extended ? 0x3D : 0x3A       // 右 Alt 带扩展位
        default:   return keyCode(forVK: vk, extended: extended)
        }
    }

    /// Windows 虚拟键码 → macOS 虚拟键码。返回 nil 表示不支持的键（忽略）。
    static func keyCode(forVK vk: UInt16, extended: Bool) -> CGKeyCode? {
        switch vk {
        // 字母
        case 0x41: return 0x00   // A
        case 0x42: return 0x0B   // B
        case 0x43: return 0x08   // C
        case 0x44: return 0x02   // D
        case 0x45: return 0x0E   // E
        case 0x46: return 0x03   // F
        case 0x47: return 0x05   // G
        case 0x48: return 0x04   // H
        case 0x49: return 0x22   // I
        case 0x4A: return 0x26   // J
        case 0x4B: return 0x28   // K
        case 0x4C: return 0x25   // L
        case 0x4D: return 0x2E   // M
        case 0x4E: return 0x2D   // N
        case 0x4F: return 0x1F   // O
        case 0x50: return 0x23   // P
        case 0x51: return 0x0C   // Q
        case 0x52: return 0x0F   // R
        case 0x53: return 0x01   // S
        case 0x54: return 0x11   // T
        case 0x55: return 0x20   // U
        case 0x56: return 0x09   // V
        case 0x57: return 0x0D   // W
        case 0x58: return 0x07   // X
        case 0x59: return 0x10   // Y
        case 0x5A: return 0x06   // Z
        // 数字行
        case 0x30: return 0x1D   // 0
        case 0x31: return 0x12   // 1
        case 0x32: return 0x13   // 2
        case 0x33: return 0x14   // 3
        case 0x34: return 0x15   // 4
        case 0x35: return 0x17   // 5
        case 0x36: return 0x16   // 6
        case 0x37: return 0x1A   // 7
        case 0x38: return 0x1C   // 8
        case 0x39: return 0x19   // 9
        // 符号
        case 0xBA: return 0x29   // ;
        case 0xBB: return 0x18   // =
        case 0xBC: return 0x2B   // ,
        case 0xBD: return 0x1B   // -
        case 0xBE: return 0x2F   // .
        case 0xBF: return 0x2C   // /
        case 0xC0: return 0x32   // `
        case 0xDB: return 0x21   // [
        case 0xDC: return 0x2A   // \
        case 0xDD: return 0x1E   // ]
        case 0xDE: return 0x27   // '
        // 控制键
        case 0x08: return 0x33   // Backspace
        case 0x09: return 0x30   // Tab
        case 0x0D: return extended ? 0x4C : 0x24   // 主 Enter / 小键盘 Enter
        case 0x1B: return 0x35   // Esc
        case 0x20: return 0x31   // Space
        case 0x14: return 0x39   // CapsLock
        case 0x2D: return 0x72   // Insert -> Help
        case 0x2E: return 0x75   // Delete
        case 0x24: return 0x73   // Home
        case 0x23: return 0x77   // End
        case 0x21: return 0x74   // PageUp
        case 0x22: return 0x79   // PageDown
        // 方向键
        case 0x25: return 0x7B
        case 0x26: return 0x7E
        case 0x27: return 0x7C
        case 0x28: return 0x7D
        // 修饰键（左右分开）
        case 0x10: return 0x38   // Shift
        case 0xA0: return 0x38   // LShift
        case 0xA1: return 0x3C   // RShift
        case 0x11: return 0x3B   // Ctrl
        case 0xA2: return 0x3B   // LCtrl
        case 0xA3: return 0x3E   // RCtrl
        case 0x12: return 0x3A   // Alt
        case 0xA4: return 0x3A   // LAlt
        case 0xA5: return 0x3D   // RAlt
        case 0x5B: return 0x37   // LWin -> Command
        case 0x5C: return 0x36   // RWin -> Right Command
        // 功能键
        case 0x70: return 0x7A   // F1
        case 0x71: return 0x78   // F2
        case 0x72: return 0x63   // F3
        case 0x73: return 0x76   // F4
        case 0x74: return 0x60   // F5
        case 0x75: return 0x61   // F6
        case 0x76: return 0x62   // F7
        case 0x77: return 0x64   // F8
        case 0x78: return 0x65   // F9
        case 0x79: return 0x6D   // F10
        case 0x7A: return 0x67   // F11
        case 0x7B: return 0x6F   // F12
        // 小键盘
        case 0x60: return 0x52
        case 0x61: return 0x53
        case 0x62: return 0x54
        case 0x63: return 0x55
        case 0x64: return 0x56
        case 0x65: return 0x57
        case 0x66: return 0x58
        case 0x67: return 0x59
        case 0x68: return 0x5B
        case 0x69: return 0x5C
        case 0x6A: return 0x43   // *
        case 0x6B: return 0x45   // +
        case 0x6D: return 0x4E   // -
        case 0x6E: return 0x41   // .
        case 0x6F: return 0x4B   // /
        default:   return nil
        }
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

    private let videoSize: () -> (Int, Int)

    init(sender: Sender, bounds: @escaping () -> CGRect, videoSize: @escaping () -> (Int, Int)) {
        self.sender = sender
        self.bounds = bounds
        self.videoSize = videoSize
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

        // 线上协议与 Windows g_coordW/H 用的是「视频像素」基准（cfg.width x cfg.height）。
        // 按 videoSize / CGDisplayBounds 比例换算，确保不管 1x 还是 2x Retina（或异常回退），
        // 线上坐标永远与视频帧像素 1:1 对齐，Windows 端零改动。
        let (vw, vh) = videoSize()
        let sx = b.width > 0 ? Float(vw) / Float(b.width) : 1.0
        let sy = b.height > 0 ? Float(vh) / Float(b.height) : 1.0
        let ox = rx * sx
        let oy = ry * sy

        let moved = !(abs(ox - lastX) < 0.5 && abs(oy - lastY) < 0.5)
        guard moved || inside != lastVisible else { return }

        lastX = ox; lastY = oy; lastVisible = inside
        sentCount += 1
        sender.sendCursor(x: ox, y: oy, visible: inside)
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
        // 面板「发送真实光标图像」开关实时生效：关掉后不再发 0x05，
        // 接收端回退 Windows 标准箭头。原来只在启动时读一次环境变量，
        // 运行中拨开关没有任何效果。
        guard !disableCursorImage else {
            lastFingerprint = 0
            return
        }
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

// 单实例：两个发送端会各建一块虚拟屏，还会抢 9922 端口，表现为画面来回跳。
// 用 flock 而不是 pid 文件：锁在进程退出时由内核释放，不存在 pid 被回收后的误判。
do {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/SecDisplay")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let lockPath = (dir as NSString).appendingPathComponent("sender.lock")
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 {
        Log.info("已有发送端在运行，本次启动退出。如需重启先结束旧进程。")
        exit(0)
    }
    // fd 故意不关闭，锁随进程存活
}

// 预设档位：不同分辨率与采集帧率组合，用于对比流畅度与清晰度
// 用 SECDISPLAY_PRESET 选择：sharp / balanced / smooth / fast
// 打包成 .app 从 Finder 启动时没有环境变量，读 Contents/Resources/preset。
var presetName = ProcessInfo.processInfo.environment["SECDISPLAY_PRESET"]
if presetName == nil, let rp = Bundle.main.resourcePath {
    let p = rp + "/preset"
    if let s = try? String(contentsOfFile: p, encoding: .utf8) {
        presetName = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
if let preset = presetName, !preset.isEmpty {
    switch preset {
    case "sharp":       // 2880×1800 真 2x Retina（1440×900 逻辑），画质最锐
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 45
    case "balanced":    // 默认：2880×1800 真 2x Retina（1440×900 逻辑），与 Windows 物理屏 1:1
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = 50
    case "smooth":      // 2240×1400 真 2x Retina（1120×700 逻辑），流畅度优先
        cfg.width = 2240; cfg.height = 1400
        cfg.logicalWidth = 1120; cfg.logicalHeight = 700
        cfg.captureHz = 60
    case "compact":     // 1x 小屏（1600×1000），适合 Sidecar 共存或窗口模式
        cfg.width = 1600; cfg.height = 1000
        cfg.logicalWidth = 1600; cfg.logicalHeight = 1000
        cfg.captureHz = 60
    case "fast":        // 1920×1200 真 2x Retina（960×600 逻辑）
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
    // 未显式指定 LOGICAL 时：>=2000 宽默认开 2x Retina（w/2 × h/2），小分辨率保持 1x。
    if w >= 2000 {
        cfg.logicalWidth = w / 2; cfg.logicalHeight = h / 2
    } else {
        cfg.logicalWidth = w; cfg.logicalHeight = h
    }
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
// 码率按像素率估算，系数 0.6（2880x1800@50 约 155 Mbps，2240x1400@60 约 113 Mbps，
// 1600x1000@60 约 58 Mbps；桌面文字边缘高频信息多，0.35 偏低容易糊）。
// RateController 会按链路健康度在 [target/3, target] 之间自适应，
// 上限 clamp 到 200；需要更高画质时用 SECDISPLAY_MBPS 覆盖。
if let mbps = Int(ProcessInfo.processInfo.environment["SECDISPLAY_MBPS"] ?? ""),
   mbps >= 10, mbps <= 1000 {
    cfg.bitrateMbps = mbps
} else {
    let pixelsPerSec = Double(cfg.width * cfg.height) * cfg.captureHz
    cfg.bitrateMbps = max(30, min(200, Int(pixelsPerSec * 0.6 / 1_000_000)))
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

// 建屏前先确认雷雳链路 carrier 正常。
// 虚拟屏只有在「Mac 发送端在跑 + 雷雳链路通」时才有意义：
// 线没插时建屏会留下一块没人用的空屏，还会占住显示器排列。
// 最多等 8 秒——等太久会让从 Finder 启动的 app 表现为「点了没反应、菜单栏没图标」。
if LinkMonitor.probe() == false {
    Log.info("雷雳链路未就绪（\(LinkMonitor.ifName) 无 carrier），最多等 8 秒…")
    var waited = 0.0
    while LinkMonitor.probe() == false && waited < 8.0 {
        usleep(500_000); waited += 0.5
    }
    switch LinkMonitor.probe() {
    case .some(true):
        Log.info("雷雳链路已就绪，耗时 \(String(format: "%.1f", waited)) 秒")
    case .some(false):
        Log.info("链路仍未就绪，先建屏；接收端连上后仍可用")
    case .none:
        Log.info("未找到链路接口 \(LinkMonitor.ifName)，跳过等待")
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

// 建屏后立刻解除镜像。此时还没起采集，重配置不会打断视频流。
MirrorGuard.install(vd.displayID)
MirrorGuard.release("建屏后")

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
// 需要「辅助功能」权限，没有的话 CGEvent 注入会被系统静默丢弃
// （表现为：光标能跟着动，但点击/滚轮完全不生效）。
let axTrusted = AXIsProcessTrusted()
if !axTrusted {
    Log.info("警告: 未获得辅助功能权限，副屏上的点击/滚轮无法生效")
    Log.info("      系统设置 → 隐私与安全性 → 辅助功能，勾选 /Applications/SecDisplay.app")
} else {
    Log.info("辅助功能权限: 已授权，副屏点击与滚轮可正常回放")
}
let injector = InputInjector()
gMouse = injector
sender.onInput = { x, y, buttons, wheel in
    // 这里不能再按「面板是否可见」整条丢弃输入。
    // 早期为了防面板被光标劫持加过这个门控，但面板点不动的真正根因是
    // NSEvent 全局监视器抢在 NSApplication 初始化前建立 SkyLight 会话
    // （已由延迟到 app.run 后注册修复）。保留门控的后果是：只要面板开着，
    // 点击事件被整条吞掉，而光标移动走 0x03 显示链路不受影响，
    // 表现就是「鼠标能动、点不动」。因此回放始终生效。
    injector.handle(x: x, y: y, buttons: buttons, wheel: wheel,
                    bounds: CGDisplayBounds(vd.displayID),
                    videoW: cfg.width, videoH: cfg.height)
}

// 键盘回放：Windows 侧 0x09 包 → macOS CGEvent 键盘事件
let keyboard = KeyboardInjector()
gKeyboard = keyboard
sender.onKey = { vk, scan, down, flags in
    keyboard.handle(vk: vk, scan: scan, down: down, keyFlags: flags)
}

// 光标转发：CGEvent.location 与 CGDisplayBounds 处于逻辑点坐标系；
// 2x Retina 时逻辑点为 1440x900，CursorTracker / InputInjector 会按 cfg/bounds 比例
// 统一换算到线上物理像素基准（2880x1800），与 Windows 端 g_coordW/H 对齐。
let vb = CGDisplayBounds(vd.displayID)
Log.info("坐标基准: 逻辑点 \(Int(vb.width))x\(Int(vb.height)) * \(String(format: "%.2f", vdBackingScale))x → 线上 \(cfg.width)x\(cfg.height)，原点 (\(Int(vb.minX)), \(Int(vb.minY)))")
let cursor = CursorTracker(sender: sender,
                           bounds: { CGDisplayBounds(vd.displayID) },
                           videoSize: { (cfg.width, cfg.height) })
// 真实光标图像：形状变化时才发，让副屏显示 Mac 的光标而非固定 Windows 箭头
// 真实光标图像（0x05）。SECDISPLAY_NOCURSORIMG=1 可整体关闭，
// 用于 A/B 判断「光标卡顿是否由接收端反复重建光标引起」——关掉后回退 Windows 标准箭头。
let cursorImage = CursorImageTracker(sender: sender)
var disableCursorImage = ProcessInfo.processInfo.environment["SECDISPLAY_NOCURSORIMG"] == "1"
if disableCursorImage {
    Log.info("已关闭真实光标图像(0x05)，使用接收端标准箭头（SECDISPLAY_NOCURSORIMG=1）")
}
// 注意：cursor.start() 调 NSEvent.addGlobalMonitorForEvents，cursorImage.start() 读 NSCursor。
// 必须在 statusApp = setupStatusBar() + statusApp.run() 初始化完 AppKit 事件会话之后再启动，
// 否则 NSEvent 全局监视器会抢先初始化半残的 SkyLight 会话，导致本进程所有窗口完全收不到鼠标点击！
// 实际启动已移至下方 statusApp.run() 前的 DispatchQueue.main.async。

// 传入 id 获取闭包：虚拟屏重建后 id 会变，采集侧每次重建流都重新问
let cap = ScreenshotCapture(encoder: encoder, cfg: cfg, displayID: { vd.displayID })
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
///
/// 清理全程约 11 秒，期间用户可能再按一次退出、或看门狗同时触发。这里用闸门保证
/// 只跑一份清理：重复请求直接返回，避免第二次 destroy 抢在采集停稳之前。
nonisolated(unsafe) private var shutdownStarted = false
private let shutdownLock = NSLock()

func shutdown(signal sig: Int32) {
    shutdownLock.lock()
    if shutdownStarted {
        shutdownLock.unlock()
        Log.info("已在清理中，忽略重复退出请求（信号 \(sig)）")
        return
    }
    shutdownStarted = true
    shutdownLock.unlock()

    Log.info("收到信号 \(sig)，开始清理")
    var stopped = false
    Task {
        cap.stop()
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

// MARK: - 客户端看门狗
//
// 客户端走了（或线拔了）就收工，别让一块空虚拟屏一直挂在显示器排列里，
// 也别让 Sidecar 继续往空屏上镜像。
//   1. 从未连上过：启动后 180 秒宽限，超时清理退出（开机自启空跑的场景）
//   2. 连上过又断开：连续断开 8 秒退出；链路已断（拔线）时缩到 2 秒
//   3. 链路断满 2 秒直接算断开：拔线后 TCP 可能几十秒都不报错，
//      只等 connected 变 false 会一直不退出
//   4. 重新连上/链路恢复立即复位计时
// 判据用 sender.connected，它由连接状态回调和发送失败回调维护。
final class ClientWatchdog {
    private enum LinkState: String {
        case up = "正常"
        case down = "已断"
        case unknown = "未知"
    }

    private let initialGrace: Double
    private let graceLinkUp: Double
    private let graceLinkDown: Double

    private var timer: Timer?
    private var startedAt = CFAbsoluteTimeGetCurrent()
    private var everConnected = false
    private var lastConnectedAt: CFAbsoluteTime = 0
    private var linkDownSince: CFAbsoluteTime?
    private var lastLink: LinkState?
    private var lastLoggedConnected: Bool?
    private var fired = false

    init(initialGrace: Double, graceLinkUp: Double, graceLinkDown: Double) {
        self.initialGrace = initialGrace
        self.graceLinkUp = graceLinkUp
        self.graceLinkDown = graceLinkDown
    }

    func start() {
        guard timer == nil else { return }
        startedAt = CFAbsoluteTimeGetCurrent()
        _ = currentLink()   // 先打一条初始链路状态，便于对照日志
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        // .common：菜单展开（eventTracking）期间也要照常计时
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("看门狗已启动: 未连接宽限 \(Int(initialGrace))s，断开宽限 \(Int(graceLinkUp))s/链路断 \(Int(graceLinkDown))s")
    }

    private func currentLink() -> LinkState {
        let link: LinkState
        switch LinkMonitor.probe() {
        case .some(true):  link = .up
        case .some(false): link = .down
        case .none:        link = .unknown
        }
        if link != lastLink {
            lastLink = link
            switch link {
            case .up:
                Log.info("链路: \(LinkMonitor.ifName) carrier 正常")
            case .down:
                Log.info("链路: \(LinkMonitor.ifName) carrier 丢失（拔线），断开宽限缩短到 \(Int(graceLinkDown))s")
            case .unknown:
                Log.info("链路: 未找到接口 \(LinkMonitor.ifName)，不做链路加速，只按 TCP 断开判定")
            }
        }
        return link
    }

    private func tick() {
        guard !fired else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let link = currentLink()
        let connected = sender.connected

        if connected != lastLoggedConnected {
            lastLoggedConnected = connected
            if connected {
                Log.info("看门狗: 客户端已连接，断开计时复位")
            } else {
                Log.info(everConnected ? "看门狗: 客户端已断开，开始计时" : "看门狗: 等待客户端连接")
            }
        }

        if connected {
            everConnected = true
            lastConnectedAt = now
        }

        // 链路断满宽限就直接算断开。拔线后 TCP 往往要等重传超时才报错，
        // 那时 connected 还是 true，只等它变 false 会让空虚拟屏继续挂几十秒。
        // 链路断满宽限就直接算断开，不要求「连过」。
        // 拔线时虚拟屏必须马上消失，否则会一直挂在显示器排列里。
        // 启动后 10 秒内的链路抖动不算（开机时网桥可能还没起来）。
        if now - startedAt >= 10 {
            if link == .down {
                if linkDownSince == nil { linkDownSince = now }
                if let since = linkDownSince, now - since >= graceLinkDown {
                    fire(String(format: "链路已断 %.1f 秒（宽限 %.0f 秒），按断开处理",
                                now - since, graceLinkDown))
                    return
                }
            } else {
                linkDownSince = nil
            }
        }

        if connected { return }

        if !everConnected {
            let waited = now - startedAt
            if waited >= initialGrace {
                fire(String(format: "启动后 %.0f 秒仍无客户端连接", waited))
            }
            return
        }

        let grace = (link == .down) ? graceLinkDown : graceLinkUp
        let off = now - lastConnectedAt
        if off >= grace {
            fire(String(format: "客户端断开 %.1f 秒（宽限 %.0f 秒，链路 %@）",
                        off, grace, link.rawValue))
        }
    }

    private func fire(_ why: String) {
        guard !fired else { return }
        fired = true
        timer?.invalidate()
        timer = nil
        Log.info("看门狗触发退出: \(why)")
        // 与菜单退出同一条路径：排到下一个 default 轮次再清理。
        // shutdown 内部会跑嵌套 RunLoop 等采集停稳，不能在定时器回调里直接进去。
        RunLoop.main.perform(inModes: [.default]) { shutdown(signal: SIGTERM) }
    }
}

let clientWatchdog = ClientWatchdog(
    initialGrace: Double(ProcessInfo.processInfo.environment["SECDISPLAY_INITIAL_GRACE"] ?? "") ?? 180,
    // 断开宽限不能太短。接收端重启（改配置、换分辨率、手动退出再开）通常要几十秒，
    // 8 秒的宽限会让发送端在接收端重启期间自己退出，连带销毁虚拟屏，用户下次
    // 还得手工重开。60 秒足够覆盖重启，又不会让孤儿屏长期挂着。
    graceLinkUp: Double(ProcessInfo.processInfo.environment["SECDISPLAY_DISCONNECT_GRACE"] ?? "") ?? 60,
    // 链路断（拔线）仍是快速判定：线都拔了就没必要留屏占显示器排列。
    graceLinkDown: Double(ProcessInfo.processInfo.environment["SECDISPLAY_DISCONNECT_GRACE_LINKDOWN"] ?? "") ?? 5
)
clientWatchdog.start()

// MARK: - 菜单栏图标
//
// 命令行程序没有 bundle，也没有窗口，退出只能靠 Ctrl-C 或 kill。
// 这里挂一个 NSStatusItem，给出可视入口：实时状态 + 一键退出。
// 退出仍走 shutdown(signal:)，保证虚拟屏按正常时序销毁。

final class StatusMenuTarget: NSObject, NSMenuItemValidation {
    @objc func quit() {
        Log.info("菜单栏请求退出")
        // 退出清理里会用嵌套 RunLoop 等采集停稳，排到 default 模式执行，
        // 等菜单 tracking 彻底退出后再开始，避免菜单挂在屏幕上等 5 秒。
        RunLoop.main.perform(inModes: [.default]) { shutdown(signal: SIGTERM) }
    }

    @objc func openPanel() {
        Log.info("菜单栏请求打开面板")
        showControlPanel()
    }

    /// 状态栏按钮点击：左键打开控制面板，右键（或 Control+左键）弹快捷菜单。
    @objc func handleClick(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        let ev = NSApp.currentEvent
        let rightClick = ev?.type == .rightMouseUp
            || (ev?.modifierFlags.contains(.control) ?? false)
        if rightClick, let menu = statusMenu {
            Log.info("菜单栏右键，弹菜单")
            button.highlight(true)
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: button.bounds.height + 4),
                       in: button)
            button.highlight(false)
            return
        }
        Log.info("菜单栏左键，打开控制面板")
        showControlPanel()
    }

    /// autoenablesItems 关掉后 AppKit 仍可能问一次，一律允许，
    /// 避免菜单项被判定 disabled：菜单照常弹出但点了没有反应。
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}

/// 菜单开关状态打点。菜单弹出/收起都写日志，
/// 用来区分「菜单没弹出」「弹出但点击没派发」「派发了但面板没显示」三种情况。
final class StatusMenuDelegate: NSObject, NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Log.info("菜单已弹出 autoenables=\(menu.autoenablesItems) items=\(menu.items.count)")
    }
    func menuDidClose(_ menu: NSMenu) {
        Log.info("菜单已收起")
    }
}

let statusMenuTarget = StatusMenuTarget()
let statusMenuDelegate = StatusMenuDelegate()
var statusItem: NSStatusItem?
var statusInfoItem: NSMenuItem?
var statusMenu: NSMenu?

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock 图标「退出」与系统/Apple Event 发起的退出都会走 -[NSApplication terminate:]，
    /// 默认直接 exit()，会绕过 shutdown()，把虚拟屏留在 WindowServer 里成为孤儿屏，
    /// 下次启动建屏失败。这里先取消这次退出，回主队列走完整清理流程。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.info("收到应用退出请求，开始清理")
        DispatchQueue.main.async {
            shutdown(signal: SIGTERM)
        }
        return .terminateCancel
    }
}

let appLifecycleDelegate = AppLifecycleDelegate()

func setupStatusBar() -> NSApplication {
    let app = NSApplication.shared
    app.delegate = appLifecycleDelegate
    app.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
        button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "SecDisplay")
        button.image?.isTemplate = true
        button.toolTip = "SecDisplay 发送端"
    }

    let menu = NSMenu()
    // 不让 AppKit 自动校验菜单项。命令行进程没有 mainMenu，
    // 校验路径一旦把项判成 disabled，菜单照常弹出但点击完全没反应。
    menu.autoenablesItems = false
    menu.delegate = statusMenuDelegate

    let info = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
    info.isEnabled = false
    menu.addItem(info)
    menu.addItem(.separator())

    let open = NSMenuItem(title: "打开面板…", action: #selector(StatusMenuTarget.openPanel), keyEquivalent: "o")
    open.target = statusMenuTarget
    open.isEnabled = true
    menu.addItem(open)
    menu.addItem(.separator())

    let quit = NSMenuItem(title: "退出 SecDisplay", action: #selector(StatusMenuTarget.quit), keyEquivalent: "q")
    quit.target = statusMenuTarget
    quit.isEnabled = true
    menu.addItem(quit)

    // 关键：不再把菜单挂到 item.menu 上。
    // 这个进程是裸命令行可执行文件，没有 bundle；status item 的自动菜单由
    // AppKit 的 menu-bar scene extension 托管（系统日志里只有
    // com.apple.menubar:menu-xpc-client 的会话激活，没有任何 action 派发），
    // 实测菜单能弹出、菜单项点了不触发。改成自己处理按钮点击 + NSMenu.popUp，
    // 走普通上下文菜单那条路径，不依赖 status item 的菜单会话。
    item.menu = nil
    if let button = item.button {
        button.target = statusMenuTarget
        button.action = #selector(StatusMenuTarget.handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    statusItem = item
    statusInfoItem = info
    statusMenu = menu
    if item.button != nil {
        Log.info("菜单栏图标已创建（右侧菜单栏，点击弹菜单）")
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
// 打印构建标记，用来判断跑的是不是旧包
if let rp = Bundle.main.resourcePath,
   let stamp = try? String(contentsOfFile: rp + "/build-stamp", encoding: .utf8) {
    Log.info("构建标记: \(stamp.trimmingCharacters(in: .whitespacesAndNewlines))")
} else {
    Log.info("构建标记: 无（命令行构建或旧包）")
}
// 等 statusApp.run() 启动主事件循环后再注册全局鼠标监视器与光标图像轮询，
// 避免在 NSApplication 初始化之前抢先建立 SkyLight 事件通道导致窗口点击失灵。
DispatchQueue.main.async {
    cursor.start()
    if !disableCursorImage {
        cursorImage.start()
    }
}

// 调试用：SECDISPLAY_SHOW_PANEL=1 启动后直接打开面板，便于不点菜单也能验证 UI。
if ProcessInfo.processInfo.environment["SECDISPLAY_SHOW_PANEL"] == "1" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Log.info("SECDISPLAY_SHOW_PANEL=1，自动打开面板")
        showControlPanel()
    }
}
statusApp.run()
