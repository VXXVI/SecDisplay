# 部署指南

从零到跑通的完整步骤。

---

## 硬性条件

| 项目 | 要求 |
|---|---|
| Mac | Apple Silicon 或 Intel，macOS 14 及以上 |
| Windows | Windows 10 及以上 |
| 传输 | **一根网线（强烈建议）**，Wi-Fi 延迟抖动大 |
| Mac 工具链 | Xcode 命令行工具（`xcode-select --install`）|
| Windows 工具链 | Visual Studio 2019/2022，带「使用 C++ 的桌面开发」 |

---

## 第一步：取得代码

```bash
git clone https://github.com/VXXVI/SecDisplay.git
cd SecDisplay
```

---

## 第二步：配好有线连接

这是延迟的关键。无线也能跑，但抖动大。

### 方案 A：一根网线直连（推荐）

两端支持自动翻转网卡的话，普通网线即可。

给两端各配一个同网段静态 IP：

**macOS**
```
系统设置 → 网络 → 选中那块网卡 → 详细信息 → TCP/IP
配置 IPv4：手动
IP 地址：192.168.77.1
子网掩码：255.255.255.0
```

**Windows**
```
设置 → 网络和 Internet → 以太网 → IP 分配 → 编辑
手动 / IPv4
IP：192.168.77.2
掩码：255.255.255.0
网关：留空
```

### 方案 B：接同一个路由器/交换机

用路由器分配的 IP 也行，但要确认两端在同一个子网。

### 验证

Mac 上：

```bash
ping -c 10 192.168.77.2
```

**延迟应稳定在 1ms 以内，抖动小于 0.3ms。** 达不到就换网卡或换线，别急着往下走。

如果 ping 不通，检查：Windows 防火墙是否拦了这块网卡（只关这块，别关全局）。

---

## 第三步：Mac 端

### 3.1 授权屏幕录制

```bash
cd prototype/mac
swiftc -O Sources/RequestPermission.swift -o reqperm
./reqperm
```

输出 `未授权` 的话，去：

```
系统设置 → 隐私与安全性 → 屏幕录制
勾选你运行命令的终端程序
然后完全退出终端（Cmd+Q）再重新打开
```

再跑一次确认显示 `已授权`。

### 3.2 编译启动

打包并安装到 `/Applications/SecDisplay.app`（长期使用推荐，内置本地网络与屏幕录制权限声明；加 `--no-install` 时产物保留在 `$TMPDIR` 临时目录）：

```bash
cd prototype/mac
./build_app.sh
open /Applications/SecDisplay.app
```

> 若系统 `TCC.db` 曾残留 `/Applications/SecDisplay.app` 的旧路径拒绝条目（`auth_value=0`），`build_app.sh` 会自动改安装到 `/Applications/SecDisplay/SecDisplay.app` 并清理旧路径，按脚本末尾输出的 `open` 路径启动即可。

命令行方式：

```bash
swiftc -O Sources/main.swift Sources/AppUI.swift Sources/MacReceiver.swift -o screensender
./screensender --mode sender
```

若启用「Mac 当副屏」模式（Windows 主控 → Mac 显示）：

```bash
./screensender --mode receiver
```

也可在运行后通过 Mac 菜单栏面板顶部的「Mac 当主屏 / Mac 当副屏」分段开关一键切换。

### 3.3 摆放虚拟屏

打开 `系统设置 → 显示器`，会看到多了一块 **SecDisplay**。

拖动它调整位置，就像外接显示器一样。点「排列」可以设置哪个在左哪个在右。

---

## 第四步：Windows 端

### 4.0 先双击 check.bat

不需要编译器，直接显示屏幕分辨率、显卡、DPI、硬件解码能力。

```cmd
check.bat
```

想测到 Mac 的连通性：

```cmd
check.bat 192.168.77.1
```

### 4.1 编译

**双击 `build.bat`**，会自动找 Visual Studio 并编译两个程序。

如果它说找不到 Visual Studio，说明没装。装 Visual Studio 2022 社区版，
勾选「使用 C++ 的桌面开发」：
https://visualstudio.microsoft.com/zh-hans/downloads/

装好后再双击 `build.bat`。

也可以手动在「x64 Native Tools Command Prompt for VS」里执行：

```cmd
cd prototype\windows
rc /nologo /fo SecDisplayReceiver.res SecDisplayReceiver.rc
cl /nologo /EHsc /std:c++17 /O2 /utf-8 SecDisplayReceiver.cpp SecDisplayReceiver.res /Fe:SecDisplayReceiver.exe
```

库都在代码里用 `#pragma comment` 自动链接，不用手动指定。

### 4.2 运行

默认接收端模式（Mac 当主屏，Windows 当副屏）：

```cmd
SecDisplayReceiver.exe 192.168.77.1 9922 2880 1800
```

