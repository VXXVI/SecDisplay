# 任务单：Mac 侧自适应码率 Phase 1（扩展 RateController）

> 状态：代码已完成（v2，提交 `6bed9a1`，CI `build-mac` 通过），待 Mac 重建/重启后真机验证
> 派发方：Windows 侧
> 目标端：Mac 侧
> 日期：2026-11-11
> 设计依据：`research/DESIGN-adaptive-bitrate-2026-11-11.md`
> 回报方式：`research/RESULT-mac-adaptive-bitrate-2026-11-11.md`

## 一、目标

现有 `RateController` 只看「在途丢帧」，触发条件太粗。
本任务只做 **Phase 1：Mac 本地闭环**，不涉及协议改动，不改 Windows。

用编码延迟、在途帧数、实际发送码率、采集帧率算一个健康度，
超过阈值就降码率，连续干净再缓慢回升。目标是压住编码/队列积压，
不是盲目降带宽。

## 二、改动范围

文件：`prototype/mac/Sources/ScreenSender.swift`

### 2.1 扩展 tick 入参

把 `tick(dropped:)` 改为传入一组信号，例如：

```swift
struct RateSignals {
    var droppedDelta: Int      // 本轮在途丢帧增量
    var inFlightMax: Int       // 本轮观察到的最大在途
    var encodeP95Ms: Double    // 本轮编码耗时 p95
    var sentMbps: Double       // 本轮实际发送码率
    var captureFps: Double     // 本轮采集帧率
}
```

`RateController` 初始化时额外接收 `captureHz`（默认取 `cfg.captureHz`）。

### 2.2 健康度

```swift
budgetMs = 1000.0 / captureHz
encodeLoad = encodeP95Ms / budgetMs
inflightLoad = Double(inFlightMax) / Double(maxInFlight)   // maxInFlight = 2
dropLoad = droppedDelta > 0 ? 1.5 : 0.0
health = max(encodeLoad, inflightLoad, dropLoad)
```

Phase 1 不使用 Windows 的 `presentP95` / `sourceP95`，那些留到 Phase 2。

### 2.3 控制律

每 2 秒：

- `captureFps < 10`：静态桌面，重置计数，直接返回。
- `health > 1.0` 连续 2 轮：`current = max(15, round(current * 0.80))`。
- `health < 0.70` 连续 3 轮且 `current < target`：`current = min(target, round(current * 1.10) + 1)`。
- 其他：重置连续计数，不动。
- 死区：`abs(next - current) < max(2, current * 0.05)` 时不改。
- 变更后调用 `encoder.setBitrate(current)`，并打印一行日志：

```
码率 120 -> 96 Mbps  health=1.32 encodeP95=21.4ms inflight=2 sent=3.1Mbps fps=58
```

### 2.4 不清零的部分

- 保留现有 `targetMbps`、`min 15` 的边界。
- 保留 `encoder.setBitrate` 的现有实现。
- 不动采集、分辨率、GOP、码率上限。

## 三、判据

1. **静态桌面 5 分钟**：`captureFps < 10`，码率不下降，日志显示跳过评估。
2. **稳定 30~40fps 运动 3 分钟**：`health` 主要在 0.7~1.0，码率不频繁变动。
3. **人为制造编码压力**（例如临时把 `captureHz` 调到 60 并播放高动态内容）：
   连续 2 轮 `health > 1.0` 后码率下降 20%。
4. **恢复**：压力解除后 6 秒开始回升，步长约 10%，不出现锯齿。
5. 日志能复盘每次变更的 `health` 与各分项。

## 四、本轮不做

- 不加 Windows 反馈包（0x07），不动协议。
- 不做质量档/分辨率回退。
- 不改 `maxInFlight`、`queueDepth`。
- 不改 `--pace` 相关逻辑。

## 五、需要用户配合

- 第 3 项压力测试需要真实高动态内容；可用 `tools/motionloader`，或由用户播放高码率视频。
- 若暂时没有压力源，先交 1、2、4 的静态与稳定内容结果，第 3 项标注待补。

## 六、回报

新建 `research/RESULT-mac-adaptive-bitrate-2026-11-11.md`，写：

- 改动文件与提交号。
- 五项判据的逐条结果。
- 码率变化日志样例。
- 是否出现震荡或画质突变。
