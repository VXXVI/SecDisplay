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

## 已落地的代码改动

- `ScreenSender.swift`：`EnableLowLatencyRateControl` 改为可用环境变量控制，
  默认仍开启；高分辨率档可 `SECDISPLAY_NOLOWLAT=1` 关闭供真机 A/B。swiftc 编译通过。
- `tools/MotionLoader.swift`：修虚拟屏识别 bug。原用 `$0 != 6` 排除旧 id，
  当前虚拟屏 id=9 且在线还有 Sidecar(id=4)，会**把动画播到 Sidecar 上**。
  改用与主程序一致的 EDID 三元组 `vendor=0xEEEE/model=0x5344` 精确认定。

## 建议的 A/B 验证（需真机，未做）

1. Mac：`SECDISPLAY_NOLOWLAT=1 ./run.sh restart`，Windows `--tearing` 呈现，测端到端。
2. 对比默认（lowlat 开 + vsync）与上述组合，用 Windows 侧统计 + Mac `latencyclient` 数据。
3. 若确认 smooth 档关 lowlat 更顺，再把默认按分辨率自适应（高分辨率默认关）。

## 边界

- 隔离测试是合成帧满负荷，不代表真实桌面；真实场景编码延迟远低于此。
- 未在真实两端联调下验证 `SECDISPLAY_NOLOWLAT` 与 `--tearing` 的组合效果。
- Windows 呈现端改动属 windowsagent 领域，本文只给 Mac 侧开关与数据，不越界改。
