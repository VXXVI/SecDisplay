@echo off
chcp 65001 >nul 2>&1
title SecDisplay 无人值守遥测安装
setlocal
cd /d "%~dp0"

set "REPO=%~dp0..\.."
for %%i in ("%REPO%") do set "REPO=%%~fi"
set "TOOLS=%REPO%\tools"

if /i "%~1"=="remove" goto :remove

echo.
echo ============================================================
echo   安装 Windows 端无人值守遥测（每 5 分钟一次）
echo   只从运行日志读脱敏指标，不抢全屏、不动光标
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0telemetry_win_loop.ps1\" -RepoRoot \"%REPO%\"';" ^
  "$t = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650);" ^
  "$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -Hidden;" ^
  "$p = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited;" ^
  "Register-ScheduledTask -TaskName 'SecDisplayTelemetry' -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null;" ^
  "Write-Output '已注册计划任务 SecDisplayTelemetry'"

if errorlevel 1 (
    echo   注册失败，请用管理员身份运行本脚本
) else (
    echo.
    echo   完成。手动触发一次：
    echo     schtasks /run /tn "SecDisplayTelemetry"
    echo   卸载：
    echo     "%~f0" remove
)
echo.
pause
exit /b 0

:remove
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Unregister-ScheduledTask -TaskName 'SecDisplayTelemetry' -Confirm:$false -ErrorAction SilentlyContinue;" ^
  "Write-Output '已卸载 Windows 遥测任务'"
echo.
pause
exit /b 0
