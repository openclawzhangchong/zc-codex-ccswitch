# Why Codex needs a proxy at all

## The protocol break

Up to Codex 0.16x, `~/.codex/config.toml` accepted:

```toml
[model_providers.x]
wire_api = "chat"    # use /v1/chat/completions
```

That let Codex talk to any OpenAI-compatible gateway, which is the shape almost
every self-hosted and third-party endpoint exposes.

OpenAI deprecated the chat wire protocol and removed it in early 2026. On 0.169.0
the config loader rejects it outright:

```
Error loading config.toml: `wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"` in your provider config.
```

So Codex now always POSTs to `<base_url>/responses`. If the gateway has no such
endpoint, the request 404s and the CLI retries five times before giving up:

```
ERROR: unexpected status 404 Not Found: ... url: http://127.0.0.1:7863/v1/responses
```

## What the translation has to move

Not just the path. The two APIs disagree on the body:

| Concept | Responses API | Chat Completions |
| --- | --- | --- |
| Input | `input` (string or item list) | `messages` (role/content) |
| System prompt | `instructions`, or a `developer` role item | a `system` message |
| Tool call output | `response.function_call_arguments.delta` events | `choices[].delta.tool_calls[].function.arguments` |
| Tool call finish | `response.output_item.done` with `type: function_call` | `finish_reason: "tool_calls"` |
| Streaming | typed SSE events (`response.output_text.delta`, ...) | `data: {"choices":[{"delta":...}]}` chunks |

Tool calls are the fragile part. An agent like Codex is useless without them, and
a translator that gets the argument-streaming wrong produces a model that looks
responsive but never executes anything.

## Where CC Switch fits

CC Switch runs a local proxy on `127.0.0.1:15721`. In Routing mode it:

1. accepts Codex's Responses request,
2. rewrites it into Chat Completions form,
3. forwards it to the real gateway with the real key,
4. converts the streamed reply back into Responses events,
5. writes `~/.codex/config.toml` so Codex points at the proxy.

Step 2 only happens when the provider's **Upstream format** is set to
`Chat Completions`. With `Responses (native)` it forwards the request untouched,
which is correct for real OpenAI endpoints and a guaranteed 404 for chat-only
gateways.

## The channel fingerprint problem

Some gateways inspect the request and refuse anything that does not look like an
official client:

```json
{"code":11128,"msg":"Illegal API invocation from an unapproved channel",
 "displayTips":{"en":"This call failed channel verification, possibly because it
 was not sent from an official client."}}
```

The trigger observed here was the Codex system prompt — specifically the opening
line `You are a coding agent running in the Codex CLI...`. Sending an otherwise
identical request with that sentence reworded returned 200.

This is a policy decision made by the gateway operator, not a protocol problem.
CC Switch does not rewrite prompts to dodge it. If you hit it, the honest fixes
are to ask the operator to allow the channel, switch to a relay without the check,
or run a shim that rewrites the identifying text — and understand that you are
working around an intentional control.

## Verifying the translation actually happened

A response that merely returns text proves little. Check three things:

1. **Text round trip** — `POST /v1/responses` returns an `output_text` item.
2. **Tool calls** — ask the model to run a shell command and confirm the command
   actually executed (not just that the reply mentions one).
3. **File access** — point it at a file with known contents and confirm it reports
   the real contents.

`scripts/verify.ps1` covers 1 and 3 through `codex exec`. For a manual tool check:

```powershell
cd <a folder with data.txt containing 3 lines>
codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox `
  "Read data.txt and report exactly how many lines it has."
```

A working chain answers `3`. A broken translation usually answers with an apology
about being unable to run commands.
