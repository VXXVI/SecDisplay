# 研究结果：不注销、不重启 WindowServer 清理孤儿虚拟屏

日期：2026-11-12
环境：macOS 27.2 (26B123)，Apple M1 Pro，WindowServer PID 470
结论：**找到可行方法，且已在真机四次端到端复现**。

## 一句话方法

```
pmset displaysleepnow      # 显示器休眠
sleep 6
caffeinate -u -t 3         # 强制唤醒
```

休眠加唤醒触发 WindowServer 完整显示重配置，owner 已死的虚拟显示设备在重配置中被清除。
用户会话不注销（`who` 显示 console 会话自 11 月 10 日一直未断），远程连接不受影响。

## 孤儿屏判定依据

1. `CGGetOnlineDisplayList` 枚举到非内建屏，`vendor=0xEEEE model=0x5344`（三元组精确匹配，含 serial）。
2. `pgrep -fl` 确认发送端进程不存在。
3. 旁证（上次 NIGHTLY 记录）：同身份 `CGVirtualDisplay initWithDescriptor:` 返回 nil，
   连 vendor/product 相同但 serial 不同的 descriptor 都被拒。WindowServer 按 vendor+product 查重，
   孤儿占了身份。

复现手段（本次研究用）：`/tmp/orphan_make3.swift` 创建 0xEEEE/0x5344 虚拟屏，applySettings
成功（id=44/45/49），观察在线 4 秒后 `kill(getpid(), SIGKILL)`，屏即成孤儿，稳定残留。

## 尝试过的路径与证据

| 路径 | 结果 | 证据 |
|---|---|---|
| `CDVirtualDisplayDestroy(_client)` | 对孤儿无效。孤儿没有本进程的 client 对象 | 反汇编 `CDVirtualDisplayDestroy`（CoreDisplay offset 0x514C）：入口做 `isKindOfClass:[VirtualDisplayClient class]` 断言，之后只操作本进程对象 |
| `SL2CDVirtualDisplayDestroy(36)`（按 displayID 直调） | 无效，孤儿不在本进程 CGXVirtualDisplay 表 | 反汇编 `CGXVirtualDisplayDestroy`（0x18ac7ccd0）：按 displayID 查本地表，找不到打 `exit VirtualDisplay(%s) displayID(0x%x) not found` 后直接返回。实测调用返回后孤儿仍在 |
| 同身份（同 vendor/product，异 serial）重建覆盖 | 创建被拒，拿不到对象 | `trydiff2`：`initWithDescriptor:` 返回 nil |
| 不同身份创建再销毁 | 成功但与孤儿无关 | `tryother`：0xABCD/0x1234 创建 id=38，destroy 正常。证明拒绝只针对同身份 |
| `CGXBroadcastDisplayChangeNotificationsAsNeeded` | 无效（且崩溃 SEGV） | `tryb` 退出码 139，孤儿仍在 |
| `CGConfigureDisplayMirrorOfDisplay` 孤儿 mirror 主屏 | complete 返回 1014，被拒 | `trymirror2/3`。可能因屏幕休眠，未深究 |
| `CGXActivateDisplays` | SEGV，需特权连接 | `tryact` 退出码 139 |
| `SLVirtualDisplay initWithConfiguration:error:`（SkyLight 新包装） | 进程挂死（10s 超时），与孤儿无关（其它身份也挂） | `slp4/5/6`。疑似需要 entitlement 或主线程 runloop，放弃 |
| `DisplayServices.framework` | 无虚拟显示相关导出 | `dyld_info -exports` 全部 55 个符号均为亮度/电源类 |
| SkyLight `SLSBringAirDisplayOffline` | AirPlay 专用，针对 connection 不针对单屏 | 反汇编 `CGXAirDisplayOffline`（0x18ac7d130）：调 `airdisplay_offline(CGXConnection*)`，绑 `airdisplay_connection_death` 回调，不适用 |
| **`pmset displaysleepnow` + 唤醒** | **有效，四次复现全成功** | 见下 |

### 清理验证时间线

| 孤儿 | 制造 | 清理动作 | 结果 |
|---|---|---|---|
| id=36 serial=77 | SIGKILL owner | mirror 尝试失败后自然唤醒屏幕 | 消失 |
| id=44 serial=79 | SIGKILL owner | displaysleepnow + caffeinate -u | 消失 |
| id=45 serial=79 | SIGKILL owner | displaysleepnow + caffeinate -u | 消失 |
| id=46 serial=77 | adopt2 未销毁退出 | displaysleepnow + caffeinate -u | 消失 |
| id=49 serial=79 | SIGKILL owner | 工具脚本 `--apply --verify` | 消失，重建验证通过 |

清理后同身份重建立即恢复（`adopt2` serial=77 创建成功 displayID=46）。

## 可用方法使用步骤

```
# 1. 确认孤儿（vendor/model 按 SecDisplay 实际值）
pgrep -fl screensender          # 确认发送端没在跑
prototype/mac/cleanup_orphan_vdisplay --vendor 0xEEEE --product 0x5344   # dry-run

# 2. 执行清理（含同身份重建验证）
prototype/mac/cleanup_orphan_vdisplay --vendor 0xEEEE --product 0x5344 --apply --verify
```

脚本：`prototype/mac/cleanup_orphan_vdisplay.swift`（编译产物同目录）。
支持 `--vendor/--product` 过滤、dry-run（默认）、`--apply`、`--verify`。
退出码：0 无孤儿或清理成功；1 dry-run 发现孤儿；2 清理后仍在线；3 参数错误。

二进制版手动等价命令：

```
pmset displaysleepnow && sleep 6 && caffeinate -u -t 3 && sleep 3
```

## 未验证 / 风险项

- **owner 存活判定不可自动化**：WindowServer 不导出"虚拟屏 owner pid"给普通进程。
  脚本只做身份过滤，需要人工确认没有发送端在跑再 `--apply`。带 owner 的屏被
  休眠唤醒后大概率仍保留（未测：owner 活着的屏经过休眠唤醒是否会被误清，理论不会，
  因为 owner 还能应答，但没有验证）。
- **休眠唤醒的副作用**：外接显示器拓扑、锁屏状态、正在播放的音视频会受一次显示休眠
  影响。远程场景下远程管理会话（VMM/向日葵类）如依赖持续亮屏需自行确认。
- `caffeinate -u` 是通过用户断言唤醒，无 root 需求；`pmset displaysleepnow` 同样无 root。
- 未验证 macOS 更早版本（此方法在 27.2 验证，老版本 WindowServer 行为可能不同）。
- 未验证多个孤儿并存场景（预计同样被清，本轮最多一次一个）。
- 未能确认 WindowServer 清理的具体触发条件（完整重配置 vs 唤醒过程中的 dead-name
  重发）。如果发现偶发清不掉，可再追加一次休眠唤醒循环。

## 研究过程附注

- CoreDisplay 导出符号清单、`VirtualDisplayClient`（unplug/proxyGone）、`SLVirtualDisplay`
  类方法 dump 等原始探测脚本在 `/tmp`（clsprobe/selp2/slp2/cdprobe2 等），未入库。
- 之前 NIGHTLY-2026-11-10 里"只能注销重登"的结论不完整：当时没试休眠唤醒循环。
  `reset-display-state.sh` 的指导建议需要同步更新。
