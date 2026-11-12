# RESULT：自适应码率控制律模拟（2026-11-12）

> 目的：在没有 Mac 真机的情况下，用 Python 复刻 v2 控制律，验证降档试探/回退逻辑。
> 脚本：`tools/sim_rate_controller.py`
> 对应设计：`research/DESIGN-adaptive-bitrate-v2-2026-11-12.md`
> 执行提交号：`bb6c51f`

## 一、模拟场景与结果

### 场景 1：45fps 编码重载，无队列积压

信号：`captureFps=45`，`encodeMs=36ms`（帧预算 22.2ms，`encodeLoad≈1.62`），
`winQueueMs=0`，无丢帧。

```
start 82 -> end 82 Mbps
  t= 2.0s down   -> 73 Mbps health=1.62
  t=10.0s revert -> 82 Mbps health=1.62
```

结论：编码延迟与码率无关时，只降一次 10%，8 秒后回退，不会像 Phase 1 那样一路滑到 17。

### 场景 2：真实队列拥塞后恢复

信号：前 8 秒 `winQueueMs=30ms`（health=2.0），随后降到 10ms，最后 0。

```
start 82 -> end 81 Mbps
  t= 2.0s down     -> 73 Mbps health=2.00
  t= 8.0s probe-ok -> 73 Mbps health=0.67
  t=14.0s up       -> 81 Mbps health=0.67
```

结论：真实拥塞时降档被保留，队列排空后缓慢回升。这修正了 4 秒窗口下
「第二帧就回退、真实拥塞反而没降」的问题。

### 场景 3：单帧瞬时丢帧

信号：`presentDrop=1` 只出现一次。

```
start 66 -> end 66 Mbps
```

结论：单帧丢帧不再触发降档，避免 Mac 正常保实时策略造成的锯齿。

### 场景 4：静止回升

信号：`captureFps=2`，无在途、无丢帧，起始 30Mbps。

```
start 30 -> end 58 Mbps
  t= 4.0s idle-up -> 34
  t=10.0s idle-up -> 38
  t=16.0s idle-up -> 42
  t=22.0s idle-up -> 47
  t=28.0s idle-up -> 52
  t=34.0s idle-up -> 58
```

结论：静止时每 6 秒回升约 10%，不会一次跳回目标，也不会卡在低码率。

## 二、由此修正的设计

原设计观察期是 4 秒、单帧判断，模拟发现真实拥塞下队列需要更长时间排空，
会在第二帧被误判为「降档无效」并回退。

已改为：

- 观察窗口 8 秒。
- 窗口内记录最低健康度，结束时用最低值判断是否改善 ≥10%。
- 任意一帧改善 ≥10% 可提前结束观察。

Mac 代码与设计文档已同步，提交 `bb6c51f`。

## 三、局限

- 这是控制律逻辑模拟，不是 Swift 运行时，也不代表 VideoToolbox 的实际响应。
- `winQueueMs`、`presentDrop` 的真实分布需要 `--feedback` 闭环后采集。
- 真实降档/回退仍需 Mac 真机 + motionloader 验证。
