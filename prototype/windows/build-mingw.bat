@echo off
chcp 65001 >nul 2>&1
title SecDisplay 编译 (MSYS2 MinGW-w64)
setlocal
cd /d "%~dp0"

set "MSYS=C:\msys64"
set "GXX=%MSYS%\ucrt64\bin\g++.exe"

if not exist "%GXX%" (
    echo.
    echo   没找到 MSYS2 的 g++：%GXX%
    echo   需要先装 MSYS2 与 mingw-w64-ucrt-x86_64-gcc，
    echo   或改用 build.bat（Visual Studio 路线）。
    echo.
    pause
    exit /b 1
)

rem cc1plus.exe 在 libexec 下，PATH 里没有 ucrt64\bin 时它会加载 DLL 失败且不报错
set "PATH=%MSYS%\ucrt64\bin;%PATH%"

set "CXXFLAGS=-std=c++17 -O2 -DNDEBUG -static"
set "LIBS=-lws2_32 -ld3d11 -ldxgi -ldxguid -lmfplat -lmfreadwrite -lmfuuid -lole32 -luser32 -lgdi32"

echo.
echo ============================================================
echo   使用 MSYS2 MinGW-w64 编译
echo ============================================================
echo.

echo   [1/2] SelfCheck.exe
g++ %CXXFLAGS% SelfCheck.cpp -o SelfCheck.exe %LIBS%
if errorlevel 1 goto :failed
echo       成功

echo.
echo   [2/2] SecDisplayReceiver.exe
g++ %CXXFLAGS% SecDisplayReceiver.cpp -o SecDisplayReceiver.exe %LIBS%
if errorlevel 1 goto :failed
echo       成功

echo.
echo ============================================================
echo   全部编译成功
echo.
echo   下一步：
echo     1. 先跑 SelfCheck.exe 确认环境
echo     2. 再运行 SecDisplayReceiver.exe ^<Mac的IP^> 9922 2880 1800
echo ============================================================
echo.
pause
exit /b 0

:failed
echo.
echo   编译失败，请把上面的错误信息发出来
pause
exit /b 1
