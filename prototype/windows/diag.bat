@echo off
chcp 65001 >nul 2>&1
title SecDisplay 一键诊断
cd /d "%~dp0"

if not exist "SecDisplayReceiver.exe" (
    echo.
    echo   先运行 build.bat 编译
    echo.
    pause
    exit /b 1
)

set "MAC_IP=%~1"
if "%MAC_IP%"=="" set "MAC_IP=10.10.10.1"

if not exist "logs" mkdir "logs"
del /q "logs\diag.log" 2>nul

echo.
echo ============================================================
echo   即将全屏运行 20 秒，请在这段时间里做这些操作：
echo.
echo     1. 鼠标在副屏上来回移动 5 秒
echo     2. 打开一个网页，上下滚动 5 秒
echo     3. 拖动一个窗口 5 秒
echo     4. 静止 5 秒
echo.
echo   20 秒后会自动退出并打印日志。
echo ============================================================
echo.
pause

start "" /b cmd /c ""%~dp0SecDisplayReceiver.exe" %MAC_IP% 9922 2880 1800 --fullscreen --log "%~dp0logs\diag.log""

echo   倒计时：
for /l %%i in (20,-1,1) do (
    <nul set /p "=%%i "
    ping -n 2 127.0.0.1 >nul
)
echo.

taskkill /f /im SecDisplayReceiver.exe >nul 2>&1
ping -n 2 127.0.0.1 >nul

echo.
echo ============================================================
echo   诊断日志
echo ============================================================
echo.
if exist "logs\diag.log" (
    type "logs\diag.log"
) else (
    echo   没有生成日志，说明程序根本没启动成功
)
echo.
echo ============================================================
echo   自动上传脱敏指标（不用你复制日志）
echo ============================================================
set "REPO=%~dp0..\.."
for %%i in ("%REPO%") do set "REPO=%%~fi"
del /q "%TEMP%\secdisplay-diag-win.json" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\extract_telemetry.ps1" ^
    -Log "%~dp0logs\diag.log" -Out "%TEMP%\secdisplay-diag-win.json" -Commit "unknown" 2>nul
if exist "%TEMP%\secdisplay-diag-win.json" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\..\tools\push_telemetry.ps1" ^
        -Json "%TEMP%\secdisplay-diag-win.json" -Platform win -RepoRoot "%REPO%" 2>nul
    echo   指标已提交到 telemetry/win/（只含数值，无 IP / 无原始日志 / 无主机名）
) else (
    echo   未生成指标文件，跳过上传
)
echo.
pause
