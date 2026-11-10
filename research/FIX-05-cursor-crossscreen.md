# 光标跨屏回主屏：协议级设计（待两端协同实现）

> 状态：设计稿，尚未落地。2026-11-10 由 Windows 端根据 `research/ISSUES-2026-11-10.md`
> 的定性写出，供 Mac 侧作为实现输入。两端代码位置以 `f3027af` 为准。

## 1. 问题定性（复述，不重复论证）

用户体感「鼠标从副屏回不到 macOS 主屏」。`ISSUES-2026-11-10.md:19-42`
已定性为架构层：当前协议只实现「鼠标在副屏内移动」，没有「跨越屏幕边界回到主屏」的语义。
两端都不放行，结果鼠标被困在副屏。

## 2. 两端现状（精确代码事实）

### Mac 侧 `prototype/mac/Sources/ScreenSender.swift`

- `CursorTracker.tick`（`S:1004`，120Hz 驱动 `S:989-997`）：
  `CGEvent.location` 取全局桌面坐标（主屏左上为原点），`bounds = CGDisplayBounds(vd.displayID)`
  （`S:1136`），`rx = p.x - b.minX`、`ry = p.y - b.minY`（`S:1013-1014`），
  `inside = (rx>=0 && ry>=0 && rx<b.width && ry<b.height)`（`S:1015`），
  `visible = inside`（`S:1022`）。
- 光标包 `0x03`（`S:829-844`）：长度 18，载荷 `[u64 时间戳][f32 x][f32 y][u8 visible]`，
  直接 `c.send`，不计 inFlight。
- **离开虚拟屏时**：`rx<0`（虚拟屏通常在主屏右侧、`b.minX>0`），`inside=false`
  → 发 `visible=0`，且 rx/ry 负值照发。
- 触发条件（`S:1017-1020`）：位置差 ≥0.5px 或 `inside` 翻转才发；静止不发。
- `showsCursor=false`（`S:554`），视频帧不含光标。
- `InputInjector.handle`（`S:925-964`）：把 `0x04` 的 vx/vy 还原成全局坐标
  `p=(bounds.minX+x, bounds.minY+y)`（`S:930`），**无条件**先 post `.mouseMoved` 到 p
  （`S:933-936`），再处理按键/滚轮。每个 `0x04` 都把 Mac 光标重放回虚拟屏内。
- 断连时仅重置 `lastX/lastY/lastVisible`（`S:1006-1009`），无「断开=放行光标」语义。

### Windows 侧 `prototype/windows/SecDisplayReceiver.cpp`

- `OnCursorPacket`（`:296`）：读 rx/ry/visible，`if(!visible) return;`（`:307`）
  —— **直接丢弃离开事件**，`g_cursorX/Y` 保留旧值。
- `cursorThread`（`:1692`）：250Hz 轮询，1 秒让位守卫（本机鼠标动过就不跟随，`:1698`），
  否则按 `g_cursorX/Y` 算屏幕坐标 `SetCursorPos`（`:1716`）。旧坐标被反复钉住。
- 输入回传（`WM_MOUSEMOVE` 等 `:1244-1275`）：`ClientToVideo` 换算后 `SendInputPacket`
  发 `0x04`，Mac 据此把光标拉回副屏。
- `WM_SETCURSOR`（`:1373`）：`f3027af` 后改用 `g_customCursor`（真实 Mac 光标图像），
  无自定义时退回 IDC_ARROW。

### 协议字段现状

类型仅 `0x01` 视频 / `0x02` 请求关键帧 / `0x03` 光标位置 / `0x04` 输入 /
`0x05` 光标图像 / `0x06` 心跳。**没有表达「离开副屏 / 释放光标 / 回主屏」的字段或事件。**
`visible` 只是「指针是否在虚拟屏矩形内」的显示开关，不是离开事件。
`0x04` 是 Windows→Mac 单向重放，无 Mac→Windows 反向状态。

## 3. 根因链（为什么两端都不放行）

```
用户在副屏边缘把鼠标往主屏方向移动
  → Mac: rx<0, inside=false, 发 0x03 visible=0
  → Windows: OnCursorPacket 遇 !visible 直接 return，保留旧坐标
  → Windows cursorThread: 继续 SetCursorPos 把光标钉回旧位置
  → 用户看到指针被拽回来，再动，Windows 又发 0x04 回传
  → Mac InputInjector: 把 Mac 光标重放回虚拟屏坐标
  → 闭环，鼠标出不去
```

## 4. 设计目标与约束

- 目标：鼠标能自然从副屏边界回到 Mac 主屏，回来后再进副屏也能正常接管。
- 约束 1：**不破坏现有 `0x03` 位置链路**。版本错配时最多丢「跨屏」，位置跟随仍正常
  （沿用 `f3027af` 对 `0x05` 的兼容思路）。
- 约束 2：Windows 不应抢用户本机光标。现有 1 秒让位守卫要保留。
- 约束 3：Mac 端的 `CGEvent` 重放要有「放行」开关，不能无条件 post mouseMoved。
- 约束 4：全屏置顶窗口盖住桌面，主屏侧的鼠标操作由 Mac 自己处理，Windows 不参与。

## 5. 协议设计（建议）

### 方案 A：扩展 `0x03`，加 1 字节 `state`（推荐，改动最小）

现有 `0x03` 载荷 `[ts][x][y][visible]` 末尾追加 `u8 state`：

| state | 含义 |
|---|---|
| 0 | `inside`，正常跟随（等价旧 `visible=1`） |
| 1 | `leave`，指针离开虚拟屏边界，Windows 释放光标控制 |
| 2 | `released`，Mac 已收回光标（可选，用于确认） |

