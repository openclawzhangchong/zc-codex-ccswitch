#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Codex Bridge 统一入口：一个 exe 两种角色。

    CodexBridge.exe            # 托盘 + WebUI(:8789) + 自动拉起桥接(:8787)
    CodexBridge.exe --bridge   # 仅跑桥接进程（由上面的主进程拉起）
    CodexBridge.exe --console  # 带控制台跑托盘（调试用）

冻结为 exe 后，Python 源码在只读的 sys._MEIPASS；所有可写状态（config.json、
.env、pid、日志、routes.json）放到 exe 同级的 bridge-data/。源码模式（直接
python bridge_app.py）保持原行为——数据目录就是源码目录。

之所以做成单 exe 双角色而不是两个 exe：托盘要能拉起桥接，桥接崩溃后要能重启；
让同一 exe 用 --bridge 参数自检，打包/分发只需一个文件。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path


def _source_dir() -> Path:
    """Python 源码所在目录：冻结时在 _MEIPASS，源码模式时是本文件目录。"""
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS"))
    return Path(__file__).resolve().parent


def _data_dir() -> Path:
    """可写数据目录：冻结时 exe 同级 bridge-data/；源码模式随源码目录。"""
    override = os.environ.get("BRIDGE_DATA_DIR")
    if override:
        d = Path(override).resolve()
    elif getattr(sys, "frozen", False):
        d = Path(sys.executable).resolve().parent / "bridge-data"
    else:
        d = Path(__file__).resolve().parent
    d.mkdir(parents=True, exist_ok=True)
    return d


# 必须先设置环境变量，再导入会读它的模块。
DATA = _data_dir()
os.environ["BRIDGE_DATA_DIR"] = str(DATA)
SOURCE = _source_dir()
sys.path.insert(0, str(SOURCE))

# 首次运行：从内置模板初始化可写配置（不覆盖用户已有配置）。
GENERIC_ENV = """# 上游 Chat Completions 网关（改成你自己的）
UPSTREAM_BASE_URL=http://127.0.0.1:7863/v1
UPSTREAM_API_KEY=replace-with-your-api-key
DEFAULT_MODEL=deepseek-v4.1-flash
HOST=127.0.0.1
PORT=8787
SANITIZE_PROMPT=1
"""
GENERIC_CONFIG = """{
  "providers": [
    {
      "id": "default",
      "name": "我的网关",
      "base_url": "http://127.0.0.1:7863/v1",
      "api_key": "replace-with-your-api-key",
      "model": "deepseek-v4.1-flash",
      "notes": "首次运行请在管理界面改成你的网关地址和 Key"
    }
  ],
  "active": "default",
  "sanitize_prompt": true,
  "host": "127.0.0.1",
  "port": 8787
}
"""
GENERIC_ROUTES = """{
  "default": {"base_url": "http://127.0.0.1:7863/v1", "api_key": "replace-with-your-api-key"},
  "routes": []
}
"""


def _init_data() -> None:
    for name, content in (("config.json", GENERIC_CONFIG),
                          (".env", GENERIC_ENV),
                          ("routes.json", GENERIC_ROUTES)):
        f = DATA / name
        if not f.exists():
            f.write_text(content, encoding="utf-8")


def main() -> None:
    _init_data()
    args = sys.argv[1:]
    if "--bridge" in args:
        import api2codex
        api2codex.main()
    else:
        # 托盘会自己拉起桥接并启动 WebUI；--console/--no-webui 等参数由 tray 解析。
        import tray
        tray.main()


if __name__ == "__main__":
    main()