参数依次是：Mac 的 IP、端口、宽、高。也可在同目录放置 `config.ini`（参考 `config.ini.example`）免参数启动。

反向主控模式（Windows 当主屏，Mac 当副屏，需先安装 Parsec VDD 驱动）：

```cmd
SecDisplayReceiver.exe --mode sender --host-size 2880 1800 --fps 60 --bitrate 50 192.168.77.1 9922
```

窗口模式下可直接在控制面板顶部切换角色。按 **F11** 切换全屏。

### 4.3 确认出画

启动日志应该依次出现：

```
D3D11 设备就绪（已绑定 MF 硬件解码管理器）
免垂直同步呈现: 支持
呈现器就绪
解码器就绪 2880x1800（硬件）
连接 192.168.77.1:9922 ...
已连接，目标 2880x1800
已注入 SPS(28) PPS(8)
输出类型已重建，继续解码
```

卡在哪一行，就是哪一环的问题，对照下面「排障」看。

---

## 第五步：调参

Mac 端可通过菜单栏面板、`prototype/mac/preset.sh` 或环境变量调整；Windows 端可通过同目录 `config.ini`（参考 `prototype/windows/config.ini.example`）调整。

### 分辨率必须对齐

**正向模式下 Mac 端虚拟屏 `width`/`height` 应匹配或整数倍于 Windows 屏物理像素，反向模式下 Windows `hostwidth`/`hostheight` 建议设为 `2880x1800` 对齐 MacBook Retina 16:10**，否则缩放后文字会模糊。

查 Windows 屏的物理分辨率：`设置 → 系统 → 显示 → 显示器分辨率`。

| Windows 屏 | width | height | logicalWidth | logicalHeight |
|---|---|---|---|---|
| **2880x1800**（16:10 Retina 推荐）| 2880 | 1800 | 1440 | 900（开 2x Retina）|
| **2560x1600** | 2560 | 1600 | 1280 | 800（开 2x Retina）|
| **2240x1400** | 2240 | 1400 | 1120 | 700 |
| **1920x1080** | 1920 | 1080 | 1920 | 1080 |

`logicalWidth/Height` 设成一半时开启 2x 渲染，界面元素比例自然且文字最锐利。

### 码率

正向模式可通过 `SECDISPLAY_MBPS` 调整（`10~1000`，默认 `180`）：

| 内容 | 正向模式建议 (Mbps) |
|---|---|
| 纯文字 | 40~80 |
| 混合办公 | 100~150 |
| 有视频 | 200~300 |

反向模式（Windows 主控 → Mac 副屏）目标码率范围为 `10~200 Mbps`（越界回落默认 `50`，在 `config.ini` 用 `bitrate=` 配置，或直接在 Windows 控制面板底栏 `30M / 50M / 80M` 按钮实时切换）；千兆或雷电直连给到 `200` 也不挤。

---

## 排障

### Mac 端：`initWithDescriptor 返回 nil`

有上次异常退出留下的残留虚拟屏占着位置。

**解决：注销并重新登录**，或重启。

### Mac 端：屏幕录制权限反复失效

改过代码后重新编译，可执行文件的签名变了，系统会当成新程序。解决：删掉列表里的旧条目，重新勾选。

### Windows 端：编译报错找不到 `cl`

用「x64 Native Tools Command Prompt for VS」，不要用普通 cmd 或 PowerShell。

### Windows 端：黑屏，日志停在「解码器就绪」

- 看有没有「已注入 SPS」。没有说明没收到关键帧，检查 Mac 端是否在发
- 有 SPS 但没有「输出类型已重建」，可能是驱动问题，试试更新显卡驱动

### Windows 端：画面色彩不对 / 绿屏

`VideoProcessorBlt` 的 NV12→BGRA 转换在部分驱动上有问题。记录下显卡型号，这是已知的驱动兼容性风险。

两端已显式锚定 BT.709 矩阵与 sRGB 传递函数（Mac 端 VideoToolbox 写 VUI，Windows 端 `VideoProcessorSetStreamColorSpace` / `SetOutputColorSpace` 设 16-235 → 0-255）。若特定显卡驱动仍忽略色彩空间属性，可把 `Contents/Resources/pixfmt` 保持为 `bgra`。

### Windows 端：投屏一段时间后会自动熄屏

Windows 电源计划默认在无本地键鼠输入时关闭显示器（例如平衡模式下插电 10 分钟、电池 3 分钟）。Mac 端拦截并回放虚拟屏输入不会重置 Windows 本地空闲计时器。

接收端现已在投屏且未最小化时自动声明 `SetThreadExecutionState(ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED)` 保持屏幕常亮，断连或最小化让位时释放。可在控制面板勾选或取消「保持屏幕常亮 (防熄屏)」。

### Windows 端：主控合盖或插拔雷电线后不亮屏、亮度调节失效

