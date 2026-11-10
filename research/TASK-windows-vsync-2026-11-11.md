# 任务单：Windows 呈现节奏（vsync / tearing）与延迟大头验证

> 状态：待执行
> 派发方：Mac 侧
> 目标端：Windows 侧
> 日期：2026-11-11
> 上报载体：新建 `prototype/windows/RESULT-vsync-2026-11-11.md` 或追加 `RESULT-2026-11-10.md`
> 关联：`research/BENCH-05-lowlat-ratecontrol.md`（Mac 侧真实端到端实测）

## 一、为什么派这个（Mac 侧已排除编码是延迟大头）

Mac 侧 2026-11-11 凌晨做了真实端到端实测（`tools/latencyclient` + `tools/motionloader`
造动画负载，本地回环，不含雷电网络与 Windows 解码/呈现）：

| 档位 | 端到端中位 | p95 | 实际帧率 |
|---|---|---|---|
| smooth 2240x1400@60，lowlat 开 | **19.74 ms** | 55.4 ms | 53.3 fps |
| smooth 2240x1400@60，lowlat 关 | 31.2~68.9 ms | 71.6~188.6 ms | 29.9~51.9 fps |

真实桌面场景编码延迟中位仅 **14~15ms**、采集 6~8ms。**编码不是「延迟大」的主因**。
端到端 19.7ms 到用户体感「很卡、延迟高」之间，剩下的主要嫌疑在 Windows 呈现节奏：

- 屏 89Hz，Mac 输出约 53fps，`89 / 53 ≈ 1.68` 非整数倍。
- 当前默认 `cfg.vsync = true` → `Present(1, 0)`（`SecDisplayReceiver.cpp:1211`），
  每帧要被垂直同步量化到 1 或 2 个刷新周期（11.2 / 22.5ms 交替），这就是「一顿一顿」。
- `--tearing` 路径已实现（`:1207-1210`，`Present(0, DXGI_PRESENT_ALLOW_TEARING)` +
  失败回退 `Present(1,0)`），但默认没启用，且是否真的更顺没有实测数据。

## 二、任务（按优先级）

### T1（最高）：vsync vs tearing 真实 A/B

1. Mac 端保持 smooth 2240x1400@60、lowlat 开（当前默认），确认 `./run.sh status` 在跑。
2. Windows 端用**同一 exe**、同一分辨率 2240 1400，分别跑两次：
   - A：默认（vsync）`SecDisplayReceiver.exe 10.10.10.1 9922 2240 1400 --fullscreen --log logs\vsync.log`
   - B：免同步 `... --tearing ...`
3. 每次跑 20 秒，期间做：鼠标快速移动 5s、拖窗口 5s、滚动网页 5s、静止 5s。
4. 回传两份日志尾部 40 行 + 主观判断（拖动是否跟手、是否「一顿一顿」、有无撕裂）。

**判据**：若 `--tearing` 明显更顺且撕裂可接受 → 建议默认改 tearing 或按运行时能力自适应；
若 tearing 撕裂明显更差 → 保持 vsync，转而查 Mac 输出帧率与刷新率配比（如把 captureHz 调到
接近 89/N，让帧率与刷新率成整数比）。

### T2：确认呈现耗时与「附加延迟」的真实含义

日志统计行的「附加延迟」是**窗口内相对最快帧的排队抖动**，不是端到端绝对延迟。
请确认 Present 前后的耗时是否有可加埋点的位置（`Present` 返回时刻 vs 帧到解码完成时刻），
若能给出 Windows 侧「解码完成 → 上屏」的耗时数据，就能定位剩余延迟在这段的比例。

### T3：顺带确认用户反馈的两个遗留问题（本轮只需取证，不改代码）

- **全屏**：用 `start.bat`（abe8e29 起默认 2240 1400 `--fullscreen`）启动，日志里
  `全屏目标尺寸` / `窗口客户区` / `窗口矩形` 三者是否相等且等于显示物理分辨率。
  14/17 份历史日志是 `--windowed`，用户「不是全屏」很可能只是启动方式，需确认。
- **点击错位**：两端坐标基准必须相等（Mac「坐标基准: 逻辑点 2240x1400」↔ Windows
  「坐标基准: 逻辑 2240x1400」）。请在副屏**正中点击一次**，回报落点方向：
  正中命中 / 偏左上（Win 基准大）/ 偏右下（Win 基准小）/ 固定偏移（Mac 原点单位问题）。

## 三、本轮不做

- 光标跨屏回主屏（`FIX-05-cursor-crossscreen.md` 设计稿，未落地，需两端协同多轮实测）。
- 真实光标图像之外的形状增强。
- 从 SPS 自适应分辨率（`RESULT-PRESET-2026-11-10.md` 的 B 路，中等工作量，另排期）。
- 辅助功能授权根治（需用户在系统设置操作）。

## 四、Mac 侧已就绪的配合

- Mac 发送端当前**已停**、且有一块残留虚拟屏 id=11 待用户注销/重启清除（
  `NIGHTLY-2026-11-10.md` 续节已记录，是我的实验副作用）。Windows 侧联调前需 Mac 先恢复。
- 恢复后 Mac 命令：`cd prototype/mac && ./run.sh start`（smooth、9922 监听）。
- 降延迟组合开关（Mac 侧已实现，供 A/B）：`SECDISPLAY_QD=1`（队列深度，默认3）、
  `SECDISPLAY_ENC=E`（禁帧重排+速度优先）、`SECDISPLAY_MBPS=NNN`（码率覆盖）、
  `SECDISPLAY_NOLOWLAT=1`（关低延迟码控，实测默认应保持开）。

## 五、回报格式

按 `research/PROTOCOL-autonomous-collab.md` 约定，在 RESULT 文件头写明：
对应任务单路径、执行提交号、逐条判据结果、遗留项、阻塞项。
