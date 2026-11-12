# RESULT（Windows）：Duet Display 4.0.479 静态深挖

> 对应任务：`research/TASK-windows-duet-analysis-2026-11-11.md`
> 前序：`research/RESULT-duet-win-static.md`、`research/REVERSE-DUET-4.0.526.md`
> 日期：2026-11-12
> 方法：只读，`dumpbin` + `strings` + INF/注册表；未启动 Duet 登录，未抓包
> 证据等级：观察 / 推断 / 未知

## 一、虚拟显示驱动：UMDF IddCx 1.2

`DuetDisplayDriver.inf` 的关键字段（观察）：

| 字段 | 值 |
|---|---|
| `Class` | `Display` |
| `ClassGUID` | `{4D36E968-E325-11CE-BFC1-08002BE10318}` |
| `UpperFilters` | `IndirectKmd` |
| `UmdfLibraryVersion` | `2.33.0` |
| `UmdfExtensions` | `IddCx0102`（IddCx 1.2） |
| `DriverVer` | `07/29/2024, 9.21.19.632` |

`duetbus.inf` 是 root 枚举的静态总线（观察）：

- `root\duetbus`，`Class = System`，KMDF 1.15。
- 作用：给 IddCx 虚拟显示器提供总线枚举，避免依赖真实硬件。

`DuetDisplayDriver.dll` 的字符串（观察）：

- `Duet_IndirectDeviceContextWrapper`
- `Duet_IndirectDeviceMonitorWrapper`
- `Global\DuetHardwareMouseEvent`

推断：

- 这是标准的 IddCx 间接显示驱动：`IndirectDeviceContext` 负责适配器与交换链，
  `IndirectDeviceMonitor` 负责监视器到达/模式/EDID。
- `Global\DuetHardwareMouseEvent` 说明硬件鼠标事件走独立的内核/用户态事件，
  与视频帧解耦，和 Duet Mac 侧的独立光标管道一致。
- 驱动 DLL 只直接导入 `d3d11.dll` / `dxgi.dll`，IddCx 函数由 UMDF 主机通过
  `IddCx0102` 扩展提供，所以 `dumpbin /imports` 看不到 `IddCx*` 符号。

## 二、protobuf 消息与字段（观察）

二进制里可见的描述符/字段名：

| 消息/枚举 | 已见字段或类 |
|---|---|
| `DuetFrameStatsProto.Duet_FrameStats` | `FrameId`、`checkpoint`、`Checkpoints` |
| `Duet_FrameCheckpoint` | 帧级检查点 |
| `Duet_FrameLabel` | 帧标签 |
| `Duet_ClockDomain` | 时钟域 |
| `DuetClientSettingsProto` | `ResolutionOption`、`DpiScalingOption` |
| `DuetRDPProto` | `Monitor`、`MonitorTopology`、`RDPSessionStart`、`RDPSessionMode` |
| `ClientSettings.proto` / `FrameStats.proto` | 协议文件名 |

运行时代码里可见的属性/方法：

- `averageLatency` / `currentLatency`
- `connectionAverageLatency` / `connectionCurrentLatency`
- `transmittedBitRateMbps`、`videoBitRateOptionsMbps`、`VideoBitRateMbps`
- `qualityIndex`、`displayResolutionOptions`、`displayImageQualityOptions`
- `mirrorAddRequest.sourceDisplayId` / `destinationDisplayId` / `version`

推断：

- Duet 的反馈不是单一 RTT，而是帧级 checkpoint（采集/编码/发送/解码/呈现）
  加 current/average 统计，再驱动质量档与码率。
- 分辨率与 DPI 由客户端声明候选项，host 侧按编码器能力选择。
- 具体字段类型与完整 descriptor 未解析，标为未知。

## 三、客户端呈现路径（观察 + 推断）

前序 `RESULT-duet-win-static.md` 已确认：

- 客户端视图是 `Duet_DesktopViewer`，用 `QGraphicsView` / `QGraphicsScene` /
  `QGraphicsPixmapItem` 画解码帧。
- 解码栈是 FFmpeg 4.x（`avcodec-58` / `avformat-58` / `swscale-5`）。
- 全屏走 `QWidget::showFullScreen()`，退出走 `showNormal()`，
  `ExitFullscreenKey` 可配置。
- 未发现 `WindowStaysOnTopHint` / `FramelessWindowHint`。
- `SetWindowDisplayAffinity` 大概率用于把 viewer 排除在屏幕捕获之外。

推断：

- 客户端呈现是 Qt pixmap 路径，不是 D3D11 flip 交换链。
- 因此它的 present 节奏受 Qt 事件循环与 pixmap 更新驱动，
  与 SecDisplay 的 D3D11 硬解 + flip 交换链不是同一条路。
- 具体是否垂直同步、present 间隔分布，需要 PresentMon/ETW 运行时确认。

## 四、与 SecDisplay 的对照

| 项 | Duet | SecDisplay 现状 | 可落地性 |
|---|---|---|---|
| 虚拟显示 | IddCx 1.2 + IndirectKmd + 静态总线 | Mac host 用 CGVirtualDisplay，Windows 是盖窗客户端 | 方向 B 才需要，当前不阻塞 |
| 帧级统计 | FrameStats + checkpoint + 时钟域 | 已有源/上屏间隔 p50/p95、丢帧 | 已接近，可补 checkpoint 命名 |
| 自适应码率 | 延迟 + 发送码率 + 质量档 | v2 已加 0x07 反馈 + 试探回退 | 已实现，待真机 |
| 光标 | 独立硬件鼠标事件 + 本地绘制 | 0x05 图像 + 事件驱动跟随 | 已接近 |
| 呈现 | Qt QGraphicsView pixmap | D3D11 硬解 + flip 交换链 | 我们的路径更低延迟，不必改 |
| 分辨率 | 客户端声明 + host 上限 | 已有 sharp/balanced/smooth/fast | 接近 |

## 五、可落地建议（按性价比）

1. **保留 D3D11 呈现路径**：Duet 的 Qt pixmap 不是更优方案，不必为了对齐而改。
2. **补帧级 checkpoint 命名**：把现有的源间隔/上屏间隔/编码耗时统一成
   capture/encode/send/decode/present 五段，日志更好对照 Duet。
3. **0x07 反馈闭环**：这是 v2 已经做的方向，继续用 `winQueueMs + presentDrop`
   而不是单纯编码延迟。
4. **IddCx 方向 B 暂不展开**：当前问题是 Mac→Windows 客户端窗口与延迟，
   IddCx 属于 Windows 当 host，优先级低。
5. **硬件鼠标事件可参考**：`Global\DuetHardwareMouseEvent` 说明光标可以完全
   独立于视频队列；我们的 0x03/0x05 已经是这个方向，可继续优化门控。

## 六、未知与待运行时

- protobuf 字段类型与完整 descriptor。
- IddCx 监视器模式、EDID、硬件光标的具体实现。
- 客户端是否硬解、present 间隔、是否垂直同步。
- `rdp-adaptive-quality=50` 的具体含义。
- 需要 Duet 登录与 PresentMon/ETW 才能补齐。

## 七、边界

- 只读静态分析，未运行 Duet 登录，未抓包。
- 不传播二进制，不复制代码。
- 本文件不记录账号、令牌、设备 UUID。
