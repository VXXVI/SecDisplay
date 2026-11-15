// MacReceiver.swift —— Mac 副屏接收端（Windows 主控 → Mac 显示与键鼠回传）
//
// 管线：
//   NWListener TCP 服务端 (监听 9922，Windows 主动连入，绕开 macOS 本地网络出站阻断)
//     → 拆帧 [4B BE len][1B type][8B BE ts][payload]
//     → 0x01 AVCC 提取 SPS/PPS → VideoToolbox 硬解 (BGRA IOSurface CVPixelBuffer)
//     → CALayer 零拷贝等比上屏 + 0x03/0x05 远端光标叠加层
//     ← 0x02 关键帧请求 / 0x04 鼠标滚轮回传 / 0x07 健康度反馈 / 0x09 键盘回传

import Foundation
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import Network
import QuartzCore

// MARK: - 角色模式与共享接收端状态

enum SecDisplayRole: String {
    case sender = "sender"     // Mac 当主屏，Windows 当副屏（默认）
    case receiver = "receiver" // Mac 当副屏，Windows 当主控
}

struct MacReceiverSnapshot {
    var connected = false
    var streaming = false
    var listening = false
    var listenerError: String? = nil
    var rejectedPeer: String? = nil
    var allowedHosts = ""
    var peer = "-"
    var width = 0
    var height = 0
    var sessionFps = 0
    var decodeFps: Double = 0
    var mbps: Double = 0
    var sourceP95: Double = 0
    var presentP95: Double = 0
    var decodedFrames: UInt64 = 0
    var decodeErrors: UInt64 = 0
    var droppedFrames: UInt64 = 0
    var cursorRecv: UInt64 = 0
    var inputSent: UInt64 = 0
    var uptimeSec: Double = 0
    var decoderName = "VideoToolbox (H.264 硬件)"
}

// MARK: - macOS CGKeyCode → Windows VK / ScanCode 反向映射

enum MacKeyMap {
    struct WinKey {
        let vk: UInt16
        let scan: UInt16
        let extended: Bool
    }

    // 与 KeyboardInjector.keyCode(forVK:extended:scan:) 严格互逆
    private static let table: [UInt16: WinKey] = [
        // 字母 A-Z
        0x00: WinKey(vk: 0x41, scan: 0x1E, extended: false), // A
        0x0B: WinKey(vk: 0x42, scan: 0x30, extended: false), // B
        0x08: WinKey(vk: 0x43, scan: 0x2E, extended: false), // C
        0x02: WinKey(vk: 0x44, scan: 0x20, extended: false), // D
        0x0E: WinKey(vk: 0x45, scan: 0x12, extended: false), // E
        0x03: WinKey(vk: 0x46, scan: 0x21, extended: false), // F
        0x05: WinKey(vk: 0x47, scan: 0x22, extended: false), // G
        0x04: WinKey(vk: 0x48, scan: 0x23, extended: false), // H
        0x22: WinKey(vk: 0x49, scan: 0x17, extended: false), // I
        0x26: WinKey(vk: 0x4A, scan: 0x24, extended: false), // J
        0x28: WinKey(vk: 0x4B, scan: 0x25, extended: false), // K
        0x25: WinKey(vk: 0x4C, scan: 0x26, extended: false), // L
        0x2E: WinKey(vk: 0x4D, scan: 0x32, extended: false), // M
        0x2D: WinKey(vk: 0x4E, scan: 0x31, extended: false), // N
        0x1F: WinKey(vk: 0x4F, scan: 0x18, extended: false), // O
        0x23: WinKey(vk: 0x50, scan: 0x19, extended: false), // P
        0x0C: WinKey(vk: 0x51, scan: 0x10, extended: false), // Q
        0x0F: WinKey(vk: 0x52, scan: 0x13, extended: false), // R
        0x01: WinKey(vk: 0x53, scan: 0x1F, extended: false), // S
        0x11: WinKey(vk: 0x54, scan: 0x14, extended: false), // T
        0x20: WinKey(vk: 0x55, scan: 0x16, extended: false), // U
        0x09: WinKey(vk: 0x56, scan: 0x2F, extended: false), // V
        0x0D: WinKey(vk: 0x57, scan: 0x11, extended: false), // W
        0x07: WinKey(vk: 0x58, scan: 0x2D, extended: false), // X
        0x10: WinKey(vk: 0x59, scan: 0x15, extended: false), // Y
        0x06: WinKey(vk: 0x5A, scan: 0x2C, extended: false), // Z

        // 数字行
        0x1D: WinKey(vk: 0x30, scan: 0x0B, extended: false), // 0
        0x12: WinKey(vk: 0x31, scan: 0x02, extended: false), // 1
        0x13: WinKey(vk: 0x32, scan: 0x03, extended: false), // 2
        0x14: WinKey(vk: 0x33, scan: 0x04, extended: false), // 3
        0x15: WinKey(vk: 0x34, scan: 0x05, extended: false), // 4
        0x17: WinKey(vk: 0x35, scan: 0x06, extended: false), // 5
        0x16: WinKey(vk: 0x36, scan: 0x07, extended: false), // 6
        0x1A: WinKey(vk: 0x37, scan: 0x08, extended: false), // 7
        0x1C: WinKey(vk: 0x38, scan: 0x09, extended: false), // 8
        0x19: WinKey(vk: 0x39, scan: 0x0A, extended: false), // 9

        // 符号
        0x29: WinKey(vk: 0xBA, scan: 0x27, extended: false), // ;
        0x18: WinKey(vk: 0xBB, scan: 0x0D, extended: false), // =
        0x2B: WinKey(vk: 0xBC, scan: 0x33, extended: false), // ,
        0x1B: WinKey(vk: 0xBD, scan: 0x0C, extended: false), // -
        0x2F: WinKey(vk: 0xBE, scan: 0x34, extended: false), // .
        0x2C: WinKey(vk: 0xBF, scan: 0x35, extended: false), // /
        0x32: WinKey(vk: 0xC0, scan: 0x29, extended: false), // `
        0x21: WinKey(vk: 0xDB, scan: 0x1A, extended: false), // [
        0x2A: WinKey(vk: 0xDC, scan: 0x2B, extended: false), // backslash
        0x1E: WinKey(vk: 0xDD, scan: 0x1B, extended: false), // ]
        0x27: WinKey(vk: 0xDE, scan: 0x28, extended: false), // '

        // 控制与导航
        0x33: WinKey(vk: 0x08, scan: 0x0E, extended: false), // Backspace
        0x30: WinKey(vk: 0x09, scan: 0x0F, extended: false), // Tab
        0x24: WinKey(vk: 0x0D, scan: 0x1C, extended: false), // Return
        0x35: WinKey(vk: 0x1B, scan: 0x01, extended: false), // Esc
        0x31: WinKey(vk: 0x20, scan: 0x39, extended: false), // Space
        0x72: WinKey(vk: 0x2D, scan: 0x52, extended: true),  // Help -> Insert
        0x75: WinKey(vk: 0x2E, scan: 0x53, extended: true),  // ForwardDelete
        0x73: WinKey(vk: 0x24, scan: 0x47, extended: true),  // Home
        0x77: WinKey(vk: 0x23, scan: 0x4F, extended: true),  // End
        0x74: WinKey(vk: 0x21, scan: 0x49, extended: true),  // PageUp
        0x79: WinKey(vk: 0x22, scan: 0x51, extended: true),  // PageDown
        0x7B: WinKey(vk: 0x25, scan: 0x4B, extended: true),  // Left
        0x7E: WinKey(vk: 0x26, scan: 0x48, extended: true),  // Up
        0x7C: WinKey(vk: 0x27, scan: 0x4D, extended: true),  // Right
        0x7D: WinKey(vk: 0x28, scan: 0x50, extended: true),  // Down

        // 功能键 F1-F12
        0x7A: WinKey(vk: 0x70, scan: 0x3B, extended: false), // F1
        0x78: WinKey(vk: 0x71, scan: 0x3C, extended: false), // F2
        0x63: WinKey(vk: 0x72, scan: 0x3D, extended: false), // F3
        0x76: WinKey(vk: 0x73, scan: 0x3E, extended: false), // F4
        0x60: WinKey(vk: 0x74, scan: 0x3F, extended: false), // F5
        0x61: WinKey(vk: 0x75, scan: 0x40, extended: false), // F6
        0x62: WinKey(vk: 0x76, scan: 0x41, extended: false), // F7
        0x64: WinKey(vk: 0x77, scan: 0x42, extended: false), // F8
        0x65: WinKey(vk: 0x78, scan: 0x43, extended: false), // F9
        0x6D: WinKey(vk: 0x79, scan: 0x44, extended: false), // F10
        0x67: WinKey(vk: 0x7A, scan: 0x57, extended: false), // F11
        0x6F: WinKey(vk: 0x7B, scan: 0x58, extended: false), // F12

        // 小键盘
        0x52: WinKey(vk: 0x60, scan: 0x52, extended: false),
        0x53: WinKey(vk: 0x61, scan: 0x4F, extended: false),
        0x54: WinKey(vk: 0x62, scan: 0x50, extended: false),
        0x55: WinKey(vk: 0x63, scan: 0x51, extended: false),
        0x56: WinKey(vk: 0x64, scan: 0x4B, extended: false),
        0x57: WinKey(vk: 0x65, scan: 0x4C, extended: false),
        0x58: WinKey(vk: 0x66, scan: 0x4D, extended: false),
        0x59: WinKey(vk: 0x67, scan: 0x47, extended: false),
        0x5B: WinKey(vk: 0x68, scan: 0x48, extended: false),
        0x5C: WinKey(vk: 0x69, scan: 0x49, extended: false),
        0x43: WinKey(vk: 0x6A, scan: 0x37, extended: false), // *
        0x45: WinKey(vk: 0x6B, scan: 0x4E, extended: false), // +
        0x4E: WinKey(vk: 0x6D, scan: 0x4A, extended: false), // -
        0x41: WinKey(vk: 0x6E, scan: 0x53, extended: false), // .
        0x4B: WinKey(vk: 0x6F, scan: 0x35, extended: true),  // /
        0x4C: WinKey(vk: 0x0D, scan: 0x1C, extended: true),  // Numpad Enter

        // 修饰键（左右区分）
        0x38: WinKey(vk: 0xA0, scan: 0x2A, extended: false), // LShift
        0x3C: WinKey(vk: 0xA1, scan: 0x36, extended: false), // RShift
        0x3B: WinKey(vk: 0xA2, scan: 0x1D, extended: false), // LCtrl
        0x3E: WinKey(vk: 0xA3, scan: 0x1D, extended: true),  // RCtrl
        0x3A: WinKey(vk: 0xA4, scan: 0x38, extended: false), // LAlt/Opt
        0x3D: WinKey(vk: 0xA5, scan: 0x38, extended: true),  // RAlt/Opt
        0x37: WinKey(vk: 0x5B, scan: 0x5B, extended: true),  // LWin (Command)
        0x36: WinKey(vk: 0x5C, scan: 0x5C, extended: true),  // RWin (Right Command)
        0x39: WinKey(vk: 0x14, scan: 0x3A, extended: false), // CapsLock
    ]

