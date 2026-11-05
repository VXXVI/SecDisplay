# SecDisplay

MacBook 当主屏，Windows 笔记本当副屏。纯软件，走有线。

自研实现，不依赖 Duet 或任何商业方案。

---

## 当前状态

| 环节 | 状态 |
|---|---|
| 虚拟屏创建/销毁 | 已验证，macOS 27.2 可用 |
| 硬件编码性能 | 实测 2560x1600@60fps，0.078ms/帧 |
| 屏幕采集 | 实测有内容时 54fps |
| 端到端链路（自环）| 实测中位延迟 4.91ms |
| Windows 端接收显示 | 代码完成，经两轮代码审查，**未在 Windows 上编译运行过** |
| Mac↔Windows 真实联调 | 待进行 |

---

## 结构

```
MacBook                                   Windows
CGVirtualDisplay 建虚拟屏
   ↓ ScreenCaptureKit 抓帧
   ↓ VideoToolbox H.264 硬编（低延迟模式）
   ↓ TCP_NODELAY，在途帧数上限 2
   ═══ 有线 ═══→
                     Media Foundation 硬解
                        ↓
                     D3D11 全屏置顶呈现
```

---

## 快速开始

### 1. Mac 端授权

```
系统设置 → 隐私与安全性 → 屏幕录制
勾选你运行程序的终端，然后完全退出终端重开
```

验证：

```bash
cd prototype/mac
swiftc -O Sources/RequestPermission.swift -o reqperm
./reqperm
# 显示「已授权」才继续
```

### 2. Mac 端启动发送

```bash
cd prototype/mac
swiftc -O Sources/ScreenSender.swift -o screensender
./screensender
```

输出：

```
虚拟屏就绪 id=38 2560x1600
抓屏已启动 2560x1600@60
监听端口 9922，等待接收端连接
```

打开「系统设置 → 显示器」能看到多了一块 **SecDisplay**，把它拖到合适位置。

### 3. Windows 端编译运行

```cmd
cd prototype\windows
cl /EHsc /std:c++17 /O2 SecDisplayReceiver.cpp
SecDisplayReceiver.exe <Mac的IP> 9922 2560 1600
```

所需的库都通过 `#pragma comment` 自动链接，不需要手动指定。

按 Esc 退出。

---

## 有线连接配置

两端各接一个网卡，或用一根网线直连。

静态 IP 示例：
- Mac：`192.168.77.1 / 24`
- Windows：`192.168.77.2 / 24`

验证：

```bash
ping -c 5 192.168.77.2
```

延迟应稳定在 1ms 以内。超过就换线或换网卡。

---

## 参数配置

在 `prototype/mac/Sources/ScreenSender.swift` 顶部：

```swift
struct Config {
    var width = 2560          // 虚拟屏背板宽度 = Windows 屏物理宽度
    var height = 1600
    var logicalWidth = 2560   // 逻辑宽度
    var logicalHeight = 1600
    var refreshRate = 60.0
    var bitrateMbps = 60
    var port: UInt16 = 9922
}
```

### 尺寸怎么配

| Windows 屏 | width/height | logical | 效果 |
|---|---|---|---|
| 2560x1600 | 2560x1600 | 2560x1600 | 1:1，UI 正常 |
| 2560x1600 | 2560x1600 | 1280x800 | Retina，UI 大一号 |
| 1920x1080 | 1920x1080 | 1920x1080 | 1:1 |

**width/height 必须等于 Windows 屏物理像素，否则缩放后文字会糊。**

### 码率建议

| 内容 | 码率 |
|---|---|
| 纯文字 | 20~40 Mbps |
| 混合 | 60~100 Mbps |
| 有视频 | 150~250 Mbps |

---

## 已验证的坑

写代码时如果重新实现，这几处一定要避开。详细说明见 `research/BENCH-03-latency.md`。

| 坑 | 正确做法 |
|---|---|
| `perform` 调 `applySettings` | 用 `@convention(c)` 读 BOOL 返回值，否则崩溃 |
| 只释放虚拟屏对象 | 读 `_client` ivar，传 `CDVirtualDisplayDestroy` |
| 有残留屏时新建 | 检查 `initWithDescriptor` 返回值 |
| VT 输出缺 SPS/PPS | 关键帧自己按 AVCC 长度前缀补参数集 |
| 用 Annex-B 起始码切分 | 全程用 AVCC，码流内部有 `00 00 00 01` |
| 解码传 `_EnableTemporalProcessing` | 实时场景不要传，会吞掉输出 |

### 残留虚拟屏清理

程序异常退出可能留下虚拟屏，占住位置导致新建失败。现象是 `initWithDescriptor` 返回 nil。

清理方式：**注销并重新登录**，或重启。

---

## 实测数据

| 文档 | 内容 |
|---|---|
| `research/REPORT-01-duet-architecture.md` | Duet 原理拆解 + 开源方案差距分析 + 本机验证总结 |
| `research/BENCH-01-encoding.md` | 编码性能：各分辨率帧率与耗时 |
| `research/BENCH-02-pipeline.md` | 虚拟屏、采集、编码各段实测 |
| `research/BENCH-03-latency.md` | 端到端延迟实测与踩坑记录 |

---

## 文件

```
prototype/mac/
  Sources/
    VirtualDisplay.swift      虚拟屏封装（含正确销毁）
    main.swift                vdtest：创建/保持/销毁验证
    ScreenSender.swift        发送端主程序
    RequestPermission.swift   权限检查
  EncodeBench2.swift          编码性能测试
  CaptureBench2.swift         采集性能测试
  LoopbackTest.swift          自环延迟测试（需要虚拟屏）
  LoopbackBuiltin.swift       自环延迟测试（用内置屏）
  CaptureDump.swift           抓一帧存 PNG 看内容

prototype/windows/
  SecDisplayReceiver.cpp      接收端

research/                     实测数据与调研报告
dumps/                        Duet 安装包分析（74MB 载荷为加密流，未能解包）
```
