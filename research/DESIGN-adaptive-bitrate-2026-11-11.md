# 设计：参考 Duet 的自适应码率与延迟反馈环（2026-11-11）

> 状态：设计稿，待评审
> 参考：`research/REVERSE-DUET-4.0.526.md`、`research/RESULT-duet-mac-static.md`、
> `research/RESULT-duet-win-static.md`、`prototype/mac/Sources/ScreenSender.swift`
> 目标：在 SecDisplay 现有固定码率基础上，补一条能压住编码/队列积压的反馈环。
> 边界：只借鉴结构，不复制 Duet 代码；不改现有协议的视频包格式。

## 一、Duet 实际在做什么（证据）

### 1.1 帧级 checkpoint

Windows 二进制里可见：

- `DuetFrameStatsProto.Duet_FrameStats`、`Duet_FrameCheckpoint`、`Duet_FrameLabel`、
  `Duet_ClockDomain`
- `Duet_ConnectionCheckpointManager`、`Duet_CheckpointTracker`、`CheckpointRecorded`
- `averageEncodeTime` / `currentEncodeTime`、`connectionAverageFrameEncodeTime`
- `Decode Presentation Dropped Frames`

推断：Duet 给每一帧打多个时间点（采集、编码、发送、解码、呈现），
用同一时钟域算 current/average latency、标准差与接收端丢帧数。
这是反馈环的测量层，不是直接调参。

### 1.2 自适应质量与码率

可见符号：

- `videoBitRateOptionsMbps`、`videoBitRateMbps`、`setVideoBitRateMbps`
- `SenderDefaultBitRateMbps`、`SenderDefaultFrameRateFPS`、`SenderDefaultImageQuality`
- `transmittedBitRateMbps`、`Encoder BitRate`、`max_bitrate`
- `qualityIndex`、`qualityOptions`、`displayImageQualityOptions`
- `averageLatency` / `currentLatency`、`connectionAverageLatency` / `connectionCurrentLatency`
- `Connection Latency Average` / `Maximum` / `Std Dev`

特性开关：

| 开关 | 值 | 作用推断 |
|---|---|---|
| `rdp-adaptive-quality` | 50 | 自适应质量阈值/等级 |
| `pc-air-lag-quality-check-enabled` | true | 基于延迟的质量检查 |
| `mac-enable-frame-resend-logic` | true | 迟到/丢失帧重发 |
| `mac-enable-1x-decoding-flag` | true | 低延迟解码路径 |
| `mac-sonoma-lag-notification-disable` | false | 系统卡顿提示 |

推断：Duet 的调节是**离散质量档 + 目标码率**，由 current/average latency 和接收端丢帧驱动，
并有一分钟窗口的统计，不是每帧抖动就改。

### 1.3 采集侧

- `CGDisplayStream` 为主，`setQueueDepth:` / `setMinimumFrameInterval:` 显式控制。
- 浅队列，宁可丢帧也不让帧在 pipeline 里排队。

## 二、SecDisplay 现状

Mac `RateController`（`ScreenSender.swift:1336-1377`）：

```swift
每 2 秒 tick(dropped)
if 有丢帧: current = max(15, current * 0.8)
else if current < target 且连续 3 轮无丢帧: current = min(target, current * 1.15 + 1)
```

特点与缺口：

- 只有「在途丢帧」一个信号，`maxInFlight=2`，触发条件很粗。
- 没有编码延迟、没有接收端呈现丢帧、没有队列积压、没有实际发送码率。
- 没有区分「源端帧节奏抖动」和「链路/编码拥塞」。
- 固定 180Mbps 目标，实际发送常见 0.3~5Mbps，链路 20Gbps。
  也就是说，当前瓶颈更多是编码/队列与源帧节奏，不是带宽。

## 三、设计目标

1. 压住**编码延迟超过帧预算**和**在途/呈现队列积压**，不是盲目降带宽。
2. 静态桌面不误判，`--pace` 的主动丢帧不参与判断。
3. 快速下降、缓慢回升，带死区与滞回，避免震荡。
4. 先做 Mac 本地闭环，再加 Windows 反馈，分两期落地。
5. 不改变视频包格式，新增反馈包对旧 Mac 安全。

## 四、健康度指标

每 2 秒计算一次，统一到 0~1 以上：

```
budgetMs   = 1000 / captureHz                  // 60Hz -> 16.7ms
encodeLoad = encodeP95Ms / budgetMs            // 编码是否超帧预算
inflightLoad = maxInFlightObserved / maxInFlight   // 2 为上限
winQueueMs = max(0, presentP95Ms - sourceP95Ms)    // Windows 侧额外排队
winQueueLoad = winQueueMs / 15.0               // 15ms 作为警戒
dropLoad   = presentDropDelta > 0 ? 1.5 : 0    // 非节拍丢帧
health = max(encodeLoad, inflightLoad, winQueueLoad, dropLoad)
```