    static func lookup(_ keyCode: UInt16) -> WinKey? {
        table[keyCode]
    }

    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39:       return .capsLock
        default:         return nil
        }
    }
}

// MARK: - VideoToolbox H.264 硬解器

final class VideoToolboxDecoder {
    private var formatDesc: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var lastSPS = Data()
    private var lastPPS = Data()
    private var pendingDecodedPB: CVPixelBuffer?
    private(set) var decodedFrames: UInt64 = 0
    private(set) var decodeErrors: UInt64 = 0
    private(set) var videoWidth = 0
    private(set) var videoHeight = 0

    var onDecodedFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onDecodeError: (() -> Void)?
    var onFrameDropped: (() -> Void)?
    var onNeedKeyframe: (() -> Void)?

    func reset() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        formatDesc = nil
        lastSPS.removeAll()
        lastPPS.removeAll()
    }

    deinit { reset() }

    func decodeAvccFrame(_ avcc: Data) {
        var sps: Data?
        var pps: Data?
        var vclPayload = Data()
        vclPayload.reserveCapacity(avcc.count)

        var offset = avcc.startIndex
        while offset + 4 <= avcc.endIndex {
            let b0 = UInt32(avcc[offset])
            let b1 = UInt32(avcc[offset + 1])
            let b2 = UInt32(avcc[offset + 2])
            let b3 = UInt32(avcc[offset + 3])
            let nalLen = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4
            guard nalLen > 0, offset + nalLen <= avcc.endIndex else {
                decodeErrors &+= 1
                return
            }
            let nalEnd = offset + nalLen
            let nalType = avcc[offset] & 0x1F
            if nalType == 7 {
                sps = avcc.subdata(in: offset..<nalEnd)
            } else if nalType == 8 {
                pps = avcc.subdata(in: offset..<nalEnd)
            } else {
                var beLen = UInt32(nalLen).bigEndian
                withUnsafeBytes(of: &beLen) { vclPayload.append(contentsOf: $0) }
                vclPayload.append(avcc[offset..<nalEnd])
            }
            offset = nalEnd
        }

        if let sps, let pps, (sps != lastSPS || pps != lastPPS || session == nil) {
            if rebuildSession(sps: sps, pps: pps) {
                lastSPS = sps
                lastPPS = pps
            } else {
                decodeErrors &+= 1
                return
            }
        }

        guard let session, let formatDesc, !vclPayload.isEmpty else {
            if session == nil {
                onNeedKeyframe?()
            }
            return
        }

        var blockBuf: CMBlockBuffer?
        let count = vclPayload.count
        let st1 = vclPayload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            var bb: CMBlockBuffer?
            let r = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: count,
                flags: 0,
                blockBufferOut: &bb
            )
            guard r == noErr, let bb else { return r }
            let r2 = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb, offsetIntoDestination: 0, dataLength: count)
            blockBuf = bb
            return r2
        }
        guard st1 == noErr, let blockBuf else {
            decodeErrors &+= 1
            return
        }

        var sampleBuf: CMSampleBuffer?
        var sampleSize = count
        let st2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuf
        )
        guard st2 == noErr, let sampleBuf else {
            decodeErrors &+= 1
            return
        }

        pendingDecodedPB = nil
        var infoFlags = VTDecodeInfoFlags()
        let st3 = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuf,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        if st3 == noErr && pendingDecodedPB == nil && infoFlags.contains(.asynchronous) {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }

        if st3 == noErr, let pb = pendingDecodedPB {
            pendingDecodedPB = nil
            decodedFrames &+= 1
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            videoWidth = w
            videoHeight = h
            onDecodedFrame?(pb, w, h)
        } else if st3 == noErr && infoFlags.contains(.frameDropped) {
            pendingDecodedPB = nil
            onFrameDropped?()
            onNeedKeyframe?()
        } else {
            pendingDecodedPB = nil
            decodeErrors &+= 1
            onDecodeError?()
            if st3 == kVTInvalidSessionErr || st3 == kVTVideoDecoderMalfunctionErr {
                reset()
            }
            onNeedKeyframe?()
        }
    }

    private static let outputCallback: VTDecompressionOutputCallback = {
        decompressionOutputRefCon, _, status, _, imageBuffer, _, _ in
        guard status == noErr, let imageBuffer, let refCon = decompressionOutputRefCon else { return }
        let me = Unmanaged<VideoToolboxDecoder>.fromOpaque(refCon).takeUnretainedValue()
        me.pendingDecodedPB = imageBuffer
    }

    private func rebuildSession(sps: Data, pps: Data) -> Bool {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        formatDesc = nil

        var desc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                var ptrs = [spsPtr, ppsPtr]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &ptrs,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
            }
        }
        guard status == noErr, let desc else {
            Log.info("MacReceiver: 创建 FormatDescription 失败 status=\(status)")
            return false
        }

        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        videoWidth = Int(dims.width)
        videoHeight = Int(dims.height)

        let decoderSpec: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
        ]
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var cbRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var newSession: VTDecompressionSession?
        let sStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: decoderSpec as CFDictionary,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &cbRecord,
            decompressionSessionOut: &newSession
        )
        guard sStatus == noErr, let newSession else {
            Log.info("MacReceiver: 创建 VTDecompressionSession 失败 status=\(sStatus)")
            return false
        }

        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        formatDesc = desc
        session = newSession
        Log.info("MacReceiver: VideoToolbox 硬解就绪 \(videoWidth)x\(videoHeight)")
        return true
    }
}

