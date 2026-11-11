# 任务单：Duet Display 原理分析（Windows 侧）

> 状态：进行中（P1/P2；A-Win-1 初查已完成，下一步 A-Win-2 呈现采样）
> 派发方：Windows 侧（按用户要求拆分）
> 目标端：Windows 侧
> 日期：2026-11-11
> 总计划：`research/PLAN-duet-analysis-2026-11-11.md`
> 回报方式：静态写 `research/RESULT-duet-win-static.md`；动态写 `research/RESULT-duet-win-runtime.md`；
> 汇总结论并入 `research/RESULT-duet-analysis-2026-11-11.md`
> 对应旧任务：`research/TASK-rea-duet-window-latency.md`（本单接管其 Windows 侧内容）

## 一、背景与范围

Duet 是双向产品。本任务做**方向 A：Windows 当客户端**，回答「为什么它的窗口不盖桌面、
呈现节奏怎么走、输入和光标怎么做」。方向 B（Windows 当 host）的 IddCx 驱动列为后续，
不阻塞当前问题。

已确证的环境：

- 安装目录：`C:\Program Files\Kairos\Duet Display`
- 主程序：`duet.exe`（约 20MB，Qt6 + FFmpeg + protobuf）
- 显示驱动：`C:\Windows\System32\DriverStore\FileRepository\duetdisplaydriver.inf_amd64_bf7487b441bd52f0\DuetDisplayDriver.dll`
  （UMDF，`UmdfExtensions = IddCx0102`，`Class = Display`）
- 总线驱动：`C:\Windows\System32\DriverStore\FileRepository\duetbus.inf_amd64_11dbe3f7491c7720\duetbus.sys`
- INF：`C:\Windows\INF\oem75.inf`（duetbus）、`C:\Windows\INF\oem76.inf`（DuetDisplayDriver）
- 服务：`DuetDisplaySL`、`DuetUpdater`
- 已知类名：`Duet_DesktopViewer`、`Duet_ClientConnectionDelegate`、`Duet_RDPClient`、
  `Duet_VirtualDisplayManagerWindows`、`Duet_DXGIDuplicateDesktop`、`Duet_WGCDuplicateDesktop`、
  `Duet_DisplayDriverDuplicateDesktop`

## 二、任务

### A-Win-1（最高优先）客户端窗口模型

目标是直接回答用户「全屏后为什么盖住所有虚拟桌面、怎么退回」。

- `Duet_DesktopViewer` 用什么窗口类型：普通 Qt 窗口、无边框、置顶、工具窗口？
- 全屏走 `QWidget::showFullScreen` 还是自建 `SetWindowPos`？
- 是否设置 `WS_EX_TOPMOST`、`WS_EX_TOOLWINDOW`、`WS_EX_APPWINDOW`。
- 进入全屏后是否出现在所有虚拟桌面，任务栏是否可见，Alt-Tab 是否可见。
- 退出全屏 / 回桌面的路径：Esc、双击、按钮、快捷键、系统原生切换。
- 多显示器时全屏落在哪块屏，是否支持选择显示器。
- 与 SecDisplay 当前「盖屏窗口」模型逐项对照，给出差异表。

可用工具：`strings`/`dumpbin`、Spy++ 或 WinSpy、`GetWindowLongPtr` 探针、Process Monitor、
Windows 虚拟桌面切换实测。

### A-Win-2 客户端解码与呈现

- 解码用 FFmpeg（`avcodec-58.dll`）还是 D3D11VA / DXVA，是否有硬解路径。
- 呈现用 D3D11 交换链、OpenGL（`opengl32sw.dll`）还是 Qt 合成。
- 是否 `Present(1,0)` 等垂直同步，是否 `ALLOW_TEARING`。
- 帧节奏：是否有队列、是否丢帧保实时、帧间隔分布。
- 用 PresentMon / WPR / GPUView 采一段运动负载，给出 present 间隔 p50/p95。

### A-Win-3 客户端输入与光标

- 输入采集：Raw Input、`SetWindowsHookEx`、Qt 事件，哪种。
- 回传路径：与视频是否同一通道，是否有独立优先级。
- 光标：本地绘制、系统光标、还是 IddCx 硬件光标；是否传光标图像与热点。
- 点击映射：坐标如何换算，是否有缩放/裁边补偿。
- 是否有本地预测光标或输入预测。

### A-Win-4 客户端默认值

- 注册表：`HKLM\SOFTWARE\Kairos\Duet Display` 及 HKCU 对应项。
- 配置文件、`ClientSettings.proto` 相关默认值。
- 默认分辨率、码率、帧率、质量档、延迟模式。
- 与 SecDisplay 的 `smooth/balanced/sharp/fast` 档位对照。

### B-Win-1（后续，不阻塞）IddCx 驱动模型

- IddCx 版本、监视器模式、EDID、帧到达方式（共享纹理）、Present、硬件光标、热插拔。
- 产出 host 模式架构图，说明它和方向 A 的客户端窗口是两条路。

### B-Win-2（后续）host 采集路径选择

- `DXGIDuplicateDesktop`、`WGCDuplicateDesktop`、`DisplayDriverDuplicateDesktop` 各自触发条件。
- 与 SecDisplay 的 Mac host 采集路径对照。

### 动态实测（需用户授权）

- D-1：同一运动负载，Duet 与 SecDisplay 各测一轮端到端延迟。
- D-2：帧率、抖动、带宽、CPU/GPU。
- D-3：光标更新率、外观、点击落点、操作往返。

### 汇总

- S-1：与 Mac 侧合并对比矩阵。
- S-2：Windows 客户端可落地的改进清单，优先回答「窗口模型」和「呈现节奏」。

## 三、判据

- A-Win-1 给出明确结论：Duet 客户端是否盖住所有虚拟桌面、如何退回，附可复现步骤与窗口样式证据。
- A-Win-2 给出呈现路径与 present 间隔 p50/p95，说明是否垂直同步。
- A-Win-3 给出输入/光标路径图，说明点击落点如何换算。
- A-Win-4 给出默认值表，至少覆盖分辨率、码率、帧率、质量档。
- 每条结论标注证据等级：观察 / 推断 / 未知。
- 动态部分未获授权时写阻塞，不伪造数据。

## 四、本轮不做

- 不分析 Mac host 二进制，那是 Mac 侧任务。
- 不在本任务里改 SecDisplay 代码；改进项先写进 S-2，等用户确认后另开任务。
- 不传播 Duet 二进制，不绕过登录/授权，不修改 Duet 安装。
- 不碰跨屏光标与辅助功能授权。

## 五、需用户配合

- 动态实测需要：Duet 登录、Windows 端允许 PresentMon/ETW/`pktmon` 抓包、
  与 Mac 同时段跑同一运动负载。
- 静态部分不需要用户，先做。
