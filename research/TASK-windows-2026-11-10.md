# Windows 端任务单（2026-11-10 晚，Mac 侧派发）

> 状态：待 Windows 端执行。本文件是任务单，不是实现记录。
> 背景：用户实机联调，反馈「解码失败」「鼠标是 Windows 箭头」「卡顿」「鼠标回不到主屏」。
> Mac 侧已完成一批修复并推到 main，需要 Windows 端 build + 实机验证配合。

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

## 未决 / 不要这轮做

- 鼠标跨屏回主屏：`research/FIX-05-cursor-crossscreen.md` 有协议设计稿，未落地，
  需两端协同 + 多轮实测，勿在本次联调里顺手改。
- 辅助功能授权：Mac 端仍未授权，副屏点击/滚轮暂不生效（画面/光标/全屏不受影响）。
- 从 SPS 自适应分辨率（免手工对齐）：设计方向已评估，作为下轮独立改动。

## 回报方式

把验证结论追加到 `prototype/windows/RESULT-2026-11-10.md` 或新建 `RESULT-*.md` 并 push，
Mac 侧通过 telemetry / git log 读取。失败时附完整日志尾部与截图。
