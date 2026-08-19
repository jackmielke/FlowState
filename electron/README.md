# Vibe Voice — Electron

A local macOS voice-chat client for OpenAI's realtime model (`gpt-realtime-2.1`) that
can also look at your screen. Talks over **WebRTC**, so Chromium does the audio
pipeline — echo cancellation, jitter buffering, barge-in — for us.

```bash
npm install
npm start
```

Then click **Connect** and just talk. Nothing connects until you click.

## Requirements

- macOS, Node 18+ (built and tested on Node 24 / Electron 43).
- `~/.config/vibe-voice/config.json` → `{"OPENAI_API_KEY": "sk-proj-..."}`, chmod 600.
  Read by the **main process only**.
- Microphone permission (prompted on first Connect).
- Screen Recording permission for screenshots. If it isn't granted, Settings ▸ Screen
  recording shows an explainer with a button that opens the right System Settings pane.
  macOS only re-reads that grant on app launch, so relaunch after granting.

## Architecture

```
main (Node)                         preload            renderer (Chromium)
──────────                          ───────            ───────────────────
reads config.json  ─┐                                  never sees sk-proj-*
POST /v1/realtime/  │  ek_ token    contextBridge      RTCPeerConnection
  client_secrets   ─┴──────────────▶ window.vv ───────▶ POST /v1/realtime/calls
desktopCapturer ────── data URI ───▶            ───────▶ oai-events data channel
globalShortcut ⌘⇧2 ─── IPC event ──▶
```

- `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`.
- The renderer's entire privileged surface is the ~10 methods in `src/preload.js`.
  The standard API key never crosses it — only the ephemeral `ek_` token, minted fresh
  per connection (it has a ~60s window to be used).
- Strict CSP in `renderer/index.html`: `default-src 'none'`, scripts `'self'` only,
  `connect-src https://api.openai.com`. No inline scripts or styles, no CDN, no bundler.
- Screenshots use `desktopCapturer.getSources` — the thumbnail *is* the frame, so there's
  no `getDisplayMedia` + canvas dance.
- Settings persist to `~/Library/Application Support/Vibe Voice/settings.json`.

## What's verified working

Confirmed by running the app and reading main-process + renderer logs:

| | |
|---|---|
| `npm install` / `npm start` | clean, no white screen, zero renderer console errors, zero CSP violations |
| Ephemeral token mint | `POST /v1/realtime/client_secrets` → 200, `ek_…` (logged redacted) |
| WebRTC SDP exchange | `POST /v1/realtime/calls?model=gpt-realtime-2.1` → **HTTP 201** + SDP answer |
| ICE / DTLS | `ice: connected`, `pc state: connected` |
| Data channel | `oai-events` opens, `session.update` accepted (`session.updated` returned) |
| **`session.created`** | received on the data channel — the voice pipeline is real |
| **Full voice round-trip** | user speech transcribed (`…input_audio_transcription.completed`) *and* the assistant replied with streaming text + audio, both rendered in the transcript |
| Screen capture | `1280×831` JPEG q70, 62 KB → 85 KB data URI, under the data-channel ceiling |
| Rounded window corners | all four corners transparent in a capture composited over a light background |

## Design notes

- The orb is a `<canvas>` driven by **two real `AnalyserNode`s** — one on the mic
  `MediaStream`, one on the remote WebRTC track. Blob deformation, core brightness,
  bloom radius and the 108-bar spectrum ring all read live FFT / RMS data. The only
  scripted motion is a slow idle breathe.
- Colour encodes who holds the turn: warm amber at rest and while the assistant speaks,
  cool cyan while you speak. Server VAD events are authoritative; amplitude is only the
  tiebreaker, so ambient room noise doesn't flip the state.
- `backgroundThrottling: false` keeps the meters and orb alive when the window is behind
  something else — it's a voice app, it shouldn't freeze when you look away.

## Known issues / caveats

- **Continuous screen mode sends frames as silent context** (no `response.create`), so the
  model knows what's on screen when you ask, instead of narrating every 5 seconds
  unprompted. The manual Screenshot button / ⌘⇧2 *does* request a spoken reply.
  A "watching screen" pill is visible in the title bar whenever it's on.
- Screenshots capture the **primary display only**; multi-monitor picking isn't exposed.
- Screen Recording permission is read at launch, so a fresh grant needs a relaunch. When
  run via `npm start` the grant belongs to Electron (or your terminal), not a signed
  "Vibe Voice.app" — packaging with a stable identity would make this stick properly.
- Not code-signed or notarized. `npm run dist` produces an unsigned `--dir` build; a real
  distributable needs a Developer ID.
- Transcript is in-memory only — no history across launches by design (local-only, no telemetry).
- The image is downscaled/re-encoded down a quality ladder until the base64 data URI fits
  under ~170 KB, because Chromium's SCTP data channel rejects messages above ~256 KB.

## Dev flags

Used for automated smoke tests. None of them connect audio.

```bash
npm start -- --test-capture                 # exercise desktopCapturer, log size/quality
npm start -- --shot=/tmp/x.png --shot-quit  # snapshot the window via capturePage, then quit
                --shot-delay=3500 --shot-settings
```

`--shot` uses `webContents.capturePage()`, which needs no Screen Recording permission and
renders the window background as transparent (that's how the rounded corners were verified).
