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

```bash
swiftc -O Sources/ScreenSender.swift -o screensender
./screensender
```

正常输出：

```
[xxx] 虚拟屏就绪 id=38 2560x1600
[xxx] SecDisplay 服务已启动，Ctrl-C 退出
[xxx] 监听端口 9922，等待接收端连接
[xxx] 抓屏已启动 2560x1600@60
```

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
cl /EHsc /std:c++17 /O2 SecDisplayReceiver.cpp
```

库都在代码里用 `#pragma comment` 自动链接，不用手动指定。

### 4.2 运行

```cmd
SecDisplayReceiver.exe 192.168.77.1 9922 2560 1600
```

参数依次是：Mac 的 IP、端口、宽、高。

窗口会全屏置顶。按 **Esc** 退出。

### 4.3 确认出画

启动日志应该依次出现：

```
D3D11 设备就绪（已绑定 MF 硬件解码管理器）
免垂直同步呈现: 支持
呈现器就绪
解码器就绪 2560x1600（硬件）
连接 192.168.77.1:9922 ...
已连接，目标 2560x1600
已注入 SPS(28) PPS(8)
输出类型已重建，继续解码
```

卡在哪一行，就是哪一环的问题，对照下面「排障」看。

---

## 第五步：调参

参数在 `prototype/mac/Sources/ScreenSender.swift` 顶部的 `Config`。

### 分辨率必须对齐

**Mac 端 `width`/`height` 必须等于 Windows 屏的物理像素**，否则会缩放，文字必糊。

查 Windows 屏的物理分辨率：`设置 → 系统 → 显示 → 显示器分辨率`。

| Windows 屏 | width | height | logicalWidth | logicalHeight |
|---|---|---|---|---|
| **2240x1400**（Lenovo 82NC 常见）| 2240 | 1400 | 2240 | 1400 |
| **2880x1800**（Lenovo 82NC 高刷版）| 2880 | 1800 | 1440 | 900（开 Retina）|
| 1920x1080 | 1920 | 1080 | 1920 | 1080 |
| 2560x1600 | 2560 | 1600 | 2560 | 1600 |

`logicalWidth/Height` 设成一半时开启 2x 渲染，界面元素会大一倍，更清晰。

### 码率

```swift
var bitrateMbps = 60
```

| 内容 | 建议 |
|---|---|
| 纯文字 | 40~80 |
| 混合办公 | 100~150 |
| 有视频 | 200~300 |

千兆网上限 940 Mbps，给到 200 也不挤。

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

### 两端都正常但延迟高

1. `ping` 确认网络延迟，超过 1ms 就先查网络
2. 看 Mac 端日志的「丢弃」数字，持续丢弃说明码率超了带宽
3. 看「在途」，一直等于 2 说明发送端在等网络

---

## 当前已知风险

**Windows 端从未在真实 Windows 机器上编译运行过。** 代码经过两轮审查，逻辑和 API 用法核对过，但没有编译器验证。

首次运行大概率需要调，重点看启动日志停在哪一步。详细审查记录见 `research/REVIEW-01-code-audit.md`。
