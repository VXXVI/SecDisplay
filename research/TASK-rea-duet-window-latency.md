# 任务单：REA 逆向 Duet 的窗口模型与延迟/输入链路

> 状态：待 REA 执行（静态部分已完成，动态双端运行阻塞）。本文件是 Windows 端派给 Mac 侧 REA 的任务单，仅列待办与取证，不含实现内容。
> 派发方：Windows 端。日期：2026-11-10 晚。取证提交：54e21d9。

## Mac 侧回执（2026-11-10 深夜，被唤起时按协作协议 SOP 处理）

读完全文，按 `research/PROTOCOL-autonomous-collab.md` 第 5 节能力边界如实标注：
- **静态部分已完成**：`REVERSE-DUET-4.0.526.md` 已覆盖第 3.1 节的 Duet 低延迟组合
  （浅队列 / RealTime / 关 B 帧 / 自适应码率 / 分辨率上限 / 独立光标管道），
  以及 2.1 我们盖屏窗口模型的代码证据。这些不需要再跑。
- **动态部分阻塞**：交付物（第 81-86 行）要求「真实 Mac + Windows 双端跑 Duet 4.0.526
  官方安装包、抓包或埋点」，拿到 2.2 扩展显示器模型、3.2 QueueDepth/呈现同步/实测
  帧率延迟抖动、4.1/4.2 输入与光标运行行为。这需要真实设备安装运行 Duet、账号、
  以及用户授权联调，属 PROTOCOL 第 5 节「需用户配合」，单靠 Mac 侧被唤起做不到。
  用户当前已休息、SecDisplay 两端处于停测状态，本轮不启动双端动态跑包，避免空转。
- 待用户下次授权「跑 Duet 双端」时，Mac 侧 REA 按交付物三节补齐运行行为结论，
  写入 `research/RESULT-rea-duet-*.md` 并把本任务单状态改为「已完成」。
- 第 101 行「20.4ms 超 22.2ms 帧预算」口径存疑，Mac 侧认同采用仓库可查的
  25.2ms(7.4+17.8) 口径，20.4 < 22.2 不构成超预算；动态复核仍待真机。
> 背景：用户暂时退出 SecDisplay，反馈全屏与鼠标三个毛病，点名要 REA 看 Duet 怎么解决「延迟」和「窗口」。
> 静态基线：research/REVERSE-DUET-4.0.526.md，下称 REVERSE。

结论先行：本轮只做一件事，让 REA 在真实双端跑 Duet 4.0.526，把静态分析看不到的运行行为补齐。核心待验证推断是 Duet 走「新增虚拟显示器」，我们走「主屏上盖一个全屏置顶窗口」，两条路完全不同，用户「占满桌面、必须从任务栏退出」的根因就在这个差异。

## 一、用户原话（如实转述，不改写）

用户暂时退出了 SecDisplay，反馈三个毛病：
1. 目前没有明确的方法全屏
2. 全屏后会占满所有 Windows 桌面导致无法使用，必须从任务栏退出
3. 鼠标延迟极高

用户明确要求：让 macOS 侧 REA 逆向 Duet，看它怎么解决「延迟」和「窗口」问题。

## 二、核心架构差异（本任务重点）

### 2.1 现有 Windows 端：盖屏窗口模型（已确证）

prototype/windows/SecDisplayReceiver.cpp:1707-1728 的全屏路径：
- `EnumDisplaySettingsW` 取物理分辨率 sw/sh（:1714-1716），用于盖满主显示器。
- `CreateWindowExA(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, ..., WS_POPUP | WS_VISIBLE, 0,0,sw,sh)`（:1724-1728）。
- 含义：在主显示器上盖一个置顶、无边框、不进任务栏（`WS_EX_TOOLWINDOW`）的全屏窗口，盖住整个 Windows 桌面；:1763-1770 再以 `SetWindowPos(HWND_TOPMOST)` 兜底。
- 退出靠 Esc / 系统托盘图标 / 全局热键 Ctrl+Alt+Q / F11 切回窗口（:1343-1353、:1755-1761；prototype/windows/README.md:198-215「退出」章节）。README:105 写明「全屏置顶窗口会盖住整个桌面」。
- 用户抱怨「占满桌面导致无法使用、必须从任务栏退出」，根因在这个盖屏窗口模型：桌面被盖住，看得见的出口只剩任务栏托盘。

