# Duet Display 原理分析：任务拆分与分发（2026-11-11）

> 状态：待确认
> 发起：用户要求 macOS 侧分析 Duet Display 原理，Windows 侧负责拆分与分发
> 现有基线：`research/REVERSE-DUET-4.0.526.md`、`research/TASK-rea-duet-window-latency.md`
> 目标：不是复刻 Duet，而是提取能落到 SecDisplay 的设计原则，回答四个问题：
> 窗口为什么不盖桌面、延迟为什么低、光标为什么跟手、输入为什么不错位。

## 一、先分清两个方向（最重要，否则任务会派错）

Duet 是双向产品，同一套 exe 里同时有 host 与 client 两套角色：

- **方向 A：Host = Mac，Client = Windows / iPad**。与 SecDisplay 当前架构一致。
- **方向 B：Host = Windows，Client = Mac / iPad**。Windows 端的 IddCx 虚拟显示驱动走这条。

静态证据（本次新增，均可复查）：

| 证据 | 位置 | 含义 |
|---|---|---|
| `Duet_HostConnectionDelegate` / `Duet_ClientConnectionDelegate` | `duet.exe` 符号 | 同一程序含 host 与 client 两套角色 |
| `Duet_RDPHost` / `Duet_RDPClient` / `Duet_RDPHostConnection` / `Duet_RDPClientConnection` | `duet.exe` | 自研 RDP 风格协议，双向复用 |
| `Duet_VirtualDisplayManagerWindows` | `duet.exe` | Windows 当 host 时管理虚拟显示器 |
| `Duet_DisplayDriverDuplicateDesktop` / `Duet_DXGIDuplicateDesktop` / `Duet_WGCDuplicateDesktop` | `duet.exe` | Windows host 侧三种采集路径 |
| `Duet_DesktopViewer` / `QWidget::showFullScreen` / `isFullScreen` | `duet.exe` | 客户端是 Qt 窗口，可全屏 |
| `DuetDisplayDriver.dll` + `oem76.inf` | `C:\Windows\System32\DriverStore\...\duetdisplaydriver.inf_amd64_bf7487b441bd52f0` | UMDF 驱动，`UmdfExtensions = IddCx0102`，`Class = Display` |
| `duetbus.sys` + `oem75.inf` | 同上 `duetbus.inf_amd64_...` | KMDF 静态总线枚举器，配合 IddCx 虚拟显示器 |
| `Duet_WebSocketClient` / `QWebSocket` / `libprotobuf.dll` | `duet.exe` | 控制/信令走 WebSocket + protobuf |

**结论：**

- 用户抱怨的「全屏后盖住所有虚拟桌面、必须从任务栏退出」发生在**方向 A 的 Windows 客户端窗口**。
  这部分对应 `Duet_DesktopViewer` 的 Qt 窗口行为，不是 IddCx 驱动。
- IddCx 驱动属于**方向 B**。它解决的是「Windows 把桌面扩展给 iPad/Mac」，
  与当前「Mac 扩给 Windows」不是同一条路。可以研究，但列为后续，不占用本轮主线。
- Mac host 侧已有 `CGVirtualDisplay` / `Duet_VirtualDisplayManagerMac`（REVERSE 已记录），
  与 SecDisplay 的虚拟屏路线一致，重点是采集/编码/光标参数。

## 二、工作包

### 方向 A：当前问题（优先）

| ID | 负责端 | 内容 | 产出 | 工具 |
|---|---|---|---|---|
| A-Mac-1 | Mac | host 采集与编码参数：CGDisplayStream 还是 SCK、QueueDepth、MinimumFrameTime、VT 属性、GOP、RealTime、自适应码率、分辨率上限 | 参数表 + 与 SecDisplay 对照 | otool/nm/strings、REA、Instruments |
| A-Mac-2 | Mac | 光标管道：`currentSystemCursor` 取图方式、图像格式、热点、位置频率、隐藏本地光标、消息字段 | 光标协议说明 + 时序 | strings、REA、运行抓包 |
| A-Mac-3 | Mac | 协议与传输：protobuf 消息表、帧格式、WebSocket/USB/AWDL 选择、加密、通道优先级 | 协议地图 + 通道表 | strings、protoc --decode_raw、Wireshark |
| A-Win-1 | Windows | 客户端窗口模型：Qt 窗口 flags、全屏路径、虚拟桌面行为、Alt-Tab/任务栏、恢复方式、多显示器 | 窗口模型结论 + 复现步骤 | strings、Spy++/WinSpy、`GetWindowLongPtr`、Process Monitor |
| A-Win-2 | Windows | 客户端解码与呈现：FFmpeg/D3D11VA、交换链、vsync/tearing、帧节奏、Present 统计 | 呈现路径 + 帧间隔分布 | strings、PresentMon、WPR/WPA、GPUView |
| A-Win-3 | Windows | 客户端输入与光标：输入采集（Raw Input/钩子）、回传路径、光标本地绘制/硬件光标、点击映射、是否预测 | 输入/光标路径图 + 延迟估算 | strings、Spy++、ETW |
| A-Win-4 | Windows | 客户端默认值：分辨率、码率、帧率、质量、延迟模式的注册表/配置文件默认值 | 默认值表 | Process Monitor、注册表导出 |

