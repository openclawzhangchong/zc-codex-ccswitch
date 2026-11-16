"""Windows tray icon for the Codex bridge.

Starts/stops the bridge, opens the management WebUI, and can register itself to
run at logon. The icon colour reflects bridge state.

    pythonw tray.py            # start in the tray, no console window
    python tray.py --console   # keep a console for debugging

Bridges on 127.0.0.1 only; nothing here listens on a public interface.
"""

from __future__ import annotations

import argparse
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

import pystray
from PIL import Image, ImageDraw, ImageFont

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE))

from config_store import ConfigStore  # noqa: E402

CONFIG_PATH = BASE / "config.json"
BRIDGE_PIDFILE = BASE / ".bridge.pid"
WEBUI_PIDFILE = BASE / ".webui.pid"
ENV_PATH = BASE / ".env"
LAUNCHER = BASE / "start-bridge.cmd"
WEBUI_PORT = 8789
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_NAME = "CodexBridgeTray"


# --------------------------------------------------------------------------
# State helpers
# --------------------------------------------------------------------------
def _pid_alive(pid: int) -> bool:
    # Chinese Windows emits GBK from tasklist; decoding it as UTF-8 raises and
    # a crash here takes the tray down before it can draw an icon.
    out = subprocess.run(
        ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
        capture_output=True, text=True, errors="replace",
    )
    return str(pid) in (out.stdout or "")


def _port_open(host: str, port: int, timeout: float = 0.4) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def load_config() -> ConfigStore:
    try:
        return ConfigStore(CONFIG_PATH)
    except Exception:
        # A corrupt config should not prevent the tray from starting - the user
        # needs the menu in order to fix it.
        return ConfigStore.__new__(ConfigStore)


def bridge_status() -> tuple[bool, int | None]:
    if BRIDGE_PIDFILE.exists():
        try:
            pid = int(BRIDGE_PIDFILE.read_text().strip())
        except ValueError:
            pid = None
        if pid and _pid_alive(pid):
            return True, pid
    try:
        cfg = load_config()
        host = getattr(cfg, "_data", {}).get("host", "127.0.0.1")
        port = getattr(cfg, "_data", {}).get("port", 8787)
    except Exception:
        host, port = "127.0.0.1", 8787
    return _port_open(host, port), None


def webui_status() -> tuple[bool, int | None]:
    if WEBUI_PIDFILE.exists():
        try:
            pid = int(WEBUI_PIDFILE.read_text().strip())
        except ValueError:
            pid = None
        if pid and _pid_alive(pid):
            return True, pid
    return _port_open("127.0.0.1", WEBUI_PORT), None


# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------
def _spawn(args: list[str], pidfile: Path, cwd: Path) -> int:
    pythonw = Path(sys.executable).with_name("pythonw.exe")
    exe = pythonw if pythonw.exists() else Path(sys.executable)
    flags = 0
    if os.name == "nt":
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
    proc = subprocess.Popen(
        [str(exe)] + args, cwd=str(cwd),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=flags,
    )
    pidfile.write_text(str(proc.pid))
    return proc.pid


def start_webui() -> bool:
    running, _ = webui_status()
    if running:
        return True
    try:
        _spawn(["webui.py", "--port", str(WEBUI_PORT)], WEBUI_PIDFILE, BASE)
    except Exception:
        return False
    for _ in range(20):
        if _port_open("127.0.0.1", WEBUI_PORT):
            return True
        time.sleep(0.4)
    return False


def stop_webui() -> None:
    running, pid = webui_status()
    if running and pid:
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
    WEBUI_PIDFILE.unlink(missing_ok=True)


def start_bridge() -> bool:
    running, _ = bridge_status()
    if running:
        return True
    if not LAUNCHER.exists():
        return False
    # The launcher reads .env into the environment; api2codex itself does not
    # parse .env, so going through it matters.
    subprocess.Popen(
        ["cmd", "/c", str(LAUNCHER)],
        cwd=str(BASE), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS,
    )
    cfg = load_config()
    host = getattr(cfg, "_data", {}).get("host", "127.0.0.1")
    port = getattr(cfg, "_data", {}).get("port", 8787)
    for _ in range(24):
        if _port_open(host, port):
            return True
        time.sleep(0.5)
    return False


