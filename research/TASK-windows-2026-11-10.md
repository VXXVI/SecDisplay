# Windows 端任务单（2026-11-10 晚，Mac 侧派发）

> 状态：待 Windows 端执行。本文件是任务单，不是实现记录。
> 背景：用户实机联调，反馈「解码失败」「鼠标是 Windows 箭头」「卡顿」「鼠标回不到主屏」。
> Mac 侧已完成一批修复并推到 main，需要 Windows 端 build + 实机验证配合。

## 进展更新（2026-11-10 深夜，Mac 侧自动核查）

用户睡前最新反馈（4 条，按优先级）：
1. **鼠标指针已经是 macOS 指针** —— 0x05 光标图像链路基本工作，这是好消息，先别动它。
2. **鼠标点击位置与实际位置不符**（错位）—— 最高优先，见下方任务 5。
3. **目前还不是全屏** —— 见任务 6。
4. **分辨率/码率想调整、延迟大** —— 见任务 7。

Mac 侧客观数据（telemetry/mac/d87b16db.json，14:19Z）：
- smooth 生效：video 2240x1400 @ capture 60Hz
- 峰值帧率 median 13 / p95 33 / max 59；编码延迟 median 14.3ms、p95 21.4ms
- `dropped_total=0`、在途峰 1、无 congestion（较之前的 dropped 32450 / congestion 13 明显好转）
- `input_pkts_total` 累计极大（328 万级），Windows 端在密集回传输入事件，与「点击错位」相关
- 链路有 ESTABLISHED，Mac 在发 0.3Mbps / 发送 22 / 光标+ / 输入 都在动，端到端是通的
- 仍有 `ax_not_trusted`（副屏点击不生效），多次 `接收端已连接` 不同端口（疑似 Windows 端反复重启测试）
- 远端 main 已到 `3e2c2e0`（cef09d7 之后全是 Mac 遥测自动提交，暂无 windowsagent 实机回传）

**给 Windows 端：请优先回传一次带 `logs\fullscreen.log` 尾部 40 行的实机结果**，Mac 侧靠它定位点击错位与全屏。

## 当前两端代码状态（远端 main = abe8e29）

- CI：abe8e29 起连续全绿（build-windows / build-mac / telemetry-consistency 全 success）。
- Mac 端：已重编重启，`./run.sh restart`，当前 **smooth 预设 2240x1400@60**，
  虚拟屏在线、9922 监听、遥测在更新（commit 1a09277 系）。
- 已合入的关键修复：
  - `0x06` 连接心跳：解「静止 120s 空闲被 ECONNRESET」
  - `0x05` 真实 Mac 光标图像：Mac 发系统光标 BGRA+热点，Windows `CreateIconIndirect` 本地绘制
  - `5f2c412` 补 `gdi32.lib`（修 f3027af 的 LNK2019，这是之前 build-windows 红的真因）
  - `abe8e29` 三个启动脚本分辨率默认对齐 smooth(2240 1400)，支持 `SECDISPLAY_W/H` 覆盖

## 任务 1（最高优先）：修「解码失败」并验证

**根因已定性**：Mac 发 2240x1400，Windows 脚本原来写死 2880 1800，解码器按
2880x1800 设 MF_MT_FRAME_SIZE，与 SPS 不符，`ProcessInput` 持续 FAILED → decodeFail 累加。
`abe8e29` 已把脚本默认改为 2240 1400。

执行：
1. `cd C:\SecDisplay && git pull` 拉到 abe8e29 及之后
2. `cd prototype\windows && build.bat`（MSVC）确认「全部编译成功」
3. 双击 `start.bat`（或 `diag.bat` 出 20 秒诊断日志）启动，Mac 端已在线
4. 看日志：
   - `解码失败 N` 应为 0 且不涨
   - `包 N / 解码 N(+M)` 持续涨
   - `坐标基准: 逻辑 2240x1400（物理 2240x1400）`
   - `窗口客户区` = 显示器物理分辨率（全屏 2880x1808 裁 2880x1800 之类，1:1 呈现）
   - `附加延迟` 有真实波动（d425094 修复）
5. 若仍报解码失败，把 `logs\fullscreen.log` 尾部 40 行贴回仓库（新建 `RESULT` 或截图）

