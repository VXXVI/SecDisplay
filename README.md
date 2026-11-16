# SecDisplay

macOS 与 Windows 双向有线扩展副屏方案：既支持 MacBook 当主屏、Windows 当副屏，也支持 Windows 当主屏、MacBook 当副屏，并附带 `9923` 端口雷电双向文件与剪贴板中转站。

---

## 当前状态

双向端到端均已在真实硬件上长期验证通过：

| 模式 | 核心链路 | 实测表现 |
|---|---|---|
| Mac 主屏 → Windows 副屏 | `CGVirtualDisplay` + `ScreenCaptureKit` + `VideoToolbox` → `Media Foundation` + `D3D11` | `2880x1800` 硬件编解码，雷电网桥低延迟直显 |
| Windows 主屏 → Mac 副屏 | `Parsec VDD` + `DXGI Duplication` + `Intel QSV MFT` → `VideoToolbox` + `IOSurface` | `2880x1800@60Hz` 1:1 Retina 清晰度，静止带宽 `0.0 Mbps`，键鼠反向回传 |
| 双向文件中转站 | `9923` 独立 TCP 通道，文件拖拽、全局悬浮盒、截图与文本粘贴互传 | 雷电直连满速传输，自动防覆盖落盘 |

验证环境：MacBook Pro M1 Pro ↔ Lenovo Yoga Slim 7 Pro 14IHU5 (Windows 11)

---

## 双向网络与架构

为了绕开 macOS 在雷电网桥上对第三方进程出站直连的本地网络权限阻断，两种角色采用对称的连接方向：**Mac 始终作为服务端监听 `9922` / `9923`，Windows 始终主动连接 Mac 的 IP**。

```
[正向] Mac 当主屏，Windows 当副屏
Mac (监听 9922/9923)                         Windows (主动连接 <Mac IP>)
  CGVirtualDisplay → ScreenCaptureKit          Media Foundation 硬解
    → VideoToolbox H.264 ──── 9922 ────→         → D3D11 窗口/全屏呈现
  CGEvent 键鼠注入 ←──── 0x04/0x09 ─────          键鼠捕获与 0x07 反馈

[反向] Windows 当主屏，Mac 当副屏
Windows (主动连接 <Mac IP>)                  Mac (监听 9922/9923)
  Parsec VDD 扩展屏 → DXGI Duplication          VideoToolbox H.264 硬解
    → D3D11 VideoProcessor → QSV MFT ─9922→      → IOSurface 1:1 Retina 呈现
  SendInput 键鼠注入 ←──── 0x04/0x09 ─────       MacKeyMap 捕获键鼠与 0x07 反馈
```

控制面板顶部（Mac 菜单栏面板与 Windows 控制面板）和托盘菜单均支持在两种角色间一键切换。

---

## 快速开始

### 1. Mac 端构建与权限

首次运行前，在「系统设置 → 隐私与安全性 → 屏幕录制」与「辅助功能」中授予权限，可先探测屏幕录制权限：

```bash
cd prototype/mac
swiftc -O Sources/RequestPermission.swift -o reqperm
./reqperm
```

推荐打包并安装到 `/Applications/SecDisplay.app`（保留 TCC 权限与 `NSLocalNetworkUsageDescription` 声明）：

```bash
cd prototype/mac
./build_app.sh
open /Applications/SecDisplay.app
```

命令行后台脚本方式：

```bash
cd prototype/mac
./run.sh start      # 编译并启动（默认 Mac 当主屏，SECDISPLAY_MODE=receiver 可直接启动副屏接收模式）
./run.sh status     # 查看状态
./run.sh log        # 实时查看日志
./run.sh stop       # 停止
```

直接命令行编译：

```bash
cd prototype/mac
swiftc -O Sources/main.swift Sources/AppUI.swift Sources/MacReceiver.swift -o screensender
./screensender --mode sender    # 或 --mode receiver
```

### 2. Windows 端准备与运行

**先双击 `prototype\windows\check.bat`** 检查硬件解码能力与网络连通性；若要使用反向投屏（Mac 当 Windows 副屏），Windows 端需安装 WHQL 签名的 **Parsec Virtual Display Adapter**（`Root\Parsec\VDA`）。

编译（Visual Studio 或 MinGW-w64）：

```cmd
cd prototype\windows
build.bat
```

或使用 MSYS2 MinGW-w64：

```cmd
cd prototype\windows
build-mingw.bat
```

运行（推荐在 `SecDisplayReceiver.exe` 同目录放置 `config.ini`，模板见 `prototype\windows\config.ini.example`）：

```cmd
SecDisplayReceiver.exe <Mac的IP> 9922 2880 1800
```

反向主控模式（Mac 当副屏）：

```cmd
SecDisplayReceiver.exe --mode sender --host-size 2880 1800 --fps 60 --bitrate 50 <Mac的IP> 9922
```

---

## 有线连接配置

建议两端通过雷电网桥或千兆网线直连。静态 IP 示例：

