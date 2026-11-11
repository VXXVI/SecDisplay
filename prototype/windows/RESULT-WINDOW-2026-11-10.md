# RESULT：窗口不盖屏 / 不跨虚拟桌面（2026-11-10）

> 对应任务：用户硬要求「开启 secdisplay 后不得因该软件导致无法使用 Windows，尤其窗口不能覆盖全部新建桌面」；
> research/TASK-windows-2026-11-10.md 任务 5（点击错位）/ 任务 6（不是全屏）的窗口侧落地。
> 执行提交：f7b01e6（windows: 窗口不盖屏不跨虚拟桌面，默认窗口化，加 Ctrl+Alt+H 让位）。
> 判据结果：默认窗口化、全屏 1:1、样式探针、让位热键、解码失败 0，均实机通过（详见第 3 节）。
> 遗留项：点击正中落点方向、辅助功能授权、默认窗口化与用户「不是全屏」预期的口径对齐。
> 需对方配合的阻塞项：用户确认启动方式与做一次副屏正中点击；Mac 侧按 1803d47 回执配合联调。

行号标注约定：原状指父提交 1803d47 的 SecDisplayReceiver.cpp，现状指 HEAD f7b01e6 同文件；均据 git grep -n 核对。

## 1. 硬约束与根因

硬约束（用户原话）：开启软件后必须仍能正常使用 Windows，窗口不能占满所有新建虚拟桌面，不能逼用户从任务栏退出程序。

代码事实（原状）：全屏创建用 WS_EX_TOPMOST | WS_EX_TOOLWINDOW（1803d47:1724），兜底定位 SetWindowPos(HWND_TOPMOST)（1803d47:1768），默认 fullscreen=true（1803d47:1415）。

Windows 行为推断（非代码事实）：TOOLWINDOW 窗口被系统 pin 到所有虚拟桌面且不进任务栏 / Alt-Tab；TOPMOST 把所有其它窗口压在下面。两者叠加导致用户 Win+Tab 新建桌面也被该窗口盖住，且缺少常规窗口的退出与让位入口。这一层是 review 子代理据现象做的系统行为定性，仓库内没有 Windows 源码可证，标为推断。

## 2. 改了什么（f7b01e6，逐条）

| 改动 | 位置 | 来源 |
|---|---|---|
| 默认改窗口化 fullscreen=false，改由 --fullscreen / F11 进入全屏 | f7b01e6:1441 | 对 1803d47:1415 |
| 全屏 EXSTYLE 去 TOPMOST/TOOLWINDOW，改 WS_EX_APPWINDOW | f7b01e6:1751-1758 | 对 1803d47:1724 |
| 全屏 style 补 WS_SYSMENU|WS_MINIMIZEBOX|WS_VISIBLE，窗口模式补 WS_MINIMIZEBOX | f7b01e6:1758、:1773 | 对 1803d47 窗口段 |
| 兜底定位与切换改 HWND_NOTOPMOST | f7b01e6:1806、:1253、:1266 | 对 1803d47:1768、:1231 |
| EnterFullscreen/ExitFullscreen 保存/还原 GWL_EXSTYLE | f7b01e6:1241、:1265 | 对 1803d47:1230 段 |
| g_isFullscreen 与启动模式对齐 | f7b01e6:1780 | 对 1803d47:1214 |
| 新增 Ctrl+Alt+H（HOTKEY_HIDE_ID=2）与托盘 ID_TRAY_MINIMIZE，ToggleMinimize 用 SW_MINIMIZE/SW_RESTORE 让位不退出 | f7b01e6:241-243、:258-268、:302、:1356、:1370、:1795、:1799 | 新增 |
| 退出清理补 UnregisterHotKey(HOTKEY_HIDE_ID) | f7b01e6:1884 | 新增 |

ToggleMinimize 只动窗口显示状态，不碰 g_alive、不 PostQuitMessage，网络与解码线程照常运行（f7b01e6:256-268）。

## 3. 实机验证（两套工具链 MSVC + MinGW 均编译通过）

| 判据 | 结果 | 来源 |
|---|---|---|
| 默认启动日志 | 「目标 ... 窗口」「让位方式: Ctrl+Alt+H...」「窗口客户区 1440x900」、解码失败 0 | f7b01e6:1710、:1799、:1816；主会话实机 |
| 样式探针（读回） | WS_EX_TOPMOST=no / WS_EX_TOOLWINDOW=no / WS_EX_APPWINDOW=yes / WS_MINIMIZEBOX=yes / WS_CAPTION=yes | 对 f7b01e6:1756、:1772 的实机读回 |
| 全屏路径 --fullscreen | TOPMOST=no、TOOLWINDOW=no、APPWINDOW=yes、客户区 2880x1800、解码失败 0 | f7b01e6:1756、:1816；主会话实机 |
| 让位探针 Ctrl+Alt+H | IsIconic 0→1→0，还原后包数继续涨、解码失败 0 | f7b01e6:258-268、:1370；主会话实机 |
| 当前接收端 | PID 23176 默认窗口化后台出画 | 主会话实机 |

