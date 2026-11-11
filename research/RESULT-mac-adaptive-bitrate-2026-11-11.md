# RESULT（Mac）：自适应码率 Phase 1（扩展 RateController）

> 对应任务：`research/TASK-mac-adaptive-bitrate-2026-11-11.md`
> 设计依据：`research/DESIGN-adaptive-bitrate-2026-11-11.md`
> 执行端：Mac 侧
> 日期：2026-11-11
> 关联提交：`536b199` 之后的本轮改动（见 git log）
> 结论摘要：控制律生效，能按健康度下调码率；但阈值与降幅需要调，静止后不回升

## 一、实现内容

`prototype/mac/Sources/ScreenSender.swift`：

### 1.1 RateSignals

```swift
struct RateSignals {
    var droppedDelta: Int     // 本轮在途丢帧增量
    var inFlight: Int         // 本轮观察到的在途帧数
    var encodeMs: Double      // 本轮平均编码耗时（Phase 1 用均值代替 p95）
    var sentMbps: Double      // 本轮实际发送码率
    var captureFps: Double    // 本轮采集帧率
}
```

### 1.2 健康度

```swift
budgetMs = 1000.0 / captureHz
encodeLoad = encodeMs / budgetMs
inflightLoad = inFlight / 2.0
dropLoad = droppedDelta > 0 ? 1.5 : 0.0
health = max(encodeLoad, max(inflightLoad, dropLoad))
```

### 1.3 控制律

- `captureFps < 10`：静态桌面，清空连续计数并返回
- `health > 1.0` 连续 2 轮：`current = max(15, current * 0.80)`
- `health < 0.70` 连续 3 轮且 `current < target`：`current = min(target, current * 1.10 + 1)`
- 死区：`abs(next - current) < max(2, current * 0.05)` 不改
- 每次变更调用 `encoder.setBitrate` 并打日志

### 1.4 调用点

2 秒统计 Timer 里先算 `encAvg`、`capturedDelta`、`droppedDelta`，再调用
`rateCtl.tick(RateSignals(...))`，然后用同一批值打印原有统计行。

## 二、实测

环境：Mac M1 Pro，虚拟屏 1600x1000（1x），smooth 档 `captureHz=60`，
`budgetMs=16.67`，初始码率 180 Mbps。

负载：`tools/motionloader 60`，在虚拟屏上跑 60 秒 CALayer 动画。

日志节选（`logs/sender_20261111_222549.log`）：

```
[99962.322] 健康度 1.08（编码 108% 在途 0%），码率下调至 144 Mbps
[99968.323] 健康度 1.23（编码 123% 在途 0%），码率下调至 115 Mbps
[99972.322] 健康度 1.05（编码 105% 在途 0%），码率下调至 92 Mbps
[99976.282] 健康度 1.21（编码 121% 在途 0%），码率下调至 73 Mbps
[99980.323] 健康度 1.14（编码 114% 在途 0%），码率下调至 58 Mbps
[99984.323] 健康度 1.23（编码 123% 在途 0%），码率下调至 46 Mbps
[99988.323] 健康度 1.13（编码 113% 在途 0%），码率下调至 36 Mbps
[99992.323] 健康度 1.17（编码 117% 在途 0%），码率下调至 28 Mbps
[99996.322] 健康度 1.16（编码 116% 在途 0%），码率下调至 22 Mbps
[   0.323] 健康度 1.11（编码 111% 在途 0%），码率下调至 17 Mbps
```

同期统计行的编码延迟在 20 到 78 ms 之间波动，在途 0 到 1，丢弃 0。

## 三、发现的问题（重要）

### 3.1 降幅过大，码率一路滑到接近下限

健康度只比 1.0 高一点（1.05 到 1.23），却触发了一次又一次 20% 下调，
180 Mbps 在约 36 秒内跌到 17 Mbps。画面质量会明显下降，但编码延迟并没有因此回落，
说明这类负载下延迟不是码率造成的，继续降码率只是伤质量。

### 3.2 静止后不会回升

`captureFps < 10` 时直接返回，不累积 `lowRounds`。运动结束、桌面静止后，
码率会停在 17 Mbps 不动。实测重启发送端才恢复到 180。

### 3.3 健康度数值与统计行编码延迟不一致

统计行显示编码延迟 50 到 78 ms，按 `budgetMs=16.67` 应得到 3.0 到 4.7 的
`encodeLoad`，但日志里的健康度只有 1.05 到 1.23。两者用的是同一个 `encAvg`，
需要下轮排查是采样窗口、重置时机还是计数口径的问题，本轮未定位。

## 四、结论

- 控制律本身跑通，健康度能驱动码率变化，日志可追溯
- 当前阈值（1.0 / 0.7）和降幅（20%）对这个负载过于激进，建议：
  - 降幅改为 10%，或加「降码率后健康度未改善则停止继续降」的保护
  - 静止时若 `current < target`，允许每 6 秒小幅回升
  - 先修 3.3 的口径问题，否则阈值判断建立在错误数值上
- 本轮不做协议改动，未涉及 Windows 侧

## 五、下一步建议

1. 修 `encAvg` 与健康度不一致（优先，影响所有判断）
2. 降幅 20% → 10%，并加连续下调次数上限
3. 静止回升：`captureFps < 10` 时也允许每 3 轮 +10%
4. 用 `--pace` 稳定内容复测，确认 p95 与 fps 不劣化
