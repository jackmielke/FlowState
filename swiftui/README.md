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

> **Launch `VibeVoice.app`, not `.build/release/VibeVoice`.**
> A bare SPM binary is not a bundle, so macOS TCC silently denies it mic and
> screen-recording access. `build.sh` copies `Resources/Info.plist` in and runs
> `codesign --force --deep --sign -` so TCC sees a stable identity across launches.

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
| Screen | ScreenCaptureKit — `SCShareableContent` + `SCContentFilter` + `SCScreenshotManager.captureImage`, downscaled to 1280px wide, JPEG q0.7, sent as a `data:` URI per contract §3 |
| Hotkey | Carbon `RegisterEventHotKey` for ⌘⇧2 (no Accessibility permission needed) |
| Settings | JSON at `~/Library/Application Support/VibeVoice/settings.json` |
| Window | `.titled` + `fullSizeContentView` + transparent titlebar + `NSVisualEffectView`. `.titled` is kept deliberately — dropping it is what loses the system corner rounding. |

Sample rates are logged and shown in the UI footer at runtime, e.g.
`in 48000 Hz × 1 ch → wire 24000 Hz mono PCM16 · out 48000 Hz`.

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

## Known issues / not verified

- **Speakers cause self-interruption.** Raw PCM through AVAudioEngine has no acoustic
  echo cancellation, so the model's own voice re-enters the mic and server VAD reads it
  as a barge-in. **Use headphones.** Fixing this properly means routing input through
  a `kAudioUnitSubType_VoiceProcessingIO` audio unit — not done.
- Screen Recording permission was already granted for this bundle ID on the dev machine;
  the **denied → explainer card → Open Privacy Settings** path is coded but was not
  exercised against an actual denial.
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
