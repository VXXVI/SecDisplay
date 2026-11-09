# 无人值守遥测：日志自动上传、GitHub 中转

## 目的

替代"每次诊断把日志整段复制粘贴"。两台设备定时从**运行中的日志**提取脱敏指标，自动 `git push` 到 `telemetry/`；这边 `git pull` 后跑一条命令就能读全，不用你贴任何内容。

## 边界（先说清楚）

- GitHub 云端 runner 连不到雷电链路 `10.10.10.x`，也不驱动虚拟屏和 89Hz 呈现，**测不了延迟和卡顿**。它只做两件事：编译两端、校验脱敏正确性。
- 设备侧跑的是普通定时任务，**没有常驻 agent**，GitHub 也不会主动到你的机器上执行任何东西。
- 定时任务只读取日志文件，不抢全屏、不移动光标、不结束进程，不影响你正常用电脑。
- 数据上传不需要你操作；但读取方只在会话被唤起时工作，所以你发一句话，我 `git pull` 后读最新 `telemetry/*.json`。

## 数据流

```
Mac:  screensender ──写──> logs/sender_*.log
      launchd 每5分钟 ─> extract_telemetry.py ─> telemetry/mac/<设备ID>.json ─push─┐
                                                                                  ├─> GitHub
Win:  接收端 --log ──写──> logs/*.log                                              │
      计划任务每5分钟 ─> extract_telemetry.py/.ps1 ─> telemetry/win/<设备ID>.json ─┘

我:  git pull && python3 tools/summarize_telemetry.py --strict
```

`<设备ID>` 是首次安装时生成的 8 位随机值，存放在仓库外（`~/.secdisplay-device-id` / `%APPDATA%\secdisplay-device-id.txt`）。主机名常含用户名，公开仓里连文件名都不能出现，所以不用主机名。

## 脱敏（仓库公开，硬约束）

`extract_telemetry.py` / `.ps1` 只输出**解析后的数字**和**固定枚举字符串**（预设名、编码方案、present_mode、warning 名）。字段白名单由 `tools/check_telemetry.py` 在 CI 里强制校验，新增字段必须显式登记。

绝不进入仓库的内容：IP、端口、endpoint、主机名、用户名、窗口标题、文件路径、日志正文、时间戳原文。样本日志里的 `10.10.10.2:58392` 一项都不会出现在输出 JSON 中，CI 把这点当硬检查。

CI 里 `check_telemetry.py` 做两道校验：一是固定敏感串黑名单，二是结构性白名单，递归遍历 JSON，任何叶子字符串必须属于固定枚举（预设名、warning 名、present_mode 等）或合法时间戳。这样即使日志将来冒出新的敏感串被正则带出来，也会在 CI 被拦下，不依赖黑名单是否列全。

## 一次性安装

### Mac

```zsh
cd C:/.../SecDisplay/prototype/mac   # 实际路径以你的克隆为准
./install_telemetry.sh
```

装的是 `~/Library/LaunchAgents/com.secdisplay.telemetry.plist`，每 5 分钟一次。

- 手动触发：`launchctl start com.secdisplay.telemetry`
- 卸载：`./install_telemetry.sh remove`
- 前提：`./run.sh start` 在运行，`logs/` 下有日志才会上传

### Windows

```
cd C:\SecDisplay\prototype\windows
install_telemetry.bat
```

装的是计划任务 `SecDisplayTelemetry`，每 5 分钟一次。

- 手动触发：`schtasks /run /tn "SecDisplayTelemetry"`
- 卸载：`install_telemetry.bat remove`
- 前提：接收端带 `--log` 运行（`start.bat` / `monitor.bat` / `diag.bat` 已带），`logs\` 下有日志才会上传

### 半自动路径

`diag.bat` 现在跑完 20 秒诊断会自动提取并上传，不需要你贴日志，也不需要装定时任务。两种方式共用同一套提取/上传脚本，不冲突。

## 读取

```zsh
cd /path/to/SecDisplay
git pull
python3 tools/summarize_telemetry.py --dir telemetry --strict
```

`--strict` 会检查两端齐全、坐标基准都是 1440x900，不一致时非零退出。输出示例：

```
=== telemetry/mac/<设备ID>.json ===
  坐标: 逻辑 1440x900
  峰值帧率: 中位 43.0 / p95 43.0 / 峰 43.0
  编码延迟ms: 中位 21.7 / p95 24.9
  告警: ax_not_trusted
```

## 已知边界

- 两端程序没运行、`logs/` 为空时，定时任务静默跳过，不上传空指标。
- 上传脚本在指标未变化（忽略时间戳与 commit）时不产生新提交，避免每 5 分钟一次空提交洪水。
- pull/rebase 冲突时只 `--abort`，绝不 `git reset`，不会动你已暂存的内容；本次上传留到下次重试。
- 云端 CI 只验证编译与脱敏，不测延迟。真实延迟、卡顿、光标鼠标跟手仍需在 `telemetry/` 的帧率/延迟/光标包指标里看趋势，或用 `diag.bat` 手动跑一轮。

## CI

`.github/workflows/ci.yml` 在每次 push / PR 时：

1. `macos-14` runner 用 `swiftc` 编译发送端
2. `windows-2022` runner 用 MSVC 编译接收端（改动 Windows 代码后不用等设备侧 build）
3. `ubuntu` runner 用同一份样本日志验证 Python / PowerShell 提取器一致、脱敏无泄漏

## 文件清单

| 文件 | 作用 |
|---|---|
| `tools/extract_telemetry.py` | 核心提取器，mac/win 双平台，输出脱敏 JSON |
| `tools/extract_telemetry.ps1` | Windows 无 Python 时的后备，schema 与 py 一致 |
| `tools/push_telemetry.sh` / `.ps1` | 只 add 目标 json、pull --rebase、无变更静默、单实例锁 |
| `prototype/mac/telemetry_mac_loop.sh` | Mac 单次采集循环，由 launchd 调用 |
| `prototype/windows/telemetry_win_loop.ps1` | Windows 单次采集循环，由计划任务调用 |
| `prototype/mac/install_telemetry.sh` | 装/卸 launchd 任务 |
| `prototype/windows/install_telemetry.bat` | 装/卸计划任务 |
| `tools/summarize_telemetry.py` | 汇总所有设备指标，`--strict` 校验 |
| `tools/make_fixtures.py` / `check_telemetry.py` | CI 样本与脱敏硬校验 |
| `telemetry/` | 设备端自动上传的指标 JSON（每设备一个稳定文件） |