### 方向 B：后续架构（可选，不占主线）

| ID | 负责端 | 内容 | 产出 |
|---|---|---|---|
| B-Win-1 | Windows | IddCx 驱动模型：IddCx 版本、监视器模式、EDID、帧到达（共享纹理）、Present、硬件光标、热插拔 | host 架构图 |
| B-Win-2 | Windows | host 采集路径选择：DXGI Desktop Duplication / WGC / 驱动直采各自的触发条件 | 选择逻辑表 |

### 动态实测（需要用户授权与真机）

| ID | 负责端 | 内容 | 产出 |
|---|---|---|---|
| D-1 | 两端 | 端到端延迟：同一运动负载，Duet 与 SecDisplay 各测一轮，高速相机或时间戳标记 | 延迟中位/p95 对照 |
| D-2 | 两端 | 帧率/抖动/带宽/CPU/GPU：运动窗口内同时采两端 | 资源与节奏对照 |
| D-3 | 两端 | 光标与点击：光标更新率、外观、点击落点、操作往返 | 光标/输入对照 |

### 汇总

| ID | 负责端 | 内容 |
|---|---|---|
| S-1 | 两端 | 对比矩阵：采集、编码、传输、解码、呈现、光标、输入、自适应码率 |
| S-2 | 两端 | 落地清单：按性价比排序，标出改动量、风险、是否需要用户配合 |

## 三、分发建议

- **Mac 侧**：A-Mac-1、A-Mac-2、A-Mac-3，加上 D-1/D-2/D-3 的 Mac 半边。
  重点是 Mac host 的采集节奏与光标管道，这两块是 SecDisplay 当前最缺的。
- **Windows 侧**：A-Win-1、A-Win-2、A-Win-3、A-Win-4，加上 D-1/D-2/D-3 的 Windows 半边。
  A-Win-1 直接回答「为什么 Duet 客户端不盖桌面」，优先级最高。
  B-Win-1/B-Win-2 作为后续，不阻塞当前问题。
- **共享**：S-1、S-2 由两端各写一半，最后合并到 `research/RESULT-duet-analysis-2026-11-11.md`。
- **用户**：安装/登录 Duet、授权屏幕录制与辅助功能、在两端各跑一次运动负载与点击测试。

## 四、现在就能做的（不需要用户）

- Mac：A-Mac-1/2/3 的静态部分。Duet Mac 安装包已在 REVERSE 里记录官方地址与大小。
- Windows：A-Win-1/2/3/4 的静态部分，以及 B-Win-1 的 INF 与驱动分析。
  Duet 已安装在 `C:\Program Files\Kairos\Duet Display`，驱动在 DriverStore，可直接读。
- Windows 侧可先用 `tools/fetch-duet.ps1` 生成字符串清单，再用 `dumpbin`/`strings` 补导入表。

## 五、需要用户授权或在场

- 运行 Duet 并登录账号（动态实测）。
- macOS 屏幕录制权限、辅助功能权限（点击回传）。
- Windows 端允许 PresentMon/ETW/`pktmon`/Wireshark 抓包。
- 两端同一时段跑同一运动负载，才能做可比对照。

## 六、边界

- 只做本地互操作研究，不传播 Duet 二进制，不绕过授权/登录，不修改 Duet 安装。
- 只提取设计原则，不复制代码；落地实现由 SecDisplay 自己写。
- 抓包只抓自己设备的流量。
- 不要同时在同一块屏上跑 Duet 与 SecDisplay 的虚拟屏，避免显示拓扑互相干扰。

## 七、与现有任务单的关系

`research/TASK-rea-duet-window-latency.md` 的动态部分已被本计划拆成 A-Mac-1/2/3 与 D-1/2/3，
静态部分继续以 `REVERSE-DUET-4.0.526.md` 为准。
本计划确认后，把该任务单状态改为「已拆分」，并在头部指向本文件。
