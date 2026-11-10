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

rem 分辨率/坐标基准必须等于 Mac 端当前预设档位的物理像素，
rem 否则解码器输入类型与 SPS 不符会持续「解码失败」。
rem 默认对应 Mac smooth(2240x1400)。切到别的档位时，在启动前设：
rem   set SECDISPLAY_W=2880
rem   set SECDISPLAY_H=1800
if not defined SECDISPLAY_W set "SECDISPLAY_W=2240"
if not defined SECDISPLAY_H set "SECDISPLAY_H=1400"

echo.
echo   SecDisplay 全屏副屏
echo   连接 %MAC_IP%:9922   分辨率 %SECDISPLAY_W%x%SECDISPLAY_H%（须与 Mac 预设档位一致）
echo.
echo   Esc / 左键托盘 / 右键菜单 / Ctrl+Alt+Q 退出    F11 或双击 切换全屏/窗口
echo.

if not exist "logs" mkdir "logs"
SecDisplayReceiver.exe %MAC_IP% 9922 %SECDISPLAY_W% %SECDISPLAY_H% --fullscreen --log logs\fullscreen.log

echo.
echo   已退出
pause