## 任务 2：验证「真实 Mac 光标」

连上后在 Mac 主屏把光标切到不同形状（箭头 → 文本 I 型 → 链接手型），看 Windows 副屏
光标是否跟着变。日志无 `0x05` 相关错误即可。若形状没变，抓：
- Mac 日志有无光标图像包发出（当前统计行无专门字段，可临时加）
- Windows `ApplyCursorImage` 是否被调用（可加一行 Log）

## 任务 3：验证「连接不再 120s 断」

静止桌面放 3 分钟以上，看是否还出现 `Connection reset by peer`（Mac 侧日志）。
`0x06` 心跳应让链路持续有数据流动。

## 任务 4（可选，需 Mac 配合）：卡顿 A/B

Mac 当前 smooth。若仍觉卡，报告「有连接时 Windows 遥测的 peak_fps / decoded_per_sample /
extra_latency_ms」，Mac 侧据此决定是否降到 fast 或调呈现节奏。

## Mac 侧读日志回执（17 份 evidence，子代理提炼，2026-11-10 深夜）

读了 `evidence/windows-2026-11-10/` 全部 17 份日志，几个结论校正了之前的猜测：

1. **「解码失败」很可能是误读**：17 份日志 `解码失败` 恒为 0，从未复现。用户看到的
   大概率是每份出画日志都有的 `按 ... 设输出类型失败 C00D36B4 → 改向解码器查询可用
   类型 → 输出类型已重建，继续解码`（如 `fullscreen.log:23-26`）。这是 MF 输出类型
   **协商回退**，不是解码失败。请 windowsagent 在 RESULT 里确认：用户报「解码失败」
   时终端里到底是 `解码失败 N>0` 还是这串 `C00D36B4` 协商日志？这决定要不要继续查。
   （若确为 C00D36B4，属正常路径，只需把该日志文案改清楚避免误解，不必改解码。）

2. **全屏路径本身无缺陷**：`fullscreen.log` / `verify2.log` / `diag.log` 三次全屏复跑，
   「全屏目标尺寸 2880x1800 / 窗口客户区 2880x1800 / 窗口矩形 2880x1800」全相等、1:1。
   但 17 份里 14 份是 `--windowed`（客户区 1440x900）。**用户「不是全屏」最可能是启动
   用的是窗口参数**，不是运行期掉出全屏（全库无 `已切换到全屏/窗口`、无双击/F11 埋点）。
   请确认用户那次的启动命令；确定全屏统一用最新版 `start.bat`（abe8e29 起带 --fullscreen）。

3. **点击错位的根因已定案、方向待实测**：根因是 Mac smooth(2240x1400) 与 Windows
   旧坐标基准(2880x1800) 错配（`run.log` 修复前 vs `preset_fix.log` 修复后对照），
   `--coord 2240 1400` + 缩放铺满已修。但日志**无点击落点实测值**，偏左上/偏右下/
   固定偏移定不了。请按任务 5 做一次「副屏正中点击」回报落点方向即可闭环。

4. **0x05 光标图像**：日志无报错但也无送达计数；用户现场确认「已是 macOS 指针」，
   以真机观察为准，暂不改这条链路。

5. **延迟/卡顿**：`附加延迟` 是窗口内排队抖动（0~几 ms、偶发 27~46ms 尖峰），
   **不是端到端绝对延迟**。`preset_fix.log` 有 fps 从 55.5 塌到 3.0~3.5 的时段，
   对应卡顿。用户「延迟大」的绝对值这批数据测不出，缺 Mac 侧分段埋点。
   连接稳定性好：`120s reset`、`Connection reset` 全库 0 命中（0x06 心跳疑似生效），
   已连接态退出干净（`网络循环退出`）。

6. **重连循环**：`preset_fix.log` 有 6 轮「已连接→…→连接结束→2 秒后重连」且期间无帧，
   值得 windowsagent 留意（可能是那次测试在反复重启 exe，非协议问题）。

以上供 windowsagent 下次唤起时对齐，避免双方基于不同参数/不同日志行各说各话。

## windowsagent 实机回传（78b0016 / RESULT-PRESET-2026-11-10.md，Mac 侧已读）