当 Windows 笔记本以主控模式合盖运行时，Windows 会关闭内建 eDP 面板并把 `ParsecVDA` 设为唯一屏幕：

1. **避免电池合盖触发休眠/掉电**：Windows 默认常将「接通电源合盖 = 无操作」而「使用电池合盖 = 睡眠/休眠」。若雷电口供电瞬断或拔掉电源，合盖会直接休眠或异常断电黑屏。请以管理员执行以下命令把接通电源与电池的合盖动作均设为「不采取任何操作」：

```cmd
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT
```

2. **程序内自动防护与唤醒**：主控端不再把合盖单屏下的 `(0,0)` 虚拟屏排布持久化写入注册表；在收到 `WM_POWERBROADCAST` 休眠通知时先卸载虚拟屏并在唤醒时调用 `SDC_TOPOLOGY_INTERNAL` 唤醒内建显示路径；开盖（`GUID_LIDSWITCH_STATE_CHANGE`）或退出时若内建屏仍处于熄灭状态，会自动切回内建屏并重建扩展桌面。若因系统异常中断导致物理黑屏，可在另一台设备通过快捷键 `Win+Ctrl+Shift+B` 重置显卡驱动或运行一次 `SecDisplayReceiver.exe` 后正常退出触发内建屏恢复。

### Mac 端：画面卡住不动 / 内存持续上涨

`SCScreenshotManager` 并发轮询有两个已知故障模式：整体卡死（完成回调永不返回），和半卡死（偶尔回一帧但远低于目标帧率）。看护会按实测帧率判断，连续异常时重启工作线程。

日志里看这两行：

```
截图采集异常（0.0fps，目标 50fps，第 1 次重启）
截图采集持续异常（0.0fps，已重启 15 次），已降为 30 秒重试一次。若画面不动请重启发送端
采集已连续重启 20 次仍未恢复（0.0fps），停止自动重启。请退出并重开 SecDisplay
```

前 4 次每 3 秒重试一次，之后降为 30 秒一次，累计 20 次后彻底停手。出现第二行说明 SCK 已经彻底不可用，重启发送端最快；出现第三行说明自动重试已经放弃，必须退出重开。

显示器休眠时不会判为故障（日志会打「显示器已休眠，暂停采集判活」），唤醒后自动恢复。如果你看到休眠期间日志里反复出现「截图采集异常」，说明这个版本之前的构建，升级即可。

面板「采集重启」那一行显示的是自上次恢复以来真正重启工作线程的次数，正常时是「无」。超过 20 次会停止自动重启并记一条告警，那时只能退出重开。

### Mac 端：退出后残留一块虚拟屏

`CDVirtualDisplayDestroy` 在采集还挂着时会被静默拒绝。正常退出会先停采集再销毁，等 1.5 秒。如果进程被 `kill -9`，会留下孤儿屏。

```
/Applications/SecDisplay.app/Contents/MacOS/SecDisplay --cleanup-orphan
```

### 雷电双向文件中转站

Mac 与 Windows 之间通过独立端口 `9923`（视频端口 + 1）提供全双工文件中转站，不占用 `9922` 视频与光标通道：

- **中转站目录**：Mac 端默认在 `~/Downloads/SecDisplay-Transfer`，Windows 端默认在桌面 `SecDisplay-Transfer` 文件夹（均会在启动时自动创建）。
- **发送方法**：在任意一端的控制面板点击「发送文件」多选文件，或直接把文件拖入控制面板窗口即可通过雷电直连高速传输（实测可达 340+ MB/s）。也可以用全局快捷键（Mac `Ctrl+Opt+B` / Windows `Ctrl+Alt+B`）随时一键呼出或隐藏置顶悬浮投递盒，支持任意空白处拖动位置、进度条与成功/失败回执提示，以及 `Cmd+V` / `Ctrl+V` 直接粘贴剪贴板截图或文件发送。Windows 端默认以无黑框模式运行，实时日志已集成到控制面板底部卡片中。
- **防覆盖**：收到文件先写 `.part` 临时文件，校验完整后原子落盘；同名文件自动追加序号，不覆盖既有文件。

### 两端都正常但延迟高

1. `ping` 确认网络延迟，超过 1ms 就先查网络
2. 看 Mac 端日志的「丢弃」数字，持续丢弃说明码率超了带宽
3. 看「在途」，一直等于 2 说明发送端在等网络

---

## 当前已知风险

**Windows 端已在真实机器上编译运行验证。** 分辨率 2880×1800、硬件解码（Microsoft H264 Video Decoder MFT）、D3D11 渲染均正常，但只在一种显卡和一种 Windows 版本上验证过。换机器仍需按上面的排障步骤走一遍。

**420v 采集模式默认关闭。** 它把 Mac 端内存从 136MB 降到 44MB，代价是帧率掉一半（约 20~37fps）。除非内存吃紧，否则保持 `bgra`。
