# LLM Proxy

**One subscription. AI in every app.**

A menu-bar-only macOS app that exposes separate OpenAI-compatible endpoints for
your Claude Code and Codex subscriptions.

LLM Proxy gives each sign-in its own local API, switch, optional API key, settings,
and help page. Claude defaults to `http://127.0.0.1:8787/v1`; Codex defaults to
`http://127.0.0.1:17878/v1`. Paste the provider URL into any app that supports a
custom OpenAI endpoint.

No separate per-app AI plan. No extra tokens to buy. The apps you already use just
start talking to the model through your one subscription.

The endpoints never route across providers. Claude accepts `sonnet`, `opus`, and
`haiku`; Codex accepts `gpt-5.6`, `gpt-5.6-sol`, `gpt-5.6-terra`, and
`gpt-5.6-luna`.

---

## How it works

Both Chat endpoints speak OpenAI `/v1/chat/completions` and `/v1/models`. Claude
drives the headless `claude` CLI. Codex keeps one official local `app-server`
process warm—there is no `codex exec` wrapper—and creates an isolated ephemeral
thread per request.

Codex may use hosted web search/browse. Shell execution, file changes, MCP,
apps, skills, and subagents are disabled. Images and caller-defined OpenAI
function tools are supported; function calls are returned to the client and are
never executed by the proxy.

```
Claude client ──HTTP :8787──▶ claude CLI
Codex client  ──HTTP :17878─▶ warm Codex app-server
             ◀──── OpenAI JSON / SSE ────
```

## Dictation — voice endpoint for TypeWhisper

