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
import Carbon
import SwiftUI   // 调试导出控制面板快照时用 NSHostingView

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
// Apple vendor 0x0610 + 16:10 Cinema Display 槽位 0x9221（该产品槽位不覆写 DisplayProductName，
// 因此在 macOS 显示器/控制中心里既保留 "SecDisplay" 名称，又具备苹果显示器图标而非通用黑框图标），
// 再配合专属序列号 0x53445344('SDSD') 精确锚定，绝不与真实物理显示器冲突。
let kVDVendorID: UInt32  = 0x0610
let kVDProductID: UInt32 = 0x9221
let kVDSerialNum: UInt32 = 0x53445344

// 升级前的旧身份（0xEEEE/0x5344/1 与 0x2B3/0x1000/1）。异常退出可能留下这种残留屏，
// 仅用于残留检测与告警，绝不作为采集目标，避免把旧残留当成自己的屏抓进去。
let kLegacyVDVendorID: UInt32  = 0xEEEE
let kLegacyVDProductID: UInt32 = 0x5344
let kLegacyVDSerialNum: UInt32 = 0x0001
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
    (CGDisplayVendorNumber(id) == kLegacyVDVendorID &&
     CGDisplayModelNumber(id) == kLegacyVDProductID &&
     CGDisplaySerialNumber(id) == kLegacyVDSerialNum) ||
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

/// 进程启动时刻（CFAbsoluteTime），面板用来算运行时长。
let appStartTime = CFAbsoluteTimeGetCurrent()

/// 键盘注入器。连接重建时从这里 reset，避免 Ctrl/Cmd 卡在按下态。
nonisolated(unsafe) var gKeyboard: KeyboardInjector?
/// 鼠标注入器。断连时同样要清，否则按住左键时对端消失会让 Mac 一直保持按下态。
nonisolated(unsafe) var gMouse: InputInjector?
/// 编码器。断连时从这里释放保留的最后一帧（整帧 7.4MB，断连后没必要钉着）。
nonisolated(unsafe) var gEncoder: Encoder?

/// 清空输入注入状态并补发残留的 keyUp / mouseUp。
/// 连接建立与断开都要调：事件是投到 .cghidEventTap 的，系统 HID 层的
/// 按下状态由投出去的事件驱动，只清内部记账等于一直按着。
func resetInjectionState() {
    gKeyboard?.reset()
    gMouse?.resetButtons()
    DispatchQueue.main.async {
        kvmPassthrough.setActive(false, notifyPeer: false)
    }
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
        displayID = 0
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
nonisolated(unsafe) var onDisplayModeReconfig: (() -> Void)? = nil

private func mirrorReconfigCallback(_ display: CGDirectDisplayID,
                                    _ flags: CGDisplayChangeSummaryFlags,
                                    _ userInfo: UnsafeMutableRawPointer?) {
    // 屏增删标志可能只出现在 begin 回调里，先置位再过滤 begin。
    if flags.contains(.addFlag) || flags.contains(.removeFlag) {
        gCaptureRebuildRequested = true
    }
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        MirrorGuard.release("显示重配置")
        onDisplayModeReconfig?()
    }
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
    private var width: Int32
    private var height: Int32
    private var bitrate: Int
    private var captureHz: Double
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
        guard let s = createSession(width: width, height: height, bitrate: bitrate, captureHz: captureHz) else {
            return false
        }
        session = s
        return true
    }

    private func createSession(width w: Int32, height h: Int32, bitrate br: Int, captureHz hz: Double) -> VTCompressionSession? {
        var spec: [String: Any] = [:]
        let noLowLat = ProcessInfo.processInfo.environment["SECDISPLAY_NOLOWLAT"] == "1"
        if !noLowLat {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
        }
        let attrs: [String: Any] = [
            // 与采集格式保持一致，避免 VT 再做一次全屏色彩转换。
            // 由 pixelFormatChoice 决定（环境变量或 bundle 内 pixfmt 文件）。
            kCVPixelBufferPixelFormatTypeKey as String:
                (pixelFormatChoice == "420v"
                    ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    : kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
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
        var newSession: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: w, height: h,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil, outputCallback: cb,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &newSession)
        guard st == noErr, let s = newSession else {
            Log.info("编码器创建失败 \(st)"); return nil
        }
        let env = ProcessInfo.processInfo.environment
        let variant = env["SECDISPLAY_ENC"] ?? "A"

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: hz))
        let gop = Int(ProcessInfo.processInfo.environment["SECDISPLAY_GOP"] ?? "") ?? 3000
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gop as CFNumber)

        switch variant {
        case "B":
            break
        case "C":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        case "D":
            let limits: [NSNumber] = [NSNumber(value: br / 8), NSNumber(value: 1.0)]
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        case "E":
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        default:
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: br as CFNumber)
            VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        }

        let stPrim = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries,
                                          value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        let stTrans = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_TransferFunction,
                                           value: kCVImageBufferTransferFunction_sRGB)
        let stMat = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                         value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if stPrim != noErr || stTrans != noErr || stMat != noErr {
            Log.info("警告: 编码器色彩属性设置未完全生效 prim=\(stPrim) trans=\(stTrans) mat=\(stMat)")
        }

        VTCompressionSessionPrepareToEncodeFrames(s)
        Log.info("编码参数方案 \(variant)")
        return s
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
        encodeInternal(pb, captureTimeMicros: captureTimeMicros, updateLast: true)
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
        encodeInternal(pb, captureTimeMicros: UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000), updateLast: false)
    }

    /// 串行化编码调用。采集线程和关键帧补发可能并发进来，
    /// frameSeq 自增不是原子的，并发会产出重复 PTS。
    private let encodeLock = NSLock()

    /// 断开时释放保留的最后一帧。整帧 2880x1800 即使改 YUV 也有 7.4MB，
    /// 断连后一直钉着没有意义（下次连上必然会有新帧）。
    func releaseLastFrame() {
        lastBufferLock.lock()
        lastPixelBuffer = nil
        lastBufferLock.unlock()
    }

    private func encodeInternal(_ pb: CVPixelBuffer, captureTimeMicros: UInt64, updateLast: Bool) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        guard let s = session else { return }
        guard CVPixelBufferGetWidth(pb) == Int(width) && CVPixelBufferGetHeight(pb) == Int(height) else { return }
        if updateLast {
            lastBufferLock.lock()
            lastPixelBuffer = pb
            lastBufferLock.unlock()
        }
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

        // 420v（VideoRange YUV）补齐像素缓冲色彩附件，确保与会话 VUI 一致
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            if CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) == nil {
                CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                                      kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                                      kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey,
                                      kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
        }

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

    /// 虚拟屏在系统设置中切换分辨率时，先新建会话再替换旧会话，失败时原编码器完整保留
    func reconfigure(width: Int, height: Int, bitrateMbps: Int, captureHz: Double) -> Bool {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        let newW = Int32(width)
        let newH = Int32(height)
        let newBr = bitrateMbps * 1_000_000
        let newHz = max(1, captureHz)
        guard let next = createSession(width: newW, height: newH, bitrate: newBr, captureHz: newHz) else {
            return false
        }
        if let old = session {
            VTCompressionSessionCompleteFrames(old, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(old)
        }
        session = next
        self.width = newW
        self.height = newH
        self.bitrate = newBr
        self.captureHz = newHz
        self.currentMbps = bitrateMbps
        releaseLastFrame()
        return true
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

// MARK: - 采集（SkyLight 合成抓屏为主，SCScreenshotManager 作兜底）
//
// 根因说明：
//   1. macOS 27 上 SCStream / CGDisplayStream 采集 CGVirtualDisplay 会误抓主屏内容。
//   2. SCScreenshotManager 每帧经 replayd 向 tccd 发送 1 次 preflight=no + 2 次 preflight=yes
//      校验；4 路 50fps 轮询很快耗尽 root tccd 的 256 个文件描述符上限（100024 EMFILE），
//      导致 tccd 偶发报 -3801 / Code=1004 并反复弹出「请求屏幕录制权限」系统弹窗。
//   3. SkyLight 的 SLSHWCaptureWindowList 直接从 WindowServer 合成并抓取虚拟屏窗口列表，
//      不经过 replayd preflight=no 弹窗链路。但它返回的合成图尺寸取决于当帧窗口列表的
//      并集包围盒：实测 120 帧里有 16 帧只合成出菜单栏条带（2880x60）。旧实现盲取
//      arr[0] 再强行拉伸到 2880x1800，画面在「正常桌面」与「放大的菜单栏」之间跳，
//      H.264 帧间预测把这种跳变渲染成拖影 / 残影 / 双指针观感。替代 API 实测：
//      SLWindowListCreateImageFromArray 与 CGDisplayCreateImage 在 macOS 27 上都只返回
//      纯灰图（diversity=1），不可用。因此这里只接受尺寸严格匹配的整屏帧，条带帧
//      重新枚举窗口列表重试，全失败则丢帧（绝不拉伸错帧）。
//   保留 SCScreenshotManager 作为回退（SECDISPLAY_CAPTURE=sck 或 420v 模式时使用）。
private enum SkyLightCapture {
    typealias MainConnFn = @convention(c) () -> UInt32
    typealias HWCWL = @convention(c) (UInt32, UnsafePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?

    private static let syms: (cidFn: MainConnFn, hwFn: HWCWL)? = {
        let rtld = UnsafeMutableRawPointer(bitPattern: -2)
        var pCid = dlsym(rtld, "SLSMainConnectionID")
        var pHw = dlsym(rtld, "SLSHWCaptureWindowList")
        if pCid == nil || pHw == nil,
           let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) {
            pCid = pCid ?? dlsym(h, "SLSMainConnectionID")
            pHw = pHw ?? dlsym(h, "SLSHWCaptureWindowList")
        }
        guard let c = pCid, let f = pHw else { return nil }
        return (unsafeBitCast(c, to: MainConnFn.self), unsafeBitCast(f, to: HWCWL.self))
    }()

    static var isAvailable: Bool { syms != nil }

    /// 采集结果：尺寸合格的整屏帧 / 条带帧（需重试或丢弃）/ 真的抓不到。
    enum Result {
        case frame(CVPixelBuffer)
        case wrongSize(w: Int, h: Int)
        case unavailable
    }
    /// 累计丢弃的条带帧数，供面板/日志确认修复是否生效。
    private static let badFrameLock = NSLock()
    private static var _badFrames = 0
    static var badFrameCount: Int { badFrameLock.lock(); defer { badFrameLock.unlock() }; return _badFrames }
    static func noteBadFrame() { badFrameLock.lock(); _badFrames += 1; badFrameLock.unlock() }

    // 连续异尺寸状态（跨 worker 共享，需加锁）。
    // 用于逃生阀：同一非目标尺寸持续出现，说明不是偶发条带帧，而是虚拟屏
    // 分辨率与目标暂时不一致（切档过渡、1x 模式等），此时缩放接受避免画面冻结。
    private static let sizeStateLock = NSLock()
    private static var _consecWrong = 0
    private static var _lastWrongW = 0
    private static var _lastWrongH = 0
    /// 逃生阀启用日志的节流时间戳，与上面的状态共用 sizeStateLock。
    private static var _lastEscalateLogAt: CFAbsoluteTime = 0
    private static func wrongSizeState() -> (consec: Int, w: Int, h: Int) {
        sizeStateLock.lock(); defer { sizeStateLock.unlock() }
        return (_consecWrong, _lastWrongW, _lastWrongH)
    }
    private static func noteWrongSize(_ w: Int, _ h: Int) {
        sizeStateLock.lock(); defer { sizeStateLock.unlock() }
        if w == _lastWrongW && h == _lastWrongH { _consecWrong += 1 }
        else { _lastWrongW = w; _lastWrongH = h; _consecWrong = 1 }
    }
    private static func resetWrongSize() {
        sizeStateLock.lock(); _consecWrong = 0; _lastWrongW = 0; _lastWrongH = 0; sizeStateLock.unlock()
    }

    static func captureFrame(_ vdID: CGDirectDisplayID, targetW: Int, targetH: Int) -> Result {
        guard let syms else { return .unavailable }
        let bounds = CGDisplayBounds(vdID)
        guard bounds.width > 1, bounds.height > 1 else { return .unavailable }
        let cid = syms.cidFn()
        let targetAspect = Double(targetW) / Double(targetH)
        let (consec, lastW, lastH) = wrongSizeState()
        // 最多尝试 2 次：条带帧多是当帧窗口列表的包围盒暂时只有菜单栏，
        // 重新枚举窗口列表再抓一次通常就能拿到整屏合成图，减少丢帧。
        var lastWrongSize = (w: 0, h: 0)
        for _ in 0..<2 {
            guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
                return .unavailable
            }
            var wids: [UInt32] = []
            wids.reserveCapacity(16)
            for info in infos {
                guard let wid = info[kCGWindowNumber as String] as? UInt32,
                      let bDict = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: bDict as CFDictionary),
                      rect.width > 0, rect.height > 0,
                      rect.intersects(bounds) else { continue }
                let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
                if alpha <= 0.01 { continue }
                wids.append(wid)
            }
            guard !wids.isEmpty else { return .unavailable }
            // 0x800 = kCGSCaptureIgnoreGlobalClipShape, 0x100 = 2x HiDPI 最高分辨率
            guard let arr = wids.withUnsafeBufferPointer({ buf in
                syms.hwFn(cid, buf.baseAddress!, UInt32(buf.count), 0x800 | 0x100)?.takeRetainedValue()
            }) else { return .unavailable }
            let result = withExtendedLifetime(arr) { () -> Result in
                let n = CFArrayGetCount(arr)
                // 空数组是 WindowServer 侧合成失败，属抓取故障，不能当条带帧。
                guard n > 0 else { return .unavailable }
                // 数组里可能同时含整屏合成图与单个窗口图；挑尺寸严格等于目标的整屏帧。
                // 绝不把 2880x60 这类条带拉伸成整屏，否则画面跳变经 H.264 变成拖影。
                var picked: CGImage? = nil
                var pickedArea = 0
                var fallback: CGImage? = nil
                var fallbackArea = 0
                var anySize: (Int, Int)? = nil
                for i in 0..<n {
                    guard let raw = CFArrayGetValueAtIndex(arr, i) else { continue }
                    let img = Unmanaged<CGImage>.fromOpaque(raw).takeUnretainedValue()
                    let iw = img.width, ih = img.height
                    if anySize == nil { anySize = (iw, ih) }
                    let area = iw * ih
                    if iw == targetW && ih == targetH {
                        // 精确尺寸可能有多个（合成图与正好铺满的窗口），取面积最大者，
                        // 面积相同保留先出现的（合成图通常在首位）。
                        if area > pickedArea { picked = img; pickedArea = area }
                    } else if ih > 0,
                              abs((Double(iw) / Double(ih)) / targetAspect - 1.0) <= 0.02,
                              iw >= targetW / 2, ih >= targetH / 2 {
                        // 逃生阀候选：纵横比与目标一致且面积不小于目标 1/4 的帧。
                        // 条带帧（如 2880x60）纵横比极端，不会命中。
                        if area > fallbackArea { fallback = img; fallbackArea = area }
                    }
                }
                if let img = picked {
                    resetWrongSize()
                    guard let pb = makePixelBuffer(from: img, targetW: targetW, targetH: targetH) else {
                        return .unavailable
                    }
                    return .frame(pb)
                }
                // 逃生阀：同一非目标尺寸持续 ≥30 帧，用纵横比匹配的候选缩放接受，
                // 避免虚拟屏分辨率与目标暂时不一致时画面长期冻结。
                // 接受后不清零计数，保持缩放模式连续出帧；只有精确尺寸分支才清零。
                // 若在这里清零，会退化成「每 31 帧才放行 1 帧」，等同周期性跳变。
                let sz = anySize ?? (0, 0)
                if consec >= 30, sz.0 == lastW, sz.1 == lastH, let img = fallback {
                    let nowEsc = CFAbsoluteTimeGetCurrent()
                    var shouldLog = false
                    sizeStateLock.lock()
                    if nowEsc - _lastEscalateLogAt > 5.0 {
                        _lastEscalateLogAt = nowEsc
                        shouldLog = true
                    }
                    sizeStateLock.unlock()
                    if shouldLog {
                        Log.info("采集尺寸持续不符 \(sz.0)x\(sz.1) != \(targetW)x\(targetH)，已启用缩放接受")
                    }
                    guard let pb = makePixelBuffer(from: img, targetW: targetW, targetH: targetH) else {
                        return .unavailable
                    }
                    return .frame(pb)
                }
                return .wrongSize(w: sz.0, h: sz.1)
            }
            // 抓到整屏帧或真正的抓取故障都立即返回；只有条带帧才重试。
            if case .wrongSize(let w, let h) = result {
                // 保留尺寸供重试耗尽后回传，让外层记录与告警有真实尺寸。
                lastWrongSize = (w, h)
                continue
            }
            return result
        }
        // 两次都是条带帧：按条带帧返回，交给调用方丢帧重抓。
        // 不返回 .unavailable，避免被计入采集失败、触发误回退。
        noteWrongSize(lastWrongSize.w, lastWrongSize.h)
        return .wrongSize(w: lastWrongSize.w, h: lastWrongSize.h)
    }
}

final class ScreenshotCapture {
    let encoder: Encoder
    private let cfg: Config
    private let displayIDProvider: () -> CGDirectDisplayID

    var captured = 0
    var capLatSum: Double = 0
    var capLatCount = 0
    var capLatMax: Double = 0
    var lastFrameTime: CFAbsoluteTime = 0
    /// 采集首帧实测到的像素格式（四字符码原始值）。面板用它显示真实通道，
    /// 而不是配置里请求的格式 —— SCK 可能忽略 pixelFormat 仍给 BGRA，
    /// 那种情况下配置值会骗人。
    ///
    /// 存 UInt32 而不是 String：写入方是 worker（encodeQueue 内），读取方是
    /// 主线程面板。String 的赋值与读取都不是原子操作，可能读到半写状态并在
    /// retain 时崩溃。格式化交给面板做，0 表示还没采到帧。
    private(set) var actualFormatCode: UInt32 = 0