## 4. 投屏 1:1 不受影响的论证

本次只动 EXSTYLE、窗口 style、z-order 参数（HWND_NOTOPMOST）与显示状态，没有改尺寸来源与呈现链路。全屏尺寸仍由 EnumDisplaySettingsW 取物理分辨率（f7b01e6:1749），客户区等于窗口矩形等于物理分辨率 2880x1800（:1816）；呈现器按 2880x1808 纹理裁到 1800 行做 1:1（research/ISSUES-2026-11-10.md:103、prototype/windows/RESULT-2026-11-10.md:250）。去掉 TOPMOST 只影响窗口叠放次序，不影响客户区像素与交换链映射。1803d47 回执「全屏 1:1 无缺陷」与本端口径一致。

## 5. 对 Mac 侧 1803d47 回执的逐条回应

| 回执点 | 本端回应 |
|---|---|
| 解码失败恒 0，用户所见是 C00D36B4 协商回退被误读 | 接受该口径。本端两套编译、默认/全屏两路径日志「解码失败 0」一致；C00D36B4 属 MF 输出类型协商回退正常路径（research/TASK-windows-2026-11-10.md:76-81），不改解码 |
| 全屏路径 1:1 无缺陷 | 一致，见第 4 节；本次修复不动尺寸与呈现 |
| 「不是全屏」最可能是启动参数 | 口径需更新：f7b01e6 起默认已是窗口化。start.bat / monitor.bat 仍带 --fullscreen（start.bat:33、monitor.bat:46），双击 exe 才落窗口化。原「默认全屏=fullscreen true」已不成立 |
| 点击错位根因坐标基准错配已修，方向待实测 | 一致。本端不盲改坐标（research/TASK-windows-2026-11-10.md:163-165），待用户正中点击实测 |
| 0x05 光标以真机为准 | 一致，不动该链路 |
| 附加延迟非端到端绝对延迟 | 一致。EstimateExtraDelayUs 是相对窗口最快帧的附加抖动（f7b01e6:416-421、research/MILESTONE-2026-11-08.md:55-56） |
| 120s reset 全库 0 命中 | 一致。0x06 心跳包在 f7b01e6:1575 被忽略但维持 TCP 流动，ScreenSender.swift:873-887 |

## 6. 遗留与阻塞

- 点击正中落点方向：偏比例 / 固定偏移 / 乱跳，需用户在副屏正中点击一次回报（任务 5 原文 research/TASK-windows-2026-11-10.md:167-172），本端给不出现场值。
- 用户启动方式确认：哪个 bat / 是否双击 exe / 是否带 SECDISPLAY_W/H，决定「不是全屏」的解释（任务 6 原文 research/TASK-windows-2026-11-10.md:174-183）。
- 辅助功能授权：Mac 端 TCC 未授权，副屏点击/滚轮不生效（research/TASK-windows-2026-11-10.md:206、prototype/windows/RESULT-2026-11-10.md:102），需用户在系统设置点一次。
- 接收端当前状态：PID 23176 默认窗口化后台出画；端到端联调类任务以该实例为准，用户此前叫停的记录见 research/ISSUES-2026-11-10.md:116-118。

## 7. 下一步（三项归属，指向文件 2）

延迟算法 / 传输协议 / 驱动优化的开发需求对齐、归属划分与「请 Mac 侧确认」清单，统一写在 research/SYNC-dev-needs-2026-11-10.md，本文件不重复展开。本端可独立推进的归 Windows，需 Mac 配合的归两端协同，Mac 侧 VT/SCK 相关归 Mac。按 research/PROTOCOL-autonomous-collab.md:14-23 的 SOP 回报，保持动态联系。

## 8. 0x04 输入回传节流（2026-11-11 凌晨，提交 a0cefa1）

`research/SYNC-dev-needs-2026-11-10.md` Top 4 指出 0x04 回传过密（遥测 input_pkts_total 328 万级、单次统计「输入 4376」）。两端代码确认：
- Windows 端每个 `WM_MOUSEMOVE` 都 `SendInputPacket` 一次（原 SecDisplayReceiver.cpp:1380-1386）。
- Mac 端 `receiveLoop`→`drainControl` 逐包处理，每个 0x04 无条件 post 一个 `CGEvent.mouseMoved`（ScreenSender.swift:758-800、969-1013），无合并、无节流、无阈值。鼠标快速移动时 Mac 侧 CGEvent 队列堆积，是「鼠标延迟极高」的真实来源之一。

