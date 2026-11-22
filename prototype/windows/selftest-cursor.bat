@echo off
chcp 65001 >nul 2>&1
setlocal
cd /d "%~dp0"

rem 光标自检：验证晃动曲线、放大几何、叠加层显示/隐藏与重采样。
rem 不需要 Mac、不需要屏幕录制权限；但必须在「已登录的桌面会话」里运行
rem （SSH / session 0 不支持 DWM 分层窗口，会跳过窗口几何两项）。
rem 结果同时打印到控制台并写入 %TEMP%\secdisplay-selftest-cursor.log。
rem 无人值守调用请加 --no-pause，否则末尾会等待按键。

set "EXE=SecDisplayReceiver.exe"
set "NOPAUSE="
if /I "%~1"=="--no-pause" set "NOPAUSE=1"
if not exist "%EXE%" (
    echo 找不到 %EXE%，请先运行 build.bat 编译。
    if not defined NOPAUSE pause
    exit /b 1
)

echo.
echo === SecDisplay 光标自检 ===
"%EXE%" --selftest-cursor
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
    echo 结果: 通过
) else (
    echo 结果: 失败（退出码 %RC%）
)
echo 日志: %TEMP%\secdisplay-selftest-cursor.log
echo.
if not defined NOPAUSE pause
exit /b %RC%