- Mac：`10.10.10.1 / 24`（或网线 `192.168.77.1 / 24`）
- Windows：`10.10.10.2 / 24`（或网线 `192.168.77.2 / 24`）

验证延迟：

```bash
ping -c 5 10.10.10.2
```

直连延迟应稳定在 `1ms` 以内。

---

## 参数配置与安全控制

### Mac 端环境变量与档位

| 变量 | 作用 | 默认 |
|---|---|---|
| `SECDISPLAY_MODE` | 角色模式：`sender`（Mac 当主屏）或 `receiver`（Mac 当副屏） | `sender` |
| `SECDISPLAY_HOST` | 记录的 Windows 地址，供中转或面板切回主屏时保留 | `10.10.10.2` |
| `SECDISPLAY_ALLOWED_HOST` | 副屏接收模式白名单 IP（逗号分隔，或 `any`；留空为私有网段+防抢占） | 自动 |
| `SECDISPLAY_W` / `SECDISPLAY_H` | 正向模式虚拟屏物理分辨率 | 随档位（默认 `2880x1800`） |
| `SECDISPLAY_HZ` | 正向模式采集帧率上限 | 随档位 |
| `SECDISPLAY_MBPS` | 目标码率（`10~1000`） | `180` |
| `SECDISPLAY_QD` | SCK 队列深度（`3~8`） | `3` |
| `SECDISPLAY_ENC` | 编码参数方案 `A~E` | `A` |
| `SECDISPLAY_NOLOWLAT=1` | 关闭 `EnableLowLatencyRateControl`（实测保持开启更优） | 开 |

快速切档可使用 `prototype/mac/preset.sh`（`sharp` / `balanced` / `smooth` / `fast`），也可直接在 Mac 菜单栏面板内切换。

### Windows 端 `config.ini` 与命令行参数

详见 `prototype/windows/config.ini.example`：

- `mode=receiver|sender`（对应命令行 `--mode receiver|sender`）
- `hostwidth` / `hostheight` / `fps` / `bitrate` / `hostdpi`（主控虚拟屏尺寸、帧率、码率及可选独立 DPI 缩放百分比，默认 `2880x1800@60`，`50 Mbps`）
- 副屏模式下控制面板支持动态切换 `2880×1800` / `2560×1600` / `1920×1200`、码率档位 `30M` / `50M` / `80M`、快速断线重连（不拆卸虚拟屏）以及重挂虚拟屏。

---

## 常见问题与虚拟屏清理

- **Mac 端异常退出残留虚拟屏**：正常退出会自动等待采集停稳后销毁虚拟屏；若被强杀导致残留，可执行 `/Applications/SecDisplay.app/Contents/MacOS/SecDisplay --cleanup-orphan`（或 `SECDISPLAY_CLEANUP_ORPHAN=1 ./run.sh start`），必要时注销重登即可回收。
- **Mac 副屏安全防抢占**：副屏接收模式下 `9922` 默认仅放行私有/链路本地/Tailscale 网段，且在已有主控连接时拒绝不同来源 IP 抢占当前会话；也可在面板填写允许接入的 Windows IP 白名单。
- **Windows 主控端 2880x1800 自定义模式**：若驱动尚未注册 `2880x1800`，以管理员权限启动一次即可自动写入 `HKLM\SOFTWARE\Parsec\vdd\0`；若虚拟屏开启了 HDR 导致格式非 `BGRA8`，请在系统显示设置中关闭该屏 HDR。
- **Windows 合盖主控黑屏防护**：如需合盖运行 Windows 主控端，建议通过 `powercfg` 将电源方案的接通电源与电池合盖动作（`SUB_BUTTONS LIDACTION`）均设为 `0`（不采取任何操作），详情见 `DEPLOY.md`；主控端已内置休眠保护、开盖唤醒内建屏与退出拓扑恢复。

---

## 目录结构

```text
prototype/mac/
  Sources/
    main.swift                Mac 端主入口（正向发送、9923 中转站、信号与生命周期）
    AppUI.swift               菜单栏与 SwiftUI 控制面板、悬浮投递盒、角色切换
    MacReceiver.swift         Mac 副屏接收端（9922 监听、VideoToolbox 硬解、MacKeyMap 键鼠回传）
    RequestPermission.swift   屏幕录制权限探测工具
    VirtualDisplay.swift      独立虚拟屏探测模块
  build_app.sh                打包与代码签名生成 SecDisplay.app
  run.sh / preset.sh          命令行管理与画质切档脚本

prototype/windows/
  SecDisplayReceiver.cpp      Windows 双模式主程序（D3D11 呈现、控制面板、托盘、9923 中转）
  WinHostSender.hpp           Windows 主控发送端（DXGI 采集、VideoProcessor、QSV 硬编、输入注入）
  WinVdd.hpp                  Parsec VDD 驱动生命周期、扩展桌面拓扑与 DPI 缩放管理
  SelfCheck.cpp               环境与硬件解码能力自检工具
  config.ini.example          配置文件模板

tools/                        遥测提取、脱敏一致性校验与实验脚本
research/                     实测报告、方案调研与代码审查归档
```
