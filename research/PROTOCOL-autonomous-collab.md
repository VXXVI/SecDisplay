# 两端异步协作协议：无常态 agent 下的推进方式

本文规定 SecDisplay 两端在没有常驻 agent 的前提下，用 GitHub 仓库 `VXXVI/SecDisplay` 当信箱异步协作的写法与动作。适用于任一端被唤起时按固定流程把任务队列推进到底。不适用宣称无人值守全自动：当前没有任何一端会主动唤醒 LLM（research/TELEMETRY.md:10、:12）。用户动机原话是「你们持续完成任务，可以灵活安排子代理或者通过 github 完成消息的交换，不然只有我上班的时候才能监督你们工作」。本文如实记录能做到的部分与做不到的部分，边界见第 5 节。

## 1. GitHub 信箱协议

载体是仓库里的文档，两端直接读写，不靠 Issues、PR 或提交说明夹带任务（prototype/windows/RESULT-2026-11-10.md:110-111 已确认任务派发的载体是文档）。文件名与头部字段定死，被唤起时一眼能看出有没有自己的活、干到哪了。

- 派任务一方写 `research/TASK-<方向>-<日期>.md`。文件头必须含：状态（待执行 / 进行中 / 已完成 / 已取消）、派发方、目标端、日期、判据、回报方式、本轮不做项。现有样例见 research/TASK-windows-2026-11-10.md:1-5、research/TASK-rea-duet-window-latency.md:1-6。
- 执行一方写 `prototype/<端>/RESULT-*.md` 或 `research/RESULT-*.md` 回报。文件头必须含：对应任务单路径、执行提交号、逐条判据结果、遗留项、需要对方配合的阻塞项。现有 RESULT 样例见 prototype/windows/RESULT-2026-11-10.md:98-102，已有「阻塞项」节的写法。
- 状态流转：待执行到进行中到已完成或已取消。执行方完成判据后，在任务单里把状态改为「已完成」并写明结果文件路径。允许改对方写的任务单，这是信箱协议的一部分，两端据此对齐。
- 派发方写清「本轮不做项」，避免执行方顺手改到需要两端协同、多轮实测的设计稿，例如 research/TASK-windows-2026-11-10.md:53-58 把跨屏与授权列为不做项。

## 2. 每次被唤起时的固定 SOP

这是让协作尽量不依赖用户在线的关键。用户一句话、自动化触发、守望发现变化，任一端 agent 每次被唤起都执行同一套动作，不必等用户逐条下指令。

1. `git fetch` 比对远端与本地，落后就 `git pull`（research/TASK-windows-2026-11-10.md:25 的拉新动作，logs/watch.sh:19 也用 `git fetch`）。
2. 读 `logs/watch.log` 尾部，看守望抓到了哪些新提交（logs/watch.sh:16-22 的日志格式）。
3. 扫 `research/TASK-*.md`，挑出状态为「待执行 / 进行中」且目标端是自己的条目。
4. 有任务就按判据执行：编译、实机验证、写 RESULT 回报、改任务单状态、`git commit` 加 `git push`。编译与启动命令沿用任务单给出的路径，例如 `cd C:\SecDisplay && git pull`、`cd prototype\windows && build.bat`（research/TASK-windows-2026-11-10.md:25-26）。
5. 没有新任务就只做同步与「无新任务」汇报，不制造改动、不空转（research/TELEMETRY.md:89 对空提交的克制同理）。
6. 需要对方配合的阻塞项写进 RESULT 的「阻塞」节并 push，让对方下次被唤起时看到（prototype/windows/RESULT-2026-11-10.md:98-102）。

这套 SOP 让两端只要有任意一次被唤起，就能把队列里的活按判据推进到底，用户不需要逐条下指令。被唤起的来源可以是用户任意一句话，或下一节之外的定时自动化，SOP 本身不挑触发方式。

## 3. 子代理调度约定

遵循全局 AGENTS.md 的「上下文窗口保护与子代理调度规约」精神：主会话做中枢编排，重活外包，只回提炼结论。

- 子代理必须与主会话同模型，显式传 `model` 参数，值为 `cli/hy4free`。
- 一次性独立取证、审查、写文档派子代理（agent / review / explore / docs）。主会话只做编排与落地：git 写操作、编译、实机运行。
- 高输出任务（跑测试、扫大文件、通读长日志）派子代理，只让它回提炼结论，禁止把未清洗原文灌回主会话。
- 子代理只读，不执行 git 写操作；跑完即返回，不能常驻。

## 4. 守望脚本的局限与改进方向

