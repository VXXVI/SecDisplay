# RESULT（Windows 侧执行）：自适应码率 v2 + 0x07 接入

> 对应任务：`research/TASK-mac-adaptive-bitrate-2026-11-11.md`
> 设计：`research/DESIGN-adaptive-bitrate-v2-2026-11-12.md`
> 补丁计划：`research/PATCH-PLAN-adaptive-bitrate-v2-2026-11-12.md`
> 执行提交号：`6bed9a1`
> 执行端：Windows 侧代改 Mac 源码，CI 编译验证
> 日期：2026-11-12

## 一、改动内容

### 1.1 `Encoder.setBitrate` 同步硬上限

之前只改 `kVTCompressionPropertyKey_AverageBitRate`，`DataRateLimits` 可能停在初始化值，
这是 Phase 1「码率降了但编码延迟没降」的一个实现缺口。现在两处一起改，
设置失败只记日志，不中断。

### 1.2 0x07 反馈解析

`Sender.drainControl()` 增加 `0x07` 分支，解析 13 字节大端包：

```
[0x07][presentP95 u16][sourceP95 u16][decodeFps*10 u16]
[presentDrop u16][pacedDrop u16][reserved u16]
```

`FeedbackSignals` 用 `NSLock` 保护，net queue 写、main queue 读。

### 1.3 健康度加入 Windows 队列

```swift
winQueueMs = max(0, presentP95 - sourceP95)
winQueueLoad = winQueueMs / 15.0
dropLoad = (presentDrop > 0 || droppedDelta > 0) ? 1.5 : 0
encodeGuard = encodeLoad > 1.5 ? encodeLoad : 0
health = max(max(winQueueLoad, dropLoad), max(inflightLoad, encodeGuard))
```

编码延迟只在超过 1.5 倍帧预算时参与，避免 Phase 1 里 1.1 这种噪声反复触发。

### 1.4 降档试探与回退

降档后 8 秒观察窗口，取窗口内最低健康度：

- 改善 ≥10%：认为降档有效，保留。
- 没有改善：回退到降档前码率，并 60 秒内不再下调。

下限改为 `max(15, target / 3)`，避免 66Mbps 目标被一路降到 15Mbps 以下太多。

## 二、编译验证

CI `SecDisplay CI` 对提交 `6bed9a1` 的结果：

```
build-mac              success
build-windows          success
telemetry-consistency  success
```

`build-mac` 用 `swiftc -O Sources/ScreenSender.swift` 实际编译，语法通过。

## 三、运行验证状态（阻塞）

还不能开 `--feedback` 做闭环，原因有两条：

1. Mac 当前运行的是旧二进制，没有 0x07 分支。对旧 Mac 发 0x07 时，
   载荷里的 `0x04` 字节会被误认为输入包，造成误输入。必须等 Mac 重建并重启。
2. Mac 上一轮强杀留下孤儿虚拟屏（vendor=0xEEEE），`run.sh restart` 被保护逻辑拒绝。
   Mac 侧已提供 `prototype/mac/cleanup_orphan_vdisplay.swift`，用
   `pmset displaysleepnow` + `caffeinate -u` 清理，不需要注销。

## 四、下一步（Mac 侧）

1. 运行 `cleanup_orphan_vdisplay --vendor 0xEEEE --product 0x5344 --apply --verify`。
2. 重新编译并 `./run.sh restart`，确认运行的是含 0x07 解析的新二进制。
3. 用 `tools/motionloader 60` 跑一轮，观察日志里的健康度与码率变化。
4. 确认静止 30 秒后码率能逐步回升，不出现 180→17 的连续下滑。
5. 完成后通知 Windows 侧，再打开 `--feedback` 做闭环 A/B。

## 五、注意事项

- `--feedback` 默认关闭，旧 Mac 不能开。
- 0x07 与 0x04 的字节边界必须严格，`removeFirst(13)` 不能少。
- `DataRateLimits` 在方案 B 下可能不生效，日志会打印设置失败。
- 本轮没有改协议视频包，也没有改 Windows 侧代码。
