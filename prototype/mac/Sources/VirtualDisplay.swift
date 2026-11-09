// VirtualDisplay.swift
// 生产级虚拟屏模块。
//
// 三条硬要求（都是踩过的坑）：
//   1. 必须持有 CGVirtualDisplay 对象引用，弱引用会被 ARC 提前释放，屏就掉线
//   2. applySettings 返回 BOOL，必须用 @convention(c) 直接调用，不能用 perform
//   3. 进程退出（包括 Ctrl-C / SIGTERM / 异常）必须显式销毁，否则残留屏会占住 ID 导致下次创建失败

import Foundation
import CoreGraphics
import AppKit
import Darwin

/// 统一日志
enum VDLog {
    static func info(_ s: String) {
        let t = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 100000))
        FileHandle.standardError.write("[\(t)] \(s)\n".data(using: .utf8)!)
    }
}

/// 虚拟显示器句柄。持有对象期间屏一直在线。
final class VirtualDisplay {
    private let object: NSObject
    private let keepAliveQueue: DispatchQueue
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int

    private static var live: [ObjectIdentifier: VirtualDisplay] = [:]
    private static let lock = NSLock()
    private var destroyed = false

    fileprivate static func drop(_ vd: VirtualDisplay) {
        lock.lock()
        live.removeValue(forKey: ObjectIdentifier(vd))
        lock.unlock()
    }

    private init(object: NSObject, id: CGDirectDisplayID, w: Int, h: Int, queue: DispatchQueue) {
        self.object = object
        self.displayID = id
        self.pixelWidth = w
        self.pixelHeight = h
        self.keepAliveQueue = queue
    }

    enum CreateError: Error, CustomStringConvertible {
        case classesMissing
        case descriptorRejected
        case modeRejected
        case applyFailed
        case notOnline
        var description: String {
            switch self {
            case .classesMissing: return "系统缺少 CGVirtualDisplay 私有类"
            case .descriptorRejected: return "initWithDescriptor 被拒绝"
            case .modeRejected: return "模式创建失败"
            case .applyFailed: return "applySettings 返回 false"
            case .notOnline: return "applySettings 成功但屏未上线"
            }
        }
    }