The app also hosts a small **local WebSocket endpoint** (`ws://127.0.0.1:8765`)
that transcribes speech through your Claude subscription. It's consumed by a
companion **[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) plugin**
— **[claude-subscription-typewhisper-plugin](https://github.com/zeus-12/claude-subscription-typewhisper-plugin)**
— so you dictate inside TypeWhisper with its normal hotkey/UX, and this app owns
all the Claude-side logic (reading the subscription token and speaking Claude's
speech-to-text protocol). The plugin just streams mic audio here and gets
transcripts back, so it stays thin and holds no credentials.

Because this app owns the endpoint, **dictation only works while this app is
running** — the plugin connects to it. The popover shows the endpoint status.

> Note: this uses Claude's raw speech-to-text, which today is rougher than
> Whisper-based dictation. It's handy and free with the subscription, but set
> expectations accordingly. See *Honest caveats*.

## Requirements

- macOS 14 or later
- At least one local client installed and logged in:
  - [Claude Code](https://claude.com/claude-code) for Claude chat models and Voice
  - [Codex](https://developers.openai.com/codex/) or the ChatGPT desktop app for GPT chat models
- Swift 6 toolchain (Xcode command-line tools) to build

## Install

1. Download the latest `LLM-Proxy-<version>.zip` from the
   [Releases](https://github.com/zeus-12/llm-proxy/releases) page.
2. Unzip it and move **LLM Proxy.app** to `/Applications`.
3. Open it the first time using **one of the two workarounds below**.
4. It launches into the menu bar (no Dock icon) — click the icon to use it.

### "LLM Proxy can't be opened" — why, and how to get past it

macOS tags anything downloaded from the internet with a *quarantine* flag, and
**Gatekeeper refuses to open apps that aren't signed and notarized by a paid
Apple Developer account** ($99/yr — which this app doesn't have). So on first
launch you'll see a warning like *"Apple could not verify LLM Proxy is free of
malware."* The app is fine; it just isn't notarized. Get past it either way:

- **Right-click** (or Control-click) the app in Finder → **Open** → **Open** again
  in the dialog. macOS remembers this and won't ask again.
- **Or** clear the quarantine flag from the terminal once:

  ```bash
  xattr -dr com.apple.quarantine "/Applications/LLM Proxy.app"
  ```

You only have to do this once, right after installing (or after each update).

## Build & run (from source)

```bash
swift build -c release
./.build/release/LLMProxy &
```

Or for development:

```bash
swift run
```

It launches as a **menu-bar app** — no Dock icon, no window. Click the icon in the
menu bar to start, stop, configure, or open help for each endpoint.
All endpoints start off disabled. Turn on whichever endpoint you want; its state
persists across app launches. API-key protection is optional and configured per
endpoint in Settings.

To stop it: `pkill -f LLMProxy`.

## Point an app at it

In any OpenAI-compatible client, choose one provider:

| Provider | Base URL | API key | Models |
| --- | --- | --- | --- |
| Claude | `http://127.0.0.1:8787/v1` | Optional | `sonnet`, `opus`, `haiku` |
| Codex | `http://127.0.0.1:17878/v1` | Optional | supported GPT-5.6 ids |

### Try it with curl

Turn on the endpoint from the menu. The examples below work with API-key
protection left off, which is the default.

Requests that carry a browser `Origin` header are refused with a 403 unless that
origin is allowlisted, so a web page you happen to have open cannot spend your
subscription. curl, the OpenAI SDKs and native clients send no `Origin` and are
unaffected.

Claude, non-streaming:

```bash
curl http://127.0.0.1:8787/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "sonnet",
    "messages": [{"role": "user", "content": "Give me three names for a coffee shop."}]
  }'
```

Codex, streaming (SSE):

```bash
curl -N http://127.0.0.1:17878/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-5.6-luna",
    "stream": true,
    "messages": [{"role": "user", "content": "Count from 1 to 5."}]
  }'
```

HTTPie Desktop waits for the transaction to finish before painting its response
pane. To verify incremental SSE delivery, use `curl -N` as above or HTTPie CLI
with `http --stream`.

## Using it beyond your Mac

The server binds to `127.0.0.1` only. To reach it from another device or a hosted
app, run a local tunnel — it runs on your Mac and forwards to the port:

Before exposing an endpoint through a tunnel, enable **Require API key** in its
Settings and keep that key private. A tunnel is the one case where the loopback
bind stops protecting you.

```bash
ngrok http 8787
# or
cloudflared tunnel --url http://127.0.0.1:8787
```

## Honest caveats

- **Terms of service.** This routes a Claude Code subscription through a
  general-purpose API endpoint. That's in tension with Anthropic's terms, which
  license the subscription for use *through* their client — not as a redistributable
  gateway. Use it for yourself, at your own risk.
- **Codex uses a documented integration boundary.** GPT requests use Codex's local
  app-server protocol and your existing Codex authentication. The server stays on
  `127.0.0.1`; do not expose it to untrusted users.
- **Codex app-server is experimental.** OpenAI documents the protocol for rich
  client integrations, but its shape may change between Codex releases.
- **These are agents, not raw APIs.** Output comes from the local Claude Code or
  Codex harness and is translated to Chat Completions, so it is not byte-for-byte
  identical to either provider's hosted API.
- **Per-request token floor.** Coding clients carry baseline context, which counts
  against subscription usage even for short replies.

## Releasing (maintainers)

Releases are tag-driven. One command from a clean `main` cuts a release:

```bash
./Scripts/release.sh 0.1.1
```

It verifies you're on `main` with a clean tree, pushes `main`, then creates and
pushes the `v0.1.1` tag. Pushing that tag triggers
[`.github/workflows/release.yml`](.github/workflows/release.yml), which builds a
universal `LLM Proxy.app` on a macOS runner and publishes it as a GitHub
Release with the zip attached. The **git tag is the single source of truth** for
the version.

To build a test artifact without publishing, run the workflow manually from the
**Actions** tab (it builds and uploads an artifact but creates no Release).

> First-time setup:
>
> - The workflow file must already be on `main` before the first tag, or the tag
>   triggers nothing.
> - **Settings → Actions → General → Workflow permissions** must be set to **Read
>   and write** so the release can be created.
> - Pushing any file under `.github/workflows/` needs a token with the `workflow`
>   scope. If `git push` is rejected with *"refusing to allow an OAuth App to
>   create or update workflow ... without `workflow` scope"*, add it once with:
>   ```bash
>   gh auth refresh -h github.com -s workflow
>   ```

## Development notes

- Pure SwiftUI / AppKit / Network / Foundation — no external dependencies.
- If runtime behavior ever contradicts your source edits, do a clean build:
  `rm -rf .build && swift build`. Incremental builds occasionally don't relink.
