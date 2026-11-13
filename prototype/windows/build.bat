@echo off
chcp 65001 >nul 2>&1
title SecDisplay 编译
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "VCVARS="

where cl >nul 2>&1
if not errorlevel 1 goto :build

for %%P in (
    "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles%\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
    "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
) do (
    if not defined VCVARS if exist %%P set "VCVARS=%%~P"
)

if not defined VCVARS (
    echo.
    echo   没找到 Visual Studio。
    echo   安装 Visual Studio 2022 社区版，勾选「使用 C++ 的桌面开发」
    echo   https://visualstudio.microsoft.com/zh-hans/downloads/
    echo.
    pause
    exit /b 1
)

echo   使用 Visual Studio: !VCVARS!
call "!VCVARS!" x64 >nul 2>&1
where cl >nul 2>&1
if errorlevel 1 (
    echo   编译器初始化失败
    pause
    exit /b 1
)

:build
echo.
echo ============================================================
echo   编译中
echo ============================================================
echo.

set FAILED=0

echo   [1/2] SelfCheck.exe
cl /nologo /EHsc /std:c++17 /O2 /utf-8 SelfCheck.cpp /Fe:SelfCheck.exe
if errorlevel 1 (
    echo       失败
    set FAILED=1
) else (
    echo       成功
)

echo.
echo   [2/2] SecDisplayReceiver.exe
rc /nologo /fo SecDisplayReceiver.res SecDisplayReceiver.rc
if errorlevel 1 (
    echo       资源编译失败
    set FAILED=1
)
cl /nologo /EHsc /std:c++17 /O2 /utf-8 SecDisplayReceiver.cpp SecDisplayReceiver.res /Fe:SecDisplayReceiver.exe
if errorlevel 1 (
    echo       失败
    set FAILED=1
) else (
    echo       成功
)

echo.
echo ============================================================
if "!FAILED!"=="1" (
    echo   有项目编译失败，请把上面的错误信息发出来
) else (
    echo   全部编译成功
    echo.
    echo   下一步：
    echo     1. 先跑 check.bat 确认环境
    echo     2. 再运行 SecDisplayReceiver.exe ^<Mac的IP^> 9922 ^<宽^> ^<高^>
)
echo ============================================================
echo.
pause