- 兼容：旧 Windows 端按 `payloadLen>=9` 读，多出的字节忽略；旧 Mac 端不发 state，
  新 Windows 端按「缺省=inside」处理。两端可独立升级。
- `leave` 触发时机：Mac `CursorTracker` 检测到 `inside` 从 true→false（`S:1018`
  已有翻转触发，正好复用），或 rx/ry 越过边界一定阈值（防抖，见 §7）。

### 方案 B：新增专用类型 `0x07` `CURSOR_LEAVE`

载荷可为空或带一个 `reason` 枚举。语义更清晰，但要占一个新类型号，
且 `NetworkLoop` 的分发（`SecDisplayReceiver.cpp:1526-1536`）要加一个分支。
方案 A 更省，本文按 A 展开，B 作为备选。

## 6. 两端协同状态机

Windows 侧维护 `cursorOwned`（bool，替代/补充 `g_cursorX<0` 这个隐含状态）：

| 事件 | Windows 动作 | Mac 动作 |
|---|---|---|
| 收到 `0x03 state=inside` + 坐标 | `cursorOwned=true`，记录坐标，cursorThread 正常 SetCursorPos | 持续采样，发位置 |
| 收到 `0x03 state=leave` | `cursorOwned=false`，`g_cursorX/Y` 置 -1，cursorThread 停止 SetCursorPos，不再发 `0x04` | 停止把 `0x04` 重放回虚拟屏；允许系统光标留在主屏 |
| `cursorOwned=false` 期间 | `WM_MOUSEMOVE` 等不映射、不回传（避免把用户主屏操作又灌回 Mac） | 光标由 macOS 自己管理 |
| 指针重新进入虚拟屏 `inside=true` | `cursorOwned=true`，恢复跟随与回传 | 恢复发位置，收到 `0x04` 时再重放 |

Mac 侧 `InputInjector` 需要对应开关：`leave` 状态下忽略 `0x04` 的 `.mouseMoved`
重放（按键/滚轮是否放行要单独定，见 §7），或由 Windows 在 `leave` 期间干脆不发
`0x04`（更简单，推荐先这样）。

## 7. 边界与防抖（必须处理，否则会抖）

- **边界判定**：虚拟屏 `bounds` 的 `minX/minY` 由 macOS 排列决定，代码里没有硬编码
  （`S:1130-1136` 是运行时 `CGDisplayBounds`）。`rx<0` 即越过左边界回主屏；
  `rx>=b.width` 是越过右边界（若虚拟屏右侧还有别的屏）。设计要按「超出矩形」
  统一处理，不要只判 `rx<0`。
- **防抖**：指针贴边时 `inside` 可能高频翻转。建议加一个滞回（hysteresis）：
  越界持续 N 毫秒（如 80ms）或位移超过 M 点（如 8pt）才发 `leave`，
  回来同理。否则会在边界反复 `leave/inside`，光标抖动。
- **DPI/坐标基准**：`e153f2c` 起坐标默认对齐物理，`0x03` 的 rx/ry 与 `--coord`
  基准要一致。跨屏判定用的是 Mac 的 `CGDisplayBounds` 点坐标，与 Windows 显示
  坐标是两套体系，`leave` 消息只带状态、不带坐标，正好避开换算。
- **断连**：连接断开时 Windows 应把 `cursorOwned=false` 放行光标（现有 `g_sock`
  清零路径可顺带做），否则 Mac 发送端挂掉后 Windows 仍钉着光标。
- **辅助功能权限**：`0x04` 重放依赖 Mac 的 TCC 授权（`research/ACCESSIBILITY.md`），
  跨屏方案不改变这个前提。

## 8. 分步落地建议

1. **Windows 端单方面可先做**（不依赖 Mac）：把 `OnCursorPacket` 的
   `if(!visible) return;` 改为「收到 leave 语义时置 `cursorOwned=false`、
   停止 SetCursorPos 与 `0x04` 回传」。当前可先把 `visible=0` 当作 leave 处理，
   作为向前兼容的第一步，风险低、立刻缓解「钉住」现象。
2. **Mac 端**：`CursorTracker` 在 `inside` 翻转时发带 state 的 `0x03`；
   `InputInjector` 在 leave 状态抑制 `.mouseMoved` 重放；加滞回防抖。
3. 两端联调：全屏下鼠标从副屏左边缘移出、回到主屏、再移回副屏，
   验证不抖、不钉、点击位置正确。
4. 版本错配回归：新旧 exe 交叉连，确认位置跟随仍工作、只是跨屏失效。

## 9. 与 `f3027af` 的关系

`f3027af` 已做「真实 Mac 光标图像」(`0x05`)，解决「还是 Windows 指针」的观感，
**未涉及跨屏**。本设计是正交的另一项，两者可并存：跨屏释放后 Windows 应把
`g_customCursor` 也停用（回退到什么都不设或 IDC_ARROW），别让自定义光标
残留在主屏侧。`0x05` 只在副屏内生效。

## 10. 需要 Mac 侧确认的点

- 虚拟屏在系统显示器排列里是主屏左侧还是右侧、`bounds.minX` 的典型量级
  （子代理只能推断，代码无显式声明）。
- `leave` 期间按键/滚轮 `0x04` 是否仍重放，还是整体抑制。
- 滞回阈值（时间/位移）取多少合适，需要真机手感调。
- 是否采用方案 A（扩展 `0x03`）或 B（新增 `0x07`）。
