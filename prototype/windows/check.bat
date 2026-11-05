@echo off
chcp 65001 >nul 2>&1
title SecDisplay 环境自检
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "MAC_IP=%~1"

echo.
echo ============================================================
echo   SecDisplay 环境自检
echo ============================================================
echo.

:: ===========================================================================
:: 第一部分：系统命令直接查，不需要编译器
:: ===========================================================================

echo ------------------------------------------------------------
echo  [1/4] 屏幕与显卡
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "$vc = Get-CimInstance Win32_VideoController; foreach ($v in $vc) { Write-Host ('  显卡      : ' + $v.Name); Write-Host ('  驱动版本  : ' + $v.DriverVersion + ' (' + $v.DriverDate + ')'); if ($v.CurrentHorizontalResolution) { Write-Host ('  当前分辨率: ' + $v.CurrentHorizontalResolution + ' x ' + $v.CurrentVerticalResolution + ' @ ' + $v.CurrentRefreshRate + ' Hz') -ForegroundColor Green } }"

powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -AssemblyName System.Windows.Forms; $s = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $dpi = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI; Write-Host ('  逻辑分辨率: ' + $s.Width + ' x ' + $s.Height); if ($dpi) { Write-Host ('  DPI 缩放  : ' + [math]::Round($dpi/96*100) + '%') }"

echo.
echo ------------------------------------------------------------
echo  [2/4] 硬件解码能力
echo ------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command "$out = Join-Path $env:TEMP 'secdisplay_dx.txt'; if (Test-Path $out) { Remove-Item $out -Force }; Start-Process dxdiag -ArgumentList '/t', $out -Wait -WindowStyle Hidden; if (Test-Path $out) { $c = Get-Content $out; $ddi = $c | Select-String -Pattern 'DDI Version' | Select-Object -First 1; if ($ddi) { Write-Host ('  ' + $ddi.Line.Trim()) }; $h = $c | Select-String -Pattern 'H264|H\.264'; if ($h) { Write-Host '  [OK] 检测到 H.264 硬件解码' -ForegroundColor Green } else { Write-Host '  dxdiag 未列出 H.264（不代表不支持）' }; Remove-Item $out -Force -ErrorAction SilentlyContinue } else { Write-Host '  dxdiag 未生成报告，跳过' }"

echo.
echo ------------------------------------------------------------
echo  [3/4] 编译工具链
echo ------------------------------------------------------------
set "HAVE_CL=0"
set "VCVARS="

where cl >nul 2>&1
if not errorlevel 1 (
    set "HAVE_CL=1"
    echo   [OK] PATH 中已有 cl 编译器
    goto :toolchain_done
)

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

if defined VCVARS (
    echo   [OK] 找到 Visual Studio
    call "!VCVARS!" x64 >nul 2>&1
    where cl >nul 2>&1
    if not errorlevel 1 (
        set "HAVE_CL=1"
        echo   [OK] 编译器已就绪
    )
) else (
    echo   [注意] 没找到 Visual Studio
    echo.
    echo   无法编译 SelfCheck.exe 和接收端。
    echo   需要安装 Visual Studio 2022 社区版，勾选「使用 C++ 的桌面开发」。
    echo   下载: https://visualstudio.microsoft.com/zh-hans/downloads/
    echo.
    echo   上面的硬件信息仍然有效，可以先记录。
)

:toolchain_done

echo.
echo ------------------------------------------------------------
echo  [4/4] C++ 深度自检
echo ------------------------------------------------------------
if "!HAVE_CL!" NEQ "1" (
    echo   [跳过] 没有编译器
    goto :summary
)

echo   正在编译 SelfCheck.cpp ...
cl /nologo /EHsc /std:c++17 /O2 SelfCheck.cpp /Fe:SelfCheck.exe >nul 2>&1
if errorlevel 1 (
    echo   [失败] 编译出错
    echo   去掉 /nologo 再跑一次能看到具体错误：
    echo     cl /EHsc /std:c++17 /O2 SelfCheck.cpp
    goto :summary
)
echo   [OK] 编译成功
echo.

if defined MAC_IP (
    SelfCheck.exe %MAC_IP%
) else (
    SelfCheck.exe
    echo.
    echo   提示：要测到 Mac 的网络连通性，这样运行
    echo     check.bat 192.168.77.1
)

:summary
echo.
echo ============================================================
echo   完成
echo ============================================================
echo.
echo   把上面的「当前分辨率」填进 Mac 端 ScreenSender.swift：
echo     var width  = 上面显示的宽度
echo     var height = 上面显示的高度
echo     var logicalWidth  = 与 width 相同（1:1 最清晰）
echo     var logicalHeight = 与 height 相同
echo.
pause
