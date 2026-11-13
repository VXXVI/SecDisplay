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

rem 分辨率只是「初始提示」，不再需要和 Mac 预设档位严格一致。
rem 新版接收端会从码流 SPS 解出真实宽高并据此协商解码器与交换链，
rem 与这里不一致时会自动重建管线，日志打「按 SPS 更新编码尺寸」。
rem 想固定某个初始窗口尺寸再设 SECDISPLAY_W / SECDISPLAY_H。
if not defined SECDISPLAY_W set "SECDISPLAY_W=2240"
if not defined SECDISPLAY_H set "SECDISPLAY_H=1400"

echo.
echo   SecDisplay 全屏副屏
echo   连接 %MAC_IP%:9922   初始尺寸 %SECDISPLAY_W%x%SECDISPLAY_H%（实际以码流为准）
echo.
echo   Esc / 左键托盘 / 右键菜单 / Ctrl+Alt+Q 退出    F11 或双击 切换全屏/窗口
echo.

if not exist "logs" mkdir "logs"
SecDisplayReceiver.exe %MAC_IP% 9922 %SECDISPLAY_W% %SECDISPLAY_H% --fullscreen --log logs\fullscreen.log

echo.
echo   已退出
pause