def stop_bridge() -> None:
    running, pid = bridge_status()
    if running and pid:
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
    else:
        # No pidfile: find the process by its command line rather than killing
        # every python on the machine.
        out = subprocess.run(
            ["wmic", "process", "where",
             "name like '%python%' and commandline like '%api2codex%'",
             "get", "processid", "/format:value"],
            capture_output=True, text=True,
        )
        for line in out.stdout.splitlines():
            line = line.strip()
            if line.isdigit():
                subprocess.run(["taskkill", "/PID", line, "/F"], capture_output=True)
    BRIDGE_PIDFILE.unlink(missing_ok=True)
    time.sleep(1.0)


def open_webui(_icon=None, _item=None) -> None:
    if start_webui():
        webbrowser.open(f"http://127.0.0.1:{WEBUI_PORT}/")
    else:
        notify("无法启动管理界面")


def autostart_enabled() -> bool:
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            winreg.QueryValueEx(key, RUN_NAME)
            return True
    except OSError:
        return False


def set_autostart(enable: bool) -> None:
    import winreg
    pythonw = Path(sys.executable).with_name("pythonw.exe")
    exe = pythonw if pythonw.exists() else Path(sys.executable)
    cmd = f'"{exe}" "{BASE / "tray.py"}"'
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as key:
        if enable:
            winreg.SetValueEx(key, RUN_NAME, 0, winreg.REG_SZ, cmd)
        else:
            try:
                winreg.DeleteValue(key, RUN_NAME)
            except FileNotFoundError:
                pass


# --------------------------------------------------------------------------
# Icon rendering
# --------------------------------------------------------------------------
def make_icon(running: bool) -> Image.Image:
    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    color = (34, 197, 94, 255) if running else (120, 128, 140, 255)
    d.ellipse((4, 4, size - 4, size - 4), fill=color)
    d.ellipse((10, 10, size - 10, size - 10), fill=(15, 17, 21, 255))
    d.ellipse((20, 20, size - 20, size - 20), fill=color)
    return img


ICON = {"img": None}


# --------------------------------------------------------------------------
# Tray
# --------------------------------------------------------------------------
def notify(msg: str, title: str = "Codex 桥接") -> None:
    try:
        ICON["img"].notify(msg, title)
    except Exception:
        pass


def refresh_icon() -> None:
    running, _ = bridge_status()
    ICON["img"].icon = make_icon(running)
    ICON["img"].title = "Codex 桥接 — " + ("运行中" if running else "已停止")
    ICON["img"].update_menu()


def toggle_bridge(_icon=None, _item=None) -> None:
    running, _ = bridge_status()
    if running:
        stop_bridge()
        notify("桥接已停止")
    else:
        ok = start_bridge()
        notify("桥接已启动" if ok else "启动失败，检查 .env 和上游地址")
    refresh_icon()


def restart_bridge(_icon=None, _item=None) -> None:
    stop_bridge()
    ok = start_bridge()
    notify("桥接已重启" if ok else "重启失败")
    refresh_icon()


def toggle_autostart(_icon=None, _item=None) -> None:
    want = not autostart_enabled()
    try:
        set_autostart(want)
        notify("已设为开机启动" if want else "已取消开机启动")
    except Exception as exc:
        notify(f"设置失败：{exc}")
    ICON["img"].update_menu()


def quit_tray(_icon=None, _item=None) -> None:
    stop_webui()
    ICON["img"].stop()


def build_menu() -> pystray.Menu:
    running, _ = bridge_status()
    return pystray.Menu(
        pystray.MenuItem("打开管理界面", open_webui, default=True),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(
            "停止桥接" if running else "启动桥接",
            toggle_bridge,
        ),
        pystray.MenuItem("重启桥接", restart_bridge, enabled=running),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem(
            "开机自动启动",
            toggle_autostart,
            checked=lambda _item: autostart_enabled(),
        ),
        pystray.Menu.SEPARATOR,
        pystray.MenuItem("退出", quit_tray),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--console", action="store_true")
    parser.add_argument("--no-webui", action="store_true")
    args = parser.parse_args()

    if not args.no_webui:
        start_webui()

    running, _ = bridge_status()
    icon = pystray.Icon(
        "codex_bridge",
        make_icon(running),
        "Codex 桥接",
        menu=build_menu(),
    )
    ICON["img"] = icon

    # Keep the icon honest without a busy loop.
    def watcher() -> None:
        last = running
        while True:
            time.sleep(5)
            now = bridge_status()[0]
            if now != last:
                last = now
                try:
                    refresh_icon()
                except Exception:
                    pass

    threading.Thread(target=watcher, daemon=True).start()
    icon.run()


if __name__ == "__main__":
    main()