    private let encodeQueue = DispatchQueue(label: "SecDisplay.encode")
    private var cachedContent: SCShareableContent?
    private var cachedAt: CFAbsoluteTime = 0
    private var contentGen: Int = 0
    private var inFlightContentTask: Task<SCShareableContent, Error>?
    private var inFlightContentGen: Int = 0
    private var lastMissingDisplayRefreshAt: CFAbsoluteTime = 0
    private var consecutiveCode1004 = 0
    private var firstCode1004At: CFAbsoluteTime = 0
    private var useSkyLight: Bool = (ProcessInfo.processInfo.environment["SECDISPLAY_CAPTURE"] != "sck"
                                     && pixelFormatChoice != "420v"
                                     && SkyLightCapture.isAvailable)
    private var consecutiveSkyLightFails = 0
    private var lastSkyLightGrabAt: CFAbsoluteTime = 0
    var isUsingSkyLight: Bool { withRawLock { useSkyLight } }
    var captureBackendLabel: String { isUsingSkyLight ? "SLSHW · 2 路" : "SCK · 4 路" }
    private var lastDumpAt: CFAbsoluteTime = 0
    private var dumpSeq = 0
    private var lastErrorLogAt: CFAbsoluteTime = 0
    private var supervisor: DispatchSourceTimer?
    private var lastSupervisorCount = -1
    private var lastSupervisorAt: CFAbsoluteTime = 0
    private var loggedFirstFrame = false
    private var lastSizeWarnAt: CFAbsoluteTime = 0
    /// 条带帧丢弃日志的独立节流时间戳。由多路 worker 共享，
    /// 必须与 lastSizeWarnAt 分开并走 withRawLock，避免跨 worker 数据竞争。
    private var lastBadSizeWarnAt: CFAbsoluteTime = 0
    /// worker 代次。spawnWorkers 每次自增，旧代次的循环看到代次变了就退出。
    /// 原来这里是直接再起 4 个 Task 而不停旧的，看护每触发一次线程数与
    /// 采集缓冲就翻一倍（每个 worker 同时持有 CGImage + CVPixelBuffer 约 40MB）。
    /// 写方是 supervisor 队列，读方是 worker 任务，用锁保护。
    private let genLock = NSLock()
    private var _running = false
    private var _permissionPaused = false
    private var _runtimeDenyCount = 0
    private var _startInProgress = false
    private var _startInProgressSince: CFAbsoluteTime = 0
    private var _startToken = 0
    private var _lastManualResumeAt: CFAbsoluteTime = 0
    private var _workerGen = 0
    private var _stopRequested = false
    private var running: Bool {
        get { genLock.lock(); defer { genLock.unlock() }; return _running }
        set { genLock.lock(); _running = newValue; genLock.unlock() }
    }
    private var permissionPaused: Bool {
        get { genLock.lock(); defer { genLock.unlock() }; return _permissionPaused }
        set { genLock.lock(); _permissionPaused = newValue; genLock.unlock() }
    }
    private var runtimeDenyCount: Int {
        genLock.lock(); defer { genLock.unlock() }
        return _runtimeDenyCount
    }
    private func withGenLock<T>(_ body: () -> T) -> T {
        genLock.lock(); defer { genLock.unlock() }
        return body()
    }
    private var workerGen: Int {
        genLock.lock(); defer { genLock.unlock() }
        return _workerGen
    }
    private var stopRequested: Bool {
        genLock.lock(); defer { genLock.unlock() }
        return _stopRequested
    }
    var isStopRequested: Bool { stopRequested }
    /// 自增代次并返回新值
    private func bumpWorkerGen() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        _workerGen &+= 1
        return _workerGen
    }
    /// 连续异常采样的次数（每 3 秒一个采样）。只用于决定退避间隔，
    /// 和「重启了几次」不是一回事 —— 退避期间采样照样在涨但不重启。
    private var slowStreak = 0
    /// 自上次恢复以来真正重启的次数。硬上限按这个算。
    private var restartCount = 0
    private var lastRestartAt: CFAbsoluteTime = 0
    /// 面板展示用：自上次恢复以来真正重启的次数。
    /// 与 supervisor 队列共享，走 genLock 保护。
    var captureRestartCount: Int {
        genLock.lock(); defer { genLock.unlock() }
        return restartCount
    }
    private func bumpSlowStreak() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        slowStreak += 1
        return slowStreak
    }
    private func bumpRestartCount() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        restartCount += 1
        return restartCount
    }
    /// 采集恢复正常时清零全部计数
    private func resetCaptureCounters() {
        genLock.lock(); slowStreak = 0; restartCount = 0; genLock.unlock()
    }
    /// 连续失败的重启上限。超过就停手，等用户重启进程 ——
    /// 这一条针对「采集彻底死掉」：退避只降低频率，卡在 await 里的 Task
    /// 永不返回，每 30 秒仍会净增 4 个线程。
    private let restartHardCap = 20
    /// 进程生命周期内 spawnWorkers 的总次数，**不随恢复清零**。
    ///
    /// 为什么需要它：连续失败上限会在采集恢复正常时归零，而「休眠 → 唤醒」
    /// 恰好是「先失败一次、随后恢复正常」的模式。屏保每分钟休眠一次时，
    /// 每次唤醒都会新建 4 个 worker，休眠期间卡住的旧 worker 永不返回，
    /// 连续失败计数却永远到不了 20。一天下来就是几千个僵尸线程。
    /// 这里按代次总量设一个绝对上限，与是否恢复无关。
    private let spawnHardCap = 300
    private var totalSpawns = 0
    private func bumpTotalSpawns() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        totalSpawns += 1
        return totalSpawns
    }
    private var totalSpawnCount: Int {
        genLock.lock(); defer { genLock.unlock() }
        return totalSpawns
    }
    /// 放弃自动重启后，日志降频到 5 分钟一条
    private var lastGiveUpLogAt: CFAbsoluteTime = 0
    /// 原始采集计数：capture 一返回就自增，不经过 encodeQueue。
    /// 看护要用它判断「采集本身」是否健康；captured 是在 encodeQueue 里
    /// encode 之后才自增的，包含编码与排队时间，VT 变慢时会被误判成采集卡死。
    private let rawLock = NSLock()
    private var _capturedRaw = 0
    var capturedRaw: Int {
        rawLock.lock(); defer { rawLock.unlock() }
        return _capturedRaw
    }
    private func bumpCapturedRaw() {
        rawLock.lock(); _capturedRaw &+= 1; rawLock.unlock()
    }
    /// 同步作用域加锁。NSLock 的 lock/unlock 在 async 上下文里会被
    /// Swift 6 判为不可用，包一层同步函数就能在 async 函数里安全调用。
    private func withRawLock<T>(_ body: () -> T) -> T {
        rawLock.lock(); defer { rawLock.unlock() }
        return body()
    }
    /// 显示器休眠只打一次日志，避免每 3 秒刷屏
    private var loggedDisplayAsleep = false
    /// 上一帧内容的采样指纹。用来识别「帧还在来、但画面不再更新」——
    /// SCScreenshotManager 跑约 30 秒后偶尔会开始返回陈旧内容，
    /// 此时 captured 仍在增长，现有看护只看计数，抓不到这种情况。
    private var lastFrameHash: UInt64 = 0
    private var unchangedSince: CFAbsoluteTime = 0
    private var lastFreezeLogAt: CFAbsoluteTime = 0

    init(encoder: Encoder, cfg: Config, displayID: @escaping () -> CGDirectDisplayID) {
        self.encoder = encoder
        self.cfg = cfg
        self.displayIDProvider = displayID
    }

    func start() async throws {
        let myToken: Int? = withGenLock {
            if _stopRequested || _startInProgress || supervisor != nil {
                return nil
            }
            _startToken &+= 1
            _startInProgress = true
            _startInProgressSince = CFAbsoluteTimeGetCurrent()
            return _startToken
        }
        guard let myToken else { return }
        defer {
            withGenLock {
                if _startToken == myToken {
                    _startInProgress = false
                    _startInProgressSince = 0
                }
            }
        }
        if !isUsingSkyLight {
            let content = try await currentContent(forceRefresh: true)
            // await 期间可能已经收到退出请求，或已被超时的恢复流程接管了新代次，必须放弃旧启动
            let stillValidStart = withGenLock {
                !_stopRequested && _startToken == myToken && supervisor == nil
            }
            guard stillValidStart else {
                Log.info("采集启动已取消或被新代次接管，放弃本次启动")
                return
            }
            guard content.displays.contains(where: { isOurVirtualDisplay($0.displayID) }) else {
                let avail = content.displays.map {
                    String(format: "id=%u vendor=0x%x", $0.displayID, CGDisplayVendorNumber($0.displayID))
                }
                throw NSError(domain: "Capture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "找不到 SecDisplay 虚拟屏，当前: \(avail.joined(separator: ", "))"
                ])
            }
        } else {
            let vdID = displayIDProvider()
            guard vdID != 0, isOurVirtualDisplay(vdID), CGDisplayBounds(vdID).width > 1 else {
                throw NSError(domain: "Capture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "找不到有效的 SecDisplay 虚拟屏 id=\(vdID)"
                ])
            }
        }
        running = true
        spawnWorkers()
        // 看护：SCScreenshotManager 并发轮询有两个已知故障模式
        //   1. 整体卡住：continuation 永不 resume，captured 不再增长
        //   2. 半卡死：偶尔回一帧，但远低于目标帧率
        // 所以判据用「实测帧率 < 目标的三分之一」，不是「严格 0 帧」。
        //
        // 关键：卡在 await 里的 Task 不会返回，代次对它们无效 —— 每次重启都是
        // 净增 4 个僵尸线程。实测日志里代次一路涨到 104，等于 400 多个线程。
        // 因此这里必须限次退避，不能无限重启。
        let sup = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SecDisplay.capture.sup"))
        sup.schedule(deadline: .now() + 3, repeating: 3)
        sup.setEventHandler { [weak self] in
            guard let self else { return }
            let isStop = self.stopRequested
            guard !isStop else { return }
            if self.permissionPaused || isScreenCaptureDenied() {
                // 仅在尚未发生过运行期拒绝/1004 暂停（runtimeDenyCount == 0）时自动恢复（如启动后用户在设置勾选）；
                // 一旦运行期触发过权限拒绝/1004 暂停（runtimeDenyCount >= 1），绝不自动重拉 worker，
                // 避免 CGPreflightScreenCaptureAccess() 毫秒级抖动导致无限循环弹窗。
                if self.runtimeDenyCount == 0 && CGPreflightScreenCaptureAccess() {
                    self.permissionPaused = false
                    setScreenCaptureDenied(false)
                    self.resetCaptureCounters()
                    if self.spawnWorkers() {
                        Log.info("屏幕录制权限已就绪，自动恢复采集")
                    }
                }
                return
            }
            guard self.running else { return }
            let now = CFAbsoluteTimeGetCurrent()

            // 显示器睡眠时采集本来就拿不到帧，不是故障。此时既不判停滞也不重启，
            // 唤醒后自动恢复。没有这段的话，用户离开屏幕休眠会触发无限重启。
            let vdID = self.displayIDProvider()
            if CGDisplayIsAsleep(vdID) != 0 {
                if !self.loggedDisplayAsleep {
                    self.loggedDisplayAsleep = true
                    Log.info("显示器已休眠，暂停采集判活（唤醒后自动恢复）")
                }
                self.lastSupervisorCount = self.capturedRaw
                self.lastSupervisorAt = now
                return
            }
            if self.loggedDisplayAsleep {
                self.loggedDisplayAsleep = false
                // 休眠期间 worker 多半已卡在 await 里，唤醒后不会自己恢复。
                // 直接重建一次比等 3 秒再判「异常」更干净。
                //
                // 唤醒本身不算失败，所以清零连续失败计数；但「线程重建总量」
                // 是另一条独立的绝对上限（spawnHardCap），屏保每分钟休眠一次
                // 时也不会无界堆线程。
                self.resetCaptureCounters()
                if self.spawnWorkers() {
                    Log.info("显示器已唤醒，重建采集工作线程")
                } else {
                    self.lastSupervisorCount = self.capturedRaw
                    self.lastSupervisorAt = now
                }
                return
            }

            // capturedRaw 只读一次：读两次之间 worker 可能又自增，
            // delta 和基准就不是同一时刻的快照了。
            let rawNow = self.capturedRaw
            let dt = now - self.lastSupervisorAt
            let delta = rawNow - self.lastSupervisorCount
            self.lastSupervisorCount = rawNow
            self.lastSupervisorAt = now
            guard dt > 0.5 else { return }

            let measuredFps = Double(delta) / dt
            // 三分之一容忍：目标 50fps 时低于 ~17fps 才判为异常，
            // 避免正常的采集抖动被当成停滞。
            let tooSlow = measuredFps < self.cfg.captureHz / 3.0

            if tooSlow {
                let slow = self.bumpSlowStreak()
                // 硬上限：真卡死时 worker 永不返回，重启只会堆线程。
                // 到这里就彻底停手，把「继续重启」换成一条明确的告警。
                // 注意判据是「真正重启的次数」，不是异常采样次数。
                if self.captureRestartCount >= self.restartHardCap {
                    if now - self.lastGiveUpLogAt > 300.0 {
                        self.lastGiveUpLogAt = now
                        Log.info(String(format: "采集已连续重启 %d 次仍未恢复（%.1ffps），停止自动重启。请退出并重开 SecDisplay",
                                        self.captureRestartCount, measuredFps))
                    }
                    return
                }
                // 退避：前 4 次每 3 秒试一次；之后拉长到 30 秒一次。
                if slow > 4 && now - self.lastRestartAt < 30.0 {
                    return
                }
                self.lastRestartAt = now
                // 先确认真的拉起了再计数、再记日志，避免出现「日志说重启了
                // 第 21 次，实际因为总量上限没拉起来」这种自相矛盾。
                guard self.spawnWorkers() else { return }
                let n = self.bumpRestartCount()
                // 每次真正重启都记一行。退避后重启频率已降到 30 秒一次，
                // 不会刷屏；而这里恰恰是「画面一直不动」时唯一的线索，
                // 之前用 %10 抽样反而会让它长期不出现。
                if n <= 4 {
                    Log.info(String(format: "截图采集异常（%.1ffps，目标 %.0ffps，第 %d 次重启）",
                                    measuredFps, self.cfg.captureHz, n))
                } else {
                    Log.info(String(format: "截图采集持续异常（%.1ffps，已重启 %d 次），已降为 30 秒重试一次。若画面不动请重启发送端",
                                    measuredFps, n))
                }
            } else {
                if self.captureRestartCount > 0 {
                    Log.info("截图采集已恢复正常（\(String(format: "%.0f", measuredFps))fps）")
                    self.resetCaptureCounters()
                }
            }
        }
        let installed = withGenLock { () -> Bool in
            if _stopRequested || _startToken != myToken || supervisor != nil { return false }
            supervisor = sup
            return true
        }
        guard installed else {
            sup.cancel()
            return
        }
        sup.resume()
    }

    /// 拉起采集工作线程。返回 false 表示已到总量上限，没有真的拉起。
    @discardableResult
    private func spawnWorkers() -> Bool {
        // 防御：stop() 可能在 start() 的 await 之后、这里之前到达。
        // 顶层代码是 @MainActor 隔离的，实际窗口很小，但不该依赖这个隐式前提。
        guard !stopRequested else {
            Log.info("已请求停止，跳过启动采集工作线程")
            return false
        }
        // 绝对上限：卡在 await 里的 Task 永不返回，代次对它们无效。
        // 这里按代次总量兜底，与「连续失败」是否已恢复无关。
        let done = totalSpawnCount
        if done >= spawnHardCap {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastGiveUpLogAt > 300.0 {
                lastGiveUpLogAt = now
                Log.info("采集线程已累计重建 \(done) 次，停止重建。请退出并重开 SecDisplay")
            }
            return false
        }
        let usingSL = isUsingSkyLight
        let workers = usingSL ? 2 : 4
        let total = bumpTotalSpawns()
        let gen = bumpWorkerGen()
        lastSupervisorAt = CFAbsoluteTimeGetCurrent()
        lastSupervisorCount = capturedRaw
        Log.info("采集通道: \(usingSL ? "SkyLight SLSHWCaptureWindowList" : "SCScreenshotManager") 轮询，\(workers) 路并发（代次 \(gen)，累计第 \(total) 次）")
        for i in 0..<workers {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop(index: i, gen: gen)
            }
        }
        return true
    }

    func pauseForPermission() {
        genLock.lock()
        _permissionPaused = true
        _runtimeDenyCount &+= 1
        _workerGen &+= 1
        genLock.unlock()
    }

    /// 返回 nil 表示已恢复或已触发启动；非 nil 为界面可直接展示的阻断原因。
    @discardableResult
    func resumeAfterPermissionGranted() -> String? {
        guard !stopRequested else { return "采集器正在停止，请点「重启应用」" }
        guard CGPreflightScreenCaptureAccess() else {
            setScreenCaptureDenied(true)
            Log.info("屏幕录制权限仍未就绪，请在系统设置勾选 SecDisplay 后再试")
            return "仍未检测到录屏授权，请在系统设置勾选 SecDisplay 后再试"
        }
        let now = CFAbsoluteTimeGetCurrent()
        enum Action { case throttled, respawn, startNew, waiting }
        var clearStuckInFlight = false
        let action: Action = withGenLock {
            if now - _lastManualResumeAt < 1.0 {
                return .throttled
            }
            _lastManualResumeAt = now
            let hasSupervisor = (supervisor != nil)
            if _startInProgress && _startInProgressSince > 0 && now - _startInProgressSince > 6.0 {
                _startToken &+= 1
                _startInProgress = false
                _startInProgressSince = 0
                clearStuckInFlight = true
            }
            _permissionPaused = false
            if hasSupervisor {
                _running = true
                return .respawn
            }
            return _startInProgress ? .waiting : .startNew
        }
        if action == .throttled {
            return "点击过于频繁，请 1 秒后再试"
        }
        setScreenCaptureDenied(false)
        resetCaptureCounters()
        withRawLock {
            contentGen &+= 1
            cachedContent = nil
            cachedAt = 0
            if clearStuckInFlight { inFlightContentTask = nil }
            consecutiveCode1004 = 0
            firstCode1004At = 0
        }
        switch action {
        case .throttled:
            return "点击过于频繁，请 1 秒后再试"
        case .respawn:
            if spawnWorkers() {
                Log.info("已手动恢复屏幕录制采集")
                return nil
            }
            setScreenCaptureDenied(true)
            Log.info("采集线程已达重建上限，请点击「重启应用」恢复")
            return "采集线程已达重建上限，请点「重启应用」"
        case .startNew:
            Log.info("已手动触发启动屏幕录制采集")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.start()
                } catch {
                    let nsErr = error as NSError
                    let isPerm = (nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
                                  nsErr.code == SCStreamError.userDeclined.rawValue) ||
                                 !CGPreflightScreenCaptureAccess()
                    Log.info("手动恢复启动采集失败: \(error)")
                    if isPerm {
                        setScreenCaptureDenied(true)
                    } else {
                        setTccConflictWarning("采集启动失败（\(error.localizedDescription)），请点「重启应用」")
                    }
                }
            }
            return nil
        case .waiting:
            Log.info("屏幕录制权限已就绪，正在等待采集启动")
            return nil
        }
    }

    /// 停止采集。这是同步函数（只置标志 + 自增代次），调用方不需要
    /// 放到 Task 里 —— 放进去反而让「采集是否停下」取决于调度器。
    func stop() {
        genLock.lock()
        _stopRequested = true
        _running = false
        _permissionPaused = false
        _workerGen &+= 1
        let sup = supervisor
        supervisor = nil
        genLock.unlock()
        // 停掉看护，避免清理过程中还在判定停滞
        sup?.cancel()
    }

    /// 当前 worker 是否仍应继续（代次未变且未请求停止）。
    /// 借 genLock 建立内存屏障，避免 stop() 的写入对 worker 不可见。
    private func stillCurrent(gen: Int) -> Bool {
        genLock.lock(); defer { genLock.unlock() }
        return _running && _workerGen == gen && !_stopRequested && !_permissionPaused
    }

    private func loop(index: Int, gen: Int) async {
        while stillCurrent(gen: gen) {
            var t0 = CFAbsoluteTimeGetCurrent()
            do {
                let wantYUV = pixelFormatChoice == "420v"
                let (targetW, targetH, _, _) = currentVideoSizeSnapshot()
                var pb: CVPixelBuffer?
                if isUsingSkyLight && !wantYUV {
                    // 按目标帧率节拍门控，避免 2 路 SkyLight 在 70+fps 下过度压迫 WindowServer/编码器
                    let minGap = (1.0 / max(1.0, cfg.captureHz)) * 0.90
                    let waitSec: Double = withRawLock {
                        let nowGate = CFAbsoluteTimeGetCurrent()
                        let dt = nowGate - lastSkyLightGrabAt
                        if dt >= minGap {
                            lastSkyLightGrabAt = nowGate
                            return 0
                        }
                        return minGap - dt
                    }
                    if waitSec > 0.001 {
                        try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                        continue
                    }
                    t0 = CFAbsoluteTimeGetCurrent()
                    let vdID = displayIDProvider()
                    var skyGrabbed = false
                    if vdID != 0 {
                        switch SkyLightCapture.captureFrame(vdID, targetW: targetW, targetH: targetH) {
                        case .frame(let buf):
                            withRawLock { consecutiveSkyLightFails = 0 }
                            pb = buf
                            skyGrabbed = true
                        case .wrongSize(let w, let h):
                            // 条带帧（实测 2880x60 菜单栏条带）是 WindowServer 当帧
                            // 窗口列表的合成包围盒，不是采集故障。绝不拉伸成整屏，
                            // 那正是拖影/残影的根源。丢帧等下一拍重新枚举即可，
                            // 不计入连续失败，避免误回退到会弹权限窗的 SCScreenshotManager。
                            SkyLightCapture.noteBadFrame()
                            // 多路 worker 共享该字段，必须走 withRawLock；
                            // 与 encodeQueue 内的 lastSizeWarnAt 分开，避免语义串扰。
                            let nowWarn = CFAbsoluteTimeGetCurrent()
                            let shouldLog = withRawLock { () -> Bool in
                                if nowWarn - lastBadSizeWarnAt > 2.0 {
                                    lastBadSizeWarnAt = nowWarn
                                    return true
                                }
                                return false
                            }
                            if shouldLog {
                                Log.info("丢弃尺寸异常的合成帧 \(w)x\(h) != \(targetW)x\(targetH)（累计丢弃 \(SkyLightCapture.badFrameCount) 张）")
                            }
                            // 节拍门已按 minGap 限速，直接 continue 即可；
                            // 原先额外 sleep 50ms 会把坏帧变成 50ms 空洞，压低有效帧率。
                            continue
                        case .unavailable:
                            // 与 vdID == 0 一样，走下方失败处理
                            break
                        }
                    }
                    if !skyGrabbed {
                        if !CGPreflightScreenCaptureAccess() {
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard stillCurrent(gen: gen) else { return }
                            if !CGPreflightScreenCaptureAccess() {
                                let alreadyPaused = permissionPaused
                                setScreenCaptureDenied(true)
                                pauseForPermission()
                                if !alreadyPaused {
                                    Log.info("屏幕录制权限未授予或已撤销，已暂停采集（请在面板授权后点击「恢复采集」或重启应用）")
                                }
                                return
                            }
                        }
                        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 || CGDisplayIsAsleep(vdID) != 0 {
                            withRawLock { consecutiveSkyLightFails = 0 }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            continue
                        }
                        let (fails, switched) = withRawLock { () -> (Int, Bool) in
                            consecutiveSkyLightFails += 1
                            if consecutiveSkyLightFails >= 10 && useSkyLight {
                                useSkyLight = false
                                return (consecutiveSkyLightFails, true)
                            }
                            return (consecutiveSkyLightFails, false)
                        }
                        if switched {
                            Log.info("SkyLight 采集连续失败 \(fails) 次，自动回退至 SCScreenshotManager")
                            _ = spawnWorkers()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                } else {
                    let content = try await currentContent()
                    let foundDisplay = content.displays.first(where: { isOurVirtualDisplay($0.displayID) })
                    let d: SCDisplay
                    if let existing = foundDisplay {
                        d = existing
                    } else {
                        let nowMissing = CFAbsoluteTimeGetCurrent()
                        let shouldRefresh = withRawLock {
                            if nowMissing - lastMissingDisplayRefreshAt >= 2.0 {
                                lastMissingDisplayRefreshAt = nowMissing
                                return true
                            }
                            return false
                        }
                        if shouldRefresh,
                           let refreshed = try await currentContent(forceRefresh: true).displays.first(where: { isOurVirtualDisplay($0.displayID) }) {
                            d = refreshed
                        } else {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            continue
                        }
                    }
                    let filter = SCContentFilter(display: d, excludingWindows: [])
                    if wantYUV {
                        let c = SCStreamConfiguration()
                        c.width = targetW
                        c.height = targetH
                        c.showsCursor = false
                        c.capturesAudio = false
                        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
                        if #available(macOS 14.0, *) { c.captureResolution = .best }
                        let sb = try await Self.captureSample(c, filter: filter)
                        guard let buf = CMSampleBufferGetImageBuffer(sb) else {
                            let t = CFAbsoluteTimeGetCurrent()
                            if t - lastErrorLogAt > 2.0 {
                                lastErrorLogAt = t
                                Log.info("采集样本没有 image buffer，丢弃该帧")
                            }
                            continue
                        }
                        pb = buf
                    } else {
                        let c = SCStreamConfiguration()
                        c.width = targetW
                        c.height = targetH
                        c.showsCursor = false
                        c.capturesAudio = false
                        if #available(macOS 14.0, *) { c.captureResolution = .best }
                        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
                        guard let buf = makePixelBuffer(from: img, targetW: targetW, targetH: targetH) else { continue }
                        pb = buf
                    }
                }
                guard let pb else { continue }
                let now = CFAbsoluteTimeGetCurrent()
                // 旧代次 worker 可能刚从一个长 await 里返回（单帧 60ms 甚至更久），
                // 这里再确认一次代次/运行状态，避免逐个多发一帧干扰看护判断。
                guard stillCurrent(gen: gen) else { return }
                // 采集健康度计数：在 encode 之前自增，不含编码与排队时间。
                // 看护用它判断采集本身是否正常，避免 VT 变慢时被误判成采集卡死。
                bumpCapturedRaw()
                withRawLock {
                    consecutiveCode1004 = 0
                    firstCode1004At = 0
                }
                let fw = CVPixelBufferGetWidth(pb)
                let fh = CVPixelBufferGetHeight(pb)
                let actualFmt = CVPixelBufferGetPixelFormatType(pb)
                encodeQueue.sync {
                    if !loggedFirstFrame {
                        loggedFirstFrame = true
                        // 打印实际像素格式：SCK 可能忽略 pixelFormat 仍给 BGRA，
                        // 那样不会黑屏（VT 会自己转），但这次省内存的收益就没了，
                        // 且从外部完全看不出来。这行是唯一的判据。
                        let f4 = String(format: "%c%c%c%c",
                                        (actualFmt >> 24) & 0xFF, (actualFmt >> 16) & 0xFF,
                                        (actualFmt >> 8) & 0xFF, actualFmt & 0xFF)
                        let wantName = wantYUV ? "420v" : "BGRA"
                        actualFormatCode = actualFmt   // 面板显示实测值，不显示配置值
                        Log.info("采集首帧实测: \(fw)x\(fh) fmt=\(f4) (期望 \(targetW)x\(targetH) \(wantName))")
                        if wantYUV && actualFmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                            && actualFmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                            Log.info("警告: 采集实际格式是 \(f4) 而非 420v，VT 会额外做一次全屏转换，内存收益失效")
                        }
                    } else if (fw != targetW || fh != targetH)
                                && now - lastSizeWarnAt > 2.0 {
                        // 限流：尺寸偏移时每帧都打会淹日志并拖慢 encodeQueue 临界区
                        lastSizeWarnAt = now
                        Log.info("警告: 采集帧尺寸偏移 \(fw)x\(fh) != \(targetW)x\(targetH)")
                    }
                    // 内容冻结诊断：帧在来但画面完全不变时记一条日志。
                    // 只在日志里报，不重启 —— 静止桌面本来就不变，重启会误伤，
                    // 而且 spawnWorkers 不回收旧 worker，会把线程数越堆越多。
                    // 指纹为 nil（取锁失败）时跳过本次比较，不要当成「没变化」。
                    if let h = Self.frameFingerprint(pb) {
                        if h == lastFrameHash {
                            if unchangedSince == 0 { unchangedSince = now }
                            // 静止桌面本来就会一直命中这里，5 分钟一条足够。
                            // 原来 30 秒一条，挂机一整晚会多出上千行无用日志。
                            if now - unchangedSince > 8.0 && now - lastFreezeLogAt > 300.0 {
                                lastFreezeLogAt = now
                                Log.info("提示: 采集内容已 \(Int(now - unchangedSince))s 无变化（帧仍以 \(Int(cfg.captureHz))fps 到达）。若 Windows 端画面也不动，说明源画面本身静止")
                            }
                        } else {
                            lastFrameHash = h
                            unchangedSince = 0
                        }
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
                let nsErr = error as NSError
                let isUserDeclined = (nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
                                      nsErr.code == SCStreamError.userDeclined.rawValue)
                let isCode1004 = (nsErr.domain == "com.apple.ScreenCaptureKit.CoreGraphicsErrorDomain" &&
                                  nsErr.code == 1004)
                var isDenied = false
                if !CGPreflightScreenCaptureAccess() {
                    // 实测 Code=1004 / -3801 伴随 TCC 抖动时 preflight 可能在 2~11ms 内从 false 跳回 true，
                    // 间隔 150ms 二次确认再判为权限拒绝，避免单次瞬态抖动误触发永久停采。
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard stillCurrent(gen: gen) else { return }
                    if !CGPreflightScreenCaptureAccess() {
                        isDenied = true
                    }
                }
                if isDenied {
                    let alreadyPaused = permissionPaused
                    setScreenCaptureDenied(true)
                    pauseForPermission()
                    if !alreadyPaused {
                        Log.info("屏幕录制权限未授予或被系统弹窗拒绝，已暂停采集防循环弹窗（请在面板授权后点击「恢复采集」或重启应用）")
                    }
                    return
                }
                if isCode1004 || isUserDeclined {
                    if CGDisplayIsAsleep(CGMainDisplayID()) != 0 || CGDisplayIsAsleep(displayIDProvider()) != 0 {
                        withRawLock {
                            consecutiveCode1004 = 0
                            firstCode1004At = 0
                        }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    let errNow = CFAbsoluteTimeGetCurrent()
                    let (streak, elapsed) = withRawLock { () -> (Int, Double) in
                        // 10 秒滚动窗口：睡眠前残留、偶发单次错误或长期静默后不累积，
                        // 仅当 10 秒窗口内持续失败 >=8 次且跨度 >=2.0 秒才闩锁。
                        if consecutiveCode1004 == 0 || (errNow - firstCode1004At) > 10.0 {
                            firstCode1004At = errNow
                            consecutiveCode1004 = 1
                        } else {
                            consecutiveCode1004 += 1
                        }
                        return (consecutiveCode1004, errNow - firstCode1004At)
                    }
                    if streak >= 8 && elapsed >= 2.0 {
                        let alreadyPaused = permissionPaused
                        setScreenCaptureDenied(true)
                        pauseForPermission()
                        if !alreadyPaused {
                            Log.info(String(format: "采集在 %.1fs 内连续 %d 次返回权限/1004 失败，已暂停采集防循环弹窗（确认权限后请点击「恢复采集」或重启应用）",
                                            elapsed, streak))
                        }
                        return
                    }
                }
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastErrorLogAt > 2.0 {
                    lastErrorLogAt = now
                    Log.info("截图采集失败: \(error)")
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// SCScreenshotManager 的 async 包装。
    /// 用 captureSampleBuffer 而不是 captureImage：前者直接给 CVPixelBuffer
    /// （IOSurface 支撑），后者给 CGImage，还要再 CVPixelBufferCreate + 全屏
    /// CGContext 重绘一次。2880x1800 下这一步每帧多 19.8MB 和一次 5.2M 像素绘制。
    private static func captureSample(_ c: SCStreamConfiguration,
                                      filter: SCContentFilter) async throws -> CMSampleBuffer {
        try await withCheckedThrowingContinuation { cont in
            SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: c) { sb, err in
                if let sb {
                    cont.resume(returning: sb)
                } else {
                    cont.resume(throwing: err ?? NSError(domain: "Capture", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "captureSampleBuffer 返回空",
                    ]))
                }
            }
        }
    }

    /// 采集帧内容的轻量指纹。按 32x18 网格抽样，取若干点做 FNV-1a。
    /// 目的是判断「画面有没有变化」，不是做精确校验，所以抽样足够。
    /// 返回 nil 表示取不到基地址（锁失败），调用方应跳过本次比较 ——
    /// 不能返回 0，否则会与初始的 lastFrameHash=0 相等，被误判成画面冻结。
    static func frameFingerprint(_ pb: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let isPlanar = CVPixelBufferIsPlanar(pb)

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ b: UInt64) {
            hash = (hash ^ b) &* 0x0000_0100_0000_01B3
        }

        let gw = 32, gh = 18
        for gy in 0..<gh {
            for gx in 0..<gw {
                let x = gx * max(1, w) / gw
                let y = gy * max(1, h) / gh
                if isPlanar, fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
                    // 只用 Y 平面：亮度变化足以判断画面是否更新，且省掉两次平面遍历。
                    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                    let p = base.advanced(by: y * stride + x)
                    mix(UInt64(p.load(as: UInt8.self)))
                } else {
                    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
                    let stride = CVPixelBufferGetBytesPerRow(pb)
                    let p = base.advanced(by: y * stride + x * 4)
                    // 只取一个通道，避免字节序差异
                    mix(UInt64(p.load(as: UInt8.self)))
                }
            }
        }
        return hash
    }

    private func currentContent(forceRefresh: Bool = false) async throws -> SCShareableContent {
        let now = CFAbsoluteTimeGetCurrent()
        // 显示排列变化（Sidecar 接入/拔线、镜像关系变动）时强制刷新一次共享内容，
        // 否则复用 300s 缓存，避免 4 个 worker 每 2 秒向 replayd/TCC 重复轮询触发系统弹窗。
        let rebuild = gCaptureRebuildRequested
        if rebuild {
            gCaptureRebuildRequested = false
            Log.info("显示排列变化，刷新采集共享内容")
        }
        enum FetchAction {
            case cached(SCShareableContent)
            case join(Task<SCShareableContent, Error>)
            case start(Task<SCShareableContent, Error>, Int)
        }
        let action: FetchAction = withRawLock {
            if forceRefresh || rebuild {
                contentGen &+= 1
                cachedContent = nil
                cachedAt = 0
            }
            if let c = cachedContent, now - cachedAt < 300.0 {
                return .cached(c)
            }
            if let existing = inFlightContentTask, inFlightContentGen == contentGen {
                return .join(existing)
            }
            let myGen = contentGen
            let t = Task<SCShareableContent, Error> {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            inFlightContentTask = t
            inFlightContentGen = myGen
            return .start(t, myGen)
        }
        switch action {
        case .cached(let c):
            return c
        case .join(let t):
            return try await t.value
        case .start(let t, let myGen):
            do {
                let c = try await t.value
                withRawLock {
                    if contentGen == myGen {
                        cachedContent = c
                        cachedAt = CFAbsoluteTimeGetCurrent()
                    }
                    if inFlightContentGen == myGen {
                        inFlightContentTask = nil
                    }
                }
                return c
            } catch {
                withRawLock {
                    if inFlightContentGen == myGen {
                        inFlightContentTask = nil
                    }
                }
                throw error
            }
        }
    }
}

private let fastPathMissLock = NSLock()
private var fastPathMissLogged = false
/// 无名 RGB 色彩空间是否等价 sRGB 的缓存。键绑定到具体色彩空间对象，
/// 避免不同空间共用单槽缓存导致静默误判（审查指出的低概率缺陷）。
private let colorSpaceCheckLock = NSLock()
private var lastColorSpaceCheck: (id: ObjectIdentifier, isSRGB: Bool)? = nil

/// 判断色彩空间是否可安全地按 BGRA 直接拷贝：
/// - nil：SkyLight 合成图有时不带 colorSpace，像素已是 BGRA，按 sRGB 处理；
/// - 名字等于 sRGB：直接放行；
/// - 无名 RGB 非宽色域：用 ICC 数据重建，等价 sRGB 才放行（实测虚拟屏就是这种）；
/// - 宽色域或其它模型：拒绝，交给回退路径做真正的色彩转换。
private func isSRGBEquivalent(_ cs: CGColorSpace?, csName: String?, srgbName: String?) -> Bool {
    guard let cs else { return true }
    if let srgbName, csName == srgbName { return true }
    guard cs.model == .rgb, !cs.isWideGamutRGB else { return false }
    colorSpaceCheckLock.lock()
    if let cached = lastColorSpaceCheck, cached.id == ObjectIdentifier(cs) {
        colorSpaceCheckLock.unlock()
        return cached.isSRGB
    }
    colorSpaceCheckLock.unlock()
    var isSRGB = false
    if let icc = cs.copyICCData(), let rebuilt = CGColorSpace(iccData: icc),
       let srgbName, (rebuilt.name as String?) == srgbName {
        isSRGB = true
    }
    colorSpaceCheckLock.lock()
    lastColorSpaceCheck = (ObjectIdentifier(cs), isSRGB)
    colorSpaceCheckLock.unlock()
    return isSRGB
}

/// 一次性记录快路径未命中原因（加锁，跨 worker 安全）。
private func logFastPathMiss(_ reason: String, img: CGImage, w: Int, h: Int,
                             cs: CGColorSpace?, csName: String?, srgbName: String?,
                             dataLen: Int?) {
    fastPathMissLock.lock()
    let shouldLog = !fastPathMissLogged
    if shouldLog { fastPathMissLogged = true }
    fastPathMissLock.unlock()
    guard shouldLog else { return }
    let csDesc: String
    if let cs {
        csDesc = csName ?? "unnamed(model=\(cs.model.rawValue) wideGamut=\(cs.isWideGamutRGB))"
    } else {
        csDesc = "null"
    }
    Log.info("快路径未命中(\(reason)): size=\(img.width)x\(img.height) target=\(w)x\(h) bpc=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) bi=\(img.bitmapInfo.rawValue) cs=\(csDesc) srgb=\(srgbName ?? "nil") len=\(dataLen.map(String.init) ?? "-")")
}

/// CGImage → CVPixelBuffer(BGRA) 的快路径。
/// SkyLight 抓到的 CGImage 通常已是 32bpp BGRA premultiplied 小端，与
/// kCVPixelFormatType_32BGRA 一致，直接按行 memcpy 到 IOSurface 像素缓冲，
/// 省掉 CGContextDrawImage 的颜色管理与格式转换（实测 CPU 82% -> 20%）。
/// 色彩空间判据见 isSRGBEquivalent：无色彩空间、明确 sRGB、或 ICC 重建后等价 sRGB
/// 的无名非宽色域 RGB 才走快路径；宽色域与其它模型交给回退路径做色彩转换。
/// 像素一致性已用探针验证 maxDiff=0。
private func makePixelBufferFast(from img: CGImage, w: Int, h: Int) -> CVPixelBuffer? {
    let cs = img.colorSpace
    let csName = cs?.name as String?
    let srgbName = CGColorSpace(name: CGColorSpace.sRGB)?.name as String?
    // 先做无副作用的廉价判断，最后才取 dataProvider.data（可能触发全帧拷贝）。
    let shapeOK = img.width == w && img.height == h
        && img.bitsPerComponent == 8 && img.bitsPerPixel == 32
        && (img.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            == CGImageAlphaInfo.premultipliedFirst.rawValue
        && (img.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue)
            == CGBitmapInfo.byteOrder32Little.rawValue
        && isSRGBEquivalent(cs, csName: csName, srgbName: srgbName)
    guard shapeOK else {
        logFastPathMiss("shape", img: img, w: w, h: h, cs: cs, csName: csName, srgbName: srgbName, dataLen: nil)
        return nil
    }
    guard let data = img.dataProvider?.data, let src = CFDataGetBytePtr(data) else {
        logFastPathMiss("data", img: img, w: w, h: h, cs: cs, csName: csName, srgbName: srgbName, dataLen: nil)
        return nil
    }
    let srcRow = img.bytesPerRow
    guard srcRow >= w * 4, CFDataGetLength(data) >= srcRow * h else {
        logFastPathMiss("rowlen", img: img, w: w, h: h, cs: cs, csName: csName, srgbName: srgbName, dataLen: CFDataGetLength(data))
        return nil
    }
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    ]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let dstRow = CVPixelBufferGetBytesPerRow(pb)
    // 不变量：CVPixelBuffer 的 bytesPerRow 必须 >= 可见宽度 * 4。
    // 一旦被打破，min(srcRow,dstRow) 会静默产出横向错位画面，不如回退。
    guard dstRow >= w * 4 else { return nil }
    let copyBytes = min(srcRow, dstRow)
    for y in 0..<h {
        memcpy(dst.advanced(by: y * dstRow), src.advanced(by: y * srcRow), copyBytes)
    }
    return pb
}

/// CGImage → CVPixelBuffer(BGRA) 的回退路径。
/// 格式/尺寸不满足快路径条件时用它：走 CoreGraphics 全屏重绘（会做色彩转换与缩放）。
func makePixelBuffer(from img: CGImage, targetW: Int? = nil, targetH: Int? = nil) -> CVPixelBuffer? {
    let w = targetW ?? img.width, h = targetH ?? img.height
    if let fast = makePixelBufferFast(from: img, w: w, h: h) { return fast }
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    ]
    guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let pb else { return nil }
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                              space: srgb,
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
    /// 累计发送帧数（不随 2 秒统计清零，给面板看总量）。
    /// 写方 net 队列、读方主线程，走锁。
    private let totalLock = NSLock()
    private var _totalSent = 0
    var totalSent: Int {
        totalLock.lock(); defer { totalLock.unlock() }
        return _totalSent
    }
    func bumpTotalSent() {
        totalLock.lock(); _totalSent += 1; totalLock.unlock()
    }
    var sentBytes = 0
    private var _connected = false
    var connected: Bool {
        get { peerLock.lock(); defer { peerLock.unlock() }; return _connected }
        set { peerLock.lock(); _connected = newValue; peerLock.unlock() }
    }

    /// 对端地址描述。写方是 net 队列（建连回调），读方是主线程（面板），
    /// String 是引用计数的多字节值类型，跨线程裸读写是 UB，必须走锁。
    private let peerLock = NSLock()
    private var _peerDescription = "-"
    private var _roleConflictMessage: String? = nil
    private var lastConflictLogAt: CFAbsoluteTime = 0
    var peerDescription: String {
        peerLock.lock(); defer { peerLock.unlock() }
        return _peerDescription
    }
    func setPeerDescription(_ s: String) {
        peerLock.lock(); _peerDescription = s; peerLock.unlock()
    }
    var roleConflictMessage: String? {
        peerLock.lock(); defer { peerLock.unlock() }
        return _roleConflictMessage
    }
    func setRoleConflictMessage(_ s: String?) {
        peerLock.lock(); _roleConflictMessage = s; peerLock.unlock()
    }

    /// 会话头里通告的虚拟屏参数，由 main 在启动时写入。
    /// 接收端据此自动调整窗口尺寸与坐标基准，两端不再手工对齐分辨率。
    var sessionWidth = 0
    var sessionHeight = 0
    var sessionFps = 0
    var sessionScaleTenths: UInt8 = 20
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
            self.setPeerDescription(String(describing: c.endpoint))

            let old = self.conn
            self.conn = c
            self.connected = true
            self.setRoleConflictMessage(nil)
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
                    // 断开后不再需要保留整帧画面用于补关键帧，释放掉
                    gEncoder?.releaseLastFrame()
                case .cancelled:
                    Log.info("连接已取消（cancelled）")
                    self.connected = false
                    resetInjectionState()
                    gEncoder?.releaseLastFrame()
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
            self.onPeerConnected?()
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
                if !self.drainControl(epoch: epoch) {
                    return
                }
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

    private func abortRoleConflict(epoch: Int, message: String, firstByte: UInt8, reasonCode: UInt8) {
        guard connEpoch == epoch else { return }
        let c = conn
        connEpoch &+= 1
        conn = nil
        connected = false
        ctrlBuf.removeAll()
        setRoleConflictMessage(message)
        resetInjectionState()
        gEncoder?.releaseLastFrame()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastConflictLogAt >= 5.0 {
            lastConflictLogAt = now
            Log.info("角色冲突/协议异常 (首字节=0x\(String(format: "%02X", firstByte))): \(message)")
        }
        guard let c = c else { return }
        // 发一帧 0x7F 通知后再取消连接，让对端也能明确提示（0x01=Mac主控冲突, 0x03=控制流越界）
        var pkt = Data(capacity: 14)
        var len = UInt32(10).bigEndian
        withUnsafeBytes(of: &len) { pkt.append(contentsOf: $0) }
        pkt.append(0x7F)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { pkt.append(contentsOf: $0) }
        pkt.append(reasonCode)
        c.send(content: pkt, completion: .contentProcessed { _ in
            c.cancel()
        })
    }

    private func drainControl(epoch: Int) -> Bool {
        while !ctrlBuf.isEmpty {
            let t = ctrlBuf[ctrlBuf.startIndex]
            if t == 0x7E {
                // 接收端握手问候: [0x7E]['S']['D']['R']['X'][ver=1][role][0] = 8 字节
                guard ctrlBuf.count >= 8 else { return true }
                let b = ctrlBuf
                let o = b.startIndex
                let magicOk = b[o + 1] == 0x53 && b[o + 2] == 0x44 && b[o + 3] == 0x52 && b[o + 4] == 0x58
                let role = b[o + 6]
                if !magicOk || role != 0x02 {
                    abortRoleConflict(epoch: epoch, message: "角色冲突：对端非 Windows 副屏接收端，已断开保护", firstByte: t, reasonCode: 0x01)
                    return false
                }
                setRoleConflictMessage(nil)
                ctrlBuf.removeFirst(8)
            } else if t == 0x02 {
                Log.info("收到关键帧请求，下一帧强制 IDR")
                onKeyframeRequest?()
                ctrlBuf.removeFirst(1)
            } else if t == 0x04 {
                // [0x04][float32 x][float32 y][uint8 buttons][int16 wheel] = 12 字节
                guard ctrlBuf.count >= 12 else { return true }
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
                let maxBound = Float(max(16384, max(sessionWidth, sessionHeight) * 2))
                if !x.isFinite || !y.isFinite || x < -64 || x > maxBound || y < -64 || y > maxBound || (buttons & ~0x07) != 0 {
                    abortRoleConflict(epoch: epoch, message: "控制流损坏（0x04 越界），已拒绝输入并断开保护", firstByte: t, reasonCode: 0x03)
                    return false
                }
                onInput?(x, y, buttons, wheel)
                ctrlBuf.removeFirst(12)
            } else if t == 0x09 {
                // [0x09][vk u16][scan u16][down u8][flags u8] = 7 字节，全大端
                guard ctrlBuf.count >= 7 else { return true }
                let b = ctrlBuf
                let o = b.startIndex
                let vk = (UInt16(b[o + 1]) << 8) | UInt16(b[o + 2])
                let scan = (UInt16(b[o + 3]) << 8) | UInt16(b[o + 4])
                let downByte = b[o + 5]
                let flags = b[o + 6]
                if downByte > 1 || (flags & ~0x03) != 0 {
                    abortRoleConflict(epoch: epoch, message: "控制流损坏（0x09 越界），已拒绝输入并断开保护", firstByte: t, reasonCode: 0x03)
                    return false
                }
                onKey?(vk, scan, downByte != 0, flags)
                ctrlBuf.removeFirst(7)
            } else if t == 0x07 {
                // [0x07][presentP95 u16][sourceP95 u16][decodeFps*10 u16]
                // [presentDrop u16][pacedDrop u16][reserved u16] = 13 字节，全大端
                guard ctrlBuf.count >= 13 else { return true }
                let b = ctrlBuf
                let o = b.startIndex
                func rd16(_ off: Int) -> UInt16 {
                    (UInt16(b[o + off]) << 8) | UInt16(b[o + off + 1])
                }
                let p95p = rd16(1)
                let p95s = rd16(3)
                let dec10 = rd16(5)
                if p95p > 10000 || p95s > 10000 || dec10 > 3000 {
                    abortRoleConflict(epoch: epoch, message: "控制流损坏（0x07 越界），已断开保护", firstByte: t, reasonCode: 0x03)
                    return false
                }
                let fb = FeedbackSignals(
                    presentP95: Double(p95p),
                    sourceP95: Double(p95s),
                    decodeFps: Double(dec10) / 10.0,
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
                // 严禁逐字节跳过未知字节（否则同为发送端的 H.264 视频帧会被误判成 0x04/0x09 乱点键盘鼠标）
                let isConflict = (t == 0x00)
                let msg = isConflict
                    ? "角色冲突：Windows 端当前也是主控发送模式，请将 Windows 切为「副屏模式」"
                    : "控制通道协议异常，已拒绝输入并断开保护"
                abortRoleConflict(epoch: epoch, message: msg, firstByte: t, reasonCode: isConflict ? 0x01 : 0x03)
                return false
            }
            if ctrlBuf.count > 65536 { ctrlBuf.removeAll() }
        }
        return true
    }

    /// 收到对端 0x02 时回调，由外部接到编码器
    var onKeyframeRequest: (() -> Void)?
    /// 新连接建立（对端已握手）时回调，用于播放「副屏在这里」的连接引导
    var onPeerConnected: (() -> Void)?
    /// 收到对端 0x04 输入事件：(x, y, buttons, wheel)
    var onInput: ((Float, Float, UInt8, Int16) -> Void)?
    /// 收到对端 0x09 键盘事件：(vk, scan, down, flags)
    var onKey: ((UInt16, UInt16, Bool, UInt8) -> Void)?

    private let counterLock = NSLock()
    private var inFlightStallSince: CFAbsoluteTime = 0

    /// 新连接建立时清零在途计数。
    /// 旧连接被重置时，未完成的 send 完成回调可能不再触发，
    /// inFlight 会永久停在 2，导致之后所有帧都被判为"拥塞"而丢弃。
    func resetInFlight() {
        counterLock.lock()
        inFlight = 0
        inFlightStallSince = 0
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
        queue.async { [weak self] in
            guard let self, self.connected, let c = self.conn else { return }
            c.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// 发送真实系统光标图像。独立类型 0x05，不动 0x03 位置链路，
    /// 这样两端版本错配时最多是没有自定义光标，位置转发仍正常。
    /// 载荷(全大端): [u16 w][u16 h][u16 hotX][u16 hotY][u32 nBytes][BGRA 像素...]
    /// BGRA 是 Windows DIB(32bpp BI_RGB) 直接可用的排布。
    func sendCursorImage(width: Int, height: Int,
                         hotX: Int, hotY: Int, bgra: Data) {
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
        queue.async { [weak self] in
            guard let self, self.connected, let c = self.conn else { return }
            c.send(content: packet, completion: .contentProcessed { _ in })
        }
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
    /// 载荷（全大端）：[version u8][width u16][height u16][fps u8][scaleTenths u8]
    func updateSessionInfo(width: Int, height: Int, fps: Int, scaleTenths: UInt8? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sessionWidth = width
            self.sessionHeight = height
            self.sessionFps = fps
            if let st = scaleTenths { self.sessionScaleTenths = st }
            self.sendSessionInfo()
        }
    }

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
        packet.append(sessionScaleTenths)    // Mac 虚拟屏 backing scale × 10（0=未知，20=2.0x）
        c.send(content: packet, completion: .contentProcessed { _ in })
        lastSessionSent = CFAbsoluteTimeGetCurrent()
    }

    func sendKvmState(active: Bool) {
        var packet = Data(capacity: 14)
        var len = UInt32(10).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x0C)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(active ? 1 : 0)
        queue.async { [weak self] in
            guard let self, self.connected, let c = self.conn else { return }
            c.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func sendKvmMouse(dx: Int16, dy: Int16, buttons: UInt8, wheel: Int16) {
        var packet = Data(capacity: 20)
        var len = UInt32(16).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x0A)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        var dxBe = UInt16(bitPattern: dx).bigEndian
        var dyBe = UInt16(bitPattern: dy).bigEndian
        var whBe = UInt16(bitPattern: wheel).bigEndian
        withUnsafeBytes(of: &dxBe) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &dyBe) { packet.append(contentsOf: $0) }
        packet.append(buttons)
        withUnsafeBytes(of: &whBe) { packet.append(contentsOf: $0) }
        queue.async { [weak self] in
            guard let self, self.connected, let c = self.conn else { return }
            c.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func sendKvmKey(vk: UInt16, scan: UInt16, down: Bool, flags: UInt8) {
        var packet = Data(capacity: 19)
        var len = UInt32(15).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x0B)
        var ts = UInt64(CFAbsoluteTimeGetCurrent() * 1_000_000).bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        var vBe = vk.bigEndian
        var sBe = scan.bigEndian
        withUnsafeBytes(of: &vBe) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &sBe) { packet.append(contentsOf: $0) }
        packet.append(down ? 1 : 0)
        packet.append(flags)
        queue.async { [weak self] in
            guard let self, self.connected, let c = self.conn else { return }
            c.send(content: packet, completion: .contentProcessed { _ in })
        }
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
        // 在途帧数超限：丢这一帧，保住实时性；若连续阻塞 >8s 则主动断开卡死连接
        let now = CFAbsoluteTimeGetCurrent()
        let epoch = connEpoch
        var abortStalledConn: (NWConnection, Int, Double, Int)? = nil
        counterLock.lock()
        if inFlight >= maxInFlight {
            dropped += 1
            if inFlightStallSince == 0 {
                inFlightStallSince = now
            } else {
                let stalledFor = now - inFlightStallSince
                if stalledFor >= 8.0 {
                    inFlightStallSince = now
                    abortStalledConn = (c, epoch, stalledFor, inFlight)
                }
            }
            counterLock.unlock()
            if let (stalledConn, stalledEpoch, stalledFor, inFlightNow) = abortStalledConn {
                queue.async { [weak self] in
                    guard let self, self.connEpoch == stalledEpoch, self.conn === stalledConn else { return }
                    self.connEpoch &+= 1
                    self.conn = nil
                    self.connected = false
                    self.resetInFlight()
                    self.ctrlBuf.removeAll()
                    resetInjectionState()
                    gEncoder?.releaseLastFrame()
                    Log.info(String(format: "发送在途拥塞卡死 %.1fs（在途 %d），主动断开卡死连接等待重连", stalledFor, inFlightNow))
                    stalledConn.cancel()
                }
            }
            return
        }
        inFlight += 1
        inFlightStallSince = 0
        lastSendAt = now
        counterLock.unlock()

        var packet = Data(capacity: frame.count + 13)
        var len = UInt32(frame.count + 9).bigEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }
        packet.append(0x01)
        var ts = captureTimeMicros.bigEndian
        withUnsafeBytes(of: &ts) { packet.append(contentsOf: $0) }
        packet.append(frame)

        sent += 1
        bumpTotalSent()
        sentBytes += packet.count
        // 捕获发起时的连接代数。重连时新连接先把 connected 置 true，
        // 旧连接上未完成的 send 随后会以错误回调；若不区分代数，这个迟到的
        // 错误会把新连接的 connected 打回 false，之后所有帧被 guard 静默丢弃，
        // 表现为「连着却永久黑屏、且不会自愈重连」。
        c.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.counterLock.lock()
            // 陈旧连接的回调不计入新连接的在途数（新连接已 resetInFlight）
            if self.connEpoch == epoch {
                self.inFlight = max(0, self.inFlight - 1)
                self.inFlightStallSince = 0
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
    private let injectLock = NSLock()
    private var injectedRing: [(at: CFAbsoluteTime, pt: CGPoint)] = []
    private var injectedHead = 0

    /// 刚刚由 Windows 0x04 回放过移动的位置（8 槽位历史环），用于避免 CursorTracker
    /// 把自己注入的移动或前一跳滞后位置当成用户移动再发回 Windows，形成双向自激震荡。
    func isEchoOfInjected(_ p: CGPoint) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        injectLock.lock()
        let snap = injectedRing
        injectLock.unlock()
        for item in snap {
            let dt = now - item.at
            guard dt >= 0 && dt < 0.08 else { continue }
            let dx = p.x - item.pt.x, dy = p.y - item.pt.y
            if (dx * dx + dy * dy) < 16.0 { return true }
        }
        return false
    }

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
            injectLock.lock()
            let nowInj = CFAbsoluteTimeGetCurrent()
            if injectedRing.count < 8 {
                injectedRing.append((nowInj, p))
            } else {
                injectedRing[injectedHead] = (nowInj, p)
                injectedHead = (injectedHead + 1) % 8
            }
            injectLock.unlock()
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
        // 避免把刚由 Windows 0x04 注入的指针移动再当作本地移动发回 Windows
        if gMouse?.isEchoOfInjected(p) == true { return }
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
    /// 形状防抖：连续两次 100ms 采样一致才发送，避免鼠标快速掠过边缘时闪烁重建
    private var pendingFingerprint: UInt64 = 0
    /// 上次观察到的连接代数，用于连接重建时强制重发
    private var lastEpoch = -1
    private let maxDim = 256       // 原生位图上限（2x 下 128pt），超出则等比缩到 128pt 等效
    /// 抑制 macOS 系统「晃动鼠标指针以定位」产生的 4fps 临时放大光标帧，
    /// 避免在 Windows 端 125Hz 晃动缩放动画期间出现双重放大与阶梯抖动；
    /// 若放大持续超过 2.2 秒，则视为辅助功能永久放大设置，正常放行。
    private var normalCursorMaxDim = 0
    private var enlargedCursorSince: CFAbsoluteTime = 0
    /// 上次实际发送时刻，用于限流：光标形状在移动中可能在箭头/I型/手型间频繁切换，
    /// 每切一次就让接收端重建一次 HCURSOR，会造成光标卡顿。限制最小间隔。
    private var lastSendAt: CFAbsoluteTime = 0
    private let minSendGap: CFAbsoluteTime = 0.25
    /// 累计发送次数，供统计展示，便于判断是否在频繁重发
    private(set) var sentCount = 0

    init(sender: Sender) { self.sender = sender }

    func start() {
        // 幂等：面板可以把开关关掉再打开，重复调用不能叠加定时器
        guard timer == nil else { return }
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
            normalCursorMaxDim = 0
            enlargedCursorSince = 0
            return
        }
        guard sender.connected else {
            // 断开时清指纹，下次连上强制重发（新接收端没有旧光标）
            lastFingerprint = 0
            normalCursorMaxDim = 0
            enlargedCursorSince = 0
            return
        }
        guard let cur = NSCursor.currentSystem,
              let cg = cur.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // 按「会话 backing scale」归一化后发送，而不是直接发 cgImage 的真实像素：
        // 接收端要用 0x06 会话头里的 scale 反推逻辑尺寸，如果这里发的是某个 rep 的原始像素
        // （自定义光标可能只有 1x rep），接收端会算错一倍，热点也跟着偏。
        // 归一化后 w == logical * scale，两端口径一致；缩放放大则从这张高分辨率图重采样。
        let logicalW = cur.image.size.width
        let logicalH = cur.image.size.height
        // 与会话头里的 scaleTenths 用同一套取整，避免 1.25 这类值两边差 4%（稳态光标略小）。
        let sendScale = max(1.0, min(4.0, (vdBackingScale * 10).rounded() / 10))
        guard logicalW > 0, logicalH > 0 else { return }
        let rawW = max(1, Int((logicalW * sendScale).rounded()))
        let rawH = max(1, Int((logicalH * sendScale).rounded()))
        let rawMax = max(rawW, rawH)
        let logicalMax = Int(max(logicalW, logicalH).rounded())

        let now = CFAbsoluteTimeGetCurrent()
        if normalCursorMaxDim == 0 {
            enlargedCursorSince = 0
            normalCursorMaxDim = logicalMax
        } else if logicalMax <= 42 {
            // 常规系统光标（如 23x22 I型 <-> 28x40 箭头）不高于 42pt，
            // 直接放行并维护基线，绝不会在晃动期间把基线抬高到 43+。
            enlargedCursorSince = 0
            normalCursorMaxDim = logicalMax
        } else if logicalMax <= Int(Double(normalCursorMaxDim) * 1.35) {
            // 已处于永久大指针模式（例如无障碍 64pt+）时的正常形状切换
            enlargedCursorSince = 0
        } else {
            if enlargedCursorSince == 0 {
                enlargedCursorSince = now
            }
            if now - enlargedCursorSince < 2.2 {
                return
            }
            normalCursorMaxDim = logicalMax
        }

        let clampScale = rawMax > maxDim ? Double(maxDim) / Double(rawMax) : 1.0
        let w = max(1, Int((Double(rawW) * clampScale).rounded()))
        let h = max(1, Int((Double(rawH) * clampScale).rounded()))
        // 热点按「原生像素 / 逻辑点」的比例换算，落点与视觉完全一致。
        let scaleX = Double(w) / Double(logicalW)
        let scaleY = Double(h) / Double(logicalH)
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

        // 裁剪四周完全透明（alpha == 0）的空白边距（保留 1pt 安全边且包含热点）。
        // macOS 默认箭头 28x40pt 底部与右侧有大量透明留白，Windows 2x 放大后达 56x80，
        // 超过 Intel Iris Xe 64x64 硬件光标上限后会退化为 DWM 软件光标导致拖动残影。
        var minX = w - 1, maxX = 0, minY = h - 1, maxY = 0
        var hasOpaque = false
        for py in 0..<h {
            let rowOff = py * w * 4
            for px in 0..<w {
                if bgra[rowOff + px * 4 + 3] > 0 {
                    hasOpaque = true
                    if px < minX { minX = px }
                    if px > maxX { maxX = px }
                    if py < minY { minY = py }
                    if py > maxY { maxY = py }
                }
            }
        }
        let clampedHotX = max(0, min(w - 1, hotX))
        let clampedHotY = max(0, min(h - 1, hotY))
        var sendW = w, sendH = h, sendHotX = clampedHotX, sendHotY = clampedHotY
        var sendBgra = bgra
        if hasOpaque {
            minX = max(0, min(minX, clampedHotX) - 1)
            minY = max(0, min(minY, clampedHotY) - 1)
            maxX = min(w - 1, max(maxX, clampedHotX) + 1)
            maxY = min(h - 1, max(maxY, clampedHotY) + 1)
            let cw = maxX - minX + 1
            let ch = maxY - minY + 1
            if cw < w || ch < h {
                var cropped = [UInt8](repeating: 0, count: cw * ch * 4)
                for py in 0..<ch {
                    let srcStart = ((minY + py) * w + minX) * 4
                    let dstStart = py * cw * 4
                    cropped.replaceSubrange(dstStart..<(dstStart + cw * 4),
                                            with: bgra[srcStart..<(srcStart + cw * 4)])
                }
                sendW = cw
                sendH = ch
                sendHotX = clampedHotX - minX
                sendHotY = clampedHotY - minY
                sendBgra = cropped
            }
        }

        // 指纹：尺寸 + 热点 + 抽样像素，足以区分不同光标形状
        var fp: UInt64 = UInt64(sendW) << 48
        fp |= UInt64(sendH) << 32
        fp |= UInt64(sendHotX & 0xff) << 24
        fp |= UInt64(sendHotY & 0xff) << 16
        var hash: UInt64 = 1469598103934665603
        let step = max(1, sendBgra.count / 256)
        var i = 0
        while i < sendBgra.count {
            hash = (hash ^ UInt64(sendBgra[i])) &* 1099511628211
            i += step
        }
        fp ^= hash & 0xffff

        // 连接代数变化(重连)也要重发
        let epoch = sender.currentEpoch
        let force = epoch != lastEpoch
        lastEpoch = epoch
        guard force || fp != lastFingerprint else {
            pendingFingerprint = fp
            return
        }
        // 非强制形状变化：要求连续两次采样一致（100ms 防抖），
        // 防止鼠标快速经过输入框/链接边缘时瞬间切一次光标又切回，导致对端频繁重建 HCURSOR。
        if !force {
            if fp != pendingFingerprint {
                pendingFingerprint = fp
                return
            }
            if CFAbsoluteTimeGetCurrent() - lastSendAt < minSendGap { return }
        }
        pendingFingerprint = fp
        lastSendAt = CFAbsoluteTimeGetCurrent()
        lastFingerprint = fp
        sentCount += 1
        if force {
            Log.info("光标图像 \(sendW)x\(sendH) hot=(\(sendHotX),\(sendHotY)) (原始 \(w)x\(h))")
        }

        sender.sendCursorImage(width: sendW, height: sendH, hotX: sendHotX, hotY: sendHotY,
                               bgra: Data(sendBgra))
    }
}

// MARK: - 雷电双向文件中转站（独立 TCP 端口，不阻塞视频与光标）

struct TransferSnapshot {
    var connected = false
    var inboxPath = ""
    var statusText = "等待连接"
    var history: [String] = []
    var busy = false
    var progress: Double = 0
    var speedText = ""
    var lastReceivedURL: URL? = nil
    var lastReceivedName = ""
    /// 短时交互回执：0=无 1=成功 -1=失败（约 2.2 秒后自动回待机）
    var feedbackKind = 0
    var feedbackTitle = ""
    var feedbackDetail = ""
}

final class FileTransferService {
    static let typeBegin: UInt8 = 0x10
    static let typeChunk: UInt8 = 0x11
    static let typeEnd:   UInt8 = 0x12
    static let typeAck:   UInt8 = 0x13
    static let typePing:  UInt8 = 0x14
    static let typeText:  UInt8 = 0x15
    static let maxTextBytes = 1024 * 1024 - 4

    private let netQueue = DispatchQueue(label: "SecDisplay.transfer.net")
    private let sendQueue = DispatchQueue(label: "SecDisplay.transfer.send")
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var conn: NWConnection?
    private var connEpoch = 0
    private var _connected = false
    private var recvBuf = Data()
    private var listenPort: UInt16 = 9923
    private var clientMode = false
    private var targetHost = "10.10.10.2"
    private var listenerRestartScheduled = false
    private var clientReconnectScheduled = false
    private var stopped = false

    let inboxURL: URL

    private struct RecvFile {
        let id: UInt32
        let safeName: String
        let expectedSize: UInt64
        var receivedSize: UInt64 = 0
        let partURL: URL
        let handle: FileHandle
        let startedAt: CFAbsoluteTime
    }
    private var activeRecvs: [UInt32: RecvFile] = [:]

    private var nextTransferId: UInt32 = 1
    private var activeEpoch = 0
    private enum OutItem {
        case file(url: URL, deleteAfterSend: Bool)
        case text(utf8: Data, preview: String)
    }
    private var outQueue: [OutItem] = []
    private var isSending = false
    private var activeStatus = "等待接收端"
    private var recentHistory: [String] = []
    private var activeBusy = false
    private var activeProgress: Double = 0
    private var activeSpeedText = ""
    private var lastRecvURL: URL? = nil
    private var lastRecvName = ""
    private var activeFeedbackKind = 0
    private var activeFeedbackTitle = ""
    private var activeFeedbackDetail = ""
    private var feedbackSeq: UInt64 = 0
    private var keepAliveTimer: DispatchSourceTimer?

    private enum SendOutcome {
        case sent
        case localFailed
        case connLost
    }

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads", isDirectory: true)
        inboxURL = base.appendingPathComponent("SecDisplay-Transfer", isDirectory: true)
        try? fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    }

    func snapshot() -> TransferSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return TransferSnapshot(
            connected: _connected,
            inboxPath: inboxURL.path,
            statusText: activeStatus,
            history: recentHistory,
            busy: activeBusy,
            progress: activeProgress,
            speedText: activeSpeedText,
            lastReceivedURL: lastRecvURL,
            lastReceivedName: lastRecvName,
            feedbackKind: activeFeedbackKind,
            feedbackTitle: activeFeedbackTitle,
            feedbackDetail: activeFeedbackDetail
        )
    }

    func showFeedback(kind: Int, title: String, detail: String = "") {
        stateLock.lock()
        feedbackSeq &+= 1
        let seq = feedbackSeq
        activeFeedbackKind = kind
        activeFeedbackTitle = title
        activeFeedbackDetail = detail
        stateLock.unlock()
        notifyUI()
        if kind != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let clear = (self.feedbackSeq == seq)
                if clear {
                    self.activeFeedbackKind = 0
                    self.activeFeedbackTitle = ""
                    self.activeFeedbackDetail = ""
                }
                self.stateLock.unlock()
                if clear { self.notifyUI() }
            }
        }
    }

    func listen(port: UInt16) {
        listenPort = port
        clientMode = false
        netQueue.async { [weak self] in
            self?.startListener()
        }
    }

    func connect(host: String, port: UInt16) {
        listenPort = port
        targetHost = host
        clientMode = true
        stateLock.lock()
        activeStatus = "正在连接中转站 \(host):\(port)…"
        stateLock.unlock()
        notifyUI()
        netQueue.async { [weak self] in
            guard let self else { return }
            self.clientReconnectScheduled = false
            self.startClientConnection()
        }
    }

    func stop() {
        var toDelete: [URL] = []
        stateLock.lock()
        stopped = true
        _connected = false
        for item in outQueue {
            if case .file(let url, let del) = item, del {
                toDelete.append(url)
            }
        }
        outQueue.removeAll()
        stateLock.unlock()
        for u in toDelete { try? FileManager.default.removeItem(at: u) }
        netQueue.async { [weak self] in
            guard let self else { return }
            self.connEpoch &+= 1
            self.keepAliveTimer?.cancel()
            self.keepAliveTimer = nil
            self.cleanupActiveRecvs()
            self.conn?.cancel()
            self.conn = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private var tempSeq: UInt32 = 0

    func enqueueClipboardImageData(_ pngData: Data) {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss_SSS"
        stateLock.lock()
        tempSeq &+= 1
        let seq = tempSeq
        let isStopped = stopped
        stateLock.unlock()
        if isStopped { return }
        let name = "Screenshot_\(df.string(from: Date()))_\(seq).png"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try pngData.write(to: tmp, options: .atomic)
            enqueue(urls: [tmp], deleteAfterSend: true)
        } catch {
            Log.info("中转站写临时截图失败: \(error)")
            updateStatus("剪贴板截图写入失败", busy: false, progress: 0, speed: "")
        }
    }

    private func makeTextPreview(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.isEmpty { return "空白文本" }
        if oneLine.count <= 24 { return oneLine }
        return String(oneLine.prefix(24)) + "…"
    }

    func enqueueClipboardText(_ text: String) {
        guard !text.isEmpty else { return }
        let utf8 = Data(text.utf8)
        if utf8.count > Self.maxTextBytes {
            updateStatus("文本超过 1MB，请保存为文件发送", busy: false, progress: 0, speed: "")
            showFeedback(kind: -1, title: "文本过大 (>1MB)", detail: "请改用文件发送")
            Log.info("中转站拒绝过大文本 (\(utf8.count) B)")
            return
        }
        let preview = makeTextPreview(text)
        var shouldStart = false
        var isStopped = false
        stateLock.lock()
        if stopped {
            isStopped = true
        } else {
            outQueue.append(.text(utf8: utf8, preview: preview))
            if !isSending {
                isSending = true
                shouldStart = true
            }
            activeStatus = _connected ? "待发送文本: \(preview)" : "已排队文本（等待连接）"
        }
        stateLock.unlock()
        if isStopped { return }
        notifyUI()
        if shouldStart {
            sendQueue.async { [weak self] in self?.drainSendQueue() }
        }
    }

    func enqueue(urls: [URL], deleteAfterSend: Bool = false) {
        let fm = FileManager.default
        var items: [OutItem] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                items.append(.file(url: u, deleteAfterSend: deleteAfterSend))
            } else if let subItems = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles]) {
                // 拖入文件夹时仅发送顶层常规文件，避免误扫庞大目录树
                for sub in subItems {
                    var subDir: ObjCBool = false
                    if fm.fileExists(atPath: sub.path, isDirectory: &subDir), !subDir.boolValue {
                        items.append(.file(url: sub, deleteAfterSend: false))
                    }
                }
            }
        }
        guard !items.isEmpty else { return }
        var shouldStart = false
        var rejectedAfterStop = false
        stateLock.lock()
        if stopped {
            rejectedAfterStop = true
        } else {
            outQueue.append(contentsOf: items)
            if !isSending {
                isSending = true
                shouldStart = true
            }
            let queued = outQueue.count
            if _connected {
                activeStatus = "待发送 \(queued) 项…"
            } else {
                activeStatus = "已排队 \(queued) 项（等待连接）"
            }
        }
        stateLock.unlock()
        if rejectedAfterStop {
            if deleteAfterSend {
                for it in items {
                    if case .file(let url, let del) = it, del {
                        try? fm.removeItem(at: url)
                    }
                }
            }
            return
        }
        notifyUI()
        if shouldStart {
            sendQueue.async { [weak self] in self?.drainSendQueue() }
        }
    }

    private func startListener() {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        if isStopped { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = 5
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        if clientMode {
            startClientConnection()
            return
        }
        let l: NWListener
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else { return }
            l = try NWListener(using: params, on: nwPort)
        } catch {
            Log.info("中转站端口 \(listenPort) 监听失败: \(error)")
            scheduleRestart()
            return
        }
        self.listener = l
        l.newConnectionHandler = { [weak self] c in
            self?.acceptConnection(c)
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                Log.info("雷电文件中转站已监听端口 \(self.listenPort) → \(self.inboxURL.path)")
                self.listenerRestartScheduled = false
            case .failed(let e):
                Log.info("中转站监听失败: \(e)")
                self.scheduleRestart()
            case .cancelled:
                break
            default:
                break
            }
        }
        l.start(queue: netQueue)
    }

    private func scheduleRestart() {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped, !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        netQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            self.listener?.cancel()
            self.listener = nil
            self.startListener()
        }
    }

    private func startClientConnection() {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard clientMode, !isStopped else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: listenPort) else { return }
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 3
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        let c = NWConnection(host: NWEndpoint.Host(targetHost), port: nwPort, using: params)
        connEpoch &+= 1
        let epoch = connEpoch
        let old = self.conn
        self.conn = c
        self.recvBuf.removeAll()
        self.cleanupActiveRecvs()
        old?.cancel()

        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.connEpoch == epoch else { return }
            switch st {
            case .ready:
                self.clientReconnectScheduled = false
                self.stateLock.lock()
                self._connected = true
                self.activeEpoch = epoch
                self.activeBusy = false
                self.activeProgress = 0
                self.activeSpeedText = ""
                self.activeStatus = "已连接 \(self.targetHost):\(self.listenPort) · 可拖入文件直传"
                self.stateLock.unlock()
                self.notifyUI()
                Log.info("中转站已连接 Windows 服务端 \(self.targetHost):\(self.listenPort)")
                self.startKeepAlive(epoch: epoch)
                self.receiveLoop(epoch: epoch)
                self.stateLock.lock()
                let hasPending = !self.outQueue.isEmpty && !self.isSending
                if hasPending { self.isSending = true }
                self.stateLock.unlock()
                if hasPending {
                    self.sendQueue.async { [weak self] in self?.drainSendQueue() }
                }
            case .failed(let e):
                Log.info("中转站连接失败/断开: \(e)")
                self.onDisconnected()
            case .cancelled:
                self.onDisconnected()
            default:
                break
            }
        }
        c.start(queue: netQueue)
    }

    private func scheduleClientReconnect() {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard clientMode, !isStopped, !clientReconnectScheduled else { return }
        clientReconnectScheduled = true
        netQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.clientReconnectScheduled = false
            self.startClientConnection()
        }
    }

    private func acceptConnection(_ c: NWConnection) {
        connEpoch &+= 1
        let epoch = connEpoch
        let old = self.conn
        self.conn = c
        self.recvBuf.removeAll()
        self.cleanupActiveRecvs()
        old?.cancel()

        stateLock.lock()
        _connected = true
        activeEpoch = epoch
        activeBusy = false
        activeProgress = 0
        activeSpeedText = ""
        activeStatus = "已连接（端口 \(listenPort)）· 可拖入文件直传"
        stateLock.unlock()
        notifyUI()
        Log.info("中转站接收端已连接: \(String(describing: c.endpoint))")

        c.stateUpdateHandler = { [weak self] st in
            guard let self, self.connEpoch == epoch else { return }
            switch st {
            case .failed(let e):
                Log.info("中转站连接断开: \(e)")
                self.onDisconnected()
            case .cancelled:
                self.onDisconnected()
            case .ready:
                self.startKeepAlive(epoch: epoch)
            default:
                break
            }
        }
        c.start(queue: netQueue)
        receiveLoop(epoch: epoch)

        // 若连接前已有排队文件，立刻续发
        stateLock.lock()
        let hasPending = !outQueue.isEmpty && !isSending
        if hasPending { isSending = true }
        stateLock.unlock()
        if hasPending {
            sendQueue.async { [weak self] in self?.drainSendQueue() }
        }
    }

    private func onDisconnected() {
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        cleanupActiveRecvs()
        stateLock.lock()
        _connected = false
        activeBusy = false
        activeProgress = 0
        activeSpeedText = ""
        activeStatus = outQueue.isEmpty
            ? (clientMode ? "等待 Windows 中转端 (\(listenPort))" : "等待接收端")
            : "连接断开，\(outQueue.count) 项等待重连"
        stateLock.unlock()
        notifyUI()
        if clientMode {
            scheduleClientReconnect()
        }
    }

    private func startKeepAlive(epoch: Int) {
        keepAliveTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: netQueue)
        t.schedule(deadline: .now() + 15.0, repeating: 15.0)
        t.setEventHandler { [weak self] in
            guard let self, self.connEpoch == epoch, let c = self.conn else { return }
            var frame = Data(capacity: 5)
            frame.append(Self.typePing)
            var zero: UInt32 = 0
            withUnsafeBytes(of: &zero) { frame.append(contentsOf: $0) }
            c.send(content: frame, completion: .contentProcessed { _ in })
        }
        t.resume()
        keepAliveTimer = t
    }

    private func receiveLoop(epoch: Int) {
        guard connEpoch == epoch, let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isEOF, err in
            guard let self, self.connEpoch == epoch else { return }
            if let data, !data.isEmpty {
                self.recvBuf.append(data)
                if !self.parseFrames() {
                    c.cancel()
                    return
                }
            }
            if isEOF || err != nil {
                c.cancel()
                self.onDisconnected()
                return
            }
            self.receiveLoop(epoch: epoch)
        }
    }

    private func parseFrames() -> Bool {
        while recvBuf.count >= 5 {
            let type = recvBuf[recvBuf.startIndex]
            let b1 = UInt32(recvBuf[recvBuf.startIndex + 1])
            let b2 = UInt32(recvBuf[recvBuf.startIndex + 2])
            let b3 = UInt32(recvBuf[recvBuf.startIndex + 3])
            let b4 = UInt32(recvBuf[recvBuf.startIndex + 4])
            let payloadLen = Int((b1 << 24) | (b2 << 16) | (b3 << 8) | b4)
            if payloadLen > 1024 * 1024 {
                Log.info("中转站收到异常大帧 len=\(payloadLen)，断开保护")
                return false
            }
            guard recvBuf.count >= 5 + payloadLen else { break }
            let start = recvBuf.startIndex + 5
            let payload = recvBuf[start..<(start + payloadLen)]
            recvBuf.removeSubrange(recvBuf.startIndex..<(start + payloadLen))
            handleFrame(type: type, payload: Data(payload))
        }
        return true
    }

    private func handleFrame(type: UInt8, payload: Data) {
        switch type {
        case Self.typeBegin:
            guard payload.count >= 14 else { return }
            let id = readU32(payload, 0)
            let size = readU64(payload, 4)
            let nameLen = Int(readU16(payload, 12))
            guard payload.count >= 14 + nameLen else { return }
            let rawName = String(data: payload[14..<(14 + nameLen)], encoding: .utf8) ?? "file_\(id)"
            let safe = sanitizeFilename(rawName, fallbackId: id)
            // 先清旧记录再建新临时文件，避免同 ID 重传误删刚打开的新句柄
            if let prev = activeRecvs.removeValue(forKey: id) {
                try? prev.handle.close()
                try? FileManager.default.removeItem(at: prev.partURL)
            }
            let partURL = inboxURL.appendingPathComponent(".secdisplay_tmp_\(id).part")
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: partURL) else {
                Log.info("中转站创建临时文件失败: \(partURL.path)")
                sendAck(id: id, ok: false)
                return
            }
            activeRecvs[id] = RecvFile(id: id, safeName: safe, expectedSize: size,
                                       receivedSize: 0, partURL: partURL, handle: h,
                                       startedAt: CFAbsoluteTimeGetCurrent())
            updateStatus("正在接收: \(safe) (0%)", busy: true, progress: 0, speed: "")
            Log.info("中转站开始接收 #\(id): \(safe) (\(fmtBytes(size)))")

        case Self.typeChunk:
            guard payload.count >= 8 else { return }
            let id = readU32(payload, 0)
            let dataLen = Int(readU32(payload, 4))
            guard payload.count >= 8 + dataLen, var rf = activeRecvs[id] else { return }
            let chunk = payload[8..<(8 + dataLen)]
            do {
                try rf.handle.write(contentsOf: chunk)
            } catch {
                Log.info("中转站写文件失败 #\(id): \(error)")
                try? rf.handle.close()
                try? FileManager.default.removeItem(at: rf.partURL)
                activeRecvs.removeValue(forKey: id)
                updateStatus("保存失败: \(rf.safeName)", busy: false, progress: 0, speed: "")
                showFeedback(kind: -1, title: "保存失败", detail: rf.safeName)
                sendAck(id: id, ok: false)
                return
            }
            rf.receivedSize += UInt64(dataLen)
            activeRecvs[id] = rf
            let dt = max(0.01, CFAbsoluteTimeGetCurrent() - rf.startedAt)
            let mbps = Double(rf.receivedSize) / dt / 1_048_576.0
            let frac = rf.expectedSize > 0 ? min(1.0, Double(rf.receivedSize) / Double(rf.expectedSize)) : 1.0
            let pct = Int(frac * 100.0)
            updateStatus(String(format: "接收 %@ · %d%% · %.0f MB/s", rf.safeName, pct, mbps),
                         busy: true, progress: frac, speed: String(format: "%.0f MB/s", mbps))

        case Self.typeEnd:
            guard payload.count >= 5 else { return }
            let id = readU32(payload, 0)
            let okFlag = payload[4] == 1
            guard let rf = activeRecvs.removeValue(forKey: id) else { return }
            try? rf.handle.synchronize()
            try? rf.handle.close()
            if okFlag && rf.receivedSize == rf.expectedSize {
                let dest = uniqueDestURL(safeName: rf.safeName)
                do {
                    try FileManager.default.moveItem(at: rf.partURL, to: dest)
                    let dt = max(0.001, CFAbsoluteTimeGetCurrent() - rf.startedAt)
                    let speed = Double(rf.receivedSize) / dt / 1_048_576.0
                    let item = "↓ \(dest.lastPathComponent) (\(fmtBytes(rf.receivedSize)))"
                    stateLock.lock()
                    lastRecvURL = dest
                    lastRecvName = dest.lastPathComponent
                    stateLock.unlock()
                    pushHistory(item)
                    updateStatus(String(format: "已收到: %@ (%.0f MB/s)", dest.lastPathComponent, speed),
                                 busy: false, progress: 1.0, speed: String(format: "%.0f MB/s", speed))
                    showFeedback(kind: 1, title: "收到文件", detail: dest.lastPathComponent)
                    Log.info("中转站接收完成: \(dest.path) (\(fmtBytes(rf.receivedSize)), \(String(format: "%.1f", speed)) MB/s)")
                    sendAck(id: id, ok: true)
                } catch {
                    try? FileManager.default.removeItem(at: rf.partURL)
                    updateStatus("保存失败: \(rf.safeName)", busy: false, progress: 0, speed: "")
                    showFeedback(kind: -1, title: "保存失败", detail: rf.safeName)
                    Log.info("中转站重命名失败: \(error)")
                    sendAck(id: id, ok: false)
                }
            } else {
                try? FileManager.default.removeItem(at: rf.partURL)
                updateStatus("接收未完成: \(rf.safeName)", busy: false, progress: 0, speed: "")
                showFeedback(kind: -1, title: "接收中断", detail: rf.safeName)
                Log.info("中转站接收中断 #\(id): \(rf.safeName) \(rf.receivedSize)/\(rf.expectedSize)")
                sendAck(id: id, ok: false)
            }

        case Self.typeText:
            guard payload.count >= 4 else { return }
            let id = readU32(payload, 0)
            let textData = payload[payload.index(payload.startIndex, offsetBy: 4)..<payload.endIndex]
            guard !textData.isEmpty, let text = String(data: Data(textData), encoding: .utf8) else {
                sendAck(id: id, ok: false)
                return
            }
            let preview = makeTextPreview(text)
            let byteCount = textData.count
            let epochSnap = connEpoch
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                let wrote = pb.setString(text, forType: .string)
                if wrote {
                    self.pushHistory("↓ 文本: \(preview)")
                    self.updateStatus("已写入剪贴板: \(preview)", busy: false, progress: 1.0, speed: "")
                    self.showFeedback(kind: 1, title: "已写入剪贴板", detail: preview)
                    Log.info("中转站收到文本 #\(id) (\(byteCount) B)，已写入剪贴板")
                } else {
                    self.updateStatus("写入剪贴板失败: \(preview)", busy: false, progress: 0, speed: "")
                    self.showFeedback(kind: -1, title: "写入剪贴板失败", detail: preview)
                    Log.info("中转站收到文本 #\(id) (\(byteCount) B)，写入剪贴板失败")
                }
                self.netQueue.async {
                    guard self.connEpoch == epochSnap else { return }
                    self.sendAck(id: id, ok: wrote)
                }
            }

        case Self.typeAck:
            guard payload.count >= 5 else { return }
            let id = readU32(payload, 0)
            let ok = payload[4] == 1
            if !ok {
                Log.info("中转站对端落盘失败 #\(id)")
                showFeedback(kind: -1, title: "对端保存失败", detail: "")
            }

        default:
            break
        }
    }

    private func sendAck(id: UInt32, ok: Bool) {
        guard let c = conn else { return }
        var p = Data(capacity: 10)
        p.append(Self.typeAck)
        appendU32(&p, 5)
        appendU32(&p, id)
        p.append(ok ? 1 : 0)
        c.send(content: p, completion: .contentProcessed { _ in })
    }

    private func cleanupActiveRecvs() {
        for (_, rf) in activeRecvs {
            try? rf.handle.close()
            try? FileManager.default.removeItem(at: rf.partURL)
        }
        activeRecvs.removeAll()
    }

    private func drainSendQueue() {
        while true {
            stateLock.lock()
            if stopped || !_connected || outQueue.isEmpty {
                isSending = false
                if !_connected && !outQueue.isEmpty {
                    activeStatus = "等待接收端重连（排队 \(outQueue.count) 项）"
                } else if _connected && outQueue.isEmpty && activeStatus.hasPrefix("发送") {
                    activeStatus = "已连接（端口 \(listenPort)）· 可拖入文件直传"
                }
                stateLock.unlock()
                notifyUI()
                return
            }
            let item = outQueue.removeFirst()
            nextTransferId &+= 1
            if nextTransferId == 0 { nextTransferId = 1 }
            let tid = nextTransferId
            stateLock.unlock()

            let outcome: SendOutcome
            switch item {
            case .file(let url, _):
                outcome = sendSingleFile(url: url, id: tid)
            case .text(let utf8, let preview):
                outcome = sendSingleText(utf8: utf8, preview: preview, id: tid)
            }
            switch outcome {
            case .sent, .localFailed:
                if case .file(let url, let del) = item, del {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            case .connLost:
                // 连接断开或已切换为新连接：重入队头；若已有新连接在线直接续发，不丢队
                stateLock.lock()
                if !stopped {
                    outQueue.insert(item, at: 0)
                } else if case .file(let url, let del) = item, del {
                    try? FileManager.default.removeItem(at: url)
                }
                let canContinue = _connected && !stopped
                if !canContinue { isSending = false }
                stateLock.unlock()
                if canContinue { continue }
                notifyUI()
                return
            }
        }
    }

    private func sendSingleText(utf8: Data, preview: String, id: UInt32) -> SendOutcome {
        var activeConn: NWConnection?
        var epochSnap = 0
        netQueue.sync {
            activeConn = self.conn
            epochSnap = self.connEpoch
        }
        guard let c = activeConn else { return .connLost }

        var frame = Data(capacity: 5 + 4 + utf8.count)
        frame.append(Self.typeText)
        appendU32(&frame, UInt32(4 + utf8.count))
        appendU32(&frame, id)
        frame.append(utf8)

        updateStatus("发送文本: \(preview)", busy: true, progress: 0.5, speed: "")

        let cond = NSCondition()
        var done = false
        var sendErr: Error?
        c.send(content: frame, completion: .contentProcessed { err in
            cond.lock()
            sendErr = err
            done = true
            cond.broadcast()
            cond.unlock()
        })

        let waitUntil = Date().addingTimeInterval(5.0)
        cond.lock()
        while !done && Date() < waitUntil {
            stateLock.lock()
            let alive = !stopped && _connected && activeEpoch == epochSnap
            stateLock.unlock()
            if !alive { break }
            cond.wait(until: Date().addingTimeInterval(0.1))
        }
        let ok = done && sendErr == nil
        cond.unlock()

        if ok {
            pushHistory("↑ 文本: \(preview)")
            updateStatus("已发送文本: \(preview)", busy: false, progress: 1.0, speed: "")
            showFeedback(kind: 1, title: "已发送文本", detail: preview)
            Log.info("中转站发送文本完成 #\(id) (\(utf8.count) B)")
            return .sent
        }
        if let sendErr {
            Log.info("中转站发送文本失败 #\(id): \(sendErr)")
        }
        updateStatus("发送文本中断: \(preview)", busy: false, progress: 0, speed: "")
        showFeedback(kind: -1, title: "发送中断", detail: preview)
        return .connLost
    }

    private func sendSingleFile(url: URL, id: UInt32) -> SendOutcome {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
              let fh = try? FileHandle(forReadingFrom: url) else {
            Log.info("中转站无法读取文件: \(url.path)")
            updateStatus("读取失败: \(url.lastPathComponent)", busy: false, progress: 0, speed: "")
            showFeedback(kind: -1, title: "读取失败", detail: url.lastPathComponent)
            return .localFailed
        }
        defer { try? fh.close() }

        var activeConn: NWConnection?
        var epochSnap = 0
        netQueue.sync {
            activeConn = self.conn
            epochSnap = self.connEpoch
        }
        guard let c = activeConn else { return .connLost }

        let nameData = Data(url.lastPathComponent.utf8.prefix(4096))
        var beginFrame = Data(capacity: 5 + 14 + nameData.count)
        beginFrame.append(Self.typeBegin)
        appendU32(&beginFrame, UInt32(14 + nameData.count))
        appendU32(&beginFrame, id)
        appendU64(&beginFrame, fileSize)
        appendU16(&beginFrame, UInt16(nameData.count))
        beginFrame.append(nameData)

        let cond = NSCondition()
        var inFlight = 0
        var sendFailed = false
        let started = CFAbsoluteTimeGetCurrent()
        let fname = url.lastPathComponent
        updateStatus("发送中: \(fname) (0%)", busy: true, progress: 0, speed: "")
        Log.info("中转站开始发送 #\(id): \(fname) (\(fmtBytes(fileSize)))")

        func connAlive() -> Bool {
            stateLock.lock()
            let ok = !stopped && _connected && activeEpoch == epochSnap
            stateLock.unlock()
            return ok
        }

        func sendFrame(_ data: Data) -> Bool {
            cond.lock()
            while inFlight >= 4 && !sendFailed {
                if !connAlive() { sendFailed = true; break }
                cond.wait(until: Date().addingTimeInterval(0.2))
            }
            if sendFailed {
                cond.unlock()
                return false
            }
            inFlight += 1
            cond.unlock()

            c.send(content: data, completion: .contentProcessed { [weak self] err in
                cond.lock()
                inFlight = max(0, inFlight - 1)
                if err != nil {
                    sendFailed = true
                    Log.info("中转站发送 chunk 失败: \(err!)")
                }
                cond.broadcast()
                cond.unlock()
                _ = self
            })
            return true
        }

        if !sendFrame(beginFrame) {
            updateStatus("发送中断: \(fname)", busy: false, progress: 0, speed: "")
            showFeedback(kind: -1, title: "发送中断", detail: fname)
            return .connLost
        }

        var sentBytes: UInt64 = 0
        var readErr = false
        var lastUiAt = CFAbsoluteTimeGetCurrent()
        let chunkCap = 262_144
        while true {
            if !connAlive() || sendFailed { break }

            let chunk: Data
            do {
                chunk = try fh.read(upToCount: chunkCap) ?? Data()
            } catch {
                Log.info("中转站读文件失败: \(error)")
                readErr = true
                break
            }
            if chunk.isEmpty { break }

            var frame = Data(capacity: 5 + 8 + chunk.count)
            frame.append(Self.typeChunk)
            appendU32(&frame, UInt32(8 + chunk.count))
            appendU32(&frame, id)
            appendU32(&frame, UInt32(chunk.count))
            frame.append(chunk)
            if !sendFrame(frame) { break }

            sentBytes += UInt64(chunk.count)
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastUiAt >= 0.2 {
                lastUiAt = now
                let dt = max(0.01, now - started)
                let speed = Double(sentBytes) / dt / 1_048_576.0
                let frac = fileSize > 0 ? min(1.0, Double(sentBytes) / Double(fileSize)) : 1.0
                let pct = Int(frac * 100.0)
                updateStatus(String(format: "发送 %@ · %d%% · %.0f MB/s", fname, pct, speed),
                             busy: true, progress: frac, speed: String(format: "%.0f MB/s", speed))
            }
        }

        let complete = !readErr && !sendFailed && connAlive() && (sentBytes == fileSize)
        if !connAlive() || sendFailed {
            // 连接已断，不再尝试发 endFrame
            updateStatus("发送中断: \(fname)", busy: false, progress: 0, speed: "")
            showFeedback(kind: -1, title: "发送中断", detail: fname)
            return .connLost
        }

        var endFrame = Data(capacity: 10)
        endFrame.append(Self.typeEnd)
        appendU32(&endFrame, 5)
        appendU32(&endFrame, id)
        endFrame.append(complete ? 1 : 0)
        _ = sendFrame(endFrame)

        // 等所有在途包落网，确认发送完整再记账
        cond.lock()
        let waitUntil = Date().addingTimeInterval(5.0)
        while inFlight > 0 && !sendFailed && connAlive() && Date() < waitUntil {
            cond.wait(until: Date().addingTimeInterval(0.1))
        }
        let ok = complete && !sendFailed && inFlight == 0
        cond.unlock()

        if ok {
            let dt = max(0.001, CFAbsoluteTimeGetCurrent() - started)
            let speed = Double(sentBytes) / dt / 1_048_576.0
            pushHistory("↑ \(fname) (\(fmtBytes(sentBytes)))")
            updateStatus(String(format: "已发送: %@ (%.0f MB/s)", fname, speed),
                         busy: false, progress: 1.0, speed: String(format: "%.0f MB/s", speed))
            showFeedback(kind: 1, title: String(format: "已发送 · %.0f MB/s", speed), detail: fname)
            Log.info("中转站发送完成 #\(id): \(fname) (\(fmtBytes(sentBytes)), \(String(format: "%.1f", speed)) MB/s)")
            return .sent
        }
        if readErr {
            updateStatus("读取失败: \(fname)", busy: false, progress: 0, speed: "")
            showFeedback(kind: -1, title: "读取失败", detail: fname)
            return .localFailed
        }
        updateStatus("发送中断: \(fname)", busy: false, progress: 0, speed: "")
        showFeedback(kind: -1, title: "发送中断", detail: fname)
        return .connLost
    }

    private func updateStatus(_ s: String, busy: Bool = false, progress: Double = 0, speed: String = "") {
        stateLock.lock()
        activeStatus = s
        activeBusy = busy
        activeProgress = progress
        activeSpeedText = speed
        if busy {
            feedbackSeq &+= 1
            activeFeedbackKind = 0
            activeFeedbackTitle = ""
            activeFeedbackDetail = ""
        }
        stateLock.unlock()
        notifyUI()
    }

    private func pushHistory(_ item: String) {
        stateLock.lock()
        recentHistory.insert(item, at: 0)
        if recentHistory.count > 4 { recentHistory.removeLast(recentHistory.count - 4) }
        stateLock.unlock()
        notifyUI()
    }

    private func notifyUI() {
        DispatchQueue.main.async {
            AppModel.shared.refreshTransferOnly()
        }
    }

    private func sanitizeFilename(_ raw: String, fallbackId: UInt32) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        let last = unified.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = last.filter { c in
            guard let scalar = c.unicodeScalars.first else { return false }
            if scalar.value < 0x20 || scalar.value == 0x7f { return false }
            return c != ":" && c != "/" && c != "\\"
        }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "file_\(fallbackId)"
        }
        return cleaned
    }

    private func uniqueDestURL(safeName: String) -> URL {
        let fm = FileManager.default
        let first = inboxURL.appendingPathComponent(safeName)
        if !fm.fileExists(atPath: first.path) { return first }
        let ns = safeName as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        for idx in 1...9999 {
            let cand = ext.isEmpty ? "\(stem) (\(idx))" : "\(stem) (\(idx)).\(ext)"
            let u = inboxURL.appendingPathComponent(cand)
            if !fm.fileExists(atPath: u.path) { return u }
        }
        let fallbackName = ext.isEmpty
            ? "\(stem)_\(Int(CFAbsoluteTimeGetCurrent()))"
            : "\(stem)_\(Int(CFAbsoluteTimeGetCurrent())).\(ext)"
        return inboxURL.appendingPathComponent(fallbackName)
    }

    private func fmtBytes(_ n: UInt64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.2f GB", Double(n) / 1_073_741_824.0) }
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576.0) }
        if n >= 1024 { return String(format: "%.0f KB", Double(n) / 1024.0) }
        return "\(n) B"
    }

    private func appendU16(_ d: inout Data, _ v: UInt16) { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
    private func appendU32(_ d: inout Data, _ v: UInt32) { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
    private func appendU64(_ d: inout Data, _ v: UInt64) { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
    private func readU16(_ d: Data, _ o: Int) -> UInt16 {
        (UInt16(d[d.startIndex + o]) << 8) | UInt16(d[d.startIndex + o + 1])
    }
    private func readU32(_ d: Data, _ o: Int) -> UInt32 {
        (UInt32(d[d.startIndex + o]) << 24) | (UInt32(d[d.startIndex + o + 1]) << 16)
        | (UInt32(d[d.startIndex + o + 2]) << 8) | UInt32(d[d.startIndex + o + 3])
    }
    private func readU64(_ d: Data, _ o: Int) -> UInt64 {
        (UInt64(readU32(d, o)) << 32) | UInt64(readU32(d, o + 4))
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

nonisolated(unsafe) var appRole: SecDisplayRole = {
    let args = CommandLine.arguments
    if args.contains("--receiver") { return .receiver }
    if args.contains("--sender") { return .sender }
    if let i = args.firstIndex(of: "--mode"), i + 1 < args.count {
        let m = args[i + 1].lowercased()
        if m == "receiver" || m == "client" { return .receiver }
        if m == "sender" || m == "host" { return .sender }
    }
    if let env = ProcessInfo.processInfo.environment["SECDISPLAY_MODE"]?.lowercased() {
        if env == "receiver" || env == "client" { return .receiver }
        if env == "sender" || env == "host" { return .sender }
    }
    if let saved = UserDefaults.standard.string(forKey: "SecDisplayRole"),
       let r = SecDisplayRole(rawValue: saved) {
        return r
    }
    return .sender
}()

nonisolated(unsafe) var winHostAddress: String = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--host"), i + 1 < args.count {
        let h = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { return h }
    }
    if let env = ProcessInfo.processInfo.environment["SECDISPLAY_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !env.isEmpty {
        return env
    }
    if let saved = UserDefaults.standard.string(forKey: "SecDisplayWinHost")?.trimmingCharacters(in: .whitespacesAndNewlines),
       !saved.isEmpty {
        return saved
    }
    return "10.10.10.2"
}()

private let waitLockMs: Int = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--wait-lock"), i + 1 < args.count, let v = Int(args[i + 1]) {
        return max(0, v)
    }
    return 0
}()

