# 实测数据：端到端延迟（自环）

测试环境：MacBook Pro M1 Pro / 16GB / macOS 27.2
测试方式：同机自环，不走 Windows

---

## 一、测试方法

```
虚拟屏/内置屏
    ↓ ScreenCaptureKit 抓帧
    ↓ VideoToolbox H.264 硬编
    ↓ 打包：4字节长度 + 1字节类型 + 8字节时间戳 + AVCC 数据
    ↓ TCP 127.0.0.1:9933
    ↓ 接收 → AVCC 解析 → VTDecompressionSession 硬解
    ↓ 解码回调里计算：当前时刻 - 发送时间戳
```

时间戳在**编码输出时**打，延迟算到**解码完成时**。所以测的是「编码之后 → 解码完成」这一段，不含抓屏和最终呈现。

---

## 二、结果

内置屏 3024x1964，8 秒，366 帧：

| 指标 | 数值 |
|---|---|
| 样本数 | 362 帧 |
| 解码成功率 | 100%（0 失败）|
| 实际帧率 | 44.6 fps |
| **最小延迟** | **1.82 ms** |
| **中位延迟** | **4.91 ms** |
| p95 延迟 | 21.51 ms |
| 最大延迟 | 74.67 ms |

---

## 三、怎么读这组数据

### 中位 4.91ms 说明什么

编码 + 回环传输 + 解码，中位只要 5ms。这是**核心管线本身的速度**。

加上没测的部分，完整链路大致是：

| 阶段 | 估算 |
|---|---|
| 合成 → SCK 抓到 | 2 ~ 5 ms |
| 编码 + 传输 + 解码 | 4.9 ms（实测中位）|
| Windows 端呈现 | 1 ~ 16 ms |
| **总计** | **约 8 ~ 26 ms** |

对标物理显示器：直连显示器也有 1 帧左右的管线延迟（约 16ms @60Hz）。所以这个方案的实际手感会**非常接近直连**。

### p95 为什么是 21.51ms

尾延迟来自几个可能：
- TCP 回环偶尔的调度抖动
- 关键帧（数据量大）处理更慢
- 解码器重建

21.5ms 相当于 1.3 帧，还在可接受范围。如果放到真实网络，还会叠加网络抖动。

### 最大 74.67ms 要留意

这个尖峰通常出现在：
- 第一帧（解码器刚建好）
- 关键帧
- 系统调度让出 CPU

后续优化方向：让关键帧间隔更长、丢帧策略更果断。

### 44.6fps 而不是 60

自环测试里，抓屏、编码、解码、`needsDisplay` 重绘全在同一个进程，CPU 和 GPU 争抢。真实部署时采集在 Mac、解码在 Windows，这个瓶颈就分散开了。

---

## 四、这一轮踩过的坑（都是会复现的真问题）

### 坑 1：VT 输出的 AVCC 不含 SPS/PPS

实测验证：`VTCompressionSession` 输出的 `CMBlockBuffer` 里，**只有图像数据 NAL**，SPS/PPS 只存在于 `formatDescription` 中。

关键帧必须自己按 AVCC 格式补上参数集：
```
[SPS长度(4字节大端)][SPS][PPS长度][PPS][IDR长度][IDR]
```

早期代码漏了这步，接收端永远建不出 `CMVideoFormatDescription`，报 `-12909 kVTVideoDecoderBadDataErr`。

### 坑 2：不能用起始码切分 Annex-B

H.264 码流里天然会出现 `00 00 00 01` 字节序列（编码后的残差数据里）。如果用起始码扫描切分 NAL，会切错位置。

**正确做法：全程用 AVCC 长度前缀，不做 Annex-B 转换。**

### 坑 3：`_EnableTemporalProcessing` 会吞掉输出

解码时传这个 flag，`VTDecompressionSessionDecodeFrame` 会延迟输出到需要参考帧时才吐。对实时显示是灾难，一帧都不会回调。

**实时场景不要传这个 flag。**

### 坑 4：`objc_setAssociatedObject` 在 Swift 里会崩

`OBJC_ASSOCIATION_RETAIN` 这个宏在 Swift 里被翻译成错误的常量值。用全局变量持有对象即可。

### 坑 5：虚拟屏 `initWithDescriptor` 返回 nil

当系统里有残留虚拟屏时（崩溃导致没清理），新建会返回 nil 而不是报错。必须：
- 检查返回值
- 提示用户残留状态
- 生产代码用信号处理和 atexit 保证清理

### 坑 6：`CGVirtualDisplay` 销毁要传内部 client 指针

`CDVirtualDisplayDestroy` 要求传 `VirtualDisplayClient` 对象指针，不是 `CGVirtualDisplay` 包装对象。传错了会触发 CoreDisplay 内部断言。

正确做法：读 `CGVirtualDisplay` 的 `_client` ivar（类型 `^v`），把它传给 `CDVirtualDisplayDestroy`。

---

## 五、复现

```bash
cd prototype/mac

# 自环延迟测试（用内置屏，避免依赖虚拟屏）
swiftc -O LoopbackBuiltin.swift -o loopbackb
./loopbackb 8

# 有虚拟屏且无残留时，用完整版
swiftc -O LoopbackTest.swift -o loopback
./loopback 8
```
