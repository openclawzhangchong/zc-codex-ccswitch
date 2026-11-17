# api2codex bridge - the option that survives channel verification
#
# CC Switch translates Responses -> Chat Completions for you, but it forwards the
# Codex system prompt verbatim. Gateways that fingerprint that prompt (error
# 11128) reject the request. This bridge does the same translation and can
# optionally neutralise the identifying wording.
#
# HISTORICAL NOTE (2026-11-17): the old scripts/install-bridge.ps1 route
# (clone upstream + venv + .env) has been removed from the repo. The bridge
# now ships as bridge/exe/CodexBridge.exe (tray + WebUI + bridge in one).
# Recover the old scripts from git history if you need them. The patch
# explanation below still applies - the same patched api2codex.py lives in
# bridge/ and is bundled into the exe.

## Quick install (current route)

1. Double-click `bridge/exe/CodexBridge.exe` (see `bridge/exe/README.md`).
2. Open http://127.0.0.1:8789/, add your upstream, click the validate button
   to check the API key, then activate it. The WebUI writes .env/routes.json,
   syncs the model line in ~/.codex/config.toml, rebuilds the model catalog,
   and restarts the bridge.
3. Confirm the chain:

```powershell
powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1 -Model your-model
```

The patch anchors on two exact code shapes and **fails loudly** if upstream
changes them, rather than silently installing an unpatched bridge.

## What it is

[api2codex](https://github.com/talkcozy/api2codex) (MIT) is a single-file FastAPI
app that accepts OpenAI Responses requests, converts them to Chat Completions,
forwards them upstream, and converts the streamed reply back.

## Doing it by hand

```powershell
git clone https://github.com/talkcozy/api2codex.git
cd api2codex

python -m venv .venv
.\.venv\Scripts\python.exe -m pip install fastapi uvicorn httpx
```

Apply the patch described below, then write `.env`:

```
UPSTREAM_BASE_URL=http://127.0.0.1:7863/v1
UPSTREAM_API_KEY=sk-your-key
DEFAULT_MODEL=deepseek-v4.1-flash
HOST=127.0.0.1
PORT=8787
SANITIZE_PROMPT=1
```

**Important:** api2codex reads plain `os.environ` and does **not** parse `.env`.
A `.env` file alone does nothing — the variables have to be in the process
environment. `install-bridge.ps1` generates a `start-bridge.cmd` that reads
`.env` and exports each key before launching:

```bat
@echo off
cd /d "%~dp0"
for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do (
  if not "%%~A"=="" set "%%~A=%%~B"
)
".venv\Scripts\python.exe" api2codex.py
```

Without that loader you get a bridge that starts and then fails with
`UPSTREAM_BASE_URL environment variable is required`.

Point Codex at it in `~/.codex/config.toml`:

```toml
model = "deepseek-v4.1-flash"
model_reasoning_effort = "high"
model_provider = "bridge"

[model_providers.bridge]
name = "api2codex"
base_url = "http://127.0.0.1:8787/v1"
wire_api = "responses"
```

Verify:

```powershell
curl.exe -s -X POST http://127.0.0.1:8787/v1/responses `
  -H "Content-Type: application/json" `
  -d '{\"model\":\"deepseek-v4.1-flash\",\"input\":\"say OK\",\"stream\":false}'
```

## The prompt-rewriting patch

api2codex forwards the system prompt unchanged, so it hits the same `11128` block
CC Switch does. The patch below adds an opt-in rewrite of the identifying
sentences, enabled with `SANITIZE_PROMPT=1`.

> **Only apply this if you are authorised to bypass that gateway's channel
> control.** It exists to make a self-hosted setup work, not to get around a
> restriction someone else put in place.

Add near the top of `api2codex.py` (the file already imports `os`):

```python
_CODEX_FINGERPRINTS = (
    ("You are a coding agent running in the Codex CLI, a terminal-based coding assistant. "
     "Codex CLI is an open source project led by OpenAI.",
     "You are a precise, safe and helpful software engineering assistant working in a local "
     "development environment."),
    ("You are Codex,", "You are a software engineering assistant,"),
    ("running in the Codex CLI", "running in a local development environment"),
    ("Codex CLI is an open source project led by OpenAI",
     "This assistant operates in a local development environment"),
)


def sanitize_prompt(text: str) -> str:
    for src, dst in _CODEX_FINGERPRINTS:
        text = text.replace(src, dst)
    return text
```

At the end of `build_chat_request()`, just before `return req`:

```python
    if os.environ.get("SANITIZE_PROMPT", "").lower() in ("1", "true", "yes"):
        for msg in req.get("messages", []):
            if msg.get("role") == "system" and isinstance(msg.get("content"), str):
                msg["content"] = sanitize_prompt(msg["content"])
```

Start with `SANITIZE_PROMPT=1` in the environment (or add it to `.env`).

## Why this works where CC Switch doesn't

| | CC Switch routing | api2codex + patch |
| --- | --- | --- |
| Responses -> Chat translation | yes | yes |
| Rewrites the identifying prompt | no | yes, opt-in |
| Survives a fingerprinting gateway | no | yes |
| Zero-maintenance | yes | needs the bridge process running |

The translation logic is equivalent; the difference is only the ability to edit
the request body on the way through.

## Keep it running

The bridge is a plain Python process - it dies when you reboot. Options:

- **Task Scheduler** (recommended): create a task at logon that runs
  `.venv\Scripts\pythonw.exe api2codex.py` with "Start in" set to the api2codex
  folder. `pythonw` avoids a console window.
- **NSSM** or **WinSW**: install it as a Windows service if you want it up before
  login.
- A shortcut in `shell:startup` is the simplest, but shows a console window.