// 单实例：两个发送端会各建一块虚拟屏，还会抢 9922 端口，表现为画面来回跳。
// 用 flock 而不是 pid 文件：锁在进程退出时由内核释放，不存在 pid 被回收后的误判。
do {
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/SecDisplay")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let lockPath = (dir as NSString).appendingPathComponent("sender.lock")
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 {
        var waited = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if waited >= waitLockMs {
                Log.info("已有 SecDisplay 实例在运行，本次启动退出。如需重启先结束旧进程。")
                exit(0)
            }
            usleep(50_000)
            waited += 50
        }
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

/// 采集像素格式：420v 省内存（44MB）但帧率掉一半，bgra 保帧率（136MB）。
/// 同样支持环境变量与 bundle 内资源文件两种来源 —— 从 Finder 启动的 .app
/// 拿不到环境变量，没有这个文件的话省内存选项等于用户根本用不上。
/// 写 Contents/Resources/pixfmt 内容为 420v 即可切换。
/// 两端均已显式锚定 BT.709 矩阵与 sRGB 传递函数。
var pixelFormatChoice = ProcessInfo.processInfo.environment["SECDISPLAY_PIXFMT"]
if pixelFormatChoice == nil, let rp = Bundle.main.resourcePath {
    let p = rp + "/pixfmt"
    if let s = try? String(contentsOfFile: p, encoding: .utf8) {
        pixelFormatChoice = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
if let preset = presetName, !preset.isEmpty {
    switch preset {
    case "sharp", "balanced":   // 别名：sharp 与 balanced 同档（画质优先）
        cfg.width = 2880; cfg.height = 1800
        cfg.logicalWidth = 1440; cfg.logicalHeight = 900
        cfg.captureHz = (preset == "sharp") ? 45 : 50
    case "smooth":      // 2240×1400 真 2x Retina（1120×700 逻辑），流畅度优先
        cfg.width = 2240; cfg.height = 1400
        cfg.logicalWidth = 1120; cfg.logicalHeight = 700
        cfg.captureHz = 60
    case "compact", "fast":     // 别名：compact 映射到省资源档，避免面板出现「自定义」
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
// 面板里调过的帧率/码率持久化在 UserDefaults，启动时覆盖预设。
// 门控：只有「当前预设档位」与面板保存时一致才套用 —— 否则用户用 preset.sh 或
// .preset 切了 sharp/smooth/fast 后，旧面板值会静默压掉新档位的帧率与码率。
// 显式环境变量优先级最高，直接跳过面板值。
let savedTuningPreset = UserDefaults.standard.string(forKey: "SecDisplayTuningPreset")
let tuningPresetMatches = (savedTuningPreset == presetName)
// 帧率与码率分别门控：只设 SECDISPLAY_MBPS 时不该连保存的帧率一起丢掉。
let useSavedHz = tuningPresetMatches
    && ProcessInfo.processInfo.environment["SECDISPLAY_HZ"] == nil
let useSavedMbps = tuningPresetMatches
    && ProcessInfo.processInfo.environment["SECDISPLAY_MBPS"] == nil
if useSavedHz,
   let hz = UserDefaults.standard.object(forKey: "SecDisplayCaptureHz") as? Double,
   hz >= 20, hz <= 120 {
    cfg.captureHz = hz
}
// 虚拟屏刷新率默认跟随采集上限，默认 60。
// 内建屏 120Hz 与 90Hz 虚拟屏同时在线时，WindowServer 要给两套不整除的
// 节拍排帧，合成开销和光标抖动都会放大。显式指定用 SECDISPLAY_REFRESH。
// 必须放在帧率覆盖之后，否则面板改 60fps 后虚拟屏仍按预设 50Hz 建模式。
if let r = Double(ProcessInfo.processInfo.environment["SECDISPLAY_REFRESH"] ?? ""), r >= 24 {
    cfg.refreshRate = r
} else {
    cfg.refreshRate = cfg.captureHz
}
// 码率按像素率估算，系数 0.6（2880x1800@50 约 155 Mbps，2240x1400@60 约 113 Mbps）。
// RateController 会按链路健康度在 [target/3, target] 之间自适应，上限 clamp 到 200。
// 同样必须在帧率覆盖之后算，否则 60fps 仍按 50fps 的像素率给码率。
if let mbps = Int(ProcessInfo.processInfo.environment["SECDISPLAY_MBPS"] ?? ""),
   mbps >= 10, mbps <= 1000 {
    cfg.bitrateMbps = mbps
} else if useSavedMbps,
          let mb = UserDefaults.standard.object(forKey: "SecDisplayMaxMbps") as? Int,
          mb >= 20, mb <= 300 {
    cfg.bitrateMbps = mb
} else {
    let pixelsPerSec = Double(cfg.width * cfg.height) * cfg.captureHz
    cfg.bitrateMbps = max(30, min(200, Int(pixelsPerSec * 0.6 / 1_000_000)))
}
nonisolated(unsafe) var vd: VirtualDisplayManager?
nonisolated(unsafe) var encoder: Encoder?
nonisolated(unsafe) var sender: Sender?
nonisolated(unsafe) var cap: ScreenshotCapture?
nonisolated(unsafe) var injector: InputInjector?
nonisolated(unsafe) var keyboard: KeyboardInjector?
nonisolated(unsafe) var cursor: CursorTracker?
nonisolated(unsafe) var cursorImage: CursorImageTracker?
nonisolated(unsafe) var rateCtl: RateController?
nonisolated(unsafe) var clientWatchdog: ClientWatchdog?

nonisolated(unsafe) var macReceiverClient: MacReceiverClient?
nonisolated(unsafe) var macReceiverWindow: ReceiverWindowController?

let transferService = FileTransferService()
var disableCursorImage = ProcessInfo.processInfo.environment["SECDISPLAY_NOCURSORIMG"] == "1"

func logicalDisplayBounds(_ id: CGDirectDisplayID) -> CGRect {
    let b = CGDisplayBounds(id)
    if let m = CGDisplayCopyDisplayMode(id), m.width > 0, m.height > 0 {
        return CGRect(x: b.origin.x, y: b.origin.y,
                      width: CGFloat(m.width), height: CGFloat(m.height))
    }
    return b
}

let cfgStateLock = NSLock()
private nonisolated(unsafe) var _screenCaptureDenied = false
private nonisolated(unsafe) var _tccConflictWarning: String? = nil

func isScreenCaptureDenied() -> Bool {
    cfgStateLock.lock(); defer { cfgStateLock.unlock() }
    return _screenCaptureDenied
}

func setScreenCaptureDenied(_ v: Bool) {
    cfgStateLock.lock(); _screenCaptureDenied = v; cfgStateLock.unlock()
}

func currentTccConflictWarning() -> String? {
    cfgStateLock.lock(); defer { cfgStateLock.unlock() }
    return _tccConflictWarning
}

func setTccConflictWarning(_ msg: String?) {
    cfgStateLock.lock(); _tccConflictWarning = msg; cfgStateLock.unlock()
}

func detectConflictingTccPathEntry() -> String? {
    let tccDb = "/Library/Application Support/com.apple.TCC/TCC.db"
    guard FileManager.default.isReadableFile(atPath: tccDb) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["-readonly", tccDb,
                   "SELECT client FROM access WHERE service='kTCCServiceScreenCapture' AND client_type=1 AND auth_value=0;"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let out = String(data: data, encoding: .utf8) else { return nil }
    let bundlePath = Bundle.main.bundlePath
    let exePath = Bundle.main.executablePath ?? ""
    let rows = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    for r in rows where !r.isEmpty {
        if r == bundlePath || r == exePath {
            return "检测到 TCC 存在旧路径拒绝条目（\(r) auth=0），可能引发反复弹窗"
        }
    }
    return nil
}

func resetScreenCaptureTccEntriesAndOpenSettings() {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.secdisplay.screensender"
    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "ScreenCapture", bundleID]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var ok = false
        do {
            try p.run()
            p.waitUntilExit()
            ok = (p.terminationStatus == 0)
        } catch {
            ok = false
        }
        let stillPathConflict = detectConflictingTccPathEntry()
        setTccConflictWarning(stillPathConflict)
        DispatchQueue.main.async {
            let cmd = stillPathConflict != nil
                ? "tccutil reset ScreenCapture"
                : "tccutil reset ScreenCapture \(bundleID)"
            if !ok || stillPathConflict != nil {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(cmd, forType: .string)
                Log.info("提示: 存在路径型 TCC 旧记录（需在系统设置点「-」删除 SecDisplay.app 或终端执行已复制命令: \(cmd)）")
            } else {
                Log.info("已重置 \(bundleID) 录屏授权并打开系统设置，勾选 SecDisplay 后点「重启应用」即可")
            }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

func currentVideoSizeSnapshot() -> (w: Int, h: Int, lw: Int, lh: Int) {
    cfgStateLock.lock()
    defer { cfgStateLock.unlock() }
    return (cfg.width, cfg.height, cfg.logicalWidth, cfg.logicalHeight)
}

if appRole == .sender {
    let vdInst = VirtualDisplayManager()
    let encInst = Encoder(width: cfg.width, height: cfg.height, bitrateMbps: cfg.bitrateMbps, captureHz: cfg.captureHz)
    let sndInst = Sender()
    vd = vdInst
    encoder = encInst
    gEncoder = encInst
    sender = sndInst

    sndInst.keepAliveGap = cfg.keepAliveGap
    sndInst.sessionWidth = cfg.width
    sndInst.sessionHeight = cfg.height
    sndInst.sessionFps = Int(cfg.captureHz.rounded())

    guard encInst.start() else { exit(3) }

    encInst.onFrame = { data, isKey, ts in
        sndInst.send(frame: data, captureTimeMicros: ts)
    }

    if CommandLine.arguments.contains("--cleanup-orphan")
        || ProcessInfo.processInfo.environment["SECDISPLAY_CLEANUP_ORPHAN"] == "1" {
        let residual = listSecDisplays()
        if !residual.isEmpty {
            Log.info("启动前发现残留虚拟屏 \(residual.count) 块，执行显示重配置清理")
            reconfigureDisplays()
        }
    }

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
        try vdInst.create(cfg)
    } catch VirtualDisplayManager.Err.initFailed {
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

    MirrorGuard.install(vdInst.displayID)
    MirrorGuard.release("建屏后")

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

    sndInst.sessionScaleTenths = UInt8(clamping: Int((vdBackingScale * 10.0).rounded()))
    sndInst.onKeyframeRequest = { encInst.forceEncodeLastFrame() }
    sndInst.onPeerConnected = {
        DispatchQueue.main.async {
            ConnectionGuideOverlay.shared.showIfEnabled(vdID: vdInst.displayID)
        }
    }
    sndInst.listen(port: cfg.port)

    transferService.listen(port: cfg.port &+ 1)

    let axTrusted = AXIsProcessTrusted()
    if !axTrusted {
        Log.info("警告: 未获得辅助功能权限，副屏上的点击/滚轮无法生效")
        Log.info("      系统设置 → 隐私与安全性 → 辅助功能，勾选 \(Bundle.main.bundlePath)")
    } else {
        Log.info("辅助功能权限: 已授权，副屏点击与滚轮可正常回放")
    }

    let injInst = InputInjector()
    injector = injInst
    gMouse = injInst
    sndInst.onInput = { x, y, buttons, wheel in
        let snap = currentVideoSizeSnapshot()
        injInst.handle(x: x, y: y, buttons: buttons, wheel: wheel,
                       bounds: logicalDisplayBounds(vdInst.displayID),
                       videoW: snap.w, videoH: snap.h)
    }

    let kbInst = KeyboardInjector()
    keyboard = kbInst
    gKeyboard = kbInst
    sndInst.onKey = { vk, scan, down, flags in
        kbInst.handle(vk: vk, scan: scan, down: down, keyFlags: flags)
    }

    let vb = logicalDisplayBounds(vdInst.displayID)
    Log.info("坐标基准: 逻辑点 \(Int(vb.width))x\(Int(vb.height)) * \(String(format: "%.2f", vdBackingScale))x → 线上 \(cfg.width)x\(cfg.height)，原点 (\(Int(vb.minX)), \(Int(vb.minY)))")
    let curInst = CursorTracker(sender: sndInst,
                                bounds: { logicalDisplayBounds(vdInst.displayID) },
                                videoSize: {
                                    let snap = currentVideoSizeSnapshot()
                                    return (snap.w, snap.h)
                                })
    cursor = curInst
    let curImgInst = CursorImageTracker(sender: sndInst)
    cursorImage = curImgInst
    if disableCursorImage {
        Log.info("已关闭真实光标图像(0x05)，使用接收端标准箭头（SECDISPLAY_NOCURSORIMG=1）")
    }

    let capInst = ScreenshotCapture(encoder: encInst, cfg: cfg, displayID: { vdInst.displayID })
    cap = capInst
    Task.detached(priority: .utility) {
        if let conflict = detectConflictingTccPathEntry() {
            setTccConflictWarning(conflict)
            Log.info("警告: \(conflict)。请在面板点击「清理冲突并重授权」或在终端执行 tccutil reset ScreenCapture")
        }
    }
    Task {
        let preflightOk = CGPreflightScreenCaptureAccess()
        Log.info("屏幕录制权限预检: \(preflightOk ? "已授权" : "未授权")")
        let didPromptKey = "SecDisplayDidRequestScreenCapture"
        if !preflightOk {
            setScreenCaptureDenied(true)
            // 整个应用生命周期内仅在首次未授权时主动触发一次系统授权请求；
            // 若用户已拒绝或手动关闭权限，后续重启绝不再次弹窗打扰，仅静默等待用户在系统设置授权。
            if !UserDefaults.standard.bool(forKey: didPromptKey) {
                UserDefaults.standard.set(true, forKey: didPromptKey)
                _ = CGRequestScreenCaptureAccess()
            } else {
                Log.info("之前已请求过录屏权限且当前未授权，静默等待授权（不再自动弹窗）")
            }
            while !CGPreflightScreenCaptureAccess() {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if vdInst.displayID == 0 || capInst.isStopRequested { return }
            }
            if vdInst.displayID == 0 || capInst.isStopRequested { return }
            setScreenCaptureDenied(false)
            Log.info("屏幕录制权限已通过预检，开始启动采集")
        } else {
            UserDefaults.standard.set(true, forKey: didPromptKey)
        }
        do {
            try await capInst.start()
        } catch {
            let nsErr = error as NSError
            let isPerm = (nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" &&
                          nsErr.code == SCStreamError.userDeclined.rawValue) ||
                         !CGPreflightScreenCaptureAccess()
            Log.info("抓屏失败: \(error)")
            if isPerm {
                Log.info("需要屏幕录制权限：系统设置 → 隐私与安全性 → 屏幕录制")
                setScreenCaptureDenied(true)
            } else {
                Log.info("非权限类采集启动失败，销毁虚拟屏并退出")
                vdInst.destroy()
                exit(4)
            }
        }
    }
} else {
    Log.info("SecDisplay 副屏模式启动: 监听端口 \(cfg.port)/\(cfg.port &+ 1)，等待 Windows 主控端连接")
    let rc = MacReceiverClient()
    let allowedRaw = ProcessInfo.processInfo.environment["SECDISPLAY_ALLOWED_HOST"]
        ?? UserDefaults.standard.string(forKey: "SecDisplayAllowedHost")
        ?? ""
    if !allowedRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        rc.setAllowedHosts(allowedRaw)
    }
    macReceiverClient = rc
    rc.listen(port: cfg.port)
    transferService.listen(port: cfg.port &+ 1)
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
    var targetMbps: Int
    /// 面板可在线改采集帧率；所有读写都在主线程（定时器与面板同线程），无需加锁。
    private var captureHz: Double

    func updateTargetMbps(_ mbps: Int) {
        targetMbps = mbps
        current = mbps
        probeMbps = nil
        highRounds = 0
        lowRounds = 0
        idleRounds = 0
        revertCooldownUntil = 0
        lastDownAt = 0
    }
    /// 面板在线改采集帧率时同步刷新预算判据，否则 health 仍按旧帧率算。
    func updateCaptureHz(_ hz: Double) {
        captureHz = hz
    }
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

    /// 面板展示用：当前生效码率
    var currentBitrate: Int { current }
    /// 面板展示用：最近一轮健康度（>1 表示过载）
    private(set) var lastHealth: Double = 0

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
            // 静止时没有编码负载，把健康度归零，否则面板会一直停在
            // 最后一次非静止时的数值（可能长期红着），排障时误导。
            lastHealth = 0
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
        lastHealth = health

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

if appRole == .sender, let enc = encoder {
    let rc = RateController(encoder: enc, targetMbps: cfg.bitrateMbps, captureHz: cfg.captureHz)
    rateCtl = rc
}

// 帧率峰值跟踪：每秒采一次完整帧数，保留最近 10 秒的最大值。
// 用户操作往往很短暂，只看 2 秒瞬时值容易错过。
var fpsWindow: [(Double, Double)] = []
var lastCapCount = 0
var lastCapTime = CFAbsoluteTimeGetCurrent()
var peakFps: Double = 0
var lastCursorCount = 0
var lastCursorImageCount = 0

if appRole == .sender {
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        guard let cap else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastCapTime
        guard dt > 0.5 else { return }
        let delta = cap.captured - lastCapCount
        lastCapCount = cap.captured
        lastCapTime = now
        let fps = Double(delta) / dt
        fpsWindow.append((now, fps))
        fpsWindow.removeAll { now - $0.0 > 10 }
        peakFps = fpsWindow.map { $0.1 }.max() ?? 0
    }
}

// 统计
var lastDroppedCount = 0
var lastCapturedCount = 0
/// 面板展示用的最近一轮统计
var lastEncAvgMs: Double = 0
var lastCapAvgMs: Double = 0
var lastMbps: Double = 0
if appRole == .sender {
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
        guard let cap, let encoder, let sender, let rateCtl, let cursor, let cursorImage, let injector else { return }
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
        Log.info(String(format: "采集 %ld  峰值 %.0ffps  异常 %ld  发送 %ld  光标+%ld  图像+%ld  输入 %ld  丢弃 %ld  %.1f Mbps  在途 %ld  采集延迟 %.1f  编码延迟 %.1f ms",
                        cap.captured, peakFps, cap.captureRestartCount, sender.sent, cursorDelta, imgDelta,
                        injector.eventCount, sender.dropped, mbps, sender.inFlight, capAvg, encAvg))
        cap.capLatSum = 0; cap.capLatCount = 0; cap.capLatMax = 0
        encoder.encLatSum = 0; encoder.encLatCount = 0; encoder.encLatMax = 0
        sender.sentBytes = 0
        sender.sent = 0
    }
} else {
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
        guard let snap = macReceiverClient?.snapshot(), snap.connected else { return }
        Log.info(String(format: "MacReceiver: %ldx%ld  %.1f fps  %.1f Mbps  p95 %.1f/%.1f ms  累计 %llu 帧  错误 %llu  丢帧 %llu  光标 %llu  输入 %llu",
                        snap.width, snap.height, snap.decodeFps, snap.mbps,
                        snap.sourceP95, snap.presentP95,
                        snap.decodedFrames, snap.decodeErrors, snap.droppedFrames,
                        snap.cursorRecv, snap.inputSent))
    }
}

// 信号处理只置标志位，实际清理在主循环里做
VirtualDisplayGuard.install()

/// 虚拟屏是否仍在线（按 EDID 三元组识别，不误伤 Sidecar）。
func vdStillOnline() -> Bool {
    var n: UInt32 = 0
    CGGetOnlineDisplayList(32, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    return ids.prefix(Int(n)).contains { isOurVirtualDisplay($0) }
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

func shutdown(signal sig: Int32, exitCode: Int32 = -1) {
    shutdownLock.lock()
    if shutdownStarted {
        shutdownLock.unlock()
        Log.info("已在清理中，忽略重复退出请求（信号 \(sig)）")
        return
    }
    shutdownStarted = true
    shutdownLock.unlock()

    Log.info("收到信号 \(sig)，开始清理")
    if appRole == .receiver {
        macReceiverWindow?.hide()
        macReceiverClient?.stop()
        transferService.stop()
        exit(0)
    }
    kvmPassthrough.setActive(false, notifyPeer: true)
    cap?.stop()
    transferService.stop()
    sender?.conn?.cancel()
    let stopDeadline = Date().addingTimeInterval(1.5)
    while Date() < stopDeadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.2))
    vd?.destroy()
    var waited = 0.0
    while vdStillOnline() && waited < 5.0 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        usleep(100_000); waited += 0.1
    }
    if vdStillOnline() {
        Log.info("警告: 虚拟屏疑似未清理干净，下次启动可能被拒；可注销重登清除")
    }
    // 导图等调试路径需要 exit(0) 让无人值守脚本判成功；正常退出沿用 128+sig。
    exit(exitCode >= 0 ? exitCode : 128 + sig)
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
//   2. 连上过又断开：连续断开 60 秒退出；链路已断（拔线）时缩到 5 秒
//      60 秒是给接收端重启（改配置、换分辨率、手动退出再开）留的窗口，
//      太短会让发送端在对方重启期间自己退出并销毁虚拟屏
//   3. 链路断满 5 秒直接算断开：拔线后 TCP 可能几十秒都不报错，
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
        if isScreenCaptureDenied() {
            // 等待用户授予屏幕录制权限期间暂停看门狗倒计时，防止 180 秒后误杀进程
            startedAt = now
            if everConnected { lastConnectedAt = now }
            linkDownSince = nil
            return
        }
        let link = currentLink()
        let connected = sender?.connected ?? false

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

if appRole == .sender {
    let wd = ClientWatchdog(
        initialGrace: Double(ProcessInfo.processInfo.environment["SECDISPLAY_INITIAL_GRACE"] ?? "") ?? 180,
        graceLinkUp: Double(ProcessInfo.processInfo.environment["SECDISPLAY_DISCONNECT_GRACE"] ?? "") ?? 60,
        graceLinkDown: Double(ProcessInfo.processInfo.environment["SECDISPLAY_DISCONNECT_GRACE_LINKDOWN"] ?? "") ?? 5
    )
    clientWatchdog = wd
    wd.start()
}

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

    @objc func openDropBox() {
        Log.info("菜单栏请求打开文件投递盒")
        showDropBoxPanel()
    }

    @objc func openReceiverWindow() {
        Log.info("菜单栏请求打开副屏显示窗口")
        macReceiverWindow?.show()
    }

    @objc func toggleRole() {
        let next: SecDisplayRole = (appRole == .sender) ? .receiver : .sender
        Log.info("菜单栏请求切换角色 -> \(next.rawValue)")
        restartWithRole(next, host: winHostAddress)
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
        button.toolTip = appRole == .receiver ? "SecDisplay 副屏 (Win→Mac)" : "SecDisplay 发送端"
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

    if appRole == .receiver {
        let winItem = NSMenuItem(title: "显示副屏窗口…", action: #selector(StatusMenuTarget.openReceiverWindow), keyEquivalent: "d")
        winItem.target = statusMenuTarget
        winItem.isEnabled = true
        menu.addItem(winItem)
    }

    let open = NSMenuItem(title: "打开面板…", action: #selector(StatusMenuTarget.openPanel), keyEquivalent: "o")
    open.target = statusMenuTarget
    open.isEnabled = true
    menu.addItem(open)

    let box = NSMenuItem(title: "文件投递盒… (Ctrl+Opt+B)", action: #selector(StatusMenuTarget.openDropBox), keyEquivalent: "b")
    box.target = statusMenuTarget
    box.isEnabled = true
    menu.addItem(box)

    let roleItem = NSMenuItem(
        title: appRole == .receiver ? "切回主控模式 (Mac→Win)" : "切到副屏模式 (Mac 当 Windows 副屏)",
        action: #selector(StatusMenuTarget.toggleRole),
        keyEquivalent: ""
    )
    roleItem.target = statusMenuTarget
    roleItem.isEnabled = true
    menu.addItem(roleItem)
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

// 每秒刷新菜单栏文字：连接状态、帧率、编码/解码指标
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    if let info = statusInfoItem {
        if appRole == .receiver {
            if let snap = macReceiverClient?.snapshot() {
                let st = snap.listenerError != nil ? "监听异常"
                       : (snap.kvmActive ? "KVM穿透控制中"
                       : (snap.streaming ? "正在接收" : (snap.connected ? "已连接等待" : "等待 Windows 主控")))
                info.title = String(format: "%@ · %.0f fps · %.1f Mbps", st, snap.decodeFps, snap.mbps)
            }
        } else if let encoder, let sender {
            let enc = encoder.encLatCount > 0 ? encoder.encLatSum / Double(encoder.encLatCount) : 0
            let conn = kvmPassthrough.isActive ? "KVM穿透中" : (sender.connected ? "已连接" : "等待连接")
            info.title = String(format: "%@ · %.0f fps · 编码 %.0f ms · %ld 在途",
                                conn, peakFps, enc, sender.inFlight)
        }
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
final class KvmPassthroughController {
    private let lock = NSLock()
    private var _active = false
    private var tap: CFMachPort?
    private var runLoopSrc: CFRunLoopSource?
    private var flushTimer: DispatchSourceTimer?
    private var accumDx: Int = 0
    private var accumDy: Int = 0
    private var buttonsMask: UInt8 = 0
    private var forwardedKeys = Set<UInt16>()
    private var heldModifiers = Set<UInt16>()

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _active
    }

    func toggle() {
        setActive(!isActive)
    }

    func setActive(_ on: Bool, notifyPeer: Bool = true) {
        if on {
            guard appRole == .sender, sender?.connected == true else {
                Log.info("KVM: Windows 副屏未连接，无法开启键鼠穿透")
                return
            }
            lock.lock()
            if _active { lock.unlock(); return }
            lock.unlock()

            if !ensureTapCreated() {
                Log.info("KVM: 创建 CGEventTap 失败（请检查「辅助功能」权限）")
                return
            }

            lock.lock()
            _active = true
            accumDx = 0
            accumDy = 0
            buttonsMask = 0
            forwardedKeys.removeAll()
            heldModifiers.removeAll()
            lock.unlock()

            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            startFlushTimer()
            if notifyPeer { sender?.sendKvmState(active: true) }
            Log.info("KVM: 已开启键鼠穿透（直接操作 Windows 系统），再按 Ctrl+Opt+K 退出")
        } else {
            lock.lock()
            let was = _active
            let prevBtns = buttonsMask
            let prevKeys = forwardedKeys
            let prevMods = heldModifiers
            _active = false
            accumDx = 0
            accumDy = 0
            buttonsMask = 0
            forwardedKeys.removeAll()
            heldModifiers.removeAll()
            lock.unlock()

            flushTimer?.cancel()
            flushTimer = nil
            if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            if was {
                if notifyPeer {
                    if prevBtns != 0 { sender?.sendKvmMouse(dx: 0, dy: 0, buttons: 0, wheel: 0) }
                    for kc in prevKeys {
                        if let wk = MacKeyMap.lookup(kc) {
                            sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
                        }
                    }
                    for kc in prevMods {
                        if let wk = MacKeyMap.lookup(kc) {
                            sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
                        }
                    }
                    sender?.sendKvmState(active: false)
                }
                Log.info("KVM: 已退出键鼠穿透，恢复操作 Mac")
            }
        }
    }

    private func ensureTapCreated() -> Bool {
        if tap != nil { return true }
        let events: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged
        ]
        var mask: CGEventMask = 0
        for e in events { mask |= CGEventMask(1 << e.rawValue) }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                return kvmPassthrough.handleEvent(type: type, event: event)
            },
            userInfo: nil
        ) else {
            return false
        }
        tap = created
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSrc = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: created, enable: false)
        return true
    }

    private func startFlushTimer() {
        flushTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now() + .milliseconds(8), repeating: .milliseconds(8))
        t.setEventHandler { [weak self] in
            self?.flushMoveIfNeeded()
        }
        t.resume()
        flushTimer = t
    }

    private func flushMoveIfNeeded() {
        lock.lock()
        guard _active, (accumDx != 0 || accumDy != 0) else {
            lock.unlock()
            return
        }
        let dx = Int16(clamping: accumDx)
        let dy = Int16(clamping: accumDy)
        let btns = buttonsMask
        accumDx = 0
        accumDy = 0
        lock.unlock()
        sender?.sendKvmMouse(dx: dx, dy: dy, buttons: btns, wheel: 0)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if isActive, let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isActive else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let mods = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            if (kc == UInt16(kVK_ANSI_K) || kc == UInt16(kVK_Escape)) && mods == [.maskControl, .maskAlternate] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { kvmPassthrough.setActive(false) }
                }
                return nil
            }
            if let wk = MacKeyMap.lookup(kc) {
                lock.lock()
                forwardedKeys.insert(kc)
                lock.unlock()
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: true, flags: wk.extended ? 0x01 : 0)
            }
            return nil

        case .keyUp:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            lock.lock()
            let wasFwd = forwardedKeys.remove(kc) != nil
            lock.unlock()
            if !wasFwd {
                return Unmanaged.passUnretained(event)
            }
            if let wk = MacKeyMap.lookup(kc) {
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
            }
            return nil

        case .flagsChanged:
            let kc = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let wk = MacKeyMap.lookup(kc), let mflag = MacKeyMap.modifierFlag(forKeyCode: kc) else {
                return Unmanaged.passUnretained(event)
            }
            if kc == 0x39 {
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: true, flags: 0)
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: false, flags: 0)
                return nil
            }
            let flagMap: CGEventFlags
            switch mflag {
            case .shift:   flagMap = .maskShift
            case .control: flagMap = .maskControl
            case .option:  flagMap = .maskAlternate
            case .command: flagMap = .maskCommand
            default:       flagMap = []
            }
            lock.lock()
            let wasDown = heldModifiers.contains(kc)
            if wasDown {
                heldModifiers.remove(kc)
                lock.unlock()
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
                return nil
            } else if !flagMap.isEmpty && event.flags.contains(flagMap) {
                heldModifiers.insert(kc)
                lock.unlock()
                sender?.sendKvmKey(vk: wk.vk, scan: wk.scan, down: true, flags: wk.extended ? 0x01 : 0)
                return nil
            } else {
                lock.unlock()
                return Unmanaged.passUnretained(event)
            }

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .scrollWheel:
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            var wheel: Int16 = 0
            var immediate = false
            lock.lock()
            accumDx += dx
            accumDy += dy
            switch type {
            case .leftMouseDown:  buttonsMask |= 0x01; immediate = true
            case .leftMouseUp:    buttonsMask &= ~0x01; immediate = true
            case .rightMouseDown: buttonsMask |= 0x02; immediate = true
            case .rightMouseUp:   buttonsMask &= ~0x02; immediate = true
            case .otherMouseDown: buttonsMask |= 0x04; immediate = true
            case .otherMouseUp:   buttonsMask &= ~0x04; immediate = true
            case .scrollWheel:
                let cont = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
                let raw = cont
                    ? event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) * 3
                    : event.getIntegerValueField(.scrollWheelEventDeltaAxis1) * 120
                wheel = Int16(clamping: raw)
                immediate = (wheel != 0)
            default:
                break
            }
            if immediate {
                let sdx = Int16(clamping: accumDx)
                let sdy = Int16(clamping: accumDy)
                let btns = buttonsMask
                accumDx = 0
                accumDy = 0
                lock.unlock()
                sender?.sendKvmMouse(dx: sdx, dy: sdy, buttons: btns, wheel: wheel)
            } else {
                lock.unlock()
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

nonisolated(unsafe) let kvmPassthrough = KvmPassthroughController()

nonisolated(unsafe) private var globalDropBoxTap: CFMachPort?
nonisolated(unsafe) private var globalDropBoxRunLoopSource: CFRunLoopSource?
nonisolated(unsafe) private var globalDropBoxKeyMon: Any?
nonisolated(unsafe) private var localDropBoxKeyMon: Any?

private func registerGlobalDropBoxHotKey() {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    if let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = globalDropBoxTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let mods = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
            if keyCode == Int64(kVK_ANSI_B) && mods == [.maskControl, .maskAlternate] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { toggleDropBoxPanel() }
                }
                return nil
            }
            if appRole == .sender && keyCode == Int64(kVK_ANSI_K) && mods == [.maskControl, .maskAlternate] {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { kvmPassthrough.toggle() }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) {
        globalDropBoxTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        globalDropBoxRunLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("全局快捷键已注册（Ctrl+Opt+B 投递盒 / Ctrl+Opt+K 键鼠穿透）")
        return
    }
    // 无辅助功能权限时降级为 NSEvent 全局/本地监听
    globalDropBoxKeyMon = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
        let mods = ev.modifierFlags.intersection([.control, .option, .command, .shift])
        if !ev.isARepeat && ev.keyCode == UInt16(kVK_ANSI_B) && mods == [.control, .option] {
            DispatchQueue.main.async { toggleDropBoxPanel() }
        }
    }
    localDropBoxKeyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
        let mods = ev.modifierFlags.intersection([.control, .option, .command, .shift])
        if ev.keyCode == UInt16(kVK_ANSI_B) && mods == [.control, .option] {
            if !ev.isARepeat {
                DispatchQueue.main.async { toggleDropBoxPanel() }
            }
            return nil
        }
        return ev
    }
    Log.info("全局快捷键 Ctrl+Opt+B 已注册（NSEvent 监听，一键呼出/隐藏投递盒）")
}

