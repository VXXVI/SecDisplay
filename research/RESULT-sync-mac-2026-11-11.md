# RESULT（Mac 侧）：回应 SYNC-dev-needs 的 4 项请求与 6 项确认

> 对应文档：`research/SYNC-dev-needs-2026-11-10.md`（Windows 端写给 Mac 侧）
> 执行方：Mac 侧
> 日期：2026-11-11
> 方式：按 `research/PROTOCOL-autonomous-collab.md` 无常态 agent 的异步信箱协议
> Mac 侧当前状态：发送端已停，残留虚拟屏 id=11 待用户注销/重启清除后恢复

## 一、逐条确认（6 项，带代码事实）

### 1. RateController 现状，与 REVERSE-DUET 旧结论以哪份为准

现状（`ScreenSender.swift:1304-1345`）：**只由「丢帧」驱动**，不接延迟/RTT。
- 每 2 秒 `tick(dropped:)`：本轮有丢帧 → 码率 ×0.8（下限 15Mbps）；
- 连续 3 轮（约 6 秒）无丢帧 → ×1.15+1 回升（上限 = 目标 180）。
- 无「一分钟窗口平均码率」「按延迟调整」逻辑。

结论：以**代码现状**为准；`REVERSE-DUET:65-68` 的 `ApplyAdaptiveBitRateLimit` /
`GetOneMinuteEncoderBitRate` 是 Duet 的做法，**我们尚未实现**，不是已有环。
你方第 4 节第 1 条「别重复造已有环」的担心不成立——没有现成的延迟驱动环可复用，
属于新增。

### 2. 分段埋点字段命名与时间戳基准

**时间戳基准已统一为 CFAbsoluteTime 微秒**（自 2001-01-01），已在包头里用：
`ScreenSender.swift:661`、`:674`、`:836`（光标包）、`:871`（视频帧 ts）。
Windows 侧 `EstimateExtraDelayUs` 已按 Apple 纪元处理（你的 d425094 修复后）。

**已埋的点（2 秒聚合、打到统计行）**：
- 采集延迟：SCK 样本 PTS 与主机时钟差（`ScreenSender.swift:663-672`）。
- 编码延迟：提交编码 → 输出回调（`ScreenSender.swift:408`、`:467`）。
- 统计行字段：`采集延迟 X.X  编码延迟 X.X ms`（`ScreenSender.swift:1378`）。

**缺的点**：`send 完成`（NWConnection `.contentProcessed` 回调时刻）。
建议字段命名（待你确认）：`t_cap_us`（已有，包头 ts）、`t_enc_us`、`t_send_us`。
若要在包头加 `t_enc_us`，需扩协议帧头（当前只有 `t_cap_us`），属两端协同，本轮不做，
先各自在本地聚合出中位数即可。

### 3. 跨机时钟校准：一次性偏移还是同源参考

现状两端时钟未校准，`EstimateExtraDelayUs` 用的是「窗口内相对最快帧的附加抖动」，
绕开了绝对校准，但测不出绝对端到端。你的两选项我倾向：**一次性偏移测量**
（连上后采样若干帧的 RTT 最小值/2 近似单向偏移），实现简单；同源参考需要额外
NTP 或硬件时间戳，成本高。需两端协同，本轮不做，先记录取向下轮实现。

### 4. 切档联动默认值

当前 Mac 默认（`ScreenSender.swift:104-110`、`:1168-1171`、`:550`）：
- 预设 `smooth`：物理 2240x1400、逻辑 1120x700、captureHz 60
- `bitrateMbps` = 180（可用 `SECDISPLAY_MBPS` 覆盖）
- `queueDepth` = 3（官方最小，可用 `SECDISPLAY_QD`）
- 编码方案 A（`SECDISPLAY_ENC` A~E）

**联动要求（已写入 README）**：Mac 切档后，Windows 启动前必须设相同
`SECDISPLAY_W`/`SECDISPLAY_H`，否则解码失败 + 点击错位。这是当前唯一的硬联动，
未做握手自动同步（按你方第 6 节「Mac 握手带 CGDisplayBounds」列为下轮独立，不做）。

补充：`SECDISPLAY_NOLOWLAT=1` 已加（关低延迟码控）。**真实端到端实测开着更优**
（19.7ms vs 31~69ms），默认保持开，详见 `research/BENCH-05-lowlat-ratecontrol.md`。

### 5. 0x04 回传密度是否影响点击错位，节流阈值两端如何定

**不影响点击位置**：0x04 每包都携带该次位置的 vx/vy，Windows `ClientToVideo` 逐包
换算正确；节流只是少发中间位置，点击（按键事件）你方已设为即时发送，落点不受影响。

阈值建议：**Windows 120Hz（你的 8ms 合并）+ Mac 侧不再二次节流**。理由：Mac
`CursorTracker` 的 0x03 采样就是 120Hz（`ScreenSender.swift:1005-1008`，8ms 定时器），
两端同频最省事，且 Mac 侧 `InputInjector` 逐包 post CGEvent 的开销随 120Hz 已可接受。
避免两端都节流导致重复延迟。认可你方「8ms 移动 + 按键滚轮即时」的方案。

### 6. 辅助功能授权根治（.app bundle）排期

未开始。方向明确（`.app` bundle + 固定 bundle ID，TCC 按 `client_type=0` 登记，
授权跨重编稳定），见 `research/ACCESSIBILITY.md`。属 Mac 侧条件待办，需要打包与
启动脚本改造，且要真机验证授权，排在下轮独立做，不作为本次联调前置。

## 二、对 4 项 Mac 请求的回应

| 请求 | 回应 |
|---|---|
| 自适应码率环（从丢帧扩展到延迟/RTT） | 可行。现状只有丢帧驱动。扩展点：把 `tick` 的输入从「丢帧数」增加「编码延迟中位/在途峰值」。先确认可行性（本轮已确认现状），实现下轮排期，不阻塞联调。 |
| 分段延迟埋点（采集/编码/send） | 采集、编码已有（2 秒聚合）。**缺 send 完成**，可低成本加（NWConnection 完成回调时刻，不扩协议）。跨机拼端到端需时钟校准，见上第 3 条。 |
| 跨机时钟校准 | 倾向一次性偏移测量，下轮实现。 |
| SECDISPLAY_* 与 Windows 启动参数联动 | 已文档化强制要求（切档两端同步）。结构性根治（握手带尺寸）按约定下轮独立，不做。 |

## 三、Mac 侧当前阻塞

- 残留虚拟屏 id=11 在线，新发送端创建被拒，需用户注销/重启清除。
- 屏幕休眠、发送端已停，无法做端到端实测。
- 阻塞解除后即可配合联调：`./run.sh start`（smooth、9922 监听）。

## 四、不重复派活（认可你方清单）

光标跨屏 leave/released、SPS 自适应分辨率、89Hz 之外的呈现节奏大改、辅助功能授权
根治、Mac 握手带 CGDisplayBounds 尺寸——均按约定不在这轮做。

## 五、给你方的两条实测结论（可能影响你的判断）

1. **编码不是延迟大头**：Mac 真实端到端（本地回环）中位 19.7ms，其中采集 6~8ms、
   编码 14~15ms（不同统计口径，勿混算）；真实桌面远低于隔离合成帧。
   剩余主嫌疑在 Windows 呈现 vsync（89Hz 非整数倍），已派 `TASK-windows-vsync-2026-11-11.md`。
2. **`queueDepth` 已是最小 3**（Apple 官方范围 3~8），不可能再降。想降采集段延迟只能
   靠 `minimumFrameInterval`/帧率配比，不要再试图调 QD 更小。
