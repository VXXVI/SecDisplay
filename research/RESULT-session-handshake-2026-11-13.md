# RESULT：会话头自动对齐分辨率（2026-11-13）

- 对应任务：用户直接指派，非 TASK 单
- 执行端：Windows
- 提交：`3bcf270`（会话头、config.ini、.app 打包、孤儿清理）
- 文档补充：计划任务电池设置（同分支后续提交）

## 改了什么

### 协议

`0x06` 从空载荷心跳扩展为两种形态，靠长度区分：

- 9 字节：旧版心跳，接收端忽略
- 16 字节：会话头 `[version u8][width u16][height u16][fps u8][reserved u8]`，全大端

Mac 连接建立后立即发一次，之后每 5 秒补发一次。旧接收端只认视频帧，多出来的 0x06 载荷会被直接忽略，两端可以各自升级。

### Windows

- 收到会话头且尺寸与当前管线不同时，断开重连，在渲染线程退出后 `ResizeBuffers` 重建交换链，同步更新坐标基准与窗口宽高比
- `config.ini` 免参数启动，命令行参数优先；带 UTF-8 BOM 也能读
- 交换链改尺寸失败的尺寸不反复重试，避免重连风暴

### Mac

- `Sender` 新增 `sendSessionInfo()`，连接 start 之后立即发送，之后每 5 秒补发
- `build_app.sh` 生成 `.app`，优先用本机 Apple Development 证书签名，没有则退回 ad-hoc
- `.app` 模式下日志写 `~/Library/Logs/SecDisplay/sender.log`
- 启动前可选清理残留虚拟屏：`--cleanup-orphan` 或 `SECDISPLAY_CLEANUP_ORPHAN=1`

## Windows 侧验证

| 场景 | 结果 |
|---|---|
| 假发送端发 1600x1000 会话头，接收端按 2880x1800 启动 | 日志出现会话头、断开重连、交换链切到 1600x1000，第二次连接不再重建 |
| 假发送端只发 9 字节心跳 | 接收端保持 1280x800，不重建 |
| config.ini（含 UTF-8 BOM） | host/port/宽高/日志路径全部生效 |
| 编译 | `build.bat` 全部成功 |

## Mac 侧待办（未验证）

1. `git pull` 到最新 main，`cd prototype/mac && swiftc -O Sources/ScreenSender.swift -o screensender` 确认编译通过
2. 启动后看发送端日志是否正常，Windows 端日志应出现 `会话头: 协议 v1 ...`
3. `preset.sh` 切档后确认 Windows 端自动跟随，不需要再改参数
4. `./build_app.sh` 生成 `.app`，确认屏幕录制授权与日志路径

## 已知边界

- 会话头每 5 秒重发，旧接收端忽略未知 0x06 载荷，两端可各自升级
- 交换链改尺寸失败时保持旧尺寸，画面由 VideoProcessor 裁边或缩放，不黑屏
- 残留虚拟屏清理会黑屏几秒，只在显式设置时执行
- Windows 计划任务默认 `DisallowStartIfOnBatteries=True`，用电池时任务会一直排队，注册后需改掉，已写入 `WINDOWS-AGENT-PROMPT.md`