// 等 statusApp.run() 启动主事件循环后再注册全局鼠标监视器与光标图像轮询，
// 避免在 NSApplication 初始化之前抢先建立 SkyLight 事件通道导致窗口点击失灵。
DispatchQueue.main.async {
    if appRole == .receiver {
        if let rc = macReceiverClient {
            let rw = ReceiverWindowController(client: rc)
            macReceiverWindow = rw
            rw.show()
        }
        registerGlobalDropBoxHotKey()
        return
    }
    guard let vd, let encoder, let sender, let rateCtl, let cursor, let cursorImage else { return }
    onDisplayModeReconfig = {
        guard vd.displayID != 0, let m = CGDisplayCopyDisplayMode(vd.displayID) else { return }
        let pw = m.pixelWidth, ph = m.pixelHeight
        let lw = m.width, lh = m.height
        guard pw >= 320, ph >= 200, lw > 0, lh > 0 else { return }
        let snap = currentVideoSizeSnapshot()
        guard pw != snap.w || ph != snap.h || lw != snap.lw || lh != snap.lh else { return }
        let oldW = snap.w, oldH = snap.h
        let pixelsPerSec = Double(pw * ph) * cfg.captureHz
        let newMbps = max(30, min(200, Int(pixelsPerSec * 0.6 / 1_000_000)))
        if pw != oldW || ph != oldH {
            guard encoder.reconfigure(width: pw, height: ph, bitrateMbps: newMbps, captureHz: cfg.captureHz) else {
                Log.info("警告: 分辨率变更 \(oldW)x\(oldH) → \(pw)x\(ph) 重建编码器失败，保持原配置")
                return
            }
        }
        cfgStateLock.lock()
        cfg.width = pw
        cfg.height = ph
        cfg.logicalWidth = lw
        cfg.logicalHeight = lh
        cfg.bitrateMbps = newMbps
        vdBackingScale = Double(pw) / Double(lw)
        cfgStateLock.unlock()
        Log.info("检测到虚拟屏分辨率变化: \(oldW)x\(oldH) → \(pw)x\(ph) (逻辑 \(lw)x\(lh) scale=\(String(format: "%.2f", vdBackingScale)))")
        if pw != oldW || ph != oldH {
            rateCtl.updateTargetMbps(newMbps)
            gCaptureRebuildRequested = true
            sender.updateSessionInfo(width: pw, height: ph, fps: Int(cfg.captureHz.rounded()),
                                     scaleTenths: UInt8(clamping: Int((vdBackingScale * 10.0).rounded())))
        }
        AppModel.shared.refresh()
    }
    cursor.start()
    if !disableCursorImage {
        cursorImage.start()
    }
    registerGlobalDropBoxHotKey()
}

