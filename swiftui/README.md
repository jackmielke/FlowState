# Vibe Voice — SwiftUI / native macOS

Native SwiftUI + AppKit client for OpenAI's realtime voice model, with screen vision.
No Xcode project: a Swift Package Manager executable plus a build script that assembles
a real `.app` bundle.

## Build & run

```bash
cd ~/dev/vibe-voice/swiftui
./build.sh                 # swift build -c release + assemble + ad-hoc codesign
open VibeVoice.app         # launch it
```

Debug build: `CONFIG=debug ./build.sh`.
Plain compile check: `swift build -c release`.
Tests: `swift test` (covers `VibeVoiceCore`, see [Response lifecycle](#response-lifecycle)).

> **Launch `VibeVoice.app`, not `.build/release/VibeVoice`.**
> A bare SPM binary is not a bundle, so macOS TCC silently denies it mic and
> screen-recording access. `build.sh` copies `Resources/Info.plist` in and runs
> `codesign --force --deep --sign -` so TCC sees a stable identity across launches.

### Screen Recording permission

Two separate things can go wrong, and the app now distinguishes them instead of
saying "off" for both:

| What you see | What is actually true | Fix |
|---|---|---|
| **Screen Recording is off** | TCC has no grant for this app | Allow **Vibe Voice** under Privacy & Security › Screen & System Audio Recording |
| **Screen Recording is on — relaunch to use it** | The grant exists, but macOS latched the *old* answer into this running process | Hit **Relaunch Vibe Voice** |

macOS hands the screen-recording decision to a process once, at first use. Flipping
the toggle while the app is running does **not** reach that process — which is why
a permission that is visibly on could keep producing "permission is off". The app
re-reads `CGPreflightScreenCaptureAccess()` on launch, on every activation, and
before every capture, and reports `needs-restart` when TCC and ScreenCaptureKit
disagree.

> **Re-running `./build.sh` can revoke the grant.** The bundle is ad-hoc signed
> (`--sign -`), so it has no Team ID and TCC pins the entry by `cdhash` — which
> changes on every rebuild. The toggle stays visibly checked while macOS treats the
> new binary as a different app. Toggle it off and back on, or:
> ```
> tccutil reset ScreenCapture com.jackmielke.vibevoice
> ```

Permission activity is logged to stderr with a `[screen]` prefix and to
`os.Logger(subsystem: "com.jackmielke.vibevoice", category: "screen-permission")`:
```
log stream --predicate 'subsystem == "com.jackmielke.vibevoice"' --info
```

The app **boots idle**. Nothing is captured and no socket opens until you click
**Connect**. There is deliberately no auto-connect flag — three of these running at
once will otherwise talk to each other through your speakers.

## API key

Read at runtime from `~/.config/vibe-voice/config.json`:

```json
{ "OPENAI_API_KEY": "sk-proj-..." }
```

Never hardcoded, never bundled. On Connect the app POSTs to
`/v1/realtime/client_secrets` to mint a short-lived `ek_…` token and puts **only that**
on the WebSocket. If minting fails it logs why and falls back to the standard key.

## Verifying the transport without opening a mic

```bash
swift Scripts/verify-transport.swift
```

Mints a token, opens `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1`, sends the
exact `session.update` the app sends, and asserts `session.created` + `session.updated`.
Touches no audio device. Last run:

```
PASS  client_secrets -> ek_…ca4b
PASS  session.created  sess_EEk602EHxKIQxqlHMqem7
PASS  session.updated (session config accepted)
RESULT: transport OK — no audio devices were opened.
```

## Architecture

| Concern | Implementation |
|---|---|
| Transport | `URLSessionWebSocketTask`, `Authorization: Bearer ek_…` (`RealtimeClient.swift`) |
| Mic | `AVAudioEngine` input tap in the hardware format → `AVAudioConverter` → **mono PCM16 @ 24 kHz** → base64 → `input_audio_buffer.append` |
| Playback | `response.output_audio.delta` → base64-decode → Float32 @ 24 kHz → `AVAudioPlayerNode` (engine resamples to the device rate) |
| Amplitude | Real RMS. Mic RMS from the input tap; output RMS from a tap installed **on the player node**, i.e. what is actually being rendered. No timer fakery. |
| Barge-in | `input_audio_buffer.speech_started` → flush the local playback queue. The server truncates its own turn (`turn_detection.interrupt_response: true`), so no `response.cancel` is sent — that only races and returns "no active response found". |
| Response lifecycle | `ResponseCoordinator` (`VibeVoiceCore`) owns every `response.create` / `response.cancel`. One response at a time, deadlines on every phase, a Stop button that always works. See below. |
| Screen | ScreenCaptureKit — `SCShareableContent` + `SCContentFilter` + `SCScreenshotManager.captureImage`, downscaled to 1280px wide, JPEG q0.7, sent as a `data:` URI per contract §3 |
| Hotkey | Carbon `RegisterEventHotKey` for ⌘⇧2 (no Accessibility permission needed) |
| Settings | JSON at `~/Library/Application Support/VibeVoice/settings.json` |
| Theme | One `Theme` token = one dynamic `NSColor`, resolved per effective appearance (`Theme.swift`) |
| Window | `.titled` + `fullSizeContentView` + transparent titlebar + `NSVisualEffectView`. `.titled` is kept deliberately — dropping it is what loses the system corner rounding. |

Sample rates are logged and shown in the UI footer at runtime, e.g.
`in 48000 Hz × 1 ch → wire 24000 Hz mono PCM16 · out 48000 Hz`.

## Response lifecycle

The realtime API allows exactly one response per conversation at a time. A second
`response.create` is refused outright:

```
Conversation already has an active response in progress
```

This app can want a turn from four places at once, which is why that error was easy to
hit: server VAD (`turn_detection.create_response: true`), a screenshot you send, the
`function_call_output` answering a tool call, and the system note filed when a long
Claude Code run finishes. The subtle part is the *window*: it opens the moment the
create leaves this machine, not when `response.created` comes back, so a flag set only
from the server's event leaves a full round trip in which a second create looks legal.

`ResponseCoordinator` closes that. It is the only thing in the app allowed to send
`response.create` or `response.cancel`, and it tracks four phases:

| Phase | Meaning |
|---|---|
| `idle` | nothing running, a create may go out |
| `requested` | our create is on the wire, unconfirmed — **this is the state the old flag was missing** |
| `active` | the server confirmed with `response.created` |
| `cancelling` | `response.cancel` sent, waiting for `response.done` |

Rules it enforces:

- **Deferred, never dropped, never doubled.** Ask while busy and the request is queued;
  several asks collapse into ONE create sent at `response.done`.
- **Server VAD goes first.** Nothing queued is sent while you are speaking, or for
  1.5 s afterwards — that is the window the server uses to open its own turn, and
  firing into it is a guaranteed collision.
- **The lock is released on every `response.done`**, whatever the status. Treating only
  `completed` as the end is how an app ends up permanently mute.
- **Self-healing.** If "already has an active response" ever arrives anyway, the server
  is believed: the coordinator takes the lock, re-queues the rejected request, and the
  user sees no error. Three failures in a row and it stops retrying instead of looping.
- **Nothing gets stuck.** Every phase carries a deadline, checked once a second. A
  create the server never confirms is retried; a response that never finishes is
  cancelled; a cancel that is never acknowledged is forced back to idle; a
  `speech_started` with no `speech_stopped` behind it stops holding the queue.

In the UI: a **REPLYING / QUEUED / STOPPING** pill in the header, a **Stop** button
while a turn is being generated (press it twice to force a stuck session back to idle),
and **Show screen** turns into a disabled **Queued** while a request is already waiting,
so a second press cannot stack a no-op. ⌘⇧2 is gated the same way.

Every start, finish, queue, cancel, timeout and recovery is logged to stderr as
`[response] …`; the ones a user could mistake for the app going silent also appear in
the transcript.

Covered by `Tests/VibeVoiceCoreTests` — 24 tests over the collision, deferral,
cancellation, error-recovery and watchdog paths, with an injected clock so the timeout
cases are deterministic. `swift test`.

## Verified working

- Ephemeral `ek_` mint, WebSocket connect, `session.created`, `session.updated`.
- 48 kHz float hardware → 24 kHz mono PCM16 conversion. Proven end to end: server VAD
  fired on real room audio and `gpt-4o-mini-transcribe` returned accurate transcripts of
  what was actually said, which cannot happen if the resampling is wrong.
- Full duplex voice: assistant audio played back through `AVAudioPlayerNode`,
  streaming transcript rendered live, barge-in cut the assistant off mid-sentence.
- ScreenCaptureKit capture: 1280×831 JPEG, ~126 KB, accepted by the model as an
  `input_image` conversation item.
- Window corners: verified rounded on all four via the captured alpha channel.

## Theme — dark, light, or whatever macOS is doing

Three choices: **System** (the default), **Light**, **Dark**. Pick one from any of:

- the sun/moon button in the header — one click steps System → Light → Dark, and the
  icon is always the mode you are currently in;
- **Settings → Appearance**, which shows all three at once;
- the **View** menu — ⌥⌘1 System, ⌥⌘2 Light, ⌥⌘3 Dark.

All three write the same field, so they stay in sync. The choice is saved to
`settings.json` alongside voice and model, and is restored on launch.

**System is live, not a snapshot.** It sets `NSApp.appearance = nil`, which hands control
back to macOS — so the app flips with the desktop, including partway through a session
on an Auto/sunset schedule. Light and Dark pin `.aqua` / `.darkAqua` and ignore the
system entirely.

How it works: every colour in `Theme.swift` is one token with two values, built as a
dynamic `NSColor` that AppKit resolves *at draw time* against whichever appearance is
in effect. Nothing observes a notification and nothing gets recomputed on a flip. Two
consequences worth knowing:

- Tokens come in **fill** and **ink** pairs — `accent` vs `accentInk`, `bad` vs `badInk`.
  A fill has something sitting on top of it so it stays bright in both themes; an ink
  sits on the background and has to darken on light or it fails contrast. Amber text on
  white is the specific thing this exists to prevent.
- The **orb inverts its blend mode**, not just its palette. Additive light
  (`.plusLighter`) is the whole idea against near-black and bleaches to nothing on paper,
  so light mode draws the same shapes subtractively (`.multiply`) with a normal-blended
  white core as the highlight. Compare `VoiceOrb.draw(…, light:)`.

## Dev Mode — talk to your code

Settings → **Dev Mode**, plus a repo path. When on, the model gets one tool,
`dispatch_to_claude_code`, and can change code while you talk to it.

How a turn actually runs:

1. You say *"the CODING badge is too purple, tone it down"*.
2. The model rewrites that into a complete instruction — Claude Code cannot hear the
   conversation, so pronouns get resolved before dispatch.
3. The tool returns **immediately** and the model says it's on it. Claude Code takes
   minutes; blocking would leave the voice session in dead silence for the whole run.
4. `claude -p --output-format json` runs in your repo, in the background.
5. When it finishes, the result is filed as a new turn, so the model **announces the
   outcome unprompted** — the real-time update, spoken.

The `session_id` from each run is passed back with `--resume`, so one voice conversation
is one Claude Code session. "Actually make that a bit faster" knows what "that" means.

A **CODING** badge shows in the header while a task runs — with the voice loop idle for
minutes, it is the only proof anything is still happening.

**It runs with `--permission-mode acceptEdits`, so it writes files without asking.** That
is the only way voice-driven coding flows, but a misheard sentence edits your code. Point
it at a repo you can `git checkout`. Dev Mode is off by default, and one task runs at a
time — the model will happily fire a second tool call while waiting, and two runs
resuming the same session id would race.

## Known issues / not verified

- **Echo cancellation is on, but untested by ear.** `setVoiceProcessingEnabled` is
  enabled on the input and output nodes and the signal path is verified end to end
  (`Scripts/verify-full-duplex.swift`). Whether it actually stops the model hearing
  itself over open speakers is a listening test that has not been run. Three silent
  traps had to be cleared to get here — see the comments in `AudioEngine.start()`.
- Screen Recording permission was already granted for this bundle ID on the dev machine.
  The **denied** and **needs-restart** cards, the `CGRequestScreenCaptureAccess()` prompt,
  and the Relaunch button are coded and logged but were not exercised against a real
  denial — reproduce one with `tccutil reset ScreenCapture com.jackmielke.vibevoice`.
- Continuous screen mode is wired to a `Timer` and the WATCHING badge renders, but a long
  multi-frame run was not soak-tested.
- Mic permission prompt: not observed first-hand (already granted). If the bundle ID
  changes, macOS will re-prompt.
- Voice, system prompt, speed, VAD threshold and silence duration are sent in
  `session.update` and the server accepts the payload; individual parameters were not
  A/B'd for audible effect.
- No unit tests.
- `swiftLanguageMode(.v5)` in `Package.swift` — Swift 6 strict-concurrency was not fought
  through for the audio callback paths, which use explicit `NSLock` instead.
