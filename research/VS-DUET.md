# 与 Duet Display 的对比

先说结论：**底层原理完全一样，差别在工程打磨程度和使用门槛。**

---

## 一、原理上没有区别

Duet 从 2014 年到现在，核心链路没变过，就是把三件事做好：

```
虚拟显示器  →  硬件编码  →  低延迟传输  →  对端硬解  →  上屏
```

2014 年 Dean McNamee 逆向 Duet 时的结论是：虚拟屏是内存后备帧缓冲，走 PeerTalk（逆向 usbmuxd）经 USB 传输，本质是 TCP over USB，编码借 CocoaSplit 的着色器。他当时的评价是「这本质上就像 VNC over TCP over UDP」。

十几年过去，它做的事就是把这套东西不断优化：软件编码换硬件编码、VNC 式协议换成按帧定制的低延迟协议、加上各家 GPU 的独立编码后端。

**本项目走的是同一条路：**`CGVirtualDisplay` 建虚拟屏 → ScreenCaptureKit 抓帧 → VideoToolbox 硬编 → TCP 传 → Media Foundation 硬解 → D3D11 直显。

---

## 二、具体差异

### 2.1 虚拟显示器

| | Duet | 本项目 |
|---|---|---|
| Windows 侧 | 自建 `DuetBus.sys` + IddCx 用户态驱动 | 不使用（Windows 只做接收端）|
| macOS 侧 | 私有 API `CGVirtualDisplay` | 私有 API `CGVirtualDisplay` |
| 驱动签名 | 有微软 WHQL 签名 | 不需要驱动 |

Duet 在 Windows 上装了完整的虚拟显示驱动，所以 Windows 也能当被投屏的一端。本项目只做 Mac → Windows 单向，Windows 端不装任何驱动，这方面门槛低很多。

### 2.2 编码

| | Duet | 本项目 |
|---|---|---|
| 编码器 | 每厂商单独实现（NVENC / Intel VPL / AMD / Adreno）| 只用 VideoToolbox |
| 支持的编码硬件 | 几乎覆盖全部 GPU | 只有 Apple Silicon / Intel Mac |
| 码率控制 | 有专家设置，可手动调 | Config 里改，需重编译 |

Duet 为每家的硬件编码 API 写了一套后端，这是它跨平台能力的基础。本项目只需要在 Mac 上编码，VideoToolbox 一个就够。

**这部分我们反而更简单：** 因为只用一套 API，不存在多后端维护的复杂度。

### 2.3 传输

| | Duet | 本项目 |
|---|---|---|
| 协议 | 自定义应用层协议跑在 TCP 上，带 TLS | 自定义二进制协议跑在 TCP 上，无加密 |
| 连接方式 | WiFi / USB / 雷电，带 UPnP 打洞可跨公网 | 只支持局域网 |
| 安全 | 256 位加密 | 无加密（依赖局域网隔离） |

Duet 有远程使用场景，所以做了 TLS 和 NAT 穿透。本项目只在你自己的局域网内用，这两块都省了。

**这是取舍，不是缺陷：** 少一层 TLS 就少一次加解密开销，局域网内也没必要。

### 2.4 功能范围

| 功能 | Duet | 本项目 |
|---|---|---|
| 扩展显示 | 有 | 有 |
| 镜像显示 | 有 | 无 |
| 触摸/手写笔输入回传 | 有 | 无 |
| 键鼠共享（一套键鼠控两台）| 有 | 无 |
| 音频转发 | 有 | 无 |
| 多设备同时投屏 | 有 | 无 |
| 远程（跨公网）| 有 | 无 |

**本项目只做一件事：把 Mac 的扩展屏投到 Windows 上。** 其余都没做。

### 2.5 成熟度

这是最大的差距。

| | Duet | 本项目 |
|---|---|---|
| 发展时间 | 2014 年至今，12 年 | 几天 |
| 用户规模 | 数十万 | 0 |
| 踩过的坑 | 更新日志里有几百条 bug 修复 | 踩了十几个，还有没踩到的 |
| GPU 兼容性 | 覆盖主流显卡 | 只验证过 M1 Pro + 待验证的 Windows |
| 长时间稳定性 | 有实际验证 | 未验证 |

举个例子，Duet 的更新日志里有这些条目：

- "Resolved a display driver crash occurring within the DXGI desktop duplication update loop"
- "Fixed an issue in the display driver path that could throttle the actual frame rate to half of the selected setting"
- "Fixed a memory leak with the Nvidia Encoder, which occurred when changing the resolution"
- "Corrected issue with image quality dropping after 5-10 minutes with host systems on AMD GPUs"

**每一条都是我们可能会撞上的坑。** 我们目前撞到了十几个，包括虚拟屏销毁、SPS/PPS 缺失、FLIP 后缓冲失效、异步 MFT 未解锁，都在 `research/REVIEW-01-code-audit.md` 里记着。

---

## 三、性能对比

### 本项目的实测数据

| 项目 | 数值 | 条件 |
|---|---|---|
| 编码耗时 | 0.078 ms/帧 | M1 Pro, 2560x1600 |
| 采集帧率 | 54.4 fps | 有动画内容 |
| 端到端延迟 | 中位 4.91 ms | 自环，编码后到解码完成 |
| 完整链路估算 | 8~26 ms | 含抓屏与呈现 |

### Duet 的公开数据

Duet 官方宣传「零延迟」「60fps retina」，但这类说法历来有夸大成分。2014 年逆向者就质疑过这点。

社区对照数据（Mirage 项目，2880x1800@60fps）：端到端中位 **19 ms**，p95 **27 ms**。

**两边的数量级是一致的，都是 20ms 上下。** 这说明 Duet 的「零延迟」是营销话术，真实的物理极限就在那里。

### 需要注意

本项目的 4.91ms 是**自环测试**，只测了「编码 → 回环 → 解码」这一段，不含抓屏和 Windows 端呈现。完整链路还没实测，因为缺 Windows 机器。

---

## 四、该选哪个

### 用 Duet 更合适的情况

- 要 iPad / iPhone / 安卓当副屏（本项目完全不支持）
- 要触摸或手写笔（画画、批注）
- 要跨公网远程
- 一套键鼠控两台机器
- 不想折腾，愿意付费换省心

### 用本项目更合适的情况

- 只要 Mac → Windows 这一种组合
- 愿意折腾，想看代码在做什么
- 局域网有线连接，追求最低延迟
- 不想订阅

### 实际差异很大的一点

Duet 是**订阅制**：Duet Air 约 $3.99/月（年付约 $48），买断 $139。

本项目免费，MIT 协议。

---

## 五、诚实的话

这个项目现在的状态是：**Mac 端验证充分，Windows 端代码写完但没在真实 Windows 上跑过。**

Duet 能卖那么多年，靠的不只是原理，是几千个细节打磨出来的稳定性。我们做的是把原理复现出来，并且拿到了不错的延迟数据，但它现在还是个原型，不是能天天依赖的工具。

如果你需要立刻能用的方案，Duet 更稳。如果你想搞清楚这件事到底是怎么做成的、并且愿意自己调，这个项目的代码可以看、可以改，比黑盒软件透明得多。