说明：

- 用 `presentP95 - sourceP95` 而不是 `presentP95` 本身，避免把 Mac 源端帧节奏抖动
  误判成 Windows 拥塞。我们此前的实测两者几乎相等。
- `pacedDropDelta` 是 `--pace` 的主动丢帧，**不进入** `dropLoad`。
- 静态桌面 `captureFps < 10` 时不评估，直接跳过。

## 五、控制律

每 2 秒：

```
if !motion: return
if health > 1.0 连续 2 轮:
    next = max(minMbps, round(current * 0.80))
elif health < 0.70 连续 3 轮 and current < target:
    next = min(target, round(current * 1.10) + 1)
else:
    return

if abs(next - current) < max(2, current * 0.05): return   // 死区
current = next
encoder.setBitrate(current)
log(health, encodeP95, winQueueMs, dropDelta, current)
```

参数建议：

| 参数 | 建议值 | 理由 |
|---|---|---|
| tick | 2 秒 | 与现有控制器一致，避免每帧抖动 |
| 下降步长 | 20% | 与现有实现一致，快速止血 |
| 上升步长 | 10% + 1Mbps | 比现有 15% 更保守 |
| 上升前干净轮数 | 3 轮（6 秒） | 与现有实现一致 |
| 下限 | 15Mbps | 现有实现的下限 |
| 上限 | targetMbps（默认 180） | 不主动超过配置 |
| 死区 | max(2Mbps, 5%) | 防止小步震荡 |

## 六、反馈协议（第二期）

Windows → Mac 新增 `0x07 FEEDBACK`，固定 13 字节：

```
[0x07]
[uint16 presentP95ms]
[uint16 sourceP95ms]
[uint16 decodeFps10]      // 解码 fps * 10
[uint16 presentDropDelta] // 非节拍丢帧
[uint16 pacedDropDelta]   // 节拍主动丢帧
[uint16 reserved]
```

- Windows 每 2 秒发一次，或跟随监控线程。
- Mac `drainControl()` 增加 0x07 分支；旧 Mac 会把未知字节逐个丢弃，不会误解析。
- 第一期不需要这个包，Mac 只用本地 `encodeP95`、`inFlight`、`sentMbps`。

## 七、落地分期

### Phase 1（Mac 本地，先做）

- 扩展 `RateController`：增加 `encodeP95Ms`、`inFlightMax`、`sentMbps`、`captureFps` 参数。
- 用 `encodeLoad`、`inflightLoad` 计算 `health`，按第五节的阈值调节。
- 日志每轮打印 `health / encodeP95 / current / target`，便于复盘。
- 不改协议，Windows 侧零改动。

### Phase 2（闭环，需两端）

- Windows 增加 0x07 反馈发送。
- Mac 把 `winQueueLoad`、`dropLoad` 纳入 `health`。
- 复测：限速或人为制造队列，确认下降及时、回升不震荡。

### Phase 3（质量档，可选）

- 若码率已到下限但 `health` 仍高，考虑分辨率/质量档回退，
  对应 Duet 的 `qualityIndex` / `resolutionOptions`。

## 八、测试方案

1. **静态桌面 5 分钟**：`captureFps < 10`，码率不应下降，日志应显示跳过评估。
2. **稳定 30~40fps 运动 3 分钟**：`health` 应在 0.7~1.0 之间，码率不频繁变动。
3. **故意限速**：在 Mac 侧用 `pfctl`/网络限速或人为加队列，确认 2 轮内下降 20%。
4. **恢复**：限速解除后 6 秒开始回升，10% 步长，不出现锯齿。
5. **`--pace` 同时开启**：`pacedDropDelta` 不计入 `dropLoad`，码率不应因节拍丢帧下降。

## 九、预期收益与局限

- 收益：编码延迟超过帧预算时能主动降码率，减少队列积压与端到端抖动。
- 局限：当前链路 20Gbps、实际发送只有几 Mbps，带宽不是瓶颈。
  这条环路主要解决编码/队列，不会消除 Mac 源端的 2:1 帧节奏。
- 不要把它当成「提高帧率」的手段；帧率由采集与内容决定。

## 十、待确认

- `kVTCompressionPropertyKey_AverageBitRate` 在运行中修改后，VideoToolbox 何时生效、
  是否需要关键帧，需 Phase 1 实测。
- Duet 的 `rdp-adaptive-quality=50` 具体含义未知，我们只借鉴「阈值 + 滞回」的结构。
- 是否要把质量档回退纳入 Phase 1，取决于用户在低码率下的画质容忍度。
