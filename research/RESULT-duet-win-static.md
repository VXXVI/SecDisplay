# RESULT（Windows）：Duet 客户端静态分析（A-Win-1/2/3/4 + B-Win-1 初查）

> 对应任务：`research/TASK-windows-duet-analysis-2026-11-11.md`
> 执行端：Windows 侧
> 日期：2026-11-11
> 版本说明：本机安装的是 **Duet Display 4.0.479**（`%APPDATA%\Kairos\Duet Display 4.0.479`），
> 静态基线 `research/REVERSE-DUET-4.0.526.md` 分析的是 4.0.526。两者可能有差异，
> 本文结论以 4.0.479 为准，需与 Mac 侧对齐版本。
> 证据等级：观察（二进制/配置/注册表直接可见）、推断（由观察组合）、未知（需运行时确认）。

## 一、A-Win-1 客户端窗口模型（优先项，已得初步结论）

### 观察

`duet.exe` 的 Qt 相关导入与字符串：

- `QWidget::showFullScreen()`、`QWidget::showNormal()`、`QWidget::isFullScreen()`、
  `QWidget::setWindowFlags()`、`QWindow::setWindowState()`。
- 字符串 `root.showNormal()`、`ToggleFullScreen`、`ExitFullscreenKey`。
- 客户端视图类：`Duet_DesktopViewer`，配合 `QGraphicsView` / `QGraphicsScene` /
  `QGraphicsPixmapItem`（解码帧作为 pixmap 画在场景里）。
- `SetWindowDisplayAffinity`、`DwmSetWindowAttribute`、`SetWindowLongPtrW`、`SetWindowPos`、
  `ShowWindow`、`GetSystemMenu`。
- **未发现** `WindowStaysOnTopHint`、`FramelessWindowHint`、`BypassWindowManagerHint`
  这类 Qt 标志字符串。

### 推断

- Duet 客户端是一个**普通 Qt 顶层窗口**，全屏走标准 `showFullScreen()`，
  退出走 `showNormal()`，触发键由 `ExitFullscreenKey` 配置。
- 没有置顶/工具窗标志，因此它应当只出现在当前虚拟桌面，并且正常进入任务栏与 Alt-Tab。
  这与用户抱怨的「盖住所有虚拟桌面、必须从任务栏退出」不是同一种窗口模型。
- `SetWindowDisplayAffinity` 大概率用于把 viewer 排除在屏幕捕获之外（WDA_EXCLUDEFROMCAPTURE），
  避免串流自身画面被再次采集。
- `SetWindowLongPtrW` + `GetSystemMenu` 说明它会改窗口样式并操作系统菜单，
  可能是全屏时去掉边框、保留系统菜单项。

### 未知（需运行时确认）

- 全屏后实际的 `GWL_STYLE` / `GWL_EXSTYLE` 数值，是否有 `WS_EX_TOPMOST` / `WS_EX_TOOLWINDOW`。
- 是否出现在所有虚拟桌面，任务栏是否可见，Alt-Tab 是否可见。
- 多显示器时全屏落在哪块屏，是否支持选择。
- `ExitFullscreenKey` 的默认键值。

### 与 SecDisplay 对照

- SecDisplay 已改为 `WS_EX_APPWINDOW`、去 `TOPMOST`/`TOOLWINDOW`、保留最小化/最大化按钮。
- Duet 的路径更简单：普通窗口 + `showFullScreen` / `showNormal`。
  两者方向一致，Duet 多了一个**可配置的退出全屏键**和明确的 `showNormal` 恢复。
- 建议后续对照：SecDisplay 是否也把「退出全屏键」做成可配置，并在全屏时给出可见提示。

## 二、A-Win-2 解码与呈现（初步）

### 观察

- 安装目录带 `avcodec-58.dll`、`avformat-58.dll`、`swscale-5.dll`，FFmpeg 4.x 软件解码栈。
- 客户端视图是 `QGraphicsView` + `QGraphicsPixmapItem`，解码帧以 pixmap 形式上屏。
- `duet.exe` 同时导入 D3D11/DXGI 相关符号，但更多出现在 host 侧采集/编码路径
  （`Duet_DXGIDuplicateDesktop`、`Duet_WGCDuplicateDesktop`、`Duet_DisplayDriverDuplicateDesktop`）。
- `duet-applicationsettings.ini` 记录 `DuetLastEncoder=MFHardware_VEN_8086`，
  说明 Windows 当 host 时用 Media Foundation 硬件编码（Intel）。

### 推断

- 客户端（Mac→Windows）很可能以 FFmpeg 解码 + Qt pixmap 绘制为主，
  不一定走 D3D11 交换链。这与 SecDisplay 的 D3D11 硬解 + flip 交换链不是同一条呈现路径。
- 该路径的 present 节奏由 Qt 事件循环与 pixmap 更新驱动，垂直同步行为需要运行时确认。

### 未知

- 是否对 H.264 使用 D3D11VA / DXVA 硬解。
- 是否 `Present(1,0)` 等垂直同步，是否 tearing。
- present 间隔 p50/p95、是否丢帧保实时。

## 三、A-Win-3 输入与光标（初步）

### 观察（`duet.exe` 导入 USER32）

