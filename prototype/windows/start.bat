@echo off
chcp 65001 >nul 2>&1
title SecDisplay 副屏
cd /d "%~dp0"

if not exist "SecDisplayReceiver.exe" (
    echo.
    echo   找不到 SecDisplayReceiver.exe，先运行 build.bat 编译
    echo.
    pause
    exit /b 1
)

set "MAC_IP=%~1"
if "%MAC_IP%"=="" set "MAC_IP=10.10.10.1"

echo.
echo   SecDisplay 全屏副屏
echo   连接 %MAC_IP%:9922   分辨率 2880x1800
echo.
echo   Esc 退出    F11 或双击 切换全屏/窗口
echo.

if not exist "logs" mkdir "logs"
SecDisplayReceiver.exe %MAC_IP% 9922 2880 1800 --fullscreen --log logs\fullscreen.log

echo.
echo   已退出
pause
