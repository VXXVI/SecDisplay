# 修复 Sidecar 与 SecDisplay 冲突：采集抓错屏

## 现象

用户反馈「Sidecar 把 SecDisplay 认成了 Sidecar」，确认具体表现为**采集时抓错屏**：SecDisplay 抓到了 Sidecar / 别的虚拟屏的画面，或找不到目标屏。

## 现场证据（本机实测）

用 `CGGetOnlineDisplayList` + `CGDisplayVendorNumber/ModelNumber/SerialNumber` 枚举在线显示器：

| | id | vendor | product | 说明 |
|---|---|---|---|---|
| 内建 | 1 | `0x0610` | `0xa04f` | 物理 Liquid Retina XDR |
| Sidecar | 53 | `0x6161706c` (`aapl`) | `0x69506164` (`iPad`) | AirPlay |

关键事实：

1. **`CGVirtualDisplay` 与 AirPlay / Sidecar 共用同一套私有 API**。Sidecar 接入/断开会触发系统重新分配 `CGDirectDisplayID`，我们记下的 `vd.displayID` 可能失效或被复用。
2. **身份三元组能原样读回**。写进 descriptor 的 `vendorID/productID/serialNum`，用 `CGDisplayVendorNumber/ModelNumber/SerialNumber` 读回来完全一致（已实测 `0xEEEE/0x5344/0x1`）。
3. **SCDisplay.frame / CGDisplayBounds / CGDisplayPixels 对虚拟屏都是物理像素**（实测 2880x1800 屏三者均为 2880x1800）。此前「CGDisplayBounds 返回逻辑点」的推断是错的，已更正。

## 根因

`Capture.buildStream()` 的选屏逻辑过于脆弱：

```swift
// 旧代码
var target = content.displays.first(where: { $0.displayID == wantID })
if target == nil {
    target = content.displays.first(where: {
        $0.displayID != CGMainDisplayID() && $0.width == cfg.width
    })
}
```

- 主路径只信 `wantID`（创建时记下的 displayID）。Sidecar 插拔导致 id 漂移或被 AirPlay 屏复用后即失效，落到回退。
- 回退是「非主屏 + 宽度 2880」，**完全不验证身份**。现场同时存在 Sidecar、GameViewer、Duet 等多个虚拟适配器，任何 2880 宽的非主屏都会顶上来，于是抓错屏。

另有一个连带 bug：创建失败分支用 `ids.count > 1` 判断「残留虚拟屏」，但 Sidecar 在线时本来就有 2 块屏，会把正常的 Sidecar 误报成残留。

## 修复

### 1. 虚拟屏改用独占领地身份号

`ScreenSender.swift` 与 `VirtualDisplay.swift` 的 descriptor 都从旧的 `0x2B3/0x1000/1` 改为：

```
vendorID  = 0xEEEE
productID = 0x5344   ('SD')
serialNum = 0x0001
```

避开系统保留号：内建 `0x0610`(Apple)、Sidecar `aapl/iPad`。

### 2. 选屏改用 EDID 三元组锚定

新增 `isOurVirtualDisplay(id)`，`buildStream()` 优先用它遍历所有 display 精确认出自己建的屏；displayID 只作为极少数情况下的兜底。内建、Sidecar、GameViewer、Duet 都不会误命中。

### 3. 残留检测精确化

新增 `listSecDisplays()`，用三元组枚举本程序建的屏（含旧身份 `0x2B3` 的残留），替代 `ids.count > 1`。旧身份残留只用于告警，绝不作为采集目标。

### 4. 启动日志

打印所有在线显示器的 vendor/model 与 `[SELF]` 标记，现场可直接核对锚定是否命中正确、Sidecar 是否被排除。

## 验证

在「内建 + Sidecar + SecDisplay 临时虚拟屏」三块共存下实测身份筛选：

```
在线显示器总数: 3
  id=1  vendor=0x610        model=0xa04f      [内建/其它-排除]
  id=53 vendor=0x6161706c   model=0x69506164  [Sidecar-排除]
  id=55 vendor=0xeeee       model=0x5344      [命中-我们的屏]
身份锚定命中数: 1（等于新建的 55）
判定: 通过
```

临时屏跑完已干净销毁，系统恢复为内建 + Sidecar 两块，无残留。

## 升级注意

改用新身份后，若之前用旧身份 `0x2B3` 建的虚拟屏因异常退出残留，它不会被新代码识别为采集目标，也不影响新建（新身份不冲突）。启动日志会把它标出来。要彻底清掉旧残留，仍按 `reset-display-state.sh` 注销重登或重启。

## 需重新编译

`cd prototype/mac && swiftc -O Sources/ScreenSender.swift -o screensender` （或 `./run.sh restart` 自动重编）。