- 输入采集：`RegisterRawInputDevices`、`GetRawInputData`、`SetWindowsHookExW`、
  `CallNextHookEx`、`UnhookWindowsHookEx`、`SetWinEventHook`。
- 注入与光标：`SendInput`、`InitializeTouchInjection`、`InjectTouchInput`、`BlockInput`、
  `ClipCursor`、`SetCursorPos`、`GetCursorPos`、`GetCursorInfo`、`GetIconInfo`、
  `DrawIconEx`、`CreateCursor`、`DestroyCursor`、`SetCursor`。
- 显示拓扑：`GetDisplayConfigBufferSizes`、`QueryDisplayConfig`、`EnumDisplaySettingsExW`、
  `ChangeDisplaySettingsExW`、`ChangeDisplaySettingsW`。
- 桌面/窗口站：`SetThreadDesktop`、`OpenDesktopW`、`OpenWindowStationW`、
  `SetProcessWindowStation`、`CloseWindowStation`。

### 推断

- 客户端用 Raw Input 与钩子采集键鼠，用 `SendInput` / 触摸注入回传。
- 光标路径包含取图标、画图标、设置光标，说明它在本机绘制远端光标。
- 显示拓扑与桌面 API 主要服务 host 模式（Windows 当主机、采集虚拟显示器），
  不应拿来解释客户端盖屏问题。

### 未知

- 输入回传与视频是否同一通道，优先级如何。
- 光标是本地绘制、系统光标还是硬件光标；更新频率。
- 点击落点的坐标换算与缩放补偿。

## 四、A-Win-4 默认值与特性开关（观察）

配置文件位置（不记录账号、令牌等敏感字段）：

- `%APPDATA%\Duet\duet-settings.ini`
- `%APPDATA%\Duet\duet-applicationsettings.ini`
- `%APPDATA%\Duet\duet-feature-flags.ini`

已读到的非敏感默认值：

| 键 | 值 | 含义 |
|---|---|---|
| `ConnectionSettings/LastSessionMirrorMode` | 0 | 上次会话为扩展模式，非镜像 |
| `ConnectionSettings/WiredFrameRate` | 60 | 有线帧率默认 60 |
| `RemoteDesktopEnabled` | true | 远程桌面模式开启 |
| `DuetLastEncoder` | `MFHardware_VEN_8086` | Windows host 用 Media Foundation 硬件编码（Intel） |

特性开关（`duet-feature-flags.ini`，只列名称与值）：

| 开关 | 值 | 可能作用 |
|---|---|---|
| `mac-enable-frame-resend-logic` | true | 帧重发逻辑，丢帧/静止时补帧 |
| `rdp-adaptive-quality` | 50 | 自适应质量阈值/档位 |
| `pc-air-lag-quality-check-enabled` | true | 基于延迟的质量检查 |
| `enhanced-cursor-scaling` | true | 光标缩放增强 |
| `pc-scale-macos-cursor-on-mirror` | false | 镜像时缩放 Mac 光标 |
| `mac-cursor-animation-cpu-optimization` | true | 光标动画 CPU 优化 |
| `mac-very-high-quality-setting-enabled` | true | 很高质量档可用 |
| `ios-frame-smoothing` | true | iOS 帧平滑 |

这些开关说明 Duet 的可调项比 SecDisplay 多，尤其是**帧重发**、**自适应质量**、
**延迟驱动质量检查**、**光标缩放**四类。后续应优先验证它们对延迟与观感的影响。

## 五、B-Win-1 IddCx 驱动（初查，方向 B）

- `oem76.inf`：`Class = Display`，UMDF，`UmdfExtensions = IddCx0102`，
  `ServiceBinary = %13%\DuetDisplayDriver.dll`。
- `oem75.inf`：KMDF 静态总线枚举器，`ServiceBinary = %12%\duetbus.sys`，
  `KmdfLibraryVersion = 1.15`。
- `DuetDisplayDriver.dll` 导入 `D3D11CreateDevice`、`CreateDXGIFactory1/2`、
  `FxDriverEntryUm`，符合 UMDF IddCx 间接显示驱动的形态。
- 结论：这是**Windows 当 host** 时给系统新增虚拟显示器用的，配合
  `Duet_DisplayDriverDuplicateDesktop` 采集；与方向 A 的客户端窗口是两条路。
  本轮不展开，留给 B-Win-1/B-Win-2。

## 六、下一步

1. 运行时确认 A-Win-1：Duet 连上后，用探针 dump 全屏窗口的 `GWL_STYLE`/`GWL_EXSTYLE`、
   虚拟桌面归属、任务栏/Alt-Tab 可见性。
2. A-Win-2：用 PresentMon / WPR 采一段运动负载，确认是否硬解、present 间隔。
3. A-Win-4：逐项验证 `frame-resend`、`adaptive-quality`、`lag-quality-check` 的实际行为。
4. 与 Mac 侧对齐 Duet 版本（本机 4.0.479，REVERSE 基线 4.0.526）。

## 七、边界

- 本文不记录账号、令牌、设备 UUID 等敏感字段。
- 不传播 Duet 二进制，不修改安装，不绕过授权。
- 运行时抓包与性能采样需用户授权后执行。
