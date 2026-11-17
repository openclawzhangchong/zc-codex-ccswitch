# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for CodexBridge.exe.

单文件 exe，两种角色（托盘 / --bridge 桥接）。webui.html 作为数据内嵌；
config/.env/routes 等可写状态由 bridge_app.py 放到 exe 旁 bridge-data/。
"""
from PyInstaller.utils.hooks import collect_data_files, collect_submodules

datas = [('webui.html', '.'), ('model_catalog_template.json', '.')]
hiddenimports = []
for mod in ('uvicorn', 'fastapi', 'httpx', 'pystray', 'PIL', 'click', 'anyio'):
    hiddenimports += collect_submodules(mod)

a = Analysis(
    ['bridge_app.py'],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'numpy', 'pytest'],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='CodexBridge',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,               # Windows Defender 易误报 UPX 压缩的 exe
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,           # 无控制台窗口（托盘应用）
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=None,
)