### 2.2 Duet：虚拟显示器模型（静态推断，待 REA 首要确认）

REVERSE:33-36 已观察 Duet Windows 端带虚拟显示驱动：`duetbus.sys`（总线）、`DuetDisplayDriver.dll` + `.inf` + `.cat`、`DuetWPDFilter.sys`、`duetbus`。
推断：Duet 给 Windows 系统新增一块虚拟显示器，系统把它当真实扩展显示器，画面直接输出到那块屏，Windows 本地桌面照常可用。这与我们「盖一个全屏窗口」是两条完全不同的路。
`DuetDisplayDriver.dll` 配合 `.inf`/`.cat` 是驱动安装包的典型组成，静态证据只能证明驱动存在，证明不了运行时窗口形态。

### 2.3 请 REA 首要确认（本任务第一优先）

- 接收端到底是不是「扩展显示器」模型：是否走 IddCx / 虚拟显示驱动，系统「显示设置」里是否多出一块可排列的屏。
- 它的窗口是不是普通可 Alt-Tab 的窗口，还是独占或置顶盖屏。
- 用户如何在 Duet 副屏与 Windows 本地桌面之间切换、回桌面，是否借用系统原生显示器切换。
- 若推断被推翻（仍是盖屏窗口），说明 Duet 靠什么避免占满桌面。

REVERSE:112-120 第五节把「接收端呈现是否用垂直同步、DWM 合成还是独占全屏」「实际运行帧率/延迟/抖动」列为静态看不到的未知项，正好交给 REA 用运行时抓包或埋点补齐。

## 三、延迟：已有结论与待补运行行为（分两条，别混）

### 3.1 已确证的静态结论（REVERSE:44-77、:104-110；ISSUES-2026-11-10.md:72-84 卡顿节）

Duet 已观察到的低延迟组合：
- `kCGDisplayStreamQueueDepth` 浅队列、`kCGDisplayStreamMinimumFrameTime` 显式帧间隔（REVERSE:60-63）。
- `kVTCompressionPropertyKey_RealTime` 实时编码、`AllowFrameReordering` 关 B 帧（REVERSE:48-56）。
- `ApplyAdaptiveBitRateLimit` / `GetOneMinuteEncoderBitRate` 一分钟窗口自适应码率环（REVERSE:65-68）。
- 分辨率上限 `s_MAXIMUM_ENCODING_RESOLUTION_WIDTH_*`（REVERSE:70-73）。
- 独立光标管道 `Duet_CursorPipeline` + `NewCursorImage` / `NewCursorLocation` / `NewCursorPosition`（REVERSE:40、:91-92）。

我们现状：固定 180Mbps 无自适应环（REVERSE:68）；Mac 采集 7.4ms + 编码 17.8ms ≈ 25.2ms，超 45Hz 的 22.2ms 帧预算，编码是瓶颈（ISSUES:77-78）；雷电桥 ping 0.76ms，链路本身不慢（REVERSE:76）；Windows 日志「附加延迟」属相对窗口内最快帧的排队抖动，绝对值以同机实测为准（MILESTONE-2026-11-08.md:55-56、ISSUES:110-111）。

### 3.2 静态拿不到、要 REA 运行时补的

- 实际 `QueueDepth` 数值、最小帧间隔取值（REVERSE:114）。
- 接收端呈现是否垂直同步、DWM 合成还是独占全屏（REVERSE:115）。
- 实际运行帧率、端到端延迟、抖动（REVERSE:116）。
- 输入事件与光标事件是否走独立高优先通道，光标位置通道的实际频率。