// MARK: - Mac 副屏网络监听端（9922：Mac 固定监听，Windows 主动直连，绕开 macOS 本地网络 TCC 阻断）

final class MacReceiverClient {
    private let netQueue = DispatchQueue(label: "SecDisplay.macrecv.net")
    private let decodeQueue = DispatchQueue(label: "SecDisplay.macrecv.decode", qos: .userInteractive)
    private let stateLock = NSLock()

    private var listener: NWListener?
    private var conn: NWConnection?
    private var connEpoch = 0
    private var stopped = true
    private var listenPort: UInt16 = 9922
    private var peerDesc = "-"
    private var recvBuf = Data()
    private var listenerRestartScheduled = false
    private var listenerRestartWorkItem: DispatchWorkItem?
    private var feedbackTimer: DispatchSourceTimer?

    private let decoder = VideoToolboxDecoder()

    private var _connected = false
    private var _streaming = false
    private var _listening = false
    private var _listenerError: String? = nil
    private var _rejectedPeer: String? = nil
    private var _allowedHostsRaw = ""
    private var _allowedHosts = Set<String>()
    private var _allowAnyHost = false
    private var _activePeerHost = ""
    private var _latestEpoch = 0
    private var _sessW = 0
    private var _sessH = 0
    private var _sessFps = 0
    private var _connStartAt: CFAbsoluteTime = 0
    private var _bytesInWindow: UInt64 = 0
    private var _framesInWindow: UInt64 = 0
    private var _windowStartAt: CFAbsoluteTime = 0
    private var _lastDecodeFps: Double = 0
    private var _lastMbps: Double = 0
    private var _droppedFrames: UInt64 = 0
    private var _decodeInFlight: Int = 0
    private var _decodedFrames: UInt64 = 0
    private var _decodeErrors: UInt64 = 0
    private var _videoWidth: Int = 0
    private var _videoHeight: Int = 0
    private var _lastFbDrops: UInt64 = 0
    private var _cursorRecv: UInt64 = 0
    private var _inputSent: UInt64 = 0
    private var _lastFrameRecvAt: CFAbsoluteTime = 0
    private var _srcIntervalsMs: [Double] = []
    private var _presIntervalsMs: [Double] = []
    private var _lastPresentAt: CFAbsoluteTime = 0
    private var _lastKeyframeReqAt: CFAbsoluteTime = 0

    var onVideoFrame: ((CVPixelBuffer, Int, Int) -> Void)?
    var onCursorMove: ((Float, Float, Bool) -> Void)?
    var onCursorImage: ((CGImage, Int, Int) -> Void)?
    var onSessionChanged: ((Int, Int, Int) -> Void)?
    var onDisconnected: (() -> Void)?

