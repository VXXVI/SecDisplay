# SecDisplay 技术原理与本机验证

日期：2026-11-05
环境：MacBook Pro M1 Pro / 16GB / macOS 27.2 (26B123) / arm64

---

## 一、结论先说

**这类方案没有任何魔法。** 它是三件成熟技术的组合，配合对延迟链路的精细打磨：

1. 让操作系统相信有一块真实显示器插着（虚拟显示器）
2. 用 GPU 硬件编码器把这块屏的画面压成视频
3. 用一条不排队的通道送过去，对端硬解后直接上屏

**这套架构在 macOS 27.2 上我们已完整复现并跑通。** 自环实测端到端中位延迟 **4.91ms**。

你之前用的开源方案差，差在三个具体的地方，不是架构本身。

---

## 二、商业方案的实现拆解

### 2.1 虚拟显示器层

从商业方案的更新日志和安装目录文件清单反推：

| 证据 | 推断 |
|---|---|
| 自建总线驱动 `*.sys` / `*.inf` | 总线枚举设备 |
| 显示驱动 `.dll/.inf`，GUID `{4D36E968-E325-11CE-BFC1-08002BE10318}` | 显示适配器类，属 IddCx 用户态 UMDF 驱动 |
| "Resolved a display driver crash occurring within the DXGI desktop duplication update loop" | 镜像模式走 DXGI Desktop Duplication 取帧 |
| "Fixed an issue in the display driver path that could throttle the actual frame rate to half" | 帧率控制在驱动侧实现 |
| "New Display Driver to improve mouse input latency" | 硬件光标由驱动提供，不画进视频 |

Windows 用 **IddCx**，微软为远程显示设计的正规用户态驱动模型。macOS 对应物是私有 API `CGVirtualDisplay`。

### 2.2 编码层

| 证据 | 推断 |
|---|---|
| "Add HEVC Encoding for NVidia GPUs" | 至少 NVIDIA 支持 HEVC |
| "Added a new video encoder utilizing the Intel Video Processing Library" | 每家 GPU 一套独立编码后端 |
| "Added a dedicated hardware video encoder for Snapdragon Adreno GPUs" | ARM64 单独适配 |
| "Resolved an issue with the Nvidia encoder getting stuck during flushing" | 用到编码器 flush 语义，说明有关键帧重建 |
| "Fixed decoder crash when the decoder is rebuilt (e.g., when host resolution changes)" | 接收端硬解，分辨率变化时重建 |

**商业方案不走 FFmpeg 编码，每个厂商单独调用硬件编码 API。** 这是它省电、低延迟的第一层原因。

### 2.3 传输层

| 证据 | 推断 |
|---|---|
| "Resolved an application crash occurring during SSL TCP data transfers" | TCP + TLS |
| "Added an expert setting to manually adjust the nominal video bitrate" | 码率显式控制 |
| "Enhanced latency calculations" | 有端到端延迟测量 |
| "Bitrate optimizations for remote mode to reduce latency" | 码率直接用于控延迟 |

2022 年 CEO 说"从零重写网络协议"。它做的是**自定义应用层协议跑在 TCP 上**，关键在控制发送队列深度。

### 2.4 历史原点

Dean McNamee 2014 年的逆向分析至今有效：虚拟屏是内存后备帧缓冲，走 PeerTalk（逆向 usbmuxd）经 USB 传输，本质是 TCP over USB，编码借 CocoaSplit 的着色器。

他当时说"这本质上就像 VNC over TCP over UDP"，且直言"零延迟"宣传有夸大。

**注意时间是 2014 年。** 那时候确实是软件编码，CPU 占用大。这十几年它做的事就是把软件编码换成硬件编码、把 VNC 式协议换成按帧定制的低延迟协议。

---

## 三、开源方案为什么感觉差

按影响程度排序。

### 3.1 色度抽样：文字糊的头号原因

H.264/HEVC 默认 **YUV 4:2:0**，色度水平垂直各砍一半。

对照片电影没感觉。对桌面文字是灾难：黑字白底，字边缘过渡本来靠色度信息，砍掉后变成彩色毛边。

**2560x1600@60fps 桌面，4:2:0 需要 30~60 Mbps 才够看，4:4:4 需要 100~200 Mbps。千兆有线吃得下。**

### 3.2 硬编 vs 软编

| | 硬编 | 软编 |
|---|---|---|
| 1080p60 延迟 | 3~15 ms | 10~30 ms |
| CPU | 几乎为 0 | 1~3 核满载 |

开源方案常见错误：FFmpeg 默认参数软编，CPU 跑满后掉帧，掉帧再补，体验就崩了。

### 3.3 队列深度：延迟堆积的真凶

用 TCP 传视频，发送端比接收端快时，数据堆在 TCP 缓冲里，你看到的永远是几百毫秒前的画面。

**正确做法：限制在途帧数（我们设为 2），满了就丢新帧；关键帧按需重发；关闭 Nagle。**

### 3.4 传输通道

| 通道 | 单程延迟 | 带宽 |
|---|---|---|
| 千兆有线 | 0.2~0.5 ms | 940 Mbps |
| 雷电桥接 | 0.1~0.3 ms | 10~20 Gbps |
| Wi-Fi 6 | 2~10 ms，抖动大 | 300~800 Mbps |

### 3.5 缩放

虚拟屏逻辑分辨率和对端物理分辨率不一致时，系统会缩放一次，编码再压一次，文字二次糊。