windowsagent 用 `--windowed 2880 1800`（旧参数）跑了一次端到端，独立确认：
- 解码器**能自适应 SPS**：日志 `可用输出[0] 尺寸 2240x1408`、`解码失败 0`、
  包数稳定涨约 14~15fps、`附加延迟` 真实波动。即 smooth(2240x1400) 码流在
  2880x1800 命令行下也能解能显。
- 它修了呈现器 `src<dst` 越界（CreateProcessor 的 source rect 方向分支），
  这是真实改进，Mac 侧不碰 Windows 端代码，避免冲突。
- 它同样定性「两端分辨率/坐标基准对不上」，建议 A 路两端统一档位。

**重要不一致，需 windowsagent 复现**：那次是 `--windowed 2880 1800` 且解码失败 0，
而用户实机报「解码失败」。两者参数不同。请用**最新脚本**（abe8e29 起默认
`2240 1400 --fullscreen`，`git pull` 后 `start.bat`）再跑一次，回传：
- `解码失败 N` 到底是 0 还是在涨
- 若仍失败，附 `logs\fullscreen.log` 尾部 40 行（尤其 `解码器就绪`、`可用输出`、
  `呈现器`、`解码失败` 几行）
这样能区分「尺寸不符导致」还是「旧 exe / 0x05 光标包 / 连接重置」等其它因素，
避免双方基于不同参数各说各话。Mac 侧不臆断解码失败的唯一根因。

## 子代理静态核查结论（2026-11-10 深夜，Mac 侧派 review 子代理产出）

对 HEAD(cef09d7) 逐行核查坐标闭环，结论：**纸面自洽，未发现代码里的 2x/缩放 bug**。
CursorTracker / InputInjector / ClientToVideo / cursorThread 四处用同一个基准
（Mac `CGDisplayBounds`；Windows `GetClientRect` + 同一 `g_coordW/H`），
全屏客户区 2880x1800 与视频 2240x1400 同为 1.6:1，拉伸均匀、换算一致。

因此点击错位最可能是「两端运行实例基准不同步」或「Mac 单位混用」，**必须靠 Windows
端一行日志 + 一次正中点击定案**：

- 两端基准必须相等：Mac `坐标基准: 逻辑点 2240x1400` ↔ Windows
  `坐标基准: 逻辑 2240x1400（物理 2240x1400）`
- **在 Windows 副屏正中点击一次**：
  - 正中命中 → 基准一致，问题在别处
  - 偏左上、误差随位置线性增大 → Windows 基准比 Mac 大（很可能 Windows 还在跑旧
    参数 2880 1800 的 exe，没 `git pull`+`start.bat` 重启）
  - 偏右下、放大 1.286 倍 → Windows 基准比 Mac 小
  - 固定偏移 → Mac 原点(1512,0) 与 bounds 单位混用（点 vs 像素），需 Mac 侧修
- 结构性根治（下轮）：Mac 在握手/心跳包里带上 `CGDisplayBounds` 尺寸，Windows
  收到后直接设 `g_coordW/H`，删掉两端手工对齐 `SECDISPLAY_W/H` 的脆弱约定。

「不是全屏」最可能原因：**误触双击**。`WM_LBUTTONDBLCLK` 直接切窗口模式
（`SecDisplayReceiver.cpp:1380`），在副屏上正常双击就会掉出全屏；其次 F11/F 误触、
或跑的是旧 exe。默认 `fullscreen=true`、三个 bat 都带 `--fullscreen`，代码路径没问题。
确定全屏命令：`SecDisplayReceiver.exe 10.10.10.1 9922 2240 1400 --fullscreen --log logs\fullscreen.log`，
日志应有 `全屏目标尺寸 2880x1800` 且 `窗口客户区 2880x1800  窗口矩形 2880x1800`。

延迟/码率可调项见任务 7；Mac 侧已补 `SECDISPLAY_MBPS` 环境变量（本轮新增），
`SECDISPLAY_QD`(默认3，降1可减30-50ms)、`SECDISPLAY_ENC=E`(禁帧重排+速度优先)、
Windows `--tearing` 是降延迟组合，代价是偶发撕裂/画质。

## 任务 5（最高优先）：点击位置与实际位置不符