## 四、鼠标延迟：拆成两种分别对照

### 4.1 观看型（Mac 光标在副屏上跟随）

我们已有：`0x03` 位置包（Mac CursorTracker 120Hz 采样，FIX-01-cursor.md:34-47）、`0x05` 真实光标图像（`f3027af`/`1a09277`，Windows `ApplyCursorImage` + `CreateIconIndirect` 本地绘制，SecDisplayReceiver.cpp:1254，:1389-1392 的 `WM_SETCURSOR` 应用自定义光标）。理论上本地绘制应当跟手，用户仍喊「延迟极高」，需 REA 对照 Duet 的本地光标是否走硬件光标路径。

### 4.2 操作型（在副屏上点击或移动去操作 Mac）

我们走 `0x04` 输入回传 → Mac `InputInjector` 用 `CGEvent` 重放 → Mac 画面变化 → 重新编码 → 回传显示（FIX-05-cursor-crossscreen.md:27-29、:38-39），是完整往返，体感延迟主要来自这里。辅助功能未授权时 `CGEvent` 点击会被系统丢弃（research/ACCESSIBILITY.md:5）。

请 REA 对照 Duet 的 `sendPointerDataWithX:Y:button:scroll:` / `CGEventTapCreate` / `CGEventPost` / `MACOS_CGEVENT_DATA`（REVERSE:94），确认它如何压低操作往返延迟、是否做本地预测光标、是否用硬件光标、输入通道是否独立于视频帧队列。

关联文档：research/FIX-01-cursor.md、research/FIX-05-cursor-crossscreen.md（跨屏协议设计稿，未落地，勿在本任务顺手改）、research/ACCESSIBILITY.md。

## 五、交付物、边界与回报

### 交付物
REA 在真实 Mac + Windows 双端跑 Duet 4.0.526（官方安装包，非转载），抓包或埋点，产出三节运行行为结论：
1. 窗口模型：扩展显示器还是盖屏窗口，切换与回桌面方式。
2. 延迟链路：QueueDepth、呈现同步方式、帧率与延迟抖动实测。
3. 输入与光标通道：操作往返、预测光标或硬件光标、通道是否独立于视频帧队列。
每节标注哪些推翻或印证了 REVERSE 的静态推断。

### 本轮不要做
- 光标跨屏回主屏（FIX-05 未落地）。
- 辅助功能授权。
- SPS 自适应分辨率。
research/TASK-windows-2026-11-10.md:53-58「未决」节同样列为不做项。

### 回报方式
新建 research/RESULT-rea-duet-*.md，或追加到 REVERSE-DUET-4.0.526.md 并 push。

## 来源与待确认

已确证（代码或文档可查）：2.1 全屏模型（SecDisplayReceiver.cpp:1707-1770、README.md:105、:198-215）；2.2 驱动文件清单（REVERSE:33-36）；3.1 Duet 属性键与字符串（REVERSE:44-77）、我们的编码瓶颈与链路数值（ISSUES:72-84、REVERSE:68、:76、MILESTONE:55-56）；4.1/4.2 协议与代码路径（FIX-01、FIX-05、ACCESSIBILITY、SecDisplayReceiver.cpp:1389-1392）。
待 REA 查（静态推断或运行行为）：2.2 扩展显示器模型、2.3 窗口形态与切换方式、3.2 QueueDepth 与呈现同步与实测帧率延迟抖动、4.1/4.2 Duet 的输入与光标运行行为。
待确认口径：派发方口述「Mac 采集 5.9ms + 编码 14.5ms ≈ 20.4ms 超 22.2ms 帧预算」，仓库内未找到对应出处；ISSUES:77-78 卡顿节记录为 7.4 + 17.8 ≈ 25.2ms 超 22.2ms，且 20.4 小于 22.2 不构成超预算。3.1 采用仓库可查的 25.2ms 口径，请 REA 运行时复核 Mac 侧采集与编码耗时以定论。