    init() {
        decoder.onDecodedFrame = { [weak self] pb, w, h in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.stateLock.lock()
            self._streaming = true
            self._framesInWindow &+= 1
            self._decodedFrames &+= 1
            self._videoWidth = w
            self._videoHeight = h
            if self._lastPresentAt > 0 {
                let dtMs = (now - self._lastPresentAt) * 1000.0
                if dtMs > 250.0 {
                    // 静止桌面恢复出画时清空陈旧采样窗口，避免把停顿时间计入呈现 p95
                    self._presIntervalsMs.removeAll()
                } else if dtMs > 0 {
                    self._presIntervalsMs.append(dtMs)
                    if self._presIntervalsMs.count > 120 { self._presIntervalsMs.removeFirst() }
                }
            }
            self._lastPresentAt = now
            self.stateLock.unlock()
            self.onVideoFrame?(pb, w, h)
        }
        decoder.onDecodeError = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self._decodeErrors &+= 1
            self.stateLock.unlock()
        }
        decoder.onFrameDropped = { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self._droppedFrames &+= 1
            self.stateLock.unlock()
        }
        decoder.onNeedKeyframe = { [weak self] in
            self?.sendKeyframeRequest(throttled: true)
        }
    }

    func setAllowedHosts(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let allowAny = (lower == "any" || lower == "*")
        var parsed = Set<String>()
        if !trimmed.isEmpty && !allowAny {
            let parts = trimmed.split { $0 == "," || $0 == " " || $0 == ";" }
            for p in parts {
                let s = Self.normalizeIP(String(p).trimmingCharacters(in: .whitespacesAndNewlines))
                if !s.isEmpty { parsed.insert(s) }
            }
        }
        stateLock.lock()
        _allowedHostsRaw = trimmed
        _allowedHosts = parsed
        _allowAnyHost = allowAny
        _rejectedPeer = nil
        stateLock.unlock()
        Log.info("MacReceiver: 访问控制策略 -> \(allowAny ? "允许任意来源" : (parsed.isEmpty ? "自动(私有/桥接网段+防抢占)" : parsed.sorted().joined(separator: ",")))")
    }

    func listen(port: UInt16) {
        stop()
        stateLock.lock()
        stopped = false
        listenPort = port
        stateLock.unlock()
        netQueue.async { [weak self] in
            self?.startListener()
        }
    }

    func stop() {
        stateLock.lock()
        stopped = true
        _connected = false
        _streaming = false
        _listening = false
        _listenerError = nil
        _activePeerHost = ""
        _latestEpoch &+= 1
        peerDesc = "-"
        stateLock.unlock()
        netQueue.async { [weak self] in
            guard let self else { return }
            self.connEpoch &+= 1
            let e = self.connEpoch
            self.stateLock.lock()
            self._latestEpoch = e
            self.stateLock.unlock()
            self.feedbackTimer?.cancel()
            self.feedbackTimer = nil
            self.conn?.cancel()
            self.conn = nil
            self.listenerRestartWorkItem?.cancel()
            self.listenerRestartWorkItem = nil
            self.listenerRestartScheduled = false
            self.listener?.cancel()
            self.listener = nil
            self.recvBuf.removeAll()
        }
        decodeQueue.async { [weak self] in
            self?.decoder.reset()
        }
    }

    func snapshot(sampleRates: Bool = true) -> MacReceiverSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if _windowStartAt == 0 {
            _windowStartAt = now
        } else if sampleRates {
            let dt = now - _windowStartAt
            if dt >= 0.8 {
                _lastDecodeFps = Double(_framesInWindow) / dt
                _lastMbps = Double(_bytesInWindow) * 8.0 / dt / 1_000_000.0
                _framesInWindow = 0
                _bytesInWindow = 0
                _windowStartAt = now
            }
        }
        let w = _videoWidth > 0 ? _videoWidth : _sessW
        let h = _videoHeight > 0 ? _videoHeight : _sessH
        let idle = (_lastFrameRecvAt > 0 && now - _lastFrameRecvAt > 3.0)
        let p95Src = idle ? 0.0 : Self.percentile95(_srcIntervalsMs)
        let p95Pres = idle ? 0.0 : Self.percentile95(_presIntervalsMs)
        return MacReceiverSnapshot(
            connected: _connected,
            streaming: _streaming,
            listening: _listening,
            listenerError: _listenerError,
            rejectedPeer: _rejectedPeer,
            allowedHosts: _allowedHostsRaw,
            peer: _connected ? peerDesc : "-",
            width: w,
            height: h,
            sessionFps: _sessFps,
            decodeFps: _lastDecodeFps,
            mbps: _lastMbps,
            sourceP95: p95Src,
            presentP95: p95Pres,
            decodedFrames: _decodedFrames,
            decodeErrors: _decodeErrors,
            droppedFrames: _droppedFrames,
            cursorRecv: _cursorRecv,
            inputSent: _inputSent,
            uptimeSec: (_connected && _connStartAt > 0) ? (now - _connStartAt) : 0,
            decoderName: "VideoToolbox (H.264 硬件)"
        )
    }

    private static func percentile95(_ arr: [Double]) -> Double {
        guard !arr.isEmpty else { return 0 }
        let s = arr.sorted()
        let idx = min(s.count - 1, Int(Double(s.count - 1) * 0.95))
        return s[idx]
    }

    private static func normalizeIP(_ raw: String) -> String {
        var s = raw
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }

    private static func extractHost(from endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint {
            return normalizeIP("\(host)")
        }
        let s = "\(endpoint)"
        if let idx = s.lastIndex(of: ":") {
            return normalizeIP(String(s[..<idx]))
        }
        return normalizeIP(s)
    }

    private static func isPrivateOrLinkLocal(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" || ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd") {
            return true
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let (a, b) = (parts[0], parts[1])
        if a == 10 || a == 127 { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && b >= 16 && b <= 31 { return true }
        if a == 192 && b == 168 { return true }
        if a == 100 && b >= 64 && b <= 127 { return true } // Tailscale CGNAT
        return false
    }

    static func localIPv4Summaries() -> [(iface: String, label: String, ip: String)] {
        var out: [(iface: String, label: String, ip: String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            cur = p.pointee.ifa_next
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(p.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            guard r == 0 else { continue }
            let ip = String(cString: hostBuf)
            let iface = String(cString: p.pointee.ifa_name)
            let label: String
            if ip.hasPrefix("10.10.10.") || iface.hasPrefix("bridge") {
                label = "雷电网桥"
            } else if iface.hasPrefix("utun") || ip.hasPrefix("100.") {
                label = "Tailscale"
            } else if iface == "en0" {
                label = "Wi-Fi/有线"
            } else {
                label = iface
            }
            out.append((iface: iface, label: label, ip: ip))
        }
        return out
    }

    private func startListener() {
        stateLock.lock()
        let isStopped = stopped
        let port = listenPort
        stateLock.unlock()
        guard !isStopped, let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
        }
        let l: NWListener
        do {
            l = try NWListener(using: params, on: nwPort)
        } catch {
            stateLock.lock()
            _listening = false
            _listenerError = "监听端口 \(port) 失败: \(error.localizedDescription)"
            stateLock.unlock()
            Log.info("MacReceiver: 监听端口 \(port) 失败 \(error)")
            scheduleListenerRestart()
            return
        }
        self.listener = l
        l.newConnectionHandler = { [weak self, weak l] c in
            guard let self, let l, self.listener === l else {
                c.cancel()
                return
            }
            self.acceptConnection(c)
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                self.listenerRestartWorkItem?.cancel()
                self.listenerRestartWorkItem = nil
                self.listenerRestartScheduled = false
                self.stateLock.lock()
                self._listening = true
                self._listenerError = nil
                self.stateLock.unlock()
                Log.info("MacReceiver: 已监听端口 \(port)，等待 Windows 主控端连接")
            case .waiting(let e):
                self.stateLock.lock()
                self._listening = false
                self._listenerError = "等待接口或本地网络权限: \(e.localizedDescription)"
                self.stateLock.unlock()
                Log.info("MacReceiver: 监听等待中 \(e)")
            case .failed(let e):
                self.stateLock.lock()
                self._listening = false
                self._listenerError = "监听异常: \(e.localizedDescription)"
                self.stateLock.unlock()
                Log.info("MacReceiver: 监听异常 \(e)")
                self.scheduleListenerRestart()
            case .cancelled:
                self.stateLock.lock()
                self._listening = false
                self.stateLock.unlock()
            default:
                break
            }
        }
        l.start(queue: netQueue)
    }

    private func scheduleListenerRestart() {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped, !listenerRestartScheduled else { return }
        listenerRestartScheduled = true
        let wi = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.listenerRestartScheduled = false
            self.listenerRestartWorkItem = nil
            self.listener?.cancel()
            self.listener = nil
            self.startListener()
        }
        listenerRestartWorkItem = wi
        netQueue.asyncAfter(deadline: .now() + 2.0, execute: wi)
    }

    private func acceptConnection(_ c: NWConnection) {
        let peerHost = Self.extractHost(from: c.endpoint)
        stateLock.lock()
        let isStopped = stopped
        let allowAny = _allowAnyHost
        let wl = _allowedHosts
        let curConnected = _connected
        let curHost = _activePeerHost
        stateLock.unlock()
        if isStopped {
            c.cancel()
            return
        }

        // 访问控制与防抢占：
        // 1) 若配置了白名单，仅允许白名单 IP
        // 2) 未配置白名单时，仅放行私有/链路本地/Tailscale 网段，且已有活跃会话时不许不同 IP 抢占
        var rejectReason: String? = nil
        if !allowAny {
            if !wl.isEmpty {
                if !wl.contains(peerHost) {
                    rejectReason = "不在允许主控 IP 白名单"
                }
            } else {
                if !Self.isPrivateOrLinkLocal(peerHost) {
                    rejectReason = "非本地/私有网段来源"
                } else if !curHost.isEmpty && curHost != peerHost && (curConnected || self.conn != nil) {
                    rejectReason = "已有主控 \(curHost) 在线，拒绝异地抢占"
                }
            }
        }
        if let reason = rejectReason {
            stateLock.lock()
            _rejectedPeer = "\(peerHost) (\(reason))"
            stateLock.unlock()
            Log.info("MacReceiver: 已拒绝来自 \(peerHost) 的连接 (\(reason))")
            c.cancel()
            return
        }

        connEpoch &+= 1
        let epoch = connEpoch
        stateLock.lock()
        _latestEpoch = epoch
        _activePeerHost = peerHost
        _rejectedPeer = nil
        stateLock.unlock()
        feedbackTimer?.cancel()
        feedbackTimer = nil
        let old = self.conn
        self.conn = c
        self.recvBuf.removeAll()
        old?.cancel()

        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, self.connEpoch == epoch else { return }
            switch st {
            case .ready:
                let ep = c.map { String(describing: $0.endpoint) } ?? "-"
                Log.info("MacReceiver: Windows 主控端已连接 \(ep)")
                self.stateLock.lock()
                self._connected = true
                self._streaming = false
                self._activePeerHost = peerHost
                self._sessW = 0
                self._sessH = 0
                self._sessFps = 0
                self.peerDesc = ep
                self._connStartAt = CFAbsoluteTimeGetCurrent()
                self._windowStartAt = CFAbsoluteTimeGetCurrent()
                self._framesInWindow = 0
                self._bytesInWindow = 0
                self._srcIntervalsMs.removeAll()
                self._presIntervalsMs.removeAll()
                self._lastFrameRecvAt = 0
                self._lastPresentAt = 0
                self._lastFbDrops = self._droppedFrames &+ self._decodeErrors
                self.stateLock.unlock()
                self.startFeedbackTimer(epoch: epoch)
                self.sendKeyframeRequest(throttled: false)
                self.receiveLoop(epoch: epoch)
            case .failed(let e):
                Log.info("MacReceiver: 连接断开 \(e)")
                self.handleDisconnect(epoch: epoch)
            case .cancelled:
                self.handleDisconnect(epoch: epoch)
            default:
                break
            }
        }
        c.start(queue: netQueue)
    }

    private func handleDisconnect(epoch: Int) {
        guard connEpoch == epoch else { return }
        connEpoch &+= 1
        let nextEpoch = connEpoch
        feedbackTimer?.cancel()
        feedbackTimer = nil
        conn?.cancel()
        conn = nil
        recvBuf.removeAll()
        stateLock.lock()
        _latestEpoch = nextEpoch
        _connected = false
        _streaming = false
        _activePeerHost = ""
        _decodeInFlight = 0
        _lastDecodeFps = 0
        _lastMbps = 0
        _srcIntervalsMs.removeAll()
        _presIntervalsMs.removeAll()
        peerDesc = "-"
        stateLock.unlock()
        decodeQueue.async { [weak self] in
            self?.decoder.reset()
        }
        onDisconnected?()
    }

    private func startFeedbackTimer(epoch: Int) {
        feedbackTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: netQueue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self, self.connEpoch == epoch else { return }
            self.sendFeedbackPacket()
        }
        t.resume()
        feedbackTimer = t
    }

    private func receiveLoop(epoch: Int) {
        guard connEpoch == epoch, let c = conn else { return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isEOF, err in
            guard let self, self.connEpoch == epoch else { return }
            if let data, !data.isEmpty {
                self.stateLock.lock()
                self._bytesInWindow &+= UInt64(data.count)
                self.stateLock.unlock()
                self.recvBuf.append(data)
                if !self.drainFrames() {
                    self.handleDisconnect(epoch: epoch)
                    return
                }
            }
            if isEOF || err != nil {
                self.handleDisconnect(epoch: epoch)
                return
            }
            self.receiveLoop(epoch: epoch)
        }
    }

    private func drainFrames() -> Bool {
        while recvBuf.count >= 4 {
            let s = recvBuf.startIndex
            let b0 = UInt32(recvBuf[s])
            let b1 = UInt32(recvBuf[s + 1])
            let b2 = UInt32(recvBuf[s + 2])
            let b3 = UInt32(recvBuf[s + 3])
            let len = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            if len <= 0 || len > 16 * 1024 * 1024 {
                Log.info("MacReceiver: 收到异常帧长 \(len)，重置连接")
                return false
            }
            guard recvBuf.count >= 4 + len else { break }
            let frame = recvBuf.subdata(in: (s + 4)..<(s + 4 + len))
            recvBuf.removeFirst(4 + len)
            handleFrame(frame)
        }
        return true
    }

    private func handleFrame(_ frame: Data) {
        guard frame.count >= 9 else { return }
        let type = frame[frame.startIndex]
        let payload = frame.subdata(in: (frame.startIndex + 9)..<frame.endIndex)

        switch type {
        case 0x01:
            let now = CFAbsoluteTimeGetCurrent()
            let hasIdr = Self.avccContainsIDR(payload)
            stateLock.lock()
            let epoch = _latestEpoch
            if _lastFrameRecvAt > 0 {
                let dtMs = (now - _lastFrameRecvAt) * 1000.0
                if dtMs > 250.0 {
                    // 静止桌面恢复出画时清空陈旧采样窗口，避免把停顿时间计入源端 p95 并误导 0x07 降码率
                    _srcIntervalsMs.removeAll()
                } else if dtMs > 0 {
                    _srcIntervalsMs.append(dtMs)
                    if _srcIntervalsMs.count > 120 { _srcIntervalsMs.removeFirst() }
                }
            }
            _lastFrameRecvAt = now
            // 解码队列背压：在途帧数 >= 3 时丢弃非关键帧防止延迟堆积
            if _decodeInFlight >= 3 && !hasIdr {
                _droppedFrames &+= 1
                stateLock.unlock()
                return
            }
            _decodeInFlight += 1
            stateLock.unlock()
            decodeQueue.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let alive = !self.stopped && self._connected && self._latestEpoch == epoch
                self.stateLock.unlock()
                if alive {
                    self.decoder.decodeAvccFrame(payload)
                }
                self.stateLock.lock()
                self._decodeInFlight = max(0, self._decodeInFlight - 1)
                self.stateLock.unlock()
            }
        case 0x03:
            guard payload.count >= 9 else { return }
            let rx = readF32BE(payload, 0)
            let ry = readF32BE(payload, 4)
            let vis = payload[payload.startIndex + 8] != 0
            stateLock.lock()
            _cursorRecv &+= 1
            stateLock.unlock()
            onCursorMove?(rx, ry, vis)
        case 0x05:
            guard payload.count >= 12 else { return }
            let w = Int(readU16BE(payload, 0))
            let h = Int(readU16BE(payload, 2))
            let hx = Int(readU16BE(payload, 4))
            let hy = Int(readU16BE(payload, 6))
            let nBytes = Int(readU32BE(payload, 8))
            guard w > 0, h > 0, w <= 256, h <= 256 else { return }
            let expected = w * h * 4
            guard nBytes == expected, payload.count - 12 >= expected else { return }
            let bgra = payload.subdata(in: (payload.startIndex + 12)..<(payload.startIndex + 12 + nBytes))
            if let cg = buildCursorCGImage(bgra: bgra, width: w, height: h) {
                onCursorImage?(cg, hx, hy)
            }
        case 0x06:
            guard payload.count >= 7 else { return }
            let w = Int(readU16BE(payload, 1))
            let h = Int(readU16BE(payload, 3))
            let fps = Int(payload[payload.startIndex + 5])
            guard w > 0, h > 0 else { return }
            stateLock.lock()
            let changed = (w != _sessW || h != _sessH || fps != _sessFps)
            _sessW = w
            _sessH = h
            _sessFps = fps
            stateLock.unlock()
            if changed {
                Log.info("MacReceiver: 收到会话头 \(w)x\(h) @ \(fps)fps")
                sendKeyframeRequest(throttled: false)
                onSessionChanged?(w, h, fps)
            }
        default:
            break
        }
    }

    private func buildCursorCGImage(bgra: Data, width: Int, height: Int) -> CGImage? {
        // Windows DIB 为非预乘 BGRA；转成预乘 BGRA 供 CoreGraphics 使用避免半透边缘发黑
        var premul = [UInt8](bgra)
        var i = 0
        while i + 3 < premul.count {
            let a = Int(premul[i + 3])
            if a == 0 {
                premul[i] = 0; premul[i + 1] = 0; premul[i + 2] = 0
            } else if a < 255 {
                premul[i]     = UInt8((Int(premul[i])     * a + 127) / 255)
                premul[i + 1] = UInt8((Int(premul[i + 1]) * a + 127) / 255)
                premul[i + 2] = UInt8((Int(premul[i + 2]) * a + 127) / 255)
            }
            i += 4
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let dataCopy = Data(premul)
        guard let provider = CGDataProvider(data: dataCopy as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // ---- 发送控制包回 Windows 主控端 ----

    private func sendBytes(_ pkt: Data) {
        netQueue.async { [weak self] in
            guard let self, let c = self.conn else { return }
            c.send(content: pkt, completion: .contentProcessed { _ in })
        }
    }

    func sendKeyframeRequest(throttled: Bool) {
        stateLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if throttled && now - _lastKeyframeReqAt < 0.8 {
            stateLock.unlock()
            return
        }
        _lastKeyframeReqAt = now
        stateLock.unlock()
        sendBytes(Data([0x02]))
    }

    func sendMouseInput(x: Float, y: Float, buttons: UInt8, wheel: Int16) {
        var pkt = Data(capacity: 12)
        pkt.append(0x04)
        var fx = x.bitPattern.bigEndian
        var fy = y.bitPattern.bigEndian
        var w16 = UInt16(bitPattern: wheel).bigEndian
        withUnsafeBytes(of: &fx) { pkt.append(contentsOf: $0) }
        withUnsafeBytes(of: &fy) { pkt.append(contentsOf: $0) }
        pkt.append(buttons)
        withUnsafeBytes(of: &w16) { pkt.append(contentsOf: $0) }
        stateLock.lock()
        _inputSent &+= 1
        stateLock.unlock()
        sendBytes(pkt)
    }

    func sendKeyInput(vk: UInt16, scan: UInt16, down: Bool, flags: UInt8) {
        var pkt = Data(capacity: 7)
        pkt.append(0x09)
        var v16 = vk.bigEndian
        var s16 = scan.bigEndian
        withUnsafeBytes(of: &v16) { pkt.append(contentsOf: $0) }
        withUnsafeBytes(of: &s16) { pkt.append(contentsOf: $0) }
        pkt.append(down ? 1 : 0)
        pkt.append(flags)
        stateLock.lock()
        _inputSent &+= 1
        stateLock.unlock()
        sendBytes(pkt)
    }

    private static func avccContainsIDR(_ avcc: Data) -> Bool {
        var offset = avcc.startIndex
        while offset + 4 <= avcc.endIndex {
            let b0 = UInt32(avcc[offset])
            let b1 = UInt32(avcc[offset + 1])
            let b2 = UInt32(avcc[offset + 2])
            let b3 = UInt32(avcc[offset + 3])
            let len = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4
            guard len > 0, offset + len <= avcc.endIndex else { break }
            if (avcc[offset] & 0x1F) == 5 { return true }
            offset += len
        }
        return false
    }

    private func sendFeedbackPacket() {
        let snap = snapshot()
        guard snap.connected else { return }
        stateLock.lock()
        let curDrops = _droppedFrames &+ _decodeErrors
        let dropDelta = curDrops >= _lastFbDrops ? (curDrops - _lastFbDrops) : curDrops
        _lastFbDrops = curDrops
        stateLock.unlock()

        var pkt = Data(capacity: 13)
        pkt.append(0x07)
        func put16(_ v: UInt16) {
            var be = v.bigEndian
            withUnsafeBytes(of: &be) { pkt.append(contentsOf: $0) }
        }
        put16(UInt16(clamping: Int(snap.presentP95.rounded())))
        put16(UInt16(clamping: Int(snap.sourceP95.rounded())))
        put16(UInt16(clamping: Int((snap.decodeFps * 10.0).rounded())))
        put16(UInt16(clamping: dropDelta))
        put16(0)
        put16(0)
        sendBytes(pkt)
    }

    private func readU16BE(_ d: Data, _ off: Int) -> UInt16 {
        let i = d.startIndex + off
        return (UInt16(d[i]) << 8) | UInt16(d[i + 1])
    }
    private func readU32BE(_ d: Data, _ off: Int) -> UInt32 {
        let i = d.startIndex + off
        return (UInt32(d[i]) << 24) | (UInt32(d[i + 1]) << 16) | (UInt32(d[i + 2]) << 8) | UInt32(d[i + 3])
    }
    private func readF32BE(_ d: Data, _ off: Int) -> Float {
        Float(bitPattern: readU32BE(d, off))
    }
}

// MARK: - 副屏显示画布与窗口控制器

final class ReceiverCanvasView: NSView {
    private let videoLayer = CALayer()
    private let cursorLayer = CALayer()
    private let waitLabel = NSTextField(labelWithString: "正在连接 Windows 主控端…")

    private var videoW: Int = 2560
    private var videoH: Int = 1600
    private var cursorW: Int = 20
    private var cursorH: Int = 28
    private var cursorHotX: Int = 4
    private var cursorHotY: Int = 4
    private var cursorVisible = false
    private var cursorPos = CGPoint(x: 0, y: 0)
    private var hasReceivedFrame = false

    private var buttonsMask: UInt8 = 0
    private var lastMoveSendAt: CFAbsoluteTime = 0
    private var heldKeys = Set<UInt16>()
    private var heldModifiers = Set<UInt16>()
    private var trackingArea: NSTrackingArea?
    /// 强持有当前展示中的 CVPixelBuffer，防止 VideoToolbox 的 CVPixelBufferPool 在 CALayer 仍在渲染该 IOSurface 时提前回收复用
    private var currentPixelBuffer: CVPixelBuffer?

    private static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: .zero)
    }()

    weak var client: MacReceiverClient?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        videoLayer.magnificationFilter = .linear
        videoLayer.minificationFilter = .trilinear
        layer?.addSublayer(videoLayer)

        cursorLayer.isHidden = true
        cursorLayer.zPosition = 10
        cursorLayer.magnificationFilter = .linear
        layer?.addSublayer(cursorLayer)

        waitLabel.textColor = NSColor(white: 0.85, alpha: 0.9)
        waitLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        waitLabel.alignment = .center
        waitLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waitLabel)
        NSLayoutConstraint.activate([
            waitLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            waitLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if hasReceivedFrame {
            addCursorRect(fittedVideoRect(), cursor: Self.invisibleCursor)
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        if let scale = window?.backingScaleFactor, scale > 0 {
            videoLayer.contentsScale = scale
            cursorLayer.contentsScale = scale
        }
        updateCursorLayerFrame()
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor, scale > 0 {
            videoLayer.contentsScale = scale
            cursorLayer.contentsScale = scale
        }
    }

    func updateWaitingText(_ text: String) {
        waitLabel.stringValue = text
        waitLabel.isHidden = false
    }

    func showDisconnected(_ text: String = "连接已断开，等待 Windows 主控重连…") {
        releaseAllInputs()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = nil
        cursorLayer.contents = nil
        cursorLayer.isHidden = true
        CATransaction.commit()
        currentPixelBuffer = nil
        cursorVisible = false
        hasReceivedFrame = false
        waitLabel.stringValue = text
        waitLabel.isHidden = false
        window?.invalidateCursorRects(for: self)
    }

    func displayFrame(_ pb: CVPixelBuffer, width: Int, height: Int) {
        guard let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        let sizeChanged = (width != videoW || height != videoH)
        videoW = max(1, width)
        videoH = max(1, height)
        if !hasReceivedFrame {
            hasReceivedFrame = true
            waitLabel.isHidden = true
            window?.invalidateCursorRects(for: self)
        }
        currentPixelBuffer = pb
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.contents = surf
        if sizeChanged { updateCursorLayerFrame() }
        CATransaction.commit()
    }

    func updateRemoteCursor(x: Float, y: Float, visible: Bool) {
        cursorPos = CGPoint(x: CGFloat(x), y: CGFloat(y))
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayerFrame()
        CATransaction.commit()
    }

    func updateRemoteCursorImage(_ img: CGImage, hotX: Int, hotY: Int) {
        cursorW = img.width
        cursorH = img.height
        cursorHotX = hotX
        cursorHotY = hotY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = img
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayerFrame()
        CATransaction.commit()
    }

    func releaseAllInputs() {
        if buttonsMask != 0 {
            let p = cursorPos
            buttonsMask = 0
            client?.sendMouseInput(x: Float(p.x), y: Float(p.y), buttons: 0, wheel: 0)
        }
        for kc in heldKeys {
            if let wk = MacKeyMap.lookup(kc) {
                client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
            }
        }
        heldKeys.removeAll()
        for kc in heldModifiers {
            if let wk = MacKeyMap.lookup(kc) {
                client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
            }
        }
        heldModifiers.removeAll()
    }

    private func fittedVideoRect() -> CGRect {
        let bw = bounds.width
        let bh = bounds.height
        guard bw > 0, bh > 0, videoW > 0, videoH > 0 else { return bounds }
        let vw = CGFloat(videoW)
        let vh = CGFloat(videoH)
        let s = min(bw / vw, bh / vh)
        let dw = vw * s
        let dh = vh * s
        return CGRect(x: (bw - dw) * 0.5, y: (bh - dh) * 0.5, width: dw, height: dh)
    }

    private func updateCursorLayerFrame() {
        let vr = fittedVideoRect()
        guard vr.width > 0, vr.height > 0, videoW > 0, videoH > 0 else { return }
        let sx = vr.width / CGFloat(videoW)
        let sy = vr.height / CGFloat(videoH)
        // Windows 光标按屏比例绘制，在 Mac 视图里按视频缩放比同步缩放，不至于过大或过小
        let scale = max(0.5, min(1.5, sx * 1.15))
        let dw = CGFloat(cursorW) * scale
        let dh = CGFloat(cursorH) * scale
        let hx = CGFloat(cursorHotX) * scale
        let hy = CGFloat(cursorHotY) * scale
        let vx = vr.minX + cursorPos.x * sx
        // AppKit layer 默认左下为原点，视频 y=0 在 vr.maxY
        let vy = vr.maxY - cursorPos.y * sy
        cursorLayer.frame = CGRect(x: vx - hx, y: vy - (dh - hy), width: dw, height: dh)
    }

    private func viewPointToVideo(_ event: NSEvent) -> (Float, Float)? {
        let pt = convert(event.locationInWindow, from: nil)
        let vr = fittedVideoRect()
        guard vr.width > 0, vr.height > 0 else { return nil }
        let nx = (pt.x - vr.minX) / vr.width
        let ny = (vr.maxY - pt.y) / vr.height
        let clampedX = Float(max(0.0, min(1.0, nx))) * Float(videoW)
        let clampedY = Float(max(0.0, min(1.0, ny))) * Float(videoH)
        return (clampedX, clampedY)
    }

    private func forwardMouseMove(_ event: NSEvent) {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveSendAt < 0.008 { return }
        guard let (vx, vy) = viewPointToVideo(event) else { return }
        lastMoveSendAt = now
        cursorPos = CGPoint(x: CGFloat(vx), y: CGFloat(vy))
        cursorVisible = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cursorLayer.contents != nil { cursorLayer.isHidden = false }
        updateCursorLayerFrame()
        CATransaction.commit()
        client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
    }

    override func mouseMoved(with event: NSEvent) { forwardMouseMove(event) }
    override func mouseExited(with event: NSEvent) {
        cursorVisible = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        CATransaction.commit()
    }
    override func mouseDragged(with event: NSEvent) { forwardMouseMove(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMouseMove(event) }
    override func otherMouseDragged(with event: NSEvent) { forwardMouseMove(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonsMask |= 0x01
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }
    override func mouseUp(with event: NSEvent) {
        buttonsMask &= ~0x01
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonsMask |= 0x02
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }
    override func rightMouseUp(with event: NSEvent) {
        buttonsMask &= ~0x02
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttonsMask |= 0x04
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        buttonsMask &= ~0x04
        if let (vx, vy) = viewPointToVideo(event) {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: 0)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let (vx, vy) = viewPointToVideo(event) else { return }
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 3.0 : event.scrollingDeltaY * 120.0
        let clamped = max(-32767.0, min(32767.0, raw))
        // Windows 接收正值向上，WinHostSender 内部做了 -(int)wheel 还原，故这里发 -clamped 保持自然一致
        let wheel = Int16((-clamped).rounded())
        if wheel != 0 {
            client?.sendMouseInput(x: vx, y: vy, buttons: buttonsMask, wheel: wheel)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Ctrl+Cmd+F（macOS 标准全屏快捷键）在本地切换全屏，先释放对端已按下的修饰键避免粘连
        if event.keyCode == 0x03 && mods == [.command, .control] {
            if !event.isARepeat {
                releaseAllInputs()
                window?.toggleFullScreen(nil)
            }
            return
        }
        guard let wk = MacKeyMap.lookup(event.keyCode) else { return }
        heldKeys.insert(event.keyCode)
        client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: true, flags: wk.extended ? 0x01 : 0)
    }

    override func keyUp(with event: NSEvent) {
        guard let wk = MacKeyMap.lookup(event.keyCode) else { return }
        guard heldKeys.remove(event.keyCode) != nil else { return }
        client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
    }

    override func flagsChanged(with event: NSEvent) {
        let kc = event.keyCode
        guard let wk = MacKeyMap.lookup(kc), let flag = MacKeyMap.modifierFlag(forKeyCode: kc) else { return }
        if kc == 0x39 {
            // CapsLock 在 macOS 每次按下都直接发送成对 down+up
            client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: true, flags: 0)
            client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: false, flags: 0)
            return
        }
        // 以 heldModifiers 集合作为单一事实来源区分同类别左右键（避免同时按左右 Shift 松开一个时仍判为 down）
        if heldModifiers.contains(kc) {
            heldModifiers.remove(kc)
            client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: false, flags: wk.extended ? 0x01 : 0)
        } else if event.modifierFlags.contains(flag) {
            heldModifiers.insert(kc)
            client?.sendKeyInput(vk: wk.vk, scan: wk.scan, down: true, flags: wk.extended ? 0x01 : 0)
        }
    }
}

