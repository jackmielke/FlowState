# Three stacks, one spec — what actually differed

All three implement the same PRODUCT-SPEC.md against the same verified API contract.
Numbers below are measured on this machine (M-series, macOS 26), not estimated.

## Measured

| | SwiftUI | Electron | Tauri |
|---|---|---|---|
| Shipped app | **2.5 MB** | 309 MB `node_modules` (unpackaged) | 16 MB |
| Memory (idle) | 94 MB, 1 process | **368 MB, 4 processes** | 92 MB, 1 process* |
| Cold launch | **0.09 s** | ~3 s | ~1 s |
| Build cache on disk | small | 309 MB | **5.4 GB** |
| Hand-written source | 2,675 lines | **1,654 lines** | 1,675 lines |
| Transport | WebSocket + AVAudioEngine | WebRTC | WebRTC |
| Echo cancellation | Apple VPIO (hand-wired) | Chromium (free) | WKWebView (free) |
| Screen capture | ScreenCaptureKit | `desktopCapturer` | Rust `xcap` |

\* WKWebView runs in shared system daemons, so Tauri's number undercounts relative to
Electron's self-contained processes. The two are closer than the table suggests.

## The finding that actually separates them: echo cancellation

This is the one that cost real time, and it is the honest reason to pick a stack.

**Electron and Tauri got it for free.** One line — `echoCancellation: true` in
`getUserMedia` — and the browser engine handles it. Neither ever had the bug.

**SwiftUI had to earn it**, through three stacked traps that each fail silently:

1. Enabling Apple's voice-processing unit **changes the input format** (1ch → 9ch here,
   the mic array). Read the format before enabling and the converter is built against a
   layout that no longer exists.
2. `AVAudioConverter` **cannot downmix that 9-channel layout** and emits digital zero.
   Not an error — silence. Measured: tap at −55 dBFS, converted stream at −999.
   `channelMap = [0]` fixes it; VPIO duplicates its mono across all 9 channels.
3. Lazily creating `mainMixerNode` **after** enabling voice processing makes
   `engine.start()` fail with `-10875`, and **no connect format avoids it** — verified
   across a full format × destination matrix. Touching the mixer first fixes it.

Each of those is a one-line fix that is invisible until measured. That is the real cost
of the native path: you own the audio stack, including its undocumented ordering rules.
`Scripts/verify-*.swift` exist so these stay caught — they run without opening speakers.

## Surprise: WKWebView does support WebRTC

The going-in assumption was that Tauri's WKWebView would fail `getUserMedia` and force
audio into Rust. It didn't. Inside the real Tauri webview: `getUserMedia` granted,
`RTCPeerConnection` present, `/v1/realtime/calls` → 201, `session.created` received,
`backdrop-filter` / `color-mix` / `:has()` all supported. The `cpal` fallback stayed
unused. Tauri gets Electron's architecture at a tenth of the footprint.

## Recommendation

**Tauri is the best engineering answer.** It gets browser-grade audio for free, like
Electron, at roughly Swift's runtime footprint. The costs are a 5.4 GB build cache and
slow Rust builds — both developer-side, neither shipped to the user.

**SwiftUI is the best *product*** if this becomes something you use daily: 2.5 MB,
instant launch, genuinely native, no web engine. But you maintain the audio stack, and
today proved that stack bites hard and quietly.

**Electron is the worst fit here** — 368 MB resident and 309 MB of dependencies for an
app whose entire job is a mic, a socket and a window. Its one real advantage, Chromium's
audio pipeline, Tauri also has.

Ordering by footprint per unit of capability: **Tauri > SwiftUI > Electron.**

## What no measurement can settle

Echo cancellation *quality* under real speakers, barge-in feel, and whether the voice
sounds natural. All three request cancellation; whether Apple's VPIO holds up as well as
Chromium's under open speakers is an ear judgement. Run `./try.sh` and use the checklist
— same steps for each, so the comparison is fair.
