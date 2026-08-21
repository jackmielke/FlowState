# Vantage

A Mac app you talk to. It can see your screen, and — if you let it — change your code
while you keep talking.

Built on OpenAI's realtime voice model (`gpt-realtime-2.1`). Everything runs on your
machine, with your own keys.

```
you: "what am I looking at?"
     → it takes a screenshot and tells you

you: "the spacing on that button is off, tighten it up"
     → it hands the task to Claude Code in your repo, narrates progress,
       and tells you what changed when it's done
```

## What it does

| | |
|---|---|
| **Talk, don't type** | Server-side voice activity detection handles turn-taking. No push-to-talk, and you can interrupt it mid-sentence |
| **It sees your screen** | On demand (⌘⇧2), or continuously. Multi-monitor: it follows whichever screen your cursor is on |
| **Dev Mode** | Say what you want changed; it dispatches to Claude Code on *your* machine. Up to three tasks at once across different repos, with live progress and an undo |
| **A queue, not a refusal** | Ask for a second change to the same repo and it waits its turn instead of being turned away — reorder or drop what's queued, and the next one starts on its own |
| **Recaps** | One button writes a summary of the conversation, keeps it where you can re-read it, and saves it as a markdown note |
| **Native tools** | Calendar, clipboard, Notion, and any macOS Shortcut you own — answered in milliseconds, not by spinning up an agent |
| **Live cost meter** | Real token counts from the API, and dollars per minute. Budget mode cuts it to roughly a third |
| **Painted backdrops** | Six places that change with your local hour, or your own photos |

## Requirements

- macOS 14 or later, Apple Silicon
- An **OpenAI API key** with a little credit — realtime voice runs roughly 5–15¢/minute
- Optional, for Dev Mode: **Claude Code** installed and signed in
  (`npm i -g @anthropic-ai/claude-code`)

## Install

**If someone sent you a `Vantage.dmg`** — open it, drag Vantage to Applications, and
double-click. That's it. It's signed and notarized by Apple, so there's no security
warning and nothing to do in Terminal.

**If you'd rather build it** — you need Xcode's command line tools:

```bash
git clone https://github.com/jackmielke/vantage && cd vantage/swiftui
./build.sh && open VibeVoice.app
```

Either way, on first launch a setup sheet asks for your OpenAI key and verifies it by
minting a real token — so a bad key fails right there rather than confusingly at Connect.

### Why it isn't on the Mac App Store

App Store apps must be sandboxed, and Vantage can't be. Dev Mode spawns *your* `claude`
binary, the tools run `/usr/bin/shortcuts`, and undo runs `git` against whatever repo you
name — none of which a sandboxed process may do. Shipping on the App Store would mean
deleting the feature the app exists for.

Developer ID + notarization is what Mac apps needing real system access actually use;
Wispr Flow, Raycast and Cursor all ship this way. For the person installing it the
experience is identical: double-click, drag, open.

Maintainers: `swiftui/release.sh` builds the notarized DMG.

## Your keys stay yours

- The OpenAI key lives in `~/.config/vibe-voice/config.json`, mode `0600`, outside the
  repo. It is never bundled into the binary — verifiable with
  `strings Vantage.app/Contents/MacOS/VibeVoice | grep sk-`.
- The app mints a short-lived `ek_…` token per session and puts **only that** on the wire.
- Dev Mode runs Claude Code as **you**, under **your** account. Vantage never sees your
  Anthropic credentials, and no coding usage is billed to anyone else.
- No servers, no telemetry, no analytics. The only host it talks to is `api.openai.com`
  (plus `api.notion.com` if you connect Notion).

## Two things worth knowing before you rely on it

**Dev Mode edits files without asking.** That is what makes voice-driven coding flow, and
it means a misheard sentence can change your code. Every task takes a git restore point
first, so *"undo that"* is one sentence — but point it at a repo you can afford to have
touched.

**Cost is real.** Screenshots are cheap (~323 tokens each) and capped: frames are pruned
so a long session cannot grow without bound. Audio is the expensive part. The meter in the
header is the truth, taken from the API's own usage numbers.

## Layout

```
swiftui/     the Mac app — this is the one that matters
docs/        the verified OpenAI realtime contract, and the notes behind decisions
tauri/       a parallel implementation, kept as a comparison point
electron/    a third, parked
```

Three implementations exist because they were built simultaneously to be compared;
[docs/COMPARISON.md](docs/COMPARISON.md) has the measurements. SwiftUI won.

## Notes worth reading

- [docs/API-CONTRACT.md](docs/API-CONTRACT.md) — the realtime API as it actually behaves,
  probed live rather than recalled. Several published details are stale.
- [docs/SCREEN-PERMISSION.md](docs/SCREEN-PERMISSION.md) — why macOS screen recording
  keeps breaking for locally built apps, and the fix. Cost a whole night.
- [docs/COMPARISON.md](docs/COMPARISON.md) — SwiftUI vs Tauri vs Electron, measured.
- [docs/TASK-QUEUE.md](docs/TASK-QUEUE.md) — two Claude Code runs in one checkout break
  each other. The rule stayed; "not now" became "next".
- [docs/CONVERSATION-MEMORY.md](docs/CONVERSATION-MEMORY.md) — what a conversation keeps
  of itself, what it refuses to keep, and how it gets summarised.
- [docs/MARKDOWN-RENDERING.md](docs/MARKDOWN-RENDERING.md) — why `**done**` used to render
  as five literal asterisks.