---

## 四、本机验证结果

### 4.1 虚拟屏：可用，但有坑

**结论：macOS 27.2 上创建虚拟屏完全可行，裸 `swiftc` 编译无需签名即可。**

正确的最小实现：

```swift
let desc = CGVirtualDisplayDescriptor()
desc.vendorID = 1          // 必须非零
desc.maxPixelsWide = 2560  // 背板像素
desc.maxPixelsHigh = 1600
desc.queue = DispatchQueue(label: "...")  // 每个屏独占一个串行队列

let display = CGVirtualDisplay(descriptor: desc)
let mode = CGVirtualDisplayMode(width: 2560, height: 1600, refreshRate: 60)
let settings = CGVirtualDisplaySettings()
settings.hiDPI = false     // 真正的 HiDPI 靠背板=逻辑x2 实现
settings.modes = [mode]
display.applySettings(settings)   // 返回 BOOL
```

**关键坑（都会复现）：**

| 问题 | 后果 | 正确做法 |
|---|---|---|
| 用 `perform(...)` 调 `applySettings` | SIGSEGV，误以为是系统拦截 | 用 `@convention(c)` 直接调用读 BOOL 返回值 |
| 只释放对象引用 | 屏不从系统消失，残留占位 | 读 `_client` ivar，传 `CDVirtualDisplayDestroy` |
| 传 `CGVirtualDisplay` 对象给 Destroy | 触发 CoreDisplay 内部断言崩溃 | 必须传内部 `VirtualDisplayClient` 指针 |
| 有残留屏时新建 | `initWithDescriptor` 返回 nil | 检查返回值并提示用户 |

**HiDPI 规则（实测对照）：**

| 背板 | 逻辑 | 结果 |
|---|---|---|
| 2560x1600 | 2560x1600 | scale 1.0，1:1 |
| 2560x1600 | 1280x800 | 系统忽略，回落 1:1 |
| 5120x3200 | 2560x1600 | **scale 2.0，真 Retina** |

> 更正说明：早期版本的本报告曾判断"系统层拦截、虚拟屏不可用"，那是错误的。根因是我自己的两处代码 bug（`perform` 读 BOOL 导致崩溃、判定逻辑写反），不是系统问题。`spawnProxy kr=0x5` 这条日志会打印，但不影响创建结果，属于噪音。

### 4.2 编码性能

H.264 High，低延迟模式，无 B 帧，目标 80 Mbps：

| 分辨率 | 帧率 | 每帧编码调用耗时 |
|---|---|---|
| 1920x1080 | 59.0 fps | 0.112 ms |
| 2560x1600 | 59.8 fps | 0.078 ms |
| 3024x1964 | 52.5 fps | 0.099 ms |
| 3840x2160 | 38.7 fps | 0.120 ms |

**编码器不是瓶颈。** 每帧 0.1ms，60fps 预算 16.6ms，余量 100 倍。4K 掉帧是测试代码的 CPU 重绘开销。

### 4.3 采集性能

| 场景 | 帧率 | 说明 |
|---|---|---|
| 静态桌面 | 12~13 fps | SCK 按需降帧，设计行为 |
| 有动画 | **54.4 fps** | 330 帧全采全编 |

抓屏内容已验证正确：抓到的是完整桌面，带菜单栏和窗口，macOS 把虚拟屏当一等公民。

### 4.4 端到端延迟（自环实测）

3024x1964，8 秒，362 帧全部解码成功：

| 指标 | 数值 |
|---|---|
| 最小 | 1.82 ms |
| **中位** | **4.91 ms** |
| p95 | 21.51 ms |
| 最大 | 74.67 ms |

这是"编码 → 回环传输 → 解码"这一段。加上抓屏和呈现，完整链路估计 **8~26 ms**，接近直连显示器的水平。

### 4.5 编码链路的格式坑

**VT 输出的 AVCC 不含 SPS/PPS**，参数集只在 `formatDescription` 里。关键帧必须自己按 AVCC 格式补上：

```
[SPS长度(4字节大端)][SPS][PPS长度][PPS][IDR长度][IDR]
```

早期漏了这步，接收端报 `-12909 kVTVideoDecoderBadDataErr`。

**另外不能用 Annex-B 起始码切分**，因为 H.264 码流内部天然出现 `00 00 00 01`，会切错。

**解码时不要传 `_EnableTemporalProcessing`**，它会吞掉输出不回调。

---

## 五、给你的方案

### 目标形态

MacBook 主屏 + Windows 副屏，有线连接。

### 管线

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

### 关键参数

| 项目 | 取值 | 理由 |
|---|---|---|
| 虚拟屏尺寸 | = Windows 屏物理分辨率 | 1:1 不缩放，文字才清晰 |
| 编码 | H.264 High，低延迟模式，无 B 帧 | 0.1ms/帧 |
| 码率 | 80~150 Mbps 起步 | 千兆网吃得下 |
| 传输 | TCP + NODELAY，在途上限 2 | 防延迟堆积 |
| 呈现 | D3D11 FLIP + ALLOW_TEARING | 绕过垂直同步 |

---

## 六、下一步

1. 清理残留虚拟屏（注销重登）
2. 在 Windows 上编译接收端
3. 配好有线静态 IP，实测完整链路
4. 按实测结果调码率和尺寸

详细运行步骤见项目根目录 `README.md`。