现状如实写：`logs/watch.sh` 每 60 秒做一次 `git ls-remote` 比对 main，有变化就把提交与 windows 端 `.cpp` 改动数记进 `logs/watch.log`（logs/watch.sh:10-28）。它只调 git 命令，调不动 LLM，进程随会话或待机被回收过，日志里留有重启记录（logs/watch.log:51「守望重启，上次进程随会话/待机终止」）。机器进现代待机会跳过定时任务，这一点依据同一条重启记录，具体触发条件待确认。Windows 端另有每小时 WorkBuddy 提交监测自动化，做 pull、有 `.cpp` 变更则编译加自检加接收端 20 秒验证（prototype/windows/RESULT-2026-11-10.md:112）。Mac 侧 launchd 每 5 分钟 push 一次 telemetry（research/TELEMETRY.md:45，logs/watch.log:185-195 的连续 telemetry 提交可印证）。

改进方向（建议，当前未实现）：守望脚本检测到 `research/TASK-*.md` 新增或变更时，在 `logs/watch.log` 写一行醒目的 `NEW_TASK` 标记，便于任一端被唤起时优先处理。这仍只是打标记，真正执行仍依赖第 2 节的 SOP 与一次唤起。

## 5. 能力边界

- 本对话不会主动弹消息给用户，agent 是被动响应（research/TELEMETRY.md:12）。
- 子代理一次性，跑完返回，不能常驻。
- 真正无人值守、两端都不需要用户，需要两端各自有常驻 agent，或有外部调度器把 agent 唤起。本仓库当前没有（research/TELEMETRY.md:10）。
- 用户能做到的最省力形态：每天任意一句话唤起一次，SOP 自动把队列清空。
- 遥测、launchd、守望都是纯脚本自动化，只搬数据与记录变化，不做决策（research/TELEMETRY.md:10-11、logs/watch.sh）。

## 6. 当前队列快照（2026-11-10）

按可执行工作单元计 9 条。跨文档重复出现的「光标跨屏回主屏」合并为 1 条（ISSUES:132 与 FIX-05 指同一件事）。ISSUES 最小起点里已划线的两条已完成，不计入。

| # | 事项 | 来源 | 派发方 | 目标端 | 状态 | 需用户配合 |
|---|---|---|---|---|---|---|
| 1 | 修解码失败并验证 | TASK-windows-2026-11-10.md:18 | Mac | Windows | 待执行 | 需要 |
| 2 | 验证真实 Mac 光标 | TASK-windows-2026-11-10.md:36 | Mac | Windows | 待执行 | 需要 |
| 3 | 验证连接不再 120s 断 | TASK-windows-2026-11-10.md:43 | Mac | Windows | 待执行 | 需要 |
| 4 | 卡顿 A/B（可选） | TASK-windows-2026-11-10.md:48 | Mac | Windows 加 Mac | 待执行 | 需要 |
| 5 | REA 逆向 Duet 窗口、延迟、输入链路 | TASK-rea-duet-window-latency.md:1、:3 | Windows | Mac REA | 待执行 | 需要 |
| 6 | 卡顿，编码 25.2ms 超 22.2ms 帧预算 | ISSUES-2026-11-10.md:133 | 联调遗留 | Mac | 待排期 | 否 |
| 7 | 89Hz 配 43fps 跳变 | ISSUES-2026-11-10.md:133 | 联调遗留 | 两端 | 待排期 | 否 |
| 8 | 光标跨屏回主屏，设计稿待落地 | ISSUES-2026-11-10.md:132、FIX-05-cursor-crossscreen.md:1、:3 | Windows（设计稿） | 两端协同 | 设计稿 | 两端协同 |
| 9 | 辅助功能授权根治，发送端做成 .app bundle | ISSUES-2026-11-10.md:136-137 | 联调遗留 | Mac | 条件待办 | 需要 |

「需用户配合」口径：必须有真人在场或授权、agent 单靠被唤起做不到的动作。第 1 至 3 项依赖接收端进程，用户已叫停且 Windows 端接收进程当前不在运行（research/ISSUES-2026-11-10.md:118），恢复实机联调需用户重新授权；Mac 侧仍在提交代码与遥测（logs/watch.log:185-195、research/ISSUES-2026-11-10.md:119）。第 4 项按任务单原文「需 Mac 配合」（TASK-windows-2026-11-10.md:48）。第 5 项要在真实 Mac 与 Windows 双端跑 Duet 4.0.526 官方安装包并抓包（TASK-rea-duet-window-latency.md:82）。第 9 项根治授权要在系统设置点一次（prototype/windows/RESULT-2026-11-10.md:102）。第 6、7 项为开发任务，按 SOP 可推进。第 8 项需两端各一次唤起协同。