用户睡前反馈「鼠标点击位置与实际位置不符」。Mac 侧观察：`input_pkts_total` 累计到
328 万级、单次统计 `输入 4376`，Windows 端在密集回传 0x04 输入事件。

**注意**：Mac 侧已派子代理对坐标闭环做静态核查（ClientToVideo / InputInjector /
CursorTracker / 光标线程、客户区尺寸与坐标基准是否混用），结论回来前**不要盲改坐标代码**，
避免和子代理重复或冲突。

Windows 端请先回传证据（这一步不依赖核查结论）：
1. `logs\fullscreen.log` 里这几行的数值：`全屏目标尺寸` / `窗口客户区` / `坐标基准` /
   `退出方式` / `呈现方式`
2. 描述错位方向：点屏幕某处，菜单/点击落在哪——是整体缩放(偏比例)、固定偏移、
   还是完全乱跳？左上角和右下角各点一次报告
3. 当前是否全屏（见任务 6），窗口模式客户区尺寸与全屏不同会直接影响换算

## 任务 6：目前还不是全屏

用户反馈「目前还不是全屏」。请回传：
- 是用 `start.bat` / `monitor.bat` / `diag.bat` 启动，还是直接双击 exe / 命令行？
- 日志里 `全屏目标尺寸` 与 `窗口客户区` 各是多少？有没有 `已切换到全屏`？
- 若按过 F11 或双击，报 `已切换到窗口/全屏` 的记录

三个 bat 都带 `--fullscreen` 且 `SECDISPLAY_W/H` 默认 2240 1400。若是直接双击 exe，
位置参数/全屏开关可能没带全——这最可能是「不是全屏」的原因。确定全屏用
`start.bat`（`git pull` 到最新版后）。

> 状态更新（2026-11-11）：任务 5 已闭环，用户实测「点击无错位」；任务 6 已解决，窗口模式补了最大化按钮与明确标题，最大化按钮 / Win+↑ / F11 均切整屏放大。详见 prototype/windows/RESULT-WINDOW-2026-11-10.md 第 10 节。

## 任务 7：分辨率 / 码率 / 延迟调整（可调项清单）

用户想调分辨率码率、觉得延迟大。当前可调项（Mac 侧环境变量，改后 `./run.sh restart`）：
- `SECDISPLAY_PRESET` = sharp(2880x1800@40) / balanced(2880x1800@45) /
  smooth(2240x1400@60，当前) / fast(1920x1200@60)
- `SECDISPLAY_W` / `SECDISPLAY_H` / `SECDISPLAY_HZ` 单项覆盖
- `cfg.bitrateMbps`（默认 180，在 ScreenSender.swift Config）
- Windows 端 `--vsync`(默认) / `--tearing`(免同步，延迟最低但可能抖)

**重要联动**：Mac 切档后，Windows 端启动前必须同步设 `SECDISPLAY_W`/`SECDISPLAY_H`
为相同值（abe8e29 已支持），否则又会「解码失败」+ 点击错位。切档务必两端一起改。

延迟大的代码来源（供排查，不急着改）：采集 `minimumFrameInterval`、编码
`VTCompressionSession` 实时参数、`queueDepth`、在途帧上限、TCP、Windows 呈现
`Present` 垂直同步与 89Hz 配 43/60fps 的节奏跳变。当前 Mac 编码延迟 median 14.3ms，
单看采集+编码未超 60Hz 的 16.7ms 预算太多，延迟大头更可能在呈现节奏或 Windows 端。

## 未决 / 不要这轮做

- 鼠标跨屏回主屏：`research/FIX-05-cursor-crossscreen.md` 有协议设计稿，未落地，
  需两端协同 + 多轮实测，勿在本次联调里顺手改。
- 辅助功能授权：Mac 端仍未授权，副屏点击/滚轮暂不生效（画面/光标/全屏不受影响）。
- 从 SPS 自适应分辨率（免手工对齐）：设计方向已评估，作为下轮独立改动。

## 回报方式

把验证结论追加到 `prototype/windows/RESULT-2026-11-10.md` 或新建 `RESULT-*.md` 并 push，
Mac 侧通过 telemetry / git log 读取。失败时附完整日志尾部与截图。