// 调试用：SECDISPLAY_SHOW_PANEL=1 启动后直接打开面板，便于不点菜单也能验证 UI。
if ProcessInfo.processInfo.environment["SECDISPLAY_SHOW_PANEL"] == "1" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        Log.info("SECDISPLAY_SHOW_PANEL=1，自动打开面板")
        showControlPanel()
    }
}

// 调试用：SECDISPLAY_GUIDE_DUMP=1 或日志目录下存在 guide_dump.request 时，
// 把「连接引导」渲染成 3 张 PNG 后退出，供无人值守环境直接检查动画效果。
let guideDumpReq = (Log.currentPath as NSString).deletingLastPathComponent + "/guide_dump.request"
let panelDumpReq = (Log.currentPath as NSString).deletingLastPathComponent + "/panel_dump.request"
if ProcessInfo.processInfo.environment["SECDISPLAY_GUIDE_DUMP"] == "1"
    || FileManager.default.fileExists(atPath: guideDumpReq)
    || ProcessInfo.processInfo.environment["SECDISPLAY_PANEL_DUMP"] == "1"
    || FileManager.default.fileExists(atPath: panelDumpReq) {
    let dir = (Log.currentPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if ProcessInfo.processInfo.environment["SECDISPLAY_GUIDE_DUMP"] == "1"
        || FileManager.default.fileExists(atPath: guideDumpReq) {
        let paths = ConnectionGuideOverlay.dumpFrames(to: dir)
        if paths.isEmpty {
            Log.info("引导动画导出失败: 0 张 PNG 写入成功（目录 \(dir)）")
        } else {
            Log.info("引导动画已导出 \(paths.count)/3 张: \(paths.joined(separator: ", "))")
        }
        // 只有三张都写成功才消耗 request，失败时留给下次重试
        if paths.count == 3, FileManager.default.fileExists(atPath: guideDumpReq) {
            try? FileManager.default.removeItem(atPath: guideDumpReq)
        }
    }
    if ProcessInfo.processInfo.environment["SECDISPLAY_PANEL_DUMP"] == "1"
        || FileManager.default.fileExists(atPath: panelDumpReq) {
        var panelOk = false
        var settingsOk = false
        // 脱离窗口离屏渲染 SwiftUI 时不会自动带材质背景，强制暗色外观 + 深底，
        // 否则浅色文字会落在白底上看不见，导图无法用于审阅。
        let root = ZStack(alignment: .top) {
            Color(NSColor(calibratedWhite: 0.12, alpha: 1)).ignoresSafeArea()
            StatusView()
        }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = NSSize(width: 420, height: 2400)
        host.frame = NSRect(origin: .zero, size: size)
        host.wantsLayer = true
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let p = dir + "/panel.png"
                do {
                    try png.write(to: URL(fileURLWithPath: p))
                    Log.info("控制面板已导出: \(p)")
                    panelOk = true
                } catch {
                    Log.info("控制面板导图写入失败: \(error.localizedDescription)")
                }
            }
        }
        // 单独导出「画质与性能」卡片：ScrollView 离屏只渲染视口，整面板导图看不到下半部分。
        let settingsRoot = ZStack(alignment: .top) {
            Color(NSColor(calibratedWhite: 0.12, alpha: 1)).ignoresSafeArea()
            QualitySettingsCard(model: AppModel.shared).padding(14)
        }
        let settingsHost = NSHostingView(rootView: settingsRoot)
        settingsHost.appearance = NSAppearance(named: .darkAqua)
        settingsHost.frame = NSRect(origin: .zero, size: NSSize(width: 420, height: 460))
        settingsHost.wantsLayer = true
        settingsHost.layoutSubtreeIfNeeded()
        if let rep2 = settingsHost.bitmapImageRepForCachingDisplay(in: settingsHost.bounds) {
            settingsHost.cacheDisplay(in: settingsHost.bounds, to: rep2)
            if let png = rep2.representation(using: .png, properties: [:]) {
                let p = dir + "/panel_settings.png"
                do {
                    try png.write(to: URL(fileURLWithPath: p))
                    Log.info("画质设置卡片已导出: \(p)")
                    settingsOk = true
                } catch {
                    Log.info("画质设置卡片导图写入失败: \(error.localizedDescription)")
                }
            }
        }
        if panelOk && settingsOk, FileManager.default.fileExists(atPath: panelDumpReq) {
            try? FileManager.default.removeItem(atPath: panelDumpReq)
        }
    }
    // 走完整 shutdown 清理：直接 vd?.destroy()+exit 不等 WindowServer 收敛，
    // 实测会留下孤儿虚拟屏，导致下次启动「虚拟屏创建被拒绝」。
    // 导图是调试路径，用 exit(0) 让无人值守脚本能按退出码判成功。
    shutdown(signal: SIGTERM, exitCode: 0)
}
statusApp.run()
