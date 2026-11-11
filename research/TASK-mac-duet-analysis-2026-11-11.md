# 任务单：Duet Display 原理分析（Mac 侧）

> 状态：待执行
> 派发方：Windows 侧（按用户要求拆分）
> 目标端：Mac 侧
> 日期：2026-11-11
> 总计划：`research/PLAN-duet-analysis-2026-11-11.md`
> 回报方式：静态写 `research/RESULT-duet-mac-static.md`；动态写 `research/RESULT-duet-mac-runtime.md`；
> 汇总结论并入 `research/RESULT-duet-analysis-2026-11-11.md`
> 对应旧任务：`research/TASK-rea-duet-window-latency.md`（本单接管其 Mac 侧内容）

## 一、背景与范围

用户要求 Mac 侧分析 Duet Display 原理。Duet 同一个程序里同时有 host 与 client 两套角色，
本任务只做**方向 A：Mac 当 host，Windows / iPad 当 client**，与 SecDisplay 当前架构一致。

Windows 端的 IddCx 虚拟显示驱动属于方向 B（Windows 当 host），不在本任务范围，
由 Windows 侧单独处理。不要把两套东西混在一起。

本任务回答四个问题里属于 Mac host 的三个：
延迟为什么低、光标为什么跟手、host 侧采集与编码怎么配。

## 二、任务

### A-Mac-1（最高优先）host 采集与编码参数

静态读 `duet.app/Contents/MacOS/duet` 与相关 dylib，产出参数表：

- 采集到底用 `CGDisplayStream` 还是 `ScreenCaptureKit`，是否有运行时切换条件。
- `kCGDisplayStreamQueueDepth` 的取值或取值范围。
- `kCGDisplayStreamMinimumFrameTime` 的取值。
- VideoToolbox 属性：`RealTime`、`AllowFrameReordering`、`MaxKeyFrameInterval`、
  `PrioritizeEncodingSpeedOverQuality`、`AverageBitRate`、`DataRateLimits`、
  `RequireHardwareAcceleratedVideoEncoder` 是否启用。
- 自适应码率：`ApplyAdaptiveBitRateLimit` / `UpdateEffectiveBitRateLocked` /
  `GetOneMinuteEncoderBitRate` 的触发条件与调节方向。
- 分辨率上限：`s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_*` 的具体数值与默认档位。

每条标注证据等级：观察 / 推断 / 未知。静态拿不到的写「未知」，不要猜成结论。

### A-Mac-2 光标管道

- 如何取当前系统光标：`currentSystemCursor` / `NSCursor` / `CGSCurrentCursorSeed` 中实际用了哪条。
- 光标图像格式、尺寸、热点 `hotSpot` 如何序列化。
- 位置消息 `NewCursorLocation` / `NewCursorPosition` 的发送频率与触发方式。
- 本地光标如何隐藏（`Duet_MacCursorHider` / `CGDisplayHideCursor`）以及何时恢复。
- 与视频流是否完全解耦，通道优先级如何。

产出：光标协议字段表 + 时序说明，能直接对照 SecDisplay 的 `0x03` / `0x05` 包。

### A-Mac-3 协议与传输

- protobuf 消息表：从二进制或抓包中提取 `Input`、`FrameStats`、`ClientSettings`、
  `Clipboard`、`FileTransfer`、`KMS`、`RDP`、`Annotation` 的实际字段。
- 视频帧封装：长度前缀、时间戳、关键帧标记、分片方式。
- 传输选择：USB（usbaapl / AOA）、AWDL、WebSocket/TCP 各自的触发条件。
- 加密：`RDPPacketCrypto` / `MTLSPacketCrypto` / `PKIPacketCrypto` 用在哪一层。
- 通道优先级：视频、光标、输入、剪贴板是否独立队列。

### 动态部分（需用户授权）

- D-1：同一运动负载下，Duet 与 SecDisplay 各测一轮端到端延迟。
- D-2：采集/编码耗时、帧率、抖动、带宽、CPU/GPU。
- D-3：光标更新率、外观、点击落点、操作往返。

动态部分没有用户授权与 Duet 登录时，只做静态，不要空转。

### 汇总

- S-1：与 Windows 侧合并对比矩阵（采集、编码、传输、解码、呈现、光标、输入、自适应码率）。
- S-2：Mac host 侧可落地的改进清单，按性价比排序，标出改动量与风险。

## 三、判据

- A-Mac-1 给出参数表，至少覆盖采集 API、QueueDepth、MinimumFrameTime、VT 关键属性、自适应码率、分辨率上限。
- A-Mac-2 给出光标字段表与时序，能说明「为什么本地绘制不拖影」。
- A-Mac-3 给出消息表与通道优先级，至少覆盖视频、光标、输入三类。
- 每条结论标注证据等级，静态无法确认的明确写「未知」。
- 动态部分若未获授权，在 RESULT 里写阻塞原因，不伪造数据。

## 四、输入与工具

- 官方安装包：`https://duetdownload.com/Mac/v4.0.526/DuetDisplay-4-0-526.dmg`（132,983,119 字节）。
- 静态基线：`research/REVERSE-DUET-4.0.526.md`。
- 工具：REA、`otool`、`nm`、`strings`、`hdiutil`、Instruments、`tcpdump`、`log stream`。
- 若需要 Windows 端二进制辅助，可用 `tools/fetch-duet.ps1` 生成清单，Mac 侧 `tools/recv-duet.py` 接收。

## 五、本轮不做

- 不分析 Windows 端的 IddCx 驱动与 `duet.exe`，那是 Windows 侧任务。
- 不改 SecDisplay 的 Mac 发送端代码，也不在本任务里落地改进。
- 不传播 Duet 二进制，不绕过登录/授权，不修改 Duet 安装。
- 不碰跨屏光标与辅助功能授权。

## 六、需用户配合

- 动态实测需要：Duet 登录、macOS 屏幕录制权限、辅助功能权限、与 Windows 同时段跑同一运动负载。
- 若暂时没有授权，先交静态结果，不要停在这里等。
