"""Configuration WebUI for the Codex bridge.

Runs as its own small HTTP server on a separate port so it never competes with
the bridge's /v1 endpoints. Changing the active provider rewrites the bridge's
.env and optionally restarts it.

    python webui.py --config config.json --port 8789

Endpoints (all JSON except /):
    GET    /                     the management page
    GET    /api/state            providers + active + bridge status
    POST   /api/providers        add a provider
    PUT    /api/providers/<id>   edit a provider
    DELETE /api/providers/<id>   remove a provider
    POST   /api/activate/<id>    make a provider active and apply it
    POST   /api/test             validate unsaved base_url/api_key/model
    POST   /api/test/<id>        validate a saved provider's key against upstream
    POST   /api/sanitize         toggle prompt rewriting
    POST   /api/restart          restart the bridge process
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

# httpx raises InvalidURL on bracketed IPv6 entries in NO_PROXY (e.g. "[::1]"),
# which some host process chains inject; strip them before any client call.
for _k in ("NO_PROXY", "no_proxy"):
    _v = os.environ.get(_k)
    if _v:
        os.environ[_k] = _v.replace("[", "").replace("]", "")

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

sys.path.insert(0, str(Path(__file__).parent))
from config_store import ConfigError, ConfigStore  # noqa: E402

app = FastAPI(title="Codex bridge manager", docs_url=None, redoc_url=None)

STORE: ConfigStore | None = None
_SOURCE_DIR: Path = Path(__file__).parent
# 冻结后数据写到 exe 旁的 bridge-data/，源码/HTML 仍在 _SOURCE_DIR（只读）。
BRIDGE_DIR: Path = Path(os.environ["BRIDGE_DATA_DIR"]).resolve() if os.environ.get("BRIDGE_DATA_DIR") else _SOURCE_DIR
BRIDGE_DIR.mkdir(parents=True, exist_ok=True)
BRIDGE_PIDFILE: Path = BRIDGE_DIR / ".bridge.pid"
ENV_PATH: Path = BRIDGE_DIR / ".env"


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
def store() -> ConfigStore:
    if STORE is None:
        raise HTTPException(500, "store not initialised")
    return STORE


def port_open(host: str, port: int, timeout: float = 0.4) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _cfg_hostport(cfg: ConfigStore) -> tuple[str, int]:
    """Read host/port defensively: a half-initialised store has no _data."""
    data = getattr(cfg, "_data", None) or {}
    return str(data.get("host", "127.0.0.1")), int(data.get("port", 8787))


def bridge_running() -> tuple[bool, int | None]:
    """Return (running, pid). Prefers the pidfile, falls back to a port probe."""
    if BRIDGE_PIDFILE.exists():
        try:
            pid = int(BRIDGE_PIDFILE.read_text().strip())
        except ValueError:
            pid = None
        if pid and _pid_alive(pid):
            return True, pid
    host, port = _cfg_hostport(store())
    return port_open(host, port), None


def _run_hidden(args: list[str]) -> subprocess.CompletedProcess:
    """Run a console tool without flashing a black window.

    WebUI shares the tray's process, so tasklist/taskkill probes on each status
    poll would otherwise flicker a terminal. CREATE_NO_WINDOW suppresses it.
    Chinese Windows emits GBK, hence errors='replace'.
    """
    kwargs: dict = {"capture_output": True, "text": True, "errors": "replace"}
    if os.name == "nt":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    return subprocess.run(args, **kwargs)


def _pid_alive(pid: int) -> bool:
    if os.name == "nt":
        out = _run_hidden(["tasklist", "/FI", f"PID eq {pid}", "/NH"])
        return str(pid) in (out.stdout or "")
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def write_env(cfg: ConfigStore) -> None:
    """Materialise the active provider into .env for api2codex to read."""
    active = cfg.active()
    if active is None:
        raise HTTPException(400, "no active provider")
    lines = [
        f"UPSTREAM_BASE_URL={active['base_url']}",
        f"UPSTREAM_API_KEY={active.get('api_key', '')}",
        f"DEFAULT_MODEL={active['model']}",
        f"HOST={cfg.host}",
        f"PORT={cfg.port}",
        f"SANITIZE_PROMPT={'1' if cfg.sanitize_prompt else ''}",
    ]
    ENV_PATH.write_text("\n".join(lines) + "\n", encoding="ascii", errors="replace")
    # api2codex lets routes.json override .env; a stale placeholder default
    # there would silently mask the provider we just activated.
    routes_path = BRIDGE_DIR / "routes.json"
    try:
        routes = json.loads(routes_path.read_text(encoding="utf-8")) if routes_path.exists() else {}
    except (OSError, json.JSONDecodeError):
        routes = {}
    if not isinstance(routes, dict):
        routes = {}
    routes["default"] = {"base_url": active["base_url"], "api_key": active.get("api_key", "")}
    routes.setdefault("routes", [])
    routes_path.write_text(json.dumps(routes, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


CODEX_HOME = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
CODEX_CONFIG = CODEX_HOME / "config.toml"
CATALOG_TEMPLATE = _SOURCE_DIR / "model_catalog_template.json"

log = logging.getLogger("webui")


def _test_upstream(base_url: str, api_key: str, model: str = "") -> dict:
    """Probe the upstream /models with the given key and report the real outcome."""
    import httpx
    url = (base_url or "").rstrip("/") + "/models"
    if not base_url:
        return {"ok": False, "kind": "input", "message": "API 地址为空"}
    try:
        resp = httpx.get(url, headers={"Authorization": f"Bearer {api_key}"}, timeout=15)
    except httpx.TimeoutException:
        return {"ok": False, "kind": "timeout", "message": f"连接超时（15s）：{url}"}
    except httpx.HTTPError as exc:
        return {"ok": False, "kind": "unreachable", "message": f"地址不可达：{exc}"}
    if resp.status_code in (401, 403):
        detail = ""
        try:
            detail = resp.json().get("error", {}).get("message", "")
        except Exception:
            pass
        return {"ok": False, "kind": "auth", "status": resp.status_code,
                "message": f"Key 无效（HTTP {resp.status_code}）" + (f"：{detail}" if detail else "")}
    if resp.status_code != 200:
        return {"ok": False, "kind": "http", "status": resp.status_code,
                "message": f"上游返回 HTTP {resp.status_code}：{resp.text[:200]}"}
    try:
        data = resp.json().get("data", [])
        ids = [m.get("id", "") for m in data if isinstance(m, dict) and m.get("id")]
    except Exception:
        return {"ok": False, "kind": "parse", "message": "上游 /models 响应不是预期的 JSON 列表"}
    result = {"ok": True, "kind": "ok", "models": ids, "models_count": len(ids),
              "message": f"验证通过：Key 有效，上游列出 {len(ids)} 个模型"}
    if model:
        result["model_present"] = model in ids
        if not result["model_present"]:
            result["message"] += f"；注意：模型 {model} 不在上游列表里"
    return result


def write_model_catalog(cfg: ConfigStore, toml_text: str) -> None:
    """Rebuild Codex's model_catalog.json for the active provider.

    The desktop model picker reads this static file; without a refresh it keeps
    listing the previous provider's models after a switch. Only touched when
    config.toml actually references model_catalog_json.
    """
    import re
    m = re.search(r"^model_catalog_json\s*=\s*['\"](.+?)['\"]", toml_text, flags=re.M)
    if not m:
        return
    active = cfg.active()
    if active is None:
        return
    probe = _test_upstream(active.get("base_url", ""), active.get("api_key", ""))
    ids = probe.get("models") or [active["model"]]
    seen: set[str] = set()
    ordered = [i for i in ids if i and not (i in seen or seen.add(i))]
    if not ordered:
        ordered = [active["model"]]
    template = json.loads(CATALOG_TEMPLATE.read_text(encoding="utf-8"))["models"][0]
    entries = []
    for mid in ordered:
        entry = dict(template)
        entry["slug"] = mid
        entry["display_name"] = mid
        entries.append(entry)
    catalog_path = Path(os.path.expandvars(m.group(1))).expanduser()
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(json.dumps({"models": entries}, ensure_ascii=False, indent=2) + "\n",
                            encoding="utf-8")


def write_codex_config(cfg: ConfigStore) -> str | None:
    """Keep Codex's model in step with the active provider.

    Codex sends `model` in every request, so if config.toml still names the
    previous provider's model the bridge would forward a model the new upstream
    has never heard of. Rewrites only the `model` line, leaving every other
    setting the user has touched alone.
    """
    active = cfg.active()
    if active is None:
        return None
    model = active["model"]
    try:
        CODEX_HOME.mkdir(parents=True, exist_ok=True)
        if CODEX_CONFIG.exists():
            text = CODEX_CONFIG.read_text(encoding="utf-8")
            import re
            if re.search(r"^model\s*=", text, flags=re.M):
                text = re.sub(r'^model\s*=\s*".*?"', f'model = "{model}"',
                              text, count=1, flags=re.M)
            else:
                text = f'model = "{model}"\n' + text
        else:
            text = (
                f'model = "{model}"\n'
                f'model_reasoning_effort = "high"\n'
                f'model_provider = "bridge"\n\n'
                f'[model_providers.bridge]\n'
                f'name = "api2codex bridge"\n'
                f'base_url = "http://127.0.0.1:{cfg.port}/v1"\n'
                f'wire_api = "responses"\n'
            )
        # No BOM: Codex's TOML loader rejects a leading U+FEFF.
        CODEX_CONFIG.write_text(text, encoding="utf-8", newline="\n")
        try:
            write_model_catalog(cfg, text)
        except Exception as exc:
            # A catalog refresh must never fail the switch itself.
            log.warning("model catalog refresh failed: %s", exc)
        return model
    except OSError:
        # A locked or unwritable config must not fail the switch - the bridge
        # itself is already updated, and the user can fix the file by hand.
        return None


def stop_bridge() -> bool:
    running, pid = bridge_running()
    if not running:
        return False
    if pid:
        _run_hidden(["taskkill", "/PID", str(pid), "/F"])
    BRIDGE_PIDFILE.unlink(missing_ok=True)
    time.sleep(1.5)
    return True


def start_bridge() -> int | None:
    """Launch api2codex detached. Returns the new pid if we could determine it."""
    cfg = store()
    env = os.environ.copy()
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()

    creationflags = 0
    if os.name == "nt":
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS

    if getattr(sys, "frozen", False):
        cmd = [sys.executable, "--bridge"]
        cwd = str(BRIDGE_DIR)
    else:
        pythonw = Path(sys.executable).with_name("pythonw.exe")
        exe = pythonw if pythonw.exists() else Path(sys.executable)
        cmd = [str(exe), str(_SOURCE_DIR / "api2codex.py")]
        cwd = str(_SOURCE_DIR)
    proc = subprocess.Popen(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=creationflags,
    )
    BRIDGE_PIDFILE.write_text(str(proc.pid) + "\n", encoding="utf-8")
    for _ in range(20):
        if port_open(cfg.host, cfg.port):
            return proc.pid
        time.sleep(0.5)
    return proc.pid


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------
@app.get("/api/state")
def state() -> JSONResponse:
    cfg = store()
    running, pid = bridge_running()
    active = cfg.active() or {}
    return JSONResponse({
        "providers": cfg.providers,
        "active": cfg.active_id,
        "sanitize_prompt": cfg.sanitize_prompt,
        "listen": {"host": cfg.host, "port": cfg.port},
        "bridge": {"running": running, "pid": pid},
        "active_target": {
            "base_url": active.get("base_url"),
            "model": active.get("model"),
        },
    })


@app.post("/api/providers")
async def add_provider(request: Request) -> JSONResponse:
    cfg = store()
    payload = await request.json()
    try:
        created = cfg.add(payload)
    except ConfigError as exc:
        raise HTTPException(400, str(exc)) from exc
    return JSONResponse(created, status_code=201)


@app.put("/api/providers/{provider_id}")
async def edit_provider(provider_id: str, request: Request) -> JSONResponse:
    cfg = store()
    payload = await request.json()
    try:
        updated = cfg.update(provider_id, payload)
    except ConfigError as exc:
        raise HTTPException(400, str(exc)) from exc
    # Editing the active provider's model or URL must reach the bridge too.
    if cfg.active_id == provider_id:
        write_env(cfg)
        write_codex_config(cfg)
        if bridge_running()[0]:
            stop_bridge()
            start_bridge()
    return JSONResponse(updated)


@app.delete("/api/providers/{provider_id}")
def delete_provider(provider_id: str) -> JSONResponse:
    cfg = store()
    try:
        cfg.remove(provider_id)
    except ConfigError as exc:
        raise HTTPException(400, str(exc)) from exc
    return JSONResponse({"deleted": provider_id})


@app.post("/api/activate/{provider_id}")
def activate(provider_id: str) -> JSONResponse:
    cfg = store()
    try:
        cfg.activate(provider_id)
        write_env(cfg)
        synced_model = write_codex_config(cfg)
    except (ConfigError, HTTPException) as exc:
        raise HTTPException(400, str(exc)) from exc
    # A running bridge reads .env only at startup, so a switch needs a restart.
    restarted = False
    if bridge_running()[0]:
        stop_bridge()
        start_bridge()
        restarted = True
    return JSONResponse({
        "active": provider_id,
        "restarted": restarted,
        "model": synced_model,
    })


@app.post("/api/test")
def test_payload(payload: dict) -> JSONResponse:
    """Validate unsaved form values (base_url/api_key/model) against the upstream."""
    return JSONResponse(_test_upstream(
        str(payload.get("base_url", "")),
        str(payload.get("api_key", "")),
        str(payload.get("model", "")),
    ))


@app.post("/api/test/{provider_id}")
def test_provider(provider_id: str) -> JSONResponse:
    cfg = store()
    p = next((x for x in cfg.providers if x.get("id") == provider_id), None)
    if p is None:
        raise HTTPException(404, "provider not found")
    return JSONResponse(_test_upstream(p.get("base_url", ""), p.get("api_key", ""), p.get("model", "")))


@app.post("/api/sanitize")
async def set_sanitize(request: Request) -> JSONResponse:
    cfg = store()
    payload = await request.json()
    cfg.set_sanitize(bool(payload.get("enabled", True)))
    write_env(cfg)
    return JSONResponse({"sanitize_prompt": cfg.sanitize_prompt})


@app.post("/api/restart")
def restart() -> JSONResponse:
    stop_bridge()
    pid = start_bridge()
    return JSONResponse({"running": port_open(store().host, store().port), "pid": pid})


@app.post("/api/stop")
def stop() -> JSONResponse:
    stopped = stop_bridge()
    return JSONResponse({"stopped": stopped})


# --------------------------------------------------------------------------
# Page
# --------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return (_SOURCE_DIR / "webui.html").read_text(encoding="utf-8")


def main() -> None:
    global STORE
    parser = argparse.ArgumentParser(description="Codex bridge manager")
    parser.add_argument("--config", default=str(BRIDGE_DIR / "config.json"))
    parser.add_argument("--port", type=int, default=8789)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    STORE = ConfigStore(args.config)

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