    /// 创建并返回一块在线虚拟屏。
    ///
    /// - Parameters:
    ///   - pixelWidth/pixelHeight: 背板像素，应与对端屏幕物理分辨率一致
    ///   - logicalWidth/logicalHeight: 逻辑分辨率。等于像素→1:1；等于一半→2x Retina
    ///   - refreshRate: 刷新率
    static func create(pixelWidth: Int, pixelHeight: Int,
                       logicalWidth: Int? = nil, logicalHeight: Int? = nil,
                       refreshRate: Double = 60,
                       name: String = "SecDisplay") throws -> VirtualDisplay {

        guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let dispCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let modeCls = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
              let setCls  = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        else { throw CreateError.classesMissing }

        // 每个屏必须独占串行队列，共用队列会导致后建的屏静默不上线
        let queue = DispatchQueue(label: "SecDisplay.vd.\(name).\(UUID().uuidString)")

        let desc = descCls.init()
        // 专属 EDID 身份：与 ScreenSender.swift 的 kVDVendorID/ProductID/SerialNum 一致。
        // 避开内建 0x610、Sidecar 'aapl'/'iPad'，供采集侧用三元组精确锚定本屏，
        // 防止 Sidecar 插拔导致 displayID 漂移时抓错屏。
        desc.setValue(NSNumber(value: UInt32(0xEEEE)), forKey: "vendorID")
        desc.setValue(NSNumber(value: UInt32(0x5344)), forKey: "productID")
        desc.setValue(NSNumber(value: UInt32(0x0001)), forKey: "serialNum")
        desc.setValue(name, forKey: "name")
        desc.setValue(NSNumber(value: pixelWidth), forKey: "maxPixelsWide")
        desc.setValue(NSNumber(value: pixelHeight), forKey: "maxPixelsHigh")
        desc.setValue(NSValue(size: NSSize(width: 25.4 * Double(pixelWidth) / 110.0,
                                           height: 25.4 * Double(pixelHeight) / 110.0)),
                      forKey: "sizeInMillimeters")
        desc.setValue(NSValue(point: NSPoint(x: 0.6797, y: 0.3203)), forKey: "redPrimary")
        desc.setValue(NSValue(point: NSPoint(x: 0.2559, y: 0.6983)), forKey: "greenPrimary")
        desc.setValue(NSValue(point: NSPoint(x: 0.1494, y: 0.0557)), forKey: "bluePrimary")
        desc.setValue(NSValue(point: NSPoint(x: 0.3125, y: 0.3291)), forKey: "whitePoint")
        desc.setValue(queue, forKey: "queue")

        let allocObj = dispCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        guard let disp = allocObj.perform(NSSelectorFromString("initWithDescriptor:"), with: desc)?
                .takeUnretainedValue() as? NSObject else {
            throw CreateError.descriptorRejected
        }

        let lw = UInt(logicalWidth ?? pixelWidth)
        let lh = UInt(logicalHeight ?? pixelHeight)
        let modeAlloc = modeCls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject?
        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        let modeInit = unsafeBitCast(modeAlloc.method(for: modeSel), to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeSel, lw, lh, refreshRate) as? NSObject else {
            throw CreateError.modeRejected
        }

        let settings = setCls.init()
        settings.setValue(lw * 2 <= UInt(pixelWidth), forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")

        // 关键修正点：BOOL 返回值必须直接调用
        let applySel = NSSelectorFromString("applySettings:")
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let ok = unsafeBitCast(disp.method(for: applySel), to: ApplyFn.self)(disp, applySel, settings)
        guard ok else { throw CreateError.applyFailed }

        let id = CGDirectDisplayID((disp.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
        guard id != 0 else { throw CreateError.applyFailed }

        let vd = VirtualDisplay(object: disp, id: id, w: pixelWidth, h: pixelHeight, queue: queue)

        // 确认上线
        var waited = 0.0
        var online = false
        while waited < 2.0 {
            var n: UInt32 = 0
            CGGetOnlineDisplayList(32, nil, &n)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
            CGGetOnlineDisplayList(n, &ids, &n)
            if ids.contains(id) { online = true; break }
            usleep(20_000); waited += 0.02
        }
        guard online else { throw CreateError.notOnline }

        // 全局登记，保证对象不会被 ARC 回收
        lock.lock()
        live[ObjectIdentifier(vd)] = vd
        lock.unlock()

        return vd
    }

    /// 显式销毁。销毁后屏立刻从系统消失。
    ///
    /// 正确路径：CGVirtualDisplay 内部持有一个 VirtualDisplayClient（存于 ivar `_client`，
    /// 类型是裸指针 ^v），必须把**这个指针**传给 CDVirtualDisplayDestroy。
    /// 传 CGVirtualDisplay 对象本身会触发 CoreDisplay 的内部断言并崩溃。
    /// 单纯释放对象引用不会让屏消失。
    func destroy() {
        guard !destroyed else { return }
        destroyed = true

        // 1. 取出内部 client 指针
        guard let cls = NSClassFromString("CGVirtualDisplay"),
              let ivar = class_getInstanceVariable(cls, "_client") else {
            VDLog.info("找不到 _client ivar，改用释放引用")
            VirtualDisplay.drop(self)
            return
        }
        let raw = UnsafeRawPointer(Unmanaged.passUnretained(object).toOpaque())
            .advanced(by: ivar_getOffset(ivar))
        guard let clientPtr = raw.load(as: UnsafeMutableRawPointer?.self) else {
            VDLog.info("_client 为空，改用释放引用")
            VirtualDisplay.drop(self)
            return
        }

        // 2. 调用 CDVirtualDisplayDestroy(client)
        if let h = dlopen("/System/Library/Frameworks/CoreDisplay.framework/Versions/A/CoreDisplay", RTLD_NOW),
           let sym = dlsym(h, "CDVirtualDisplayDestroy") {
            typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer) -> Void
            unsafeBitCast(sym, to: DestroyFn.self)(clientPtr)
        } else {
            VDLog.info("CDVirtualDisplayDestroy 不可用")
        }

        // 3. 从全局登记表移除，让对象释放
        VirtualDisplay.drop(self)
    }

    /// 销毁所有现存虚拟屏。destroy() 幂等，重复调用安全。
    static func destroyAll() {
        lock.lock()
        let all = Array(live.values)
        lock.unlock()
        for vd in all { vd.destroy() }
        usleep(100_000)
    }

    var description: String {
        "VirtualDisplay(id=\(displayID), \(pixelWidth)x\(pixelHeight), 逻辑=\(CGDisplayBounds(displayID).width)x\(CGDisplayBounds(displayID).height))"
    }
}

// MARK: - 信号处理：保证异常退出也能清理

enum VirtualDisplayGuard {
    private static var installed = false
    /// 信号处理器里只置标志位。真正的清理放在主循环轮询里做，
    /// 因为 signal handler 中调用 ObjC runtime / dlopen 属于 async-signal-unsafe。
    nonisolated(unsafe) static var pendingSignal: Int32 = 0

    static func install() {
        guard !installed else { return }
        installed = true
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { s in
                VirtualDisplayGuard.pendingSignal = s
            }
        }
        atexit {
            VirtualDisplay.destroyAll()
        }
    }

    /// 在主循环里定期调用。收到信号时清理并退出。
    static func checkAndExitIfNeeded() {
        let sig = pendingSignal
        guard sig != 0 else { return }
        pendingSignal = 0
        VDLog.info("收到信号 \(sig)，清理虚拟屏后退出")
        VirtualDisplay.destroyAll()
        exit(128 + sig)
    }
}