改法（本端独立，不动协议）：
- UI 线程 `WM_MOUSEMOVE` 只更新最新位置与 dirty 标记，不直接发。
- 新增独立 `inputThread`，每 4ms 轮询：鼠标移动按 8ms 间隔合并发送（约 120Hz，与 Mac 侧 0x03 采样同频）；按键/滚轮置 `eventPending`，下一轮约 4ms 内立即发。
- 单线程发送，避免 UI 线程与发送线程并发 send 同一 socket。
- 曾先试 `WM_TIMER` 方案，实测行为不稳：消息堆积时合并成 1 个（过少），消息稀疏时几乎每条都发（过多），因为 WM_TIMER 低优先级、触发取决于消息队列状态。改独立线程后稳定。

实机验证（本地假服务端统计 0x04 包）：
- 鼠标移动：精确 1ms 间隔投递 200 个消息（359ms），实收 24 个 0x04 包，约 8.3:1 压缩、稳定间隔，符合 120Hz 预期。
- 按键：模拟左键按下+抬起，实收 `buttons=0x01` 与 `buttons=0x00` 两个包，立即发出，点击不丢。
- MSVC + MinGW 两套工具链均编译通过。

边界：这是发送端节流，Mac 侧接收处理未改。若 Mac 侧也想在接收端合并，需另议，避免两端重复。端到端手感改善需 Mac 发送端在线做真机联调确认。

## 9. 本端可独立项收尾（2026-11-11，提交见下）

按 research/SYNC-dev-needs-2026-11-10.md 第 5 节 Top 5 逐项处理，本轮把剩下三项定性：修 1 项、复核 2 项。

### 9.1 Top 2 多线程保护警告：误报，已修

原代码 `if (!mt->SetMultithreadProtected(TRUE)) Log("警告: 多线程保护未启用")` 把返回值当成功标志，判断反了。查 Windows SDK 头文件 `d3d11_4.h:1958` 与官方文档：`SetMultithreadProtected` 返回「调用前是否已开启」，FALSE 只表示之前没开、本次已成功开启。真实状态要用同接口的 `GetMultithreadProtected()` 回读（`d3d11_4.h:1962`）。

改成：调用 `SetMultithreadProtected(TRUE)` 后用 `GetMultithreadProtected()` 回读，为真打「多线程保护已启用」，仍为假才打「未能启用」。实机运行日志已确认输出「多线程保护已启用」，此前的假警告消失。MSVC + MinGW 均编译通过。

### 9.2 Top 1 呈现节奏 89Hz 配 43fps：复核结论为现状即较优，需真机验证，本轮不改

现状 SecDisplayReceiver.cpp:1216-1226：默认 `Present(1,0)` 垂直同步，免同步仅在 `tearing_ && !useVsync_` 时走 `DXGI_PRESENT_ALLOW_TEARING`。89/43≈2.07 个刷新周期每帧，vsync 下表现为「2,2,2,3…」周期性多等一个周期，属刷新率与帧率非整数比的结构性跳动。

判断：改判定阈值或强行 tearing 都会改变观感，且必须在该分辨率/刷新率的真实显示器上看效果，当前环境无 89Hz 屏，改动无法验证。按不盲改原则，本轮只记录结论，留待真机联调时 A/B（vsync 与 tearing 各跑一段），再决定是否引入「帧率接近刷新率整数分频时才启用 tearing」的启发式。归属 Windows 独立，但依赖真机。

### 9.3 Top 3 视图缓存上限与清理策略：复核无缺陷，本轮不改

现状 SecDisplayReceiver.cpp:1184-1209：输入视图按 `(纹理指针<<8)|子索引` 缓存、上限 32，超出整体 clear；输出视图按后备缓冲指针缓存、上限 8，超出整体 clear。

复核要点：
- 缓存 key 用裸纹理指针不会误命中：`CreateVideoProcessorInputView` 会持有资源引用，旧纹理在被缓存视图引用期间不会被释放，指针不会复用，且 key 带子索引。
- 规模有界：输入 key 数量受解码输出纹理池 × 子索引限制，输出 key 受交换链后备缓冲数限制，实际远小于 32/8，clear 分支基本不触发，不存在周期性抖动风险。
- 整体 clear 即使触发也是一次性重建，不影响正确性。

结论：无缺陷，不改。若日后解码纹理池增大到接近上限，再考虑换 LRU 或惰性淘汰。

### 9.4 Top 4 / Top 5 已完成

0x04 节流见第 8 节；窗口样式与让位路径回归见第 3 节。Top 5 至此全部有结论。
