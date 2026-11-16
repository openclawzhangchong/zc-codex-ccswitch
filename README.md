# zc-codex-ccswitch

Install a ZCode-like desktop client for **OpenAI Codex** on a fresh Windows machine, pointed at your own OpenAI-compatible gateway.

One command on a new PC gets you: **Codex CLI + CC GUI desktop app + CC Switch**, already wired together.

```
CC GUI (desktop app)  ->  Codex CLI  ->  CC Switch local proxy (:15721)  ->  your gateway
                                          Responses <-> Chat Completions
```

> **Read this before you start.** This repo solves the *protocol* problem (Codex only speaks Responses; chat-only gateways 404). It does **not** solve *gateway policy* problems. If your gateway enforces "official client only" channel checks (`11128 Illegal API invocation from an unapproved channel`), the chain will work intermittently and then start failing — see [Channel verification](#channel-verification-11128). Tested against a gateway that enforces this, plain proxied requests succeed while full Codex requests get blocked and then cool down the upstream account.

---

## Why this exists

Codex 0.169 **removed** `wire_api = "chat"`. It only speaks the Responses API now. Most self-hosted and third-party OpenAI-compatible gateways only expose `/v1/chat/completions`, so Codex gets a `404` on `/v1/responses` and cannot talk to them at all.

CC Switch's **Routing** mode sits in the middle and translates between the two. That translation is not on by default — you have to set the provider's **Upstream format** to `Chat Completions`. Missing that one setting is the cause of the `404` this repo exists to prevent.

---

## What gets installed

| Component | Version | Why |
| --- | --- | --- |
| [Codex CLI](https://github.com/openai/codex) | `0.169.0` | The agent engine, installed via npm |
| [CC GUI (desktop-cc-gui)](https://github.com/zhukunpenglinyutong/desktop-cc-gui) | `1.2.4` | The desktop window you actually type in |
| [CC Switch](https://github.com/farion1231/cc-switch) | `4.0.32` | Local proxy + provider management |

Portable: nothing lands in `Program Files` and nothing is registered as an installed application. Everything lives under `%LOCALAPPDATA%\zc-codex-ccswitch\` and is removed by deleting that folder.

---

## Which setup do you need?

| Your gateway | Use |
| --- | --- |
| Serves `/v1/responses` natively | Codex + CC GUI only. Point `base_url` straight at it, no proxy. |
| Chat Completions only, **no** channel fingerprinting | `install.ps1` + CC Switch routing with `Upstream format: Chat Completions`. |
| Chat Completions only, **and** rejects non-official clients (`11128`) | `install-bridge.ps1` — same translation, plus an opt-in prompt rewrite. |

---

## Requirements

- **Windows 10 1803+ / Windows 11** (x64)
- **Node.js 22 or newer** — only needed for the Codex CLI, not for the desktop apps.
  Download: <https://nodejs.org/>
- A gateway that speaks **OpenAI Chat Completions** (`/v1/chat/completions`), with its base URL, API key and a model name.

---

## Quick start

Open a normal (non-elevated) PowerShell in the repo root:

```powershell
# 1. Install everything
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1

# 2. Seed the Codex provider inside CC Switch, with Upstream format already
#    set to "Chat Completions". Run this with CC Switch CLOSED.
powershell -ExecutionPolicy Bypass -File .\scripts\import-provider.ps1 `
    -BaseUrl http://127.0.0.1:7863/v1 `
    -ApiKey  sk-your-key `
    -Model   deepseek-v4.1-flash

# 3. Start CC Switch, open the Codex tab, click "Start routing"
#    (or -DryRun first to see what will be written)

# 4. Prove the chain works
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -Model deepseek-v4.1-flash
```

`verify.ps1` runs four checks and exits non-zero if any fail:

1. Codex CLI on PATH
2. Something listening on `127.0.0.1:15721`
3. The proxy answers a real Responses request
4. `codex exec` returns the expected token end to end

---

## Doing it by hand (no scripts)

If you would rather click through the UI, that is fine — the result is identical.

**a. Install the three pieces**

```powershell
npm install -g @openai/codex@0.169.0
```

Then download and run:
- CC GUI: <https://github.com/zhukunpenglinyutong/desktop-cc-gui/releases> → `CC.GUI_1.2.4_x64-setup.exe`
- CC Switch: <https://github.com/farion1231/cc-switch/releases> → `CC-Switch-v4.0.32-Windows-Portable.zip` (extract, keep `portable.ini` next to the exe)

**b. Add the provider in CC Switch**

Codex tab → `Add provider` → `Custom configuration`:

| Field | Value |
| --- | --- |
| Name | anything, e.g. `Local Gateway` |
| API key | your gateway key |
| API request URL | your gateway base URL, e.g. `http://127.0.0.1:7863/v1` |
| Model | your model name, e.g. `deepseek-v4.1-flash` |

**The step people miss:** open **Advanced options** and set

> **Upstream format → `Chat Completions (translated)`**

Then **Save**, switch to the **Routing** tab and click **Start routing**.

**c. Point Codex at the proxy**

CC Switch writes `~/.codex/config.toml` itself when it takes over. If you need to do it manually:

```toml
model = "deepseek-v4.1-flash"
model_reasoning_effort = "high"
model_provider = "ccswitch"

[model_providers.ccswitch]
name = "CC Switch Local Proxy"
base_url = "http://127.0.0.1:15721/v1"
wire_api = "responses"
requires_openai_auth = false
experimental_bearer_token = "PROXY_MANAGED"
```

---

## Troubleshooting

### `404 ... /v1/responses`

The provider's **Upstream format** is still `Responses (native)`, so CC Switch forwarded the request untranslated to a gateway that has no `/v1/responses` endpoint.

Fix: provider card → edit → **Advanced options** → **Upstream format** → `Chat Completions (translated)` → Save.

### Channel verification (`11128`)

Your gateway fingerprints the request and only accepts what it considers an official client. Observed behaviour during testing:

| Request | Result |
| --- | --- |
| `curl` → proxy → gateway (short prompt) | 200 |
| `codex exec` → proxy → gateway | `11128` on the first attempt |
| immediately afterwards | upstream account enters cooldown → `503` |
| after ~1 minute | plain `curl` works again |

The trigger is the Codex system prompt, specifically the opening line `You are a coding agent running in the Codex CLI...`. Sending the same request with that sentence reworded returned 200.

**Setting `Upstream format: Chat Completions` does not defeat this check.** It only fixes the protocol mismatch. A translated request still carries the identifying prompt.

Options, in order of honesty:

1. **Ask the gateway operator to allow the channel.** This control is intentional; working around it may violate the terms you agreed to.
2. **Use a relay that does not enforce it.**
3. **Run a shim that rewrites the identifying text** — only if you have authorisation to bypass that control on that gateway. This repo does not ship one.

If none of these is available, no proxy configuration will make that gateway work reliably with Codex CLI.

### Codex says `wire_api = "chat" is no longer supported`

Codex 0.169 dropped the chat wire protocol. Do not try to set it — leave `wire_api = "responses"` and let CC Switch do the translation instead.

### CC Switch keeps writing the config back

CC Switch owns `~/.codex/config.toml` while routing is active. Quit it through the tray icon rather than killing the process, otherwise the config is left pointing at a proxy that is no longer running. If that happens, CC GUI reports `provider "custom" is no longer configured` on old sessions — start a **new** chat.

### Old chats fail after switching providers

Sessions are bound to the provider they were created with. Create a new chat; the old ones stay broken by design.

### `codex exec` hangs at `Reading additional input from stdin...`

It waits for EOF on stdin when it detects a pipe. Redirect stdin from an empty file, or run it from a real terminal.

---

## Layout

```
config/codex-config.toml.template   reference config.toml, with the direct-connection alternative
scripts/install.ps1                 downloads + installs Codex CLI, CC GUI, CC Switch
scripts/import-provider.ps1         seeds the CC Switch database (with -DryRun)
scripts/install-bridge.ps1          api2codex bridge + prompt-rewrite patch (for 11128 gateways)
scripts/verify.ps1                  four end-to-end checks, works against either proxy
scripts/checksums.psd1              pinned SHA256 for every download
docs/why-a-proxy.md                 the protocol break, explained
docs/api2codex-bridge.md            the bridge, what the patch changes, how to run it
```

---

## Pinned versions and checksums

`scripts/checksums.psd1` pins a SHA256 for every downloaded file, and `install.ps1` refuses to run an installer that does not match. When bumping a version, update both the URL table in `install.ps1` and the hash in `checksums.psd1`:

```powershell
Get-FileHash <downloaded-file> -Algorithm SHA256
```

npm packages are pinned by exact version (`@openai/codex@0.169.0`), which npm verifies against its own registry integrity data.
