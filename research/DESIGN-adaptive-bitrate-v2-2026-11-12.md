# 设计 v2：自适应码率控制律修订（基于 Phase 1 实测）

> 状态：设计稿，待实现
> 前序：`research/DESIGN-adaptive-bitrate-2026-11-11.md`
> Phase 1 实测：`research/RESULT-mac-adaptive-bitrate-2026-11-11.md`
> 日期：2026-11-12

## 一、Phase 1 暴露的两个事实

### 1.1 编码延迟不随码率下降而下降

Mac 侧实测：健康度 1.08~1.23，连续触发下调，180Mbps 在 36 秒内降到 17Mbps，
但编码延迟没有回落。说明在这类负载下，编码耗时不是码率驱动的，
继续降码率只伤画质。

### 1.2 `setBitrate` 可能没有真正生效

默认编码方案 A 在初始化时设置：

```swift
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
```

运行时 `setBitrate` 也只改 `AverageBitRate`：

```swift
VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                     value: (clamped * 1_000_000) as CFNumber)
```

没有同步 `kVTCompressionPropertyKey_DataRateLimits`。
VideoToolbox 的 `AverageBitRate` 是长期平均目标，运行时修改后对瞬时编码速度的约束有限；
`DataRateLimits` 才是硬上限。方案 D 初始化时用的就是 `DataRateLimits`。
这可能是「码率降了但编码延迟没降」的原因之一，至少是一个实现缺口。

## 二、修订后的控制律

### 2.1 信号

本地（Mac）：

- `inFlight`：在途帧数，真实拥塞信号。
- `droppedDelta`：在途丢帧增量。
- `encodeMs`：本轮平均编码耗时，只作辅助。
- `captureFps`：采集帧率，用于判断是否静止。

Windows 反馈（0x07）：

- `presentP95Ms`：上屏间隔 p95。
- `sourceP95Ms`：源到达间隔 p95。
- `presentDropDelta`：非节拍丢帧。
- `pacedDropDelta`：节拍主动丢帧，**不参与判断**。

### 2.2 健康度

```swift
budgetMs   = 1000.0 / captureHz
encodeLoad = encodeMs / budgetMs
inflightLoad = Double(inFlight) / 2.0
winQueueMs = max(0, presentP95 - sourceP95)
winQueueLoad = winQueueMs / 15.0
dropLoad = presentDropDelta > 0 ? 1.5 : 0.0

// 编码延迟只在明显超标时参与，避免 1.1 这种噪声反复触发
encodeGuard = encodeLoad > 1.5 ? encodeLoad : 0.0

health = max(winQueueLoad, dropLoad, inflightLoad, encodeGuard)
```

没有收到 0x07 时，`winQueueLoad` 和 `dropLoad` 为 0，退回本地判断，
行为与 Phase 1 接近，但编码延迟阈值提高到 1.5。

### 2.3 试探与回退

这是防止 180→17 连续下滑的关键：

```swift
if health > 1.15 连续 2 轮:
    记录 probe = (beforeMbps: current, beforeHealth: health, at: now)
    current = max(floor, current * 0.90)
    应用新码率
    进入「观察期」

观察期（降档后 2 轮，约 4 秒）：
    if health < probe.beforeHealth * 0.90:
        认为降档有效，清除 probe
    else:
        回退到 probe.beforeMbps
        设置 60 秒不再下调（floor 保持）
        记录「降档无效，回退」
```

这样即使编码延迟与码率无关，最多降一次就会回退，不会一路滑到 15Mbps。

### 2.4 回升

- 静止（`captureFps < 10`）：每 3 轮（约 6 秒）回升 10%，直到 target。
- 运动中且 `health < 0.70` 连续 3 轮：回升 10% + 1Mbps。
- 回升前检查死区 `max(2, current * 0.05)`。

### 2.5 边界

- 下限：`max(15, target / 3)`，避免 66Mbps 目标被降到 15Mbps 以下太多。
- 上限：`targetMbps`。
- 降档冷却：10 秒；回退后 60 秒内不再下调。
- 死区：`max(2, current * 0.05)`。

## 三、`setBitrate` 修订

```swift
func setBitrate(_ mbps: Int) {
    guard let s = session, mbps > 0 else { return }
    let clamped = max(8, min(mbps, 300))
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                         value: (clamped * 1_000_000) as CFNumber)
    // 同步硬上限，避免 AverageBitRate 改了但 DataRateLimits 仍停在旧值
    let limits: [NSNumber] = [NSNumber(value: clamped * 1_000_000 / 8), NSNumber(value: 1.0)]
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits,
                         value: limits as CFArray)
    currentMbps = clamped
}
```

注意：方案 B（低延迟 rate control）可能不接受这两个属性；需要按 variant 分支处理，
或失败时只记日志、不中断。

## 四、0x07 解析

在 `drainControl` 增加：

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
    latestFeedback = fb
    feedbackLock.unlock()
    ctrlBuf.removeFirst(13)
}
```

线程安全：`drainControl` 在 net queue，Timer 在 main queue，用 `NSLock` 保护快照。

## 五、日志

每次调整打印一行，包含所有分项：

```
码率 66 -> 59 Mbps  health=1.22 winQ=18ms presentDrop=0 enc=112% inflight=0 fps=58
```

回退时：

```
降档无效，回退 59 -> 66 Mbps  health=1.20 -> 1.18
```

## 六、验证计划

1. 静止 5 分钟：码率不下降，静止回升生效。
2. 稳定 30~40fps 运动 3 分钟：不频繁调整，`winQueueMs` 接近 0。
3. 人为制造队列：`health > 1.15` 连续 2 轮，降 10%；若健康度无改善，回退并 60 秒不再降。
4. 压力解除：6 秒后开始回升，10% 步长，不震荡。
5. 同时开 `--feedback` 与 `--pace`：`pacedDrop` 不计入 `dropLoad`。

## 七、待确认

- `DataRateLimits` 在方案 A/B/C/D 下的实际生效情况，需要真机 A/B。
- 0x07 反馈的采样窗口与 Windows 端 2 秒统计是否对齐。
- 回退后 60 秒的冷却是否过长，需要实测体感。
