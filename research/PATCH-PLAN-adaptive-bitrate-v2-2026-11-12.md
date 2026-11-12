# 补丁计划：自适应码率 v2 + 0x07 解析（Mac 侧）

> 状态：待实施（等代码审查结果后落地）
> 设计：`research/DESIGN-adaptive-bitrate-v2-2026-11-12.md`
> 目标文件：`prototype/mac/Sources/ScreenSender.swift`
> 约束：不改协议视频包；0x07 解析必须能安全忽略旧格式；不在 Windows 侧改代码。

## 一、新增 FeedbackSignals

放在 `RateSignals` 附近：

```swift
struct FeedbackSignals {
    var presentP95: Double = 0
    var sourceP95: Double = 0
    var decodeFps: Double = 0
    var presentDrop: Int = 0
    var pacedDrop: Int = 0
}
```

## 二、Sender 增加 0x07 解析

在 `Sender` 内加：

```swift
private let feedbackLock = NSLock()
private var feedback = FeedbackSignals()

func latestFeedback() -> FeedbackSignals {
    feedbackLock.lock()
    defer { feedbackLock.unlock() }
    return feedback
}
```

`drainControl()` 增加分支（放在 0x04 之后）：

```swift
} else if t == 0x07 {
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
    ctrlBuf.removeFirst(13)
}
```

注意：必须在 0x04 分支之后，避免 0x07 载荷里的 0x04 被误判。但 `drainControl` 是按首字节 `t` 分支的，0x07 包的首字节是 0x07，不会进入 0x04；载荷里的 0x04 只在 `removeFirst(13)` 时被整体跳过。旧 Mac 没有这个分支，会逐字节误判，所以 `--feedback` 默认关闭。

## 三、RateSignals 扩展

```swift
struct RateSignals {
    var droppedDelta: Int
    var inFlight: Int
    var encodeMs: Double
    var sentMbps: Double
    var captureFps: Double
    var winQueueMs: Double = 0
    var presentDrop: Int = 0
    var pacedDrop: Int = 0
}
```

## 四、Timer 调用点

在 `Timer.scheduledTimer(withTimeInterval: 2.0, ...)` 里：

```swift
let fb = sender.latestFeedback()
let winQueueMs = max(0, fb.presentP95 - fb.sourceP95)
rateCtl.tick(RateSignals(
    droppedDelta: droppedDelta,
    inFlight: sender.inFlight,
    encodeMs: encAvg,
    sentMbps: mbps,
    captureFps: Double(capturedDelta) / 2.0,
    winQueueMs: winQueueMs,
    presentDrop: fb.presentDrop,
    pacedDrop: fb.pacedDrop
))
```

## 五、RateController 控制律

新增状态：

```swift
private var probeMbps: Int? = nil
private var probeHealth: Double = 0
private var probeAt: CFAbsoluteTime = 0
private var revertCooldownUntil: CFAbsoluteTime = 0
```

健康度：

```swift
let budgetMs = 1000.0 / captureHz
let encodeLoad = s.encodeMs / budgetMs
let inflightLoad = Double(s.inFlight) / 2.0
let winQueueLoad = s.winQueueMs / 15.0
let dropLoad = s.presentDrop > 0 ? 1.5 : 0.0
let encodeGuard = encodeLoad > 1.5 ? encodeLoad : 0.0
let health = max(max(winQueueLoad, dropLoad), max(inflightLoad, encodeGuard))
```

试探与回退：

```swift
// 观察期：降档后 2 轮
if let pm = probeMbps, now - probeAt < 4 {
    if health < probeHealth * 0.90 {
        probeMbps = nil          // 降档有效
    } else {
        // 降档无效，回退
        current = pm
        encoder.setBitrate(current)
        probeMbps = nil
        revertCooldownUntil = now + 60
        Log.info("降档无效，回退至 \(current) Mbps")
    }
    return
}
probeMbps = nil
```

下调：

```swift
if health > 1.15, now >= revertCooldownUntil {
    highRounds += 1
    lowRounds = 0
    guard highRounds >= 2, now - lastDownAt >= downCooldown else { return }
    highRounds = 0
    lastDownAt = now
    let floor = max(15, targetMbps / 3)
    let next = max(floor, Int(Double(current) * 0.90))
    guard abs(next - current) >= max(2, Int(Double(current) * 0.05)) else { return }
    probeMbps = current
    probeHealth = health
    probeAt = now
    current = next
    encoder.setBitrate(current)
    Log.info(...)
}
```

回升与静止逻辑保留，回升阈值仍为 0.70。

## 六、Encoder.setBitrate 修订

```swift
func setBitrate(_ mbps: Int) {
    guard let s = session, mbps > 0 else { return }
    let clamped = max(8, min(mbps, 300))
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                         value: (clamped * 1_000_000) as CFNumber)
    let limits: [NSNumber] = [NSNumber(value: clamped * 1_000_000 / 8), NSNumber(value: 1.0)]
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                         value: limits as CFArray)
    currentMbps = clamped
}
```

## 七、测试

1. 静止 5 分钟：码率不下降，静止回升生效。
2. 稳定 30~40fps 运动：`winQueueMs` 接近 0，码率不频繁调整。
3. 人为制造队列：降 10% 后观察 2 轮，无改善则回退，60 秒内不再降。
4. 同时开 `--feedback` 与 `--pace`：`pacedDrop` 不计入 `dropLoad`。
5. 旧 Mac 不开 `--feedback`：行为与 Phase 1 一致，不误解析。

## 八、风险

- `DataRateLimits` 在方案 B 下可能不生效，需要按 variant 分支或失败只记日志。
- 0x07 与 0x04 的字节边界必须严格，`removeFirst(13)` 不能少。
- 试探回退可能造成一次画质波动，需要在日志里明确标注。
