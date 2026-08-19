# Vibe Voice — Tauri v2 implementation

Local macOS voice client for OpenAI's realtime model, with screen vision.
Rust backend (Tauri v2) + vanilla-JS webview (no bundler, no frontend framework).

## Build & run

Rust is required and is **not** installed by default:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
source $HOME/.cargo/env
```

Then:

```sh
cd tauri
npm install
npm run tauri dev          # dev run (hot-reloads the Rust side on file change)
npm run tauri dev -- --no-watch   # dev run without the file watcher
npm run tauri build        # release .app -> src-tauri/target/release/bundle/macos/Vibe Voice.app
```

First `cargo build` takes ~4–6 minutes (≈480 crates). Subsequent builds are ~10s
because the frontend is plain static files — editing `src/*.js|css|html` needs no
rebuild at all, just reload the window.

The API key is read at runtime from `~/.config/vibe-voice/config.json`:

```json
{ "OPENAI_API_KEY": "sk-proj-..." }
```

### Headless check (no mic, no speakers, no window)

```sh
node scripts/verify-session.mjs
# ok  mint      ek_6a863… expires_at=…
# ok  websocket open
# ok  session.created  id=sess_… model=gpt-realtime-2.1 voice=marin
```

### Safety switch

`VIBE_NO_CONNECT=1 npm run tauri dev` boots the UI but makes the Connect button
refuse to open a session. Useful when several of these apps are open at once and
you do not want them talking to each other through the speakers.

## The headline finding: WKWebView **does** do WebRTC + getUserMedia

This was the main architectural risk. It is not a problem on this machine.
Probed inside the actual Tauri WKWebView (macOS 26.5.2, Tauri 2.11.5, wry/WKWebView):

| Capability | Result |
|---|---|
| `navigator.mediaDevices.getUserMedia({audio:true})` | **granted** — returned a live track labelled `MacBook Pro Microphone` |
| `window.isSecureContext` | `true` |
| `RTCPeerConnection` | present and functional |
| `POST /v1/realtime/calls` (SDP offer) | `201`, valid SDP answer |
| `pc.connectionState` | reached `connected` |
| `oai-events` data channel | opened |
| `session.created` | **received** |
| `pc.ontrack` remote audio | received and attached to `<audio>` |
| `AudioContext` + `createMediaStreamSource` on the remote WebRTC stream | works (drives the assistant-side orb) |
| CSS `backdrop-filter`, `color-mix`, `:has()` | all supported |

So the **WebRTC transport is the one in use**. The Rust-side WebSocket + `cpal`
fallback was never needed. `tokio-tungstenite`, `cpal` and `futures-util` are still
in `Cargo.toml` from the pre-flight (harmless, but they can be dropped).

Caveats worth knowing:

* `tauri dev` serves the frontend from `http://127.0.0.1:1430/`, which is a
  *potentially trustworthy* origin, so `isSecureContext` is `true` for free.
  A packaged build serves from the `tauri://localhost` custom scheme. WebKit
  treats that as secure too, but **the packaged build's mic path was not
  exercised** here — see "Not verified" below.
* WKWebView shows no permission prompt of its own; it delegates to the host
  process's TCC state. In `tauri dev` the mic grant lands on the bare
  `target/debug/tauri` binary, not on an `.app`. `src-tauri/Info.plist`
  (merged into the bundle at package time) carries
  `NSMicrophoneUsageDescription`, `NSCameraUsageDescription` and
  `NSScreenCaptureUsageDescription` for the packaged app.

## Architecture

```
src-tauri/src/lib.rs        Rust: key handling, ek_ minting, screen capture, settings, hotkey
src/index.html/styles.css/app.js   webview: WebRTC, orb, transcript, settings UI
scripts/verify-session.mjs  headless contract check
```

* **The webview never sees `sk-proj-…`.** `mint_ephemeral_token` reads the config
  file in Rust, POSTs to `/v1/realtime/client_secrets`, and returns only the
  `ek_` value. Every connection mints a fresh one.
* **Screen capture is in Rust** (`xcap`, with `/usr/sbin/screencapture` as a
  fallback), downscaled to 1280px wide and JPEG q70, returned as a `data:` URI —
  `getDisplayMedia` is never touched. Typical frame: 1280×831, ~98 KB.
* **Global hotkey ⌘⇧2** via `tauri-plugin-global-shortcut`, emitted to the
  webview as a `hotkey-screenshot` event. There is also an in-window ⌘⇧2 handler.
* **Settings** persist to `~/Library/Application Support/com.jackmielke.vibevoice/settings.json`.
* **Orb** is a canvas visualiser driven by two real `AnalyserNode`s — one on the
  mic `MediaStream`, one on the remote WebRTC stream. Cool blue when you speak,
  warm accent when the model speaks, with a slow breathing baseline so it is
  never a dead circle. No CSS fake animation anywhere.
* **Window**: native decorations with `titleBarStyle: "Overlay"`, `hiddenTitle`,
  `transparent: true`, and a native `hudWindow` vibrancy effect with radius 12.
  `#app` additionally carries `border-radius: 12px; overflow: hidden` plus a
  `-webkit-mask-image` — WKWebView will otherwise happily paint square corners
  past the native corner mask. Verified by compositing a window-only capture
  over a light background; all four corners are round.

## Realtime contract notes (as implemented)

Follows `docs/API-CONTRACT.md` exactly:
`POST /v1/realtime/client_secrets` to mint, `POST /v1/realtime/calls?model=…` with
`Content-Type: application/sdp` to connect, `session.update` with
`session.type:"realtime"` and `voice`/`turn_detection` nested under `audio`,
images sent as `conversation.item.create` with an `input_image` data URI followed
by `response.create`.

## Verified working

* Rust backend boots, reads the config file, mints `ek_` tokens (real 201s).
* WebRTC handshake from the webview to OpenAI: `201` → `connected` → data channel
  open → **`session.created`** → `session.updated` applied.
* Remote audio track received and attached.
* Screen capture end-to-end: `capture_screen` → 1280×831 JPEG → sent as
  `input_image` over `oai-events` → **the model described the screen correctly**
  ("I see your Vibe Voice app open in the center with a big glowing…") and the
  reply streamed back into the transcript.
* Settings load/save round-trip; UI renders with no console errors.
* App boots **idle**: no `getUserMedia`, no `AudioContext`, no session until a
  human clicks Connect. Verified with click instrumentation (`isTrusted`).
* Release `.app` bundle builds.

## Not verified / known gaps

* **Actual speech in and out was never heard.** The session went live and audio
  tracks were negotiated in both directions, but no one spoke into the mic, so
  turn-taking, barge-in and VAD tuning are implemented-to-contract but untested
  by ear.
* **The packaged `.app`'s mic path is untested.** Only the `tauri dev` origin
  (`http://127.0.0.1:1430`) was exercised with a real `getUserMedia` call.
  The packaged app serves from `tauri://localhost`; if the mic ever fails there,
  the fix is `app.security.dangerousUseHttpScheme`-style origin work, or the
  Rust/`cpal` WebSocket fallback whose dependencies are already vendored in.
* **Continuous screen mode** is wired (timer, indicator, interval slider) but was
  only exercised for a single manual frame, not over a long auto-send run.
* Voice changes mid-session are pushed via `session.update`; the API may reject a
  voice change after audio has already started — the error surfaces in the banner
  rather than being pre-empted.
* Unsigned and unnotarised; macOS will need a right-click → Open on first launch
  of the packaged build.