final class ReceiverWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let canvas: ReceiverCanvasView
    private weak var client: MacReceiverClient?

    init(client: MacReceiverClient) {
        self.client = client
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = min(screenFrame.width * 0.85, 1280)
        let h = w * 10.0 / 16.0
        let rect = NSRect(
            x: screenFrame.midX - w * 0.5,
            y: screenFrame.midY - h * 0.5,
            width: w,
            height: h
        )
        let win = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "SecDisplay 副屏 (Windows 主控) · Ctrl+Cmd+F 全屏"
        win.isReleasedWhenClosed = false
        win.backgroundColor = .black
        win.acceptsMouseMovedEvents = true
        win.collectionBehavior = [.fullScreenPrimary]

        let view = ReceiverCanvasView(frame: NSRect(origin: .zero, size: rect.size))
        view.client = client
        win.contentView = view

        self.window = win
        self.canvas = view
        super.init()
        win.delegate = self

        client.onVideoFrame = { [weak view] pb, vw, vh in
            DispatchQueue.main.async {
                view?.displayFrame(pb, width: vw, height: vh)
            }
        }
        client.onCursorMove = { [weak view] rx, ry, vis in
            DispatchQueue.main.async {
                view?.updateRemoteCursor(x: rx, y: ry, visible: vis)
            }
        }
        client.onCursorImage = { [weak view] img, hx, hy in
            DispatchQueue.main.async {
                view?.updateRemoteCursorImage(img, hotX: hx, hotY: hy)
            }
        }
        client.onSessionChanged = { [weak win] vw, vh, fps in
            DispatchQueue.main.async {
                guard let win else { return }
                win.title = "SecDisplay 副屏 (\(vw)×\(vh) @ \(fps)Hz) · Ctrl+Cmd+F 全屏"
                // 窗口模式下按 1:1 Retina 物理像素自适应窗口尺寸，避免非整数缩放发虚
                if !win.styleMask.contains(.fullScreen),
                   let scr = win.screen ?? NSScreen.main {
                    let scale = max(1.0, win.backingScaleFactor)
                    var cw = CGFloat(vw) / scale
                    var ch = CGFloat(vh) / scale
                    let vf = scr.visibleFrame
                    let maxW = vf.width * 0.90
                    let maxH = vf.height * 0.90
                    if cw > maxW || ch > maxH {
                        let s = min(maxW / cw, maxH / ch)
                        cw *= s
                        ch *= s
                    }
                    let frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: cw, height: ch))
                    let centered = NSRect(
                        x: vf.midX - frame.width * 0.5,
                        y: vf.midY - frame.height * 0.5,
                        width: frame.width,
                        height: frame.height
                    )
                    win.setFrame(centered, display: true)
                }
            }
        }
        client.onDisconnected = { [weak view, weak win] in
            DispatchQueue.main.async {
                view?.showDisconnected("连接已断开，等待 Windows 主控重连…")
                win?.title = "SecDisplay 副屏 (等待重连) · Ctrl+Cmd+F 全屏"
            }
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        canvas.releaseAllInputs()
        window.orderOut(nil)
    }

    func toggleFullscreen() {
        show()
        window.toggleFullScreen(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        canvas.releaseAllInputs()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.releaseAllInputs()
        if !isControlPanelVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
