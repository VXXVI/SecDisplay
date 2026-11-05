# SecDisplay 运行说明

Mac 当主屏，Windows 当副屏。MacBook 上会多出一块虚拟显示器，把它拖到你想要的位置；Windows 那边全屏显示这块屏的画面。

---

## 一、整体结构

```
MacBook                                              Windows
─────────────────────────────────────               ──────────────────────
CGVirtualDisplay  ← 系统认为是真显示器
     ↓
ScreenCaptureKit 抓这块屏
     ↓
VideoToolbox H.264 硬编（低延迟模式）
     ↓
TCP :9922  ────────── 有线 ──────────→  connect 192.168.x.x:9922
                                                ↓
                                          Media Foundation 硬解
                                                ↓
                                          D3D11 全屏置顶呈现
```

---

## 二、先决条件

### Mac 侧

| 项目 | 要求 | 检查方式 |
|---|---|---|
| macOS | 14 及以上 | `sw_vers` |
| Xcode 命令行工具 | 有 `swiftc` | `swiftc --version` |
| 屏幕录制权限 | 必须授权 | 见下方 |

**授权屏幕录制权限：**

```
系统设置 → 隐私与安全性 → 屏幕录制
找到你运行程序的终端（Terminal / iTerm / opencode）
勾选它，然后完全退出终端再重新打开
```

授权后验证：

```bash
cd prototype/mac
swiftc -O Sources/RequestPermission.swift -o reqperm
./reqperm
# 输出「当前屏幕录制权限: 已授权」才算成功
```

### Windows 侧

| 项目 | 要求 |
|---|---|
| Visual Studio | 2019 或 2022，带 C++ 桌面开发 |
| SDK | Windows 10 SDK 及以上 |

---

## 三、有线连接配置

**推荐用 USB 网卡或雷电转以太网，两端直连或用交换机。**

1. 两端各接一个网卡，或用一根网线直连（需要网卡支持自动交叉）
2. 给两端配同网段静态 IP，例如：
   - Mac: `192.168.77.1 / 24`
   - Windows: `192.168.77.2 / 24`
3. 关闭这块网卡上的防火墙（只对这块网卡，别关全局）
4. 验证连通：

```bash
# Mac 上 ping Windows
ping -c 5 192.168.77.2
```

延迟应该稳定在 1 ms 以内，抖动小于 0.3 ms。如果超过这个数，换线或换网卡。

---

## 四、运行

### 第 1 步：Mac 启动发送端

```bash
cd prototype/mac
swiftc -O Sources/ScreenSender.swift -o screensender
./screensender
```

正常输出：

```
[xx] 虚拟屏就绪 id=38 2560x1600
[xx] 抓屏已启动 2560x1600@60
[xx] 监听端口 9922，等待接收端连接
```

然后打开「系统设置 → 显示器」，能看到多了一块 **SecDisplay**。拖动它调整位置，这就是你的副屏。

### 第 2 步：Windows 启动接收端

```cmd
cd prototype\windows
cl /EHsc /std:c++17 /O2 SecDisplayReceiver.cpp /link ole32.lib
SecDisplayReceiver.exe 192.168.77.1 9922 2560 1600
```

参数依次是：Mac 的 IP、端口、宽度、高度。

窗口会全屏置顶显示 Mac 那块虚拟屏的画面。按 Esc 退出。

### 第 3 步：观察统计

两端都会每 2 秒打印一次统计：

```
Mac:     采集 120 帧 编码 120 发送 118 丢弃 2 62.3 Mbps 在途 1
Windows: 包 118 (+59)  解码 118 (+59)  62.1 Mbps
```

关键指标：
- **丢弃**：应该是个位数。持续丢弃说明带宽不够，降码率或降分辨率
- **在途**：应该稳定在 0~2。一直等于 2 说明网络在堵
- **Mbps**：桌面静止时应该很低（几 Mbps），有动画时才会上去

---

## 五、调参

所有参数在 `Sources/ScreenSender.swift` 顶部的 `Config`：

```swift
struct Config {
    var width = 2560          // 虚拟屏背板宽度 = Windows 屏物理宽度
    var height = 1600         // 同上
    var logicalWidth = 2560   // 逻辑宽度
    var logicalHeight = 1600  // 逻辑高度
    var refreshRate = 60.0
    var bitrateMbps = 60
    var port: UInt16 = 9922
}
```

### 尺寸怎么配

| 你的 Windows 屏 | width/height | logical | 效果 |
|---|---|---|---|
| 2560x1600（物理） | 2560x1600 | 2560x1600 | 1:1，UI 正常大小 |
| 2560x1600（物理） | 2560x1600 | 1280x800 | Retina，UI 大一号 |
| 1920x1080 | 1920x1080 | 1920x1080 | 1:1 |

**原则：width/height 必须等于 Windows 屏的物理像素，否则会缩放，文字必糊。**

### 码率怎么定

| 内容 | 建议码率 |
|---|---|
| 纯文字、码字 | 20~40 Mbps |
| 混合（浏览器+终端） | 60~100 Mbps |
| 有视频播放 | 150~250 Mbps |

千兆网理论上限 940 Mbps，留足余量后 200 Mbps 是很安全的。

---

## 六、已验证 / 未验证

### 已验证

- 虚拟屏创建、上线、销毁：`Sources/main.swift` → `vdtest`
- HiDPI 2x 配置生效
- 编码器参数配置正确（编译通过，待权限后实测）

### 未验证（等屏幕录制权限）

- ScreenCaptureKit 抓虚拟屏的实际帧率与延迟
- 端到端延迟实测
- Windows 端编译与运行

### 已知问题

- 进程非正常退出可能残留虚拟屏，占用 displayID 后导致下次创建失败。清理方式：注销并重新登录
- `Sources/ScreenSender.swift` 里 `destroy()` 只用 `unplug` 选择器，如果系统不响应需要补 `CDVirtualDisplayDestroy` 调用

---

## 七、文件清单

```
prototype/mac/
  Sources/
    VirtualDisplay.swift      虚拟屏封装（生命周期管理）
    main.swift                vdtest 入口，验证创建/保持/销毁
    ScreenSender.swift        发送端主程序
    RequestPermission.swift   权限检查工具
  vdcreate.py                  （旧）单次创建验证
  PipeProbe.swift             （旧）管线验证

prototype/windows/
  SecDisplayReceiver.cpp      接收端主程序
```
