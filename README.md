# SecDisplay

MacBook 当主屏，Windows 笔记本当副屏。纯软件，走有线。

自研实现，不依赖任何商业方案。

---

## 当前状态

**端到端已打通**，在真实硬件上验证通过。

| 环节 | 状态 |
|---|---|
| 虚拟屏创建/销毁 | ✅ macOS 27.2，退出无残留 |
| 硬件编码 | ✅ 2880x1800@90Hz，0.078ms/帧 |
| 屏幕采集 | ✅ 有内容时 54fps；流中断可自愈 |
| Mac ↔ Windows 联调 | ✅ 雷电线 20Gbps，517 包零解码失败 |
| 画面呈现 | ✅ DXVA 硬解 + D3D11 直显，比例正确 |
| 端到端延迟 | ✅ 同机实测中位 21.7ms，p95 28.3ms |

验证环境：MacBook Pro M1 Pro / macOS 27.2 ↔ Lenovo Yoga Slim 7 Pro 14IHU5 (82NC) / Windows 11

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

用后台脚本管理（推荐）：

```bash
cd prototype/mac
./run.sh start      # 启动（自动编译）
./run.sh status     # 看状态
./run.sh log        # 实时看日志
./run.sh stop       # 停止
```

日志写入 `prototype/mac/logs/`。

也可以前台直接跑：

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

### 3. Windows 端

**具体步骤见 `prototype/windows/README.md`**，那份是给 Windows 机器看的操作清单，含成功判据和排障对照表。


**双击 `prototype\windows\check.bat`** 先看环境。它不需要编译器也能跑，
会直接显示屏幕分辨率、显卡、DPI 缩放、硬件解码能力。

如果想测到 Mac 的连通性：

```cmd
check.bat 192.168.77.1
```

要编译完整程序，双击 **`build.bat`**，它会自动找 Visual Studio 并编译
`SelfCheck.exe` 和 `SecDisplayReceiver.exe`。

编译完成后运行：

```cmd
SecDisplayReceiver.exe <Mac的IP> 9922 2240 1400
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
    var width = 2240          // 虚拟屏背板宽度 = Windows 屏物理宽度
    var height = 1400
    var logicalWidth = 2240   // 逻辑宽度
    var logicalHeight = 1400
    var refreshRate = 60.0
    var bitrateMbps = 120
    var port: UInt16 = 9922
}
```

默认值按 Lenovo 82NC（2240x1400）预设。其他机器改这四行即可。

### 尺寸怎么配

| Windows 屏 | width/height | logical | 效果 |
|---|---|---|---|
| 2240x1400 | 2240x1400 | 2240x1400 | 1:1，UI 正常 |
| 2880x1800 | 2880x1800 | 1440x900 | Retina，UI 大一号 |
| 1920x1080 | 1920x1080 | 1920x1080 | 1:1 |

**width/height 必须等于 Windows 屏物理像素，否则缩放后文字会糊。**

### 码率建议

| 内容 | 码率 |
|---|---|
| 纯文字 | 40~80 Mbps |
| 混合办公 | 100~150 Mbps |
| 有视频 | 200~300 Mbps |

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

## 文档

| 文档 | 内容 |
|---|---|
| `DEPLOY.md` | 从零到跑通的完整部署步骤与排障 |
| `research/ADAPT-82NC.md` | 针对 Lenovo 82NC（小新 Pro 14 2021）的适配说明 |
| `research/OFFICE-GUIDE.md` | 办公场景的画质与延迟调优指南 |
| `research/VS-COMMERCIAL.md` | 与商业方案的详细对比 |
| `research/REPORT-01-architecture.md` | 技术原理拆解 + 开源方案差距分析 |

## 实测数据

| 文档 | 内容 |
|---|---|
| `research/BENCH-01-encoding.md` | 编码性能：各分辨率帧率与耗时 |
| `research/BENCH-02-pipeline.md` | 虚拟屏、采集、编码各段实测 |
| `research/BENCH-03-latency.md` | 端到端延迟实测与踩坑记录 |
| `research/REVIEW-01-code-audit.md` | 两轮代码审查记录 |

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

tools/pkg-inspect/            第三方安装包结构分析脚本
research/                     实测数据、调研报告、代码审查记录
```
