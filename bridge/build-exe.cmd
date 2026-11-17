@echo off
REM ============================================================
REM  CodexBridge.exe 一键打包脚本（Windows）
REM
REM  用法：双击本文件，或命令行 build-exe.cmd
REM  产物：exe\CodexBridge.exe （单文件，双击即用）
REM
REM  流程：建 venv -> 装依赖+PyInstaller -> 按 spec 打包 -> 复制到 exe\
REM ============================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "VENV=%~dp0.venv-build"
set "PY=%VENV%\Scripts\python.exe"

echo [信息] CodexBridge.exe 打包开始

if not exist "%PY%" (
    echo [信息] 创建独立构建环境: %VENV%
    python -m venv "%VENV%"
    if errorlevel 1 goto :fail
)

echo [信息] 安装依赖（首次较慢，需联网）...
"%PY%" -m pip install --disable-pip-version-check -q ^
    "fastapi>=0.115.0" "uvicorn>=0.30.0" "httpx>=0.27.0" ^
    "pystray>=0.19.0" "Pillow>=10.0.0" pyinstaller
if errorlevel 1 goto :fail

echo [信息] PyInstaller 打包中（约 1-3 分钟）...
if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
"%PY%" -m PyInstaller --noconfirm --clean CodexBridge.spec
if errorlevel 1 goto :fail

echo [信息] 复制产物...
if not exist exe mkdir exe
copy /y dist\CodexBridge.exe exe\CodexBridge.exe >nul
if errorlevel 1 goto :fail

echo [成功] 完成: %~dp0exe\CodexBridge.exe
echo [提示] 把 exe 放到任意目录双击即可；配置在同目录 bridge-data\
goto :end

:fail
echo [错误] 打包失败，请查看上方输出。
exit /b 1

:end
endlocal
