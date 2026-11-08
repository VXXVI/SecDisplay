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
    timeout /t 1 >nul
)
echo.

taskkill /f /im SecDisplayReceiver.exe >nul 2>&1
timeout /t 1 >nul

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
echo   把上面从"SecDisplay 接收端"开始的内容整段复制发出来
echo ============================================================
pause
