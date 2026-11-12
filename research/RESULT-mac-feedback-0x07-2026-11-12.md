# RESULT：Mac 侧 0x07 反馈包解析（2026-11-12）

> 任务：Phase 2 Mac 半边，0x07 反馈解析 + 接入 RateController
> 代码：`prototype/mac/Sources/ScreenSender.swift`
> 验证脚本：`tools/test_0x07_feedback.swift`
> 关联：`research/DESIGN-adaptive-bitrate-v2-2026-11-12.md`、
> `research/RESULT-adaptive-bitrate-v2-2026-11-12.md`（Windows 侧代改提交 `6bed9a1`）

## 零、执行说明与既有实现

本任务的核心逻辑（`drainControl` 0x07 分支、`FeedbackSignals`、
`RateSignals` 新字段、健康度融合）在提交 `6bed9a1` 已由 Windows 侧代改落地。
本轮逐行核查了该实现，确认与设计文档一致，并补齐三个缺口：

1. **收到反馈无日志**：`drainControl` 0x07 分支增加一行 `Log.info`，
   打印全部字段值（`ScreenSender.swift:939-941`）。
2. **`clientFps` 未透传**：`RateSignals` 增加 `clientFps` 字段（解码呈现 fps，
   仅观测不参与健康度），2 秒统计定时器把 `fb.decodeFps` 填入
   （`ScreenSender.swift:1499`、`1685`）。
3. **无解析验证**：新增 `tools/test_0x07_feedback.swift`，8 项场景全过（见第五节）。

## 一、包格式（字节级）

Windows → Mac，定长 13 字节，全大端：

```
偏移  长度  字段            说明
 0     1   type = 0x07
 1     2   presentP95 u16  上屏间隔 p95，毫秒
 3     2   sourceP95  u16  源到达间隔 p95，毫秒
 5     2   decodeFps10 u16 解码呈现 fps × 10（597 = 59.7fps）
 7     2   presentDrop u16 非节拍丢帧增量
 9     2   pacedDrop   u16 节拍主动丢帧增量（Mac 侧不参与判断）
11     2   reserved    u16 保留，必须为 0
```

- 每帧通道复用现有控制字节流（与 0x02/0x04 同一条），无独立长度前缀，
  `drainControl` 按类型定长消费。
- `drainControl` 在 net queue 写 `feedback`，`NSLock` 保护；
  2 秒统计定时器在 main queue 经 `latestFeedback()` 读快照。

## 二、健康度融合呈现信号

2 秒 tick 组装 `RateSignals` 时：

```swift
let fb = sender.latestFeedback()
let winQueueMs = max(0, fb.presentP95 - fb.sourceP95)   // Windows 侧额外排队
```

控制律：

```
budgetMs     = 1000 / captureHz
encodeLoad   = encodeMs / budgetMs
inflightLoad = inFlight / 2.0              // 本地信号，Phase 1 优先级不变
winQueueLoad = winQueueMs / 15.0           // 呈现侧负载，15ms 警戒
dropLoad     = (presentDrop + droppedDelta) >= 2 ? 1.5 : 0.0
encodeGuard  = encodeLoad > 1.5 ? encodeLoad : 0.0   // 本地，防噪声

health = max(winQueueLoad, dropLoad, inflightLoad, encodeGuard)
```

- 本地信号（`inflightLoad`、`encodeGuard`）与呈现信号（`winQueueLoad`、
  `dropLoad`）取 max，任何一路超标都能降档，不存在呈现信号压制本地信号。
- `pacedDrop`（Windows 节拍器主动丢帧）明确排除在 `dropLoad` 外，
  避免正常节奏被误判拥塞。
- `clientFps` 只随日志观测，不进健康度：它与 `captureFps` 的差值
  可用于后续诊断，但当前阈值律没有消费它，贸然加入只会引入震荡。

## 三、未收到反馈时的降级行为

`FeedbackSignals` 各字段默认 0。没有 0x07 到达时：

- `winQueueMs = 0 → winQueueLoad = 0`
- `presentDrop = 0`，但本地 `droppedDelta > 0` 仍能触发 `dropLoad = 1.5`
- 健康度退化为 `max(inflightLoad, dropLoad(本地), encodeGuard)`，
  与 Phase 1 行为一致（编码延迟阈值 1.5 是 v2 已修订项，非本轮改动）。
- 连接重建时 `ctrlBuf.removeAll()` 清残留，旧连接的半个包不会
  把 0x07 载荷误解析成 0x04（`ScreenSender.swift:791`）。

## 四、编译结果

```
swiftc -O Sources/ScreenSender.swift -o /tmp/check_bin
exit=0
```

两个 warning（`fps` 未使用、`vdStillOnline` @Sendable）均为改动前既有的，
与 0x07 无关。

## 五、验证方式与结果

`tools/test_0x07_feedback.swift`：把 `drainControl` 的 0x07 分支按行复刻成
可直调函数（不连生产端口、不碰运行中的 screensender），覆盖：

| 场景 | 结果 |
|---|---|
| 正常单包字段解码（33/20/59.7fps/2/1） | PASS |
| 单包消费后无残留字节 | PASS |
| 三包粘包一次 drain | PASS |
| 半包（8 字节）等待不误消费 | PASS |
| 半包补齐后解析 | PASS |
| 载荷含 `0x04` 字节不串包（旧 Mac 会误当输入包） | PASS |
| 未知类型字节 `0x99` 跳过后继续解析 | PASS |
| 0x02 关键帧请求与 0x07 混排 | PASS |

```
$ swift tools/test_0x07_feedback.swift
8 项全部 PASS
```

局限：这是对拍复刻验证，验证的是字节级格式与消费边界；
`drainControl` 本体在真机上的行为需在 `--feedback` 闭环时由
`0x07 反馈:` 日志行确认。

## 六、需要 Windows 侧配合的最小实现

Mac 解析已就绪，Windows 侧可以启用反馈：

1. **发送节奏**：每 2 秒一次，与监控线程合并即可，独立线程没必要。
2. **字节序**：13 字节全大端，字段顺序严格按第一节表格。
   `presentDrop`/`pacedDrop` 发**增量**（相对上次发送），不要发累计值，
   否则 Mac 单帧判断 `(presentDrop + droppedDelta) >= 2` 会长期为真。
3. **字段口径**：
   - `presentP95`：上屏间隔 p95，单位 ms，取 2 秒窗口。
   - `sourceP95`：源到达间隔 p95，与 `presentP95` 同窗口同口径，
     Mac 用两者差值估 Windows 排队，口径不一致会算出负值或虚高。
   - `decodeFps10`：实际呈现 fps × 10，如 597。
   - `reserved` 恒 0，留作后续扩展（窗口宽高可走这里的高 16 位段，
     需要时再升协议版本，不动现有字段）。
4. **启用条件**：确认 Mac 运行的是含 0x07 分支的新二进制后再开
   `--feedback`。旧二进制会把载荷中的 `0x04` 误当输入包（本脚本
   场景 6 即复现该风险）。开反馈后先在 Mac 日志确认
   `0x07 反馈:` 行出现且数值合理。
5. **窗口宽高**：当前 13 字节包没有承载窗口尺寸的字段。若需要
   分辨率同步信号，建议用 `reserved` 之外的扩展包（如 0x08），
   不要挤进 0x07 改变定长。

## 七、后续

- `clientFps` 与 `captureFps` 的差值可在闭环后评估是否纳入健康度。
- 真机闭环：`motionloader` + `--feedback`，观察日志中
  `0x07 反馈:` 与码率变化联动。
