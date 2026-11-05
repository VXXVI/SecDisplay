// RequestPermission.swift
// 触发屏幕录制权限申请。系统只会弹一次，之后需要在设置里手动勾选。
import Foundation
import CoreGraphics
import AppKit
import Darwin

setvbuf(stdout, nil, _IONBF, 0)

// CGPreflightScreenCaptureAccess 检查是否已授权，CGRequestScreenCaptureAccess 触发弹窗
let granted = CGPreflightScreenCaptureAccess()
print("当前屏幕录制权限: \(granted ? "已授权" : "未授权")")

if !granted {
    print("发起权限申请...")
    let ok = CGRequestScreenCaptureAccess()
    print("申请结果: \(ok)")
    print("如果刚才没有弹窗，说明之前拒绝过，需要手动到：")
    print("  系统设置 → 隐私与安全性 → 屏幕录制 → 勾选运行本程序的终端")
    print("勾选后需要完全退出终端再重新打开。")
}

exit(granted ? 0 : 1)
