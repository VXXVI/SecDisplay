# 编码延迟实测：EnableLowLatencyRateControl 并非恒优（2026-11-11 凌晨，自主实验）

> 用户授权「工作不要停止，自己尝试找更好的方案，可以查阅资料、自己尝试」。
> 本文记录 Mac 侧用 `tools/EncLatency.swift` 隔离实测编码器「提交→输出」延迟的发现。
> 隔离测试不走 ScreenCaptureKit、不走网络，只测编码器内部缓冲。

## 结论（修正了一个既有假设）

**`kVTVideoEncoderSpecification_EnableLowLatencyRateControl` 不是恒优，取决于分辨率。**
高分辨率接近 M1 Pro 编码器吞吐上限时，开启它反而**更慢**；低分辨率富余时才更快。

这与 Sunshine issue #5814（Apple Silicon 上 `AV_CODEC_FLAG_LOW_DELAY` 把 4K 上限压到
~55fps）的机制一致。此前 `BENCH-04` 记录「低延迟模式确实起效 50.5 vs 59.6ms」是在
2880x1800@60 满负荷场景，本次在 smooth 2240x1400@60 与多档位复测得出相反结论。

## 实测数据（M1 Pro，macOS 27.2，ENC_DELAY=1，码率固定 100Mbps）

| 分辨率 @ 提交帧率 | lowlat 开 · 中位 / p95 | lowlat 关 · 中位 / p95 | 更优 |
|---|---|---|---|
| 2240x1400 @60（当前 smooth） | 34~37 / 65~91 ms | **21~23 / 39 ms** | 关 |
| 2880x1800 @45（balanced） | 44~50 / 78~99 ms | **35~36 / 61~63 ms** | 关 |
| 1920x1200 @60（fast） | **9 / 17 ms** | 14 / 29 ms | 开 |

每组 2~3 轮，结果稳定。实际输出帧率各档 48~55fps（未达 60，见下）。

## 另一个发现：ENC_DELAY=0 反而更差

`MaxFrameDelayCount=0`（真正 one-in-one-out）在 2240x1400@60 下**中位 44ms > =1 时的 36ms**。
所以当前代码 A 方案的 `MaxFrameDelayCount=1` 不该改成 0，与 StackOverflow 上「=0 不一定解决」
的经验一致。

## 对「延迟大」的判断修正

真实桌面（静止/简单内容）下，Mac 日志实测编码延迟中位仅 **14~15ms**、采集 6~8ms，
编码本身不是大头（隔离测试的 34ms 是满负荷合成帧的最坏情况）。端到端延迟大头更可能在：
1. **Windows 呈现 vsync**：89Hz 屏 + ~53fps 帧率，`Present(1,0)` 每帧等 1~2 个刷新周期
   （11~22ms 额外），且非整数倍导致节奏跳变（对应「卡顿」）。
2. Windows 端 `附加延迟` 只是窗口内排队抖动，非端到端绝对值。

## 真实端到端复测：推翻了上面的隔离结论（重要）

隔离测试之后，用 `tools/latencyclient` 连真实发送端 + `tools/motionloader` 造动画负载，
测了同一 smooth 2240x1400@60 档位 lowlat 开/关的**真实端到端延迟**：

| 配置 | 端到端中位 | p95 | 实际帧率 |
|---|---|---|---|
| lowlat 开（当前默认） | **19.74 ms** | 55.4 ms | 53.3 fps |
| lowlat 关（NOLOWLAT=1） | 31.21 ~ 68.86 ms | 71.6 ~ 188.6 ms | 29.9 ~ 51.9 fps |

**真实场景下 lowlat 开明显更优，与隔离测试相反。** 原因：隔离测试用每帧变一个字节的
合成帧，接近编码器吞吐极限；真实桌面内容复杂度低，lowlat 的 rate control 收益体现出来。

**结论修正：保持默认 lowlat 开，不改默认。** `SECDISPLAY_NOLOWLAT=1` 开关仅作实验手段保留。
这正说明隔离合成帧不能替代真实负载验证——一次真实测试推翻了一次隔离测试。

## 另一个真实发现：shutdown 的虚拟屏残留 bug

`shutdown` 里 `vd.destroy()` 报告「虚拟屏已销毁」，但 WindowServer 实际没移除，
下次启动创建被拒（日志「initWithDescriptor 返回 nil」）。根因：`stopCapture()` 未完全
完成时调 destroy 会被系统静默拒绝；旧代码只等 2 秒 + destroy 一次。

已修：`shutdown` 改为停采集最多等 3 秒，destroy 后**轮询 `CGGetOnlineDisplayList`
确认虚拟屏真的从在线列表消失**，最多重试 2 秒；仍在线则日志警告。这是防残留的根因修复。

注：已被强杀进程留下的残留屏，从外部清不掉（`CDVirtualDisplayDestroy` 需 client 指针，
指针随进程消失）。这类历史残留仍需注销重登或重启清除，无法用代码自愈——
尝试过「复用残留屏」方案，但残留屏的 owner 进程已死，SCG 采集不到内容（黑屏），
比明确报错更糟，故撤掉该方案。

## 已落地的代码改动

- `ScreenSender.swift`：`EnableLowLatencyRateControl` 可用 `SECDISPLAY_NOLOWLAT=1`
  控制，**默认保持开启**（真实测试证明开更优）。swiftc 编译通过。
- `ScreenSender.swift`：`shutdown` 改为轮询确认虚拟屏真正移除 + 重试，防残留。
- `tools/MotionLoader.swift`：修虚拟屏识别 bug。原用 `$0 != 6` 排除旧 id，
  当前虚拟屏 id=9/10 且在线可能有 Sidecar(id=4)，会**把动画播到 Sidecar 上**。
  改用与主程序一致的 EDID 三元组 `vendor=0xEEEE/model=0x5344` 精确认定。

## 边界与后续

- 真实端到端数据都在这台 M1 Pro 上、本地回环（127.0.0.1）测得，不含雷电网络与 Windows 解码/呈现。
- 延迟大头判断仍成立：真实桌面编码延迟仅 14~15ms，端到端 19.7ms，剩余主要在
  Windows 呈现 vsync（89Hz 非整数倍）与网络。该结论指向 windowsagent 领域。
- 待屏幕唤醒、Windows 联调时，可再验 `--tearing` + lowlat 组合的真实体感。
- 一个可靠的实验方法沉淀：`tools/EncLatency.swift`（隔离编码）+ `tools/latencyclient`
  + `tools/motionloader`（真实端到端），先用隔离快速排除参数，再用端到端定论，不轻信单一结果。
