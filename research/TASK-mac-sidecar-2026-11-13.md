# Mac 侧待办：Sidecar 镜像与采集目标（2026-11-13）

> 派发方：Windows 侧
> 目标端：Mac 侧
> 现象：关掉 Sidecar 时 SecDisplay 显示正常；打开 Sidecar 并选“扩展”后，Sidecar 实际镜像了 SecDisplay，Windows 端看到的还是同一份内容
> 回报：`research/RESULT-mac-sidecar-2026-11-13.md`

## 一、先确认镜像状态（不改代码）

把下面脚本存成 `tools/check_displays.swift`，在 Mac 上运行：

```swift
import CoreGraphics
import Foundation

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetOnlineDisplayList(16, &ids, &count)

for i in 0..<Int(count) {
    let id = ids[i]
    let b = CGDisplayBounds(id)
    print(String(
        format: "id=%u vendor=0x%04X model=0x%04X serial=%u bounds=%.0fx%.0f main=%d mirrorOf=%u",
        id,
        CGDisplayVendorNumber(id),
        CGDisplayModelNumber(id),
        CGDisplaySerialNumber(id),
        b.width,
        b.height,
        CGDisplayIsMain(id),
        CGDisplayMirrorsDisplay(id)
    ))
}
```

```bash
swift tools/check_displays.swift
```

判读：

- SecDisplay 虚拟屏：`vendor=0xEEEE model=0x5344 serial=1`
- `mirrorOf=0` 表示不镜像；`mirrorOf=<别的 id>` 表示这块屏正在镜像那块
- 分别记录 Sidecar 关闭时、Sidecar 打开并选“扩展”后的两次输出

## 二、现场排列（用户手动，先做这一步）

1. 系统设置 → 显示器，左侧选中 iPad/Sidecar，不要选 SecDisplay
2. “使用方式”选“扩展显示器”（Extend display）
3. 点“排列…”，把 iPad 的矩形拖到 SecDisplay 矩形外面，两块不要重叠
4. 把顶部白色菜单栏拖回内建屏，让内建屏当主屏
5. 断开 Sidecar 再重连，重新跑一次 `check_displays.swift`，确认 Sidecar 的 `mirrorOf=0`

只改“使用方式”不会移动排列图里的矩形，矩形重叠时系统仍然按镜像处理。这是本次现象的直接原因。

## 三、代码加固（发送端）

### 1. 建屏后强制解除镜像

`VirtualDisplayManager.create` 成功后补一次：

```swift
var cfgRef: CGDisplayConfigRef?
if CGBeginDisplayConfiguration(&cfgRef) == .success, let cfgRef {
    CGConfigureDisplayMirrorOfDisplay(cfgRef, vd.displayID, kCGNullDirectDisplay)
    CGCompleteDisplayConfiguration(cfgRef, .permanently)
}
```

### 2. 显示器变化后重新断言

注册重配置回调，Sidecar 插拔后检查并修正：

```swift
CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
    guard flags.contains(.after) else { return }
    // 这里只做轻量检查，真正的排列调整放到主队列，避免在回调里长时间阻塞
    DispatchQueue.main.async {
        let vdID = vd.displayID
        if CGDisplayMirrorsDisplay(vdID) != kCGNullDirectDisplay {
            var cfgRef: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&cfgRef) == .success, let cfgRef {
                CGConfigureDisplayMirrorOfDisplay(cfgRef, vdID, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(cfgRef, .permanently)
            }
        }
    }
}, nil)
```

### 3. 采集兜底加严格校验

`Capture.buildStream` 里先按 EDID 三元组找屏，找不到时退回 `wantID`。把兜底改成必须同时匹配 vendor/model，否则抛错并打印所有候选屏身份：

```swift
if target == nil {
    target = content.displays.first {
        $0.displayID == wantID &&
        CGDisplayVendorNumber($0.displayID) == kVDVendorID &&
        CGDisplayModelNumber($0.displayID) == kVDProductID
    }
}
guard let display = target else {
    // 打印 content.displays 的 id/vendor/model 后抛错，不要静默抓别的屏
    throw ...
}
```

### 4. 日志补全

启动和每次显示器重配置时打印：

- 每块屏的 id、vendor、model、serial、bounds、是否主屏、`mirrorOf`
- `抓屏已启动 displayID=X` 里的 X 是否等于 `[SELF]` 的 id

## 四、验收判据

- W1：Sidecar 关闭时，Windows 窗口显示一块独立的扩展桌面，点击能落到该桌面的窗口
- W2：Sidecar 打开并选“扩展”后，iPad 显示自己的桌面，不是 SecDisplay 的复制
- W3：`check_displays.swift` 输出里，SecDisplay 和 Sidecar 的 `mirrorOf` 都是 0
- W4：发送端日志 `抓屏已启动 displayID=` 等于 `[SELF]` 的 id
- W5：断开重连 Sidecar 两次，排列保持，不自动恢复成镜像

## 五、远程登录（只在需要 Windows 进 Mac 时做）

截图里的“远程管理”（Remote Management）是 VNC/ARD，不是 SSH，而且和“远程登录”互斥。

配置 SSH：

1. 系统设置 → 通用 → 共享
2. 关闭“远程管理”
3. 打开“远程登录”（Remote Login）
4. 允许访问选“所有用户”或指定账户

命令行：

```bash
sudo systemsetup -setremotelogin on
```

开好后 Windows 侧用 `ssh 用户名@10.10.10.1` 连接。直连地址是 `10.10.10.1`，截图里的 `192.168.1.109` 是 Wi-Fi 地址。

## 六、本轮不做

- 不改协议
- 不改 Windows 接收端（已验证单实例、解码、呈现都正常）
- 不动静止帧跳过策略（静止 2fps 是预期）
