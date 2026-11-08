@echo off
chcp 65001 >nul 2>&1
title SecDisplay 后台监控
setlocal enabledelayedexpansion
cd /d "%~dp0"

if not exist "SecDisplayReceiver.exe" (
    echo.
    echo   找不到 SecDisplayReceiver.exe
    echo   先运行 build.bat 或 build-mingw.bat 编译
    echo.
    pause
    exit /b 1
)

set "MAC_IP=%~1"
if "%MAC_IP%"=="" set "MAC_IP=10.10.10.1"

set "LOGDIR=%~dp0logs"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value ^| find "="') do set "TS=%%I"
set "TS=%TS:~0,8%_%TS:~8,6%"
set "LOGFILE=%LOGDIR%\monitor_%TS%.log"

echo.
echo ============================================================
echo   SecDisplay 后台监控模式
echo ============================================================
echo.
echo   Mac 地址 : %MAC_IP%:9922
echo   模式     : 全屏
echo   自动重连 : 是
echo   日志文件 : %LOGFILE%
echo.
echo   在这台机器本地操作时，可看到一个窗口显示 Mac 扩展屏。
echo   按 Esc 或关闭窗口退出。
echo.
echo   如果在远程桌面里看：窗口不会盖住桌面，可以边看日志边操作。
echo.

start "" /b cmd /c ""%~dp0SecDisplayReceiver.exe" %MAC_IP% 9922 2880 1800 --fullscreen --log "%LOGFILE%""

echo   已启动。实时日志：
echo     powershell -Command "Get-Content '%LOGFILE%' -Wait -Tail 20"
echo.

timeout /t 2 >nul

echo ============================================================
echo   实时日志（Ctrl+C 只退出日志查看，不影响接收端）
echo ============================================================
echo.
powershell -NoProfile -Command "if (Test-Path '%LOGFILE%') { Get-Content '%LOGFILE%' -Wait -Tail 30 } else { Write-Host '日志尚未生成，等一下' }"
