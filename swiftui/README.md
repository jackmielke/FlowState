# FlowState — SwiftUI / native macOS

Native SwiftUI + AppKit client for OpenAI's realtime voice model, with screen vision.
No Xcode project: a Swift Package Manager executable plus a build script that assembles
a real `.app` bundle.

## Build & run

```bash
cd ~/dev/FlowState/swiftui
./build.sh                 # swift build -c release + assemble + ad-hoc codesign
open FlowState.app         # launch it
```

Debug build: `CONFIG=debug ./build.sh`.
Plain compile check: `swift build -c release`.
Tests: `swift test` (covers `FlowStateCore`, see [Response lifecycle](#response-lifecycle)).

> **Launch `FlowState.app`, not `.build/release/FlowState`.**
> A bare SPM binary is not a bundle, so macOS TCC silently denies it mic and
> screen-recording access. `build.sh` copies `Resources/Info.plist` in and runs
> `codesign --force --deep --sign -` so TCC sees a stable identity across launches.

### Screen Recording permission

Two separate things can go wrong, and the app now distinguishes them instead of
saying "off" for both:

| What you see | What is actually true | Fix |
|---|---|---|
| **Screen Recording is off** | TCC has no grant for this app | Allow **FlowState** under Privacy & Security › Screen & System Audio Recording |
| **Screen Recording is on — relaunch to use it** | The grant exists, but macOS latched the *old* answer into this running process | Hit **Relaunch FlowState** |

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

## Recording a conversation

```bash
./Scripts/verify-recorder.sh
```

`SessionRecorder` tees the two PCM streams the app already carries — your microphone on
its way out, the model's voice on its way in — and mixes them into one 16-bit WAV under
`~/Library/Application Support/FlowState/Recordings`. No extra permission, no second
capture, no re-encoding. The mic is the clock: its sample count is the timeline, and the
model's voice is mixed in wherever that timeline stands when it lands.

The recorder lives in the app target, which cannot be unit-tested — it is compiled beside
AppKit and AVAudioEngine. So the script above compiles `SessionRecorder.swift` on its own
(it imports nothing but Foundation, AVFoundation, Combine, os and the pure-Foundation
`FlowStateCore`, deliberately) and drives it directly, including from background threads,
which is where the audio tap runs. Last run:

```
1. a second of microphone audio comes back as a second of WAV     ok
1b. the model's voice lands on the mic's timeline                 ok
1c. a reply still running at the end is not truncated             ok
2. a recording nothing was ever fed into is reported              ok
3. a real but tiny recording is 'too short'                       ok
4. the audio thread can feed it while the main thread stops it    ok
5. two loud voices at once clip instead of wrapping               ok
6. a video recording hands the finished mixdown to the writer     ok
6a. a pause takes nothing in, and the file continues              ok
6d. every ending that is not a saved file tears the capture down  ok
PASS
```

**Pausing** is a splice, not a gap. `setPaused(true)` drops everything fed to the recorder
until it is resumed — mic, model, speakers, frames — so a take paused for ten minutes is
ten minutes shorter rather than ten minutes of silence, and it is still one file. The
video writer is told and shifts its own timestamps by the same span, which is why
`RecordingVideoTrack.setPaused` is a requirement rather than an optional courtesy: a
writer that ignored it would keep stamping frames against a clock the audio no longer
shares, and the movie would drift further out of sync with every pause. The camera stays
open across a pause — the light stays on, honestly — because resuming is one word away and
ScreenCaptureKit takes a third of a second to come back up.

When one finishes, the app keeps the final output path and shows a result panel rather
than a line of transcript that names a file and then scrolls away. The card carries a
QuickLook preview of the file — a placeholder tile with the file named beside it when the
system cannot make one — its length, size and format, the folder it landed in, and two
buttons: **Play** and **Open in Finder**. The same card is in Settings › Recordings, where
it falls back to the newest file on disk so it survives a relaunch.

Every route into Finder goes through `AppState.reveal`, which asks `RecordingLocation`
(in `FlowStateCore`, so it is tested) what to open. This matters because
`activateFileViewerSelecting` accepts a path to a file that is not there and then does
nothing at all — a recording moved or thrown away since the panel was drawn used to make
the button look dead. It now opens the folder instead and says why, on the row or card
that was actually clicked.

Every way it can fail is a named case rather than a nil — `tooShort`,
`captureNeverStarted`, `writeFailed` — and each one is reported in the transcript, in
Settings, and to `os_log` under subsystem `com.jackmielke.vibevoice`, category
`recorder`:

```bash
log stream --predicate 'subsystem == "com.jackmielke.vibevoice" AND category == "recorder"'
```

## Saying it instead of clicking it

The recording transport and the camera bubble are voice commands:

| Say | Tool | What it does |
| --- | --- | --- |
| "start recording" | `start_recording` | Begins a take in the current capture mode |
| "stop recording" | `stop_recording` | Ends it and writes the file |
| "pause recording" | `pause_recording` | Holds it — same file, nothing captured |
| "resume recording" | `resume_recording` | Carries on where it left off |
| "show my face" | `show_face` | Puts the camera bubble on screen, and in the take |
| "hide my face" | `hide_face` | Takes it off screen |

One vocabulary, two routes, in `VoiceCommand` (`FlowStateCore`, so it is tested):

* **With a session open**, the model calls them as tools. The descriptions it reads come
  from the same enum.
* **With no session open**, the on-device recogniser already running for the wake phrase
  matches the phrases directly — no socket, no API key, nothing leaving the Mac. This is
  the case that matters: the reason to say "stop recording" instead of clicking it is that
  you are in the middle of something else, and that is exactly when no conversation is
  open. It rides on the wake phrase's recogniser, so it needs **Wake phrase on** (Settings
  › Access › Wake phrase) and its own switch, Settings › Access › Recording commands.

The button in the header and the ⌘⇧R shortcut go through the same door, so all four routes
obey one set of rules and land in one log.

**What it will not do.** Every command passes `VoiceCommandGate`, which does nothing and
says why rather than doing something surprising:

* Phrases only count when they are the point of the sentence — "don't stop recording" is
  not a stop, "restart recording" is not a start, and anything said more than sixty
  characters ago has stopped counting as being said now (the same tail rule the wake
  phrase learned the hard way).
* A denied microphone blocks all four transport commands; a denied camera blocks
  "show my face" but never "hide my face" — a revoked permission must not trap a face on
  screen.
* Stopping is never blocked by a permission: a take that is already running has to be
  stoppable whatever has changed since it started.
* Saying something twice is not an error. "Already recording", "it's already paused",
  "nothing is being recorded" — each is reported, and nothing happens.
* "Start recording" over a *paused* take resumes it rather than refusing or starting a
  second file.

**Everything is logged**, including the commands that did nothing, because "ignored" is
the line somebody debugging this actually needs:

```bash
log stream --predicate 'subsystem == "com.jackmielke.vibevoice" AND category == "voice-command"'
[voice-command] stop_recording via speech — performed: Saved 2:14 as 2026-08-24 14.02 — Standup.mov
[voice-command] show_face via model — ignored (blocked): Camera is off for FlowState — turn it on in …
```

## Recording the screen and the camera

```bash
./Scripts/verify-video.sh
```

The record button captures one of four things, chosen from the menu beside it or in
**Settings › Data › What to capture**:

| Mode | What lands on disk | Needs |
|---|---|---|
| **Audio** | One 24 kHz WAV, both halves of the conversation | Microphone |
| **Screen** | A QuickTime movie of the chosen display, with that same audio on it | + Screen Recording |
| **Camera** | The same, from the face camera | + Camera |
| **Both** | The screen with the camera composited into the bottom-right corner | + both |

**Audio-only is unchanged and is still the default.** Same folder, same `.wav`, same
name, same mixdown, same code path — the video writer is not in it. That is the point of
`RecordingVideoTrack`: `SessionRecorder` owns the timeline, the mixdown and every outcome
the user is told about, and knows nothing about ScreenCaptureKit or AVAssetWriter, which
live behind that protocol in `VideoCapture.swift`.

### One file, one mixdown

The movie's audio track is the *same* mixdown the WAV would have held — the mic and the
model's voice, teed from the streams the app already carries. Nothing is captured twice
and no second microphone is opened.

It is handed over whole, at the end, rather than streamed in as it arrives. That is not
laziness: the model's voice is mixed into the timeline retroactively, so a sample that has
already been written can still change until the recording stops. Streaming it would put
the earlier, unmixed version in the file. `verify-recorder.sh` §6 pins this down.

### Size, and being told about it

Video is between four and thirty times the size of audio, and the failure mode of a screen
recorder is not a bad file — it is a full startup disk two hours into a session. So the
rate is stated before the button is pressed, in the units Finder uses, and again while
recording once it stops being trivial.

| Profile | Screen | Rate | An hour |
|---|---|---|---|
| **Small** | 1280 px @ 10 fps, HEVC | ≈5 MB/min | ≈0.3 GB |
| **Balanced** *(default)* | 1920 px @ 24 fps, HEVC | ≈27 MB/min | ≈1.6 GB |
| **Light** | 1600 px @ 24 fps, H.264 | ≈29 MB/min | ≈1.7 GB |

Light is the *biggest* of the three on purpose: H.264 costs the encoder the least and
plays everywhere, and it pays for that in bytes. Small is the one to reach for on a laptop
that is nearly full — a fifth of the size, and perfectly legible for anything that is
mostly text.

Warnings, all in `CaptureStorage` and all unit-tested:

- **Under 2 GB free** — critical, whatever the mode. macOS itself starts failing there.
- **Room for under 15 minutes** — critical before starting; **under 4 hours** — caution.
- **An hour over 1.7 GB** — caution even on a terabyte, because "you will not run out of
  space" and "this file will be enormous" are different facts. The default deliberately
  does not trip it: a warning the default trips is a warning people scroll past.
- **Under 5 minutes of headroom mid-recording** — critical; **under 2 hours** — caution.
  While a movie is being written the meter reads the real file size off disk, not the
  estimate, and re-checks free space every ten seconds.

Estimates are always marked as estimates (`≈`). The encoders are variable-bitrate, and
idle frames — ones where nothing on screen changed — are never encoded at all, so a
recording of someone reading a document comes in far under the number.

### Constraints worth knowing

- **File naming** is one rule, in `FlowStateCore/RecordingName.swift`, tested in
  `RecordingNameTests`: `2026-02-02 02.40 — standup.wav`. Stamp first so the folder sorts
  chronologically; `/` and `:` become `-`; newlines and control characters become spaces;
  a leading `.` is dropped so the file is not invisible; 40 characters *and* 180 bytes of
  title, because APFS counts bytes and emoji are seven of them each.
- **Codec** follows the profile: HEVC except on Light. Both are hardware-encoded on Apple
  Silicon.
- **Dimensions are always even.** H.264 and HEVC encode chroma at half resolution per
  axis, so an odd width is rejected or silently padded — and the padding is a green stripe
  down one side of every frame.
- **Sources are never upscaled.** A 720p camera blown up to 1920 is the same picture at
  four times the bit rate.
- **`.full` composites** with Core Image into the writer's own pixel buffer pool; the
  other two modes never touch Core Image at all — ScreenCaptureKit and AVFoundation are
  asked for frames at exactly the size the plan wants.
- **Permissions are asked for when the mode is picked**, not when record is pressed. A
  camera prompt that appears three seconds into a recording is a prompt you dismiss, and
  then the recording has no camera in it.
- **A capture that dies mid-recording** — display unplugged, permission pulled — stops the
  recording and says why, keeping what was captured. Every ending that is not a saved file
  tears the capture down and deletes the partial movie: a camera light left on after stop
  is the worst possible bug in this feature.

### What the script proves, and what it cannot

A bare binary gets no Screen Recording grant from TCC, so the *capture* half cannot be
tested outside a real session. Everything between a frame arriving and the file being
playable can be, and is: `verify-video.sh` pushes synthetic frames through
`VideoTrackWriter`, then reads the result back with AVFoundation.

```
1. 1280 × 720 · 24 fps · HEVC at 1548 kbps                        ok
2. one video track, one audio track, right size, even dimensions  ok
3. the size estimate is in the right neighbourhood                ok
3b. a composited frame goes through Core Image and into the file  ok
4. a cancelled recording leaves no file behind                    ok
PASS
```

Not covered by it: that ScreenCaptureKit hands over frames, that the camera opens, and
what a long recording does to a warm laptop. Those need a real Mac, real permissions and a
real session — including the video half of a **pause**, which is why the smoke test can do
one:

```bash
FLOWSTATE_RECORD_TEST=6 FLOWSTATE_RECORD_TEST_MODE=screen FLOWSTATE_RECORD_TEST_PAUSE=4 \
  /Applications/FlowState.app/Contents/MacOS/FlowState
[record-test] file: … .mov — 780772 bytes, 6.21s
[record-test] paused 4s — the file should be ~6s, not ~10s
```

Ten seconds of wall clock, six seconds of movie, and both tracks the same length — which
is the whole claim `VideoTrackWriter.setPaused` makes.

## Architecture

| Concern | Implementation |
|---|---|
| Transport | `URLSessionWebSocketTask`, `Authorization: Bearer ek_…` (`RealtimeClient.swift`) |
| Mic | `AVAudioEngine` input tap in the hardware format → `AVAudioConverter` → **mono PCM16 @ 24 kHz** → base64 → `input_audio_buffer.append` |
| Playback | `response.output_audio.delta` → base64-decode → Float32 @ 24 kHz → `AVAudioPlayerNode` (engine resamples to the device rate) |
| Amplitude | Real RMS. Mic RMS from the input tap; output RMS from a tap installed **on the player node**, i.e. what is actually being rendered. No timer fakery. |
| Barge-in | `input_audio_buffer.speech_started` → flush the local playback queue. The server truncates its own turn (`turn_detection.interrupt_response: true`), so no `response.cancel` is sent — that only races and returns "no active response found". |
| Response lifecycle | `ResponseCoordinator` (`FlowStateCore`) owns every `response.create` / `response.cancel`. One response at a time, deadlines on every phase, a Stop button that always works. See below. |
| Screen | ScreenCaptureKit — `SCShareableContent` + `SCContentFilter` + `SCScreenshotManager.captureImage`, downscaled to 1280px wide, JPEG q0.7, sent as a `data:` URI per contract §3. One display at a time — see below |
| Hotkey | Carbon `RegisterEventHotKey`, seven slots (no Accessibility permission needed): ⌘⇧2 screenshot, summon, connect, record, hush, wake, and the dictation slot (the only one that also reports key-up). Every registration is checked — a chord another app owns fails with an `OSStatus`, and that failure is carried up to the row in Settings that set it rather than dying in stderr |
| Wake key | ⌃Q — a tap toggles a session on or off, from anywhere; hold it to dictate. Launch-at-login (`SMAppService`) keeps the process alive so the key has something to fire in; `flowstate://connect` is the cold-start route for when it does not. See below |
| Deactivate key | Esc — turn it off, from anywhere. The one binding that is not permanent: a modifier-less chord is registered only while a session is live *and* FlowState is not the app in front. See below |
| Shortcut conflicts | `HotkeyConflict` (`FlowStateCore`) — two rows on one chord, a chord macOS refused, and a chord that already means something elsewhere (⌃Q is XON, ⌥Space is Raycast's). All three are said out loud under the picker that set them |
| Settings | JSON at `~/Library/Application Support/FlowState/settings.json` |
| Settings pane | A floating, draggable pane with six tabs that sizes itself to whichever is open (`FloatingPanel.swift`; geometry in `PanelLayout`, `FlowStateCore`) |
| Theme | One `Theme` token = one dynamic `NSColor`, resolved per effective appearance (`Theme.swift`) |
| Window | `.titled` + `fullSizeContentView` + transparent titlebar + `NSVisualEffectView`. `.titled` is kept deliberately — dropping it is what loses the system corner rounding. |

### The wake key (⌃Q)

One key, one gesture, two directions: **a tap toggles**. If nothing is running, it brings
FlowState forward, ends any hush snooze, unmutes the microphone and opens a session; if a
session is already open, that same tap hangs it up. `HotkeyGesture.Recognizer` resolves the
tap the instant the key comes back up — no double-press window, no lag either direction —
and `AppState.wakeAndConnect`/`hush` are each idempotent, so leaning on the key or firing it
from a deep link at the same moment never costs a live session. Holding the key instead
dictates; see `DictationDriver` and `HotkeyGesture.swift`.

**"Even when the app is closed" is a claim with a catch, and it is worth being straight
about it.** `RegisterEventHotKey` binds a hotkey to a *running process*. macOS has no
facility for launching an app because a key was pressed — not LaunchServices, not a
plist, nothing. So there are exactly two honest implementations, and both ship:

1. **Make sure it is running.** Settings › Access › *Start at login* registers the app
   with `SMAppService` (`LoginItem.swift`), and closing the window no longer quits it
   (`applicationShouldTerminateAfterLastWindowClosed` now returns false as long as the
   menu bar icon or the wake key gives you a way back in). The Carbon hotkey is then
   live from login to logout.
2. **Let something that is running launch it.** `flowstate://connect` — registered in
   `CFBundleURLTypes`, handled in `DeepLink.swift`. Bind ⌃Q in Shortcuts.app, Raycast,
   Alfred or Keyboard Maestro to `open flowstate://connect`: those keep a resident
   process, so they can catch the key and cold-start FlowState into exactly the same
   place the hotkey lands. `flowstate://show` and `flowstate://hush` are there too.

A URL that arrives before `AppState` exists is held in `DeepLink.pending` and drained
during init — on a cold start SwiftUI builds the delegate before the scene's
`@StateObject`, and dropping the URL there is the difference between "⌃Q launches Flow
and connects" and "⌃Q launches Flow".

Delivery is `.onOpenURL` on the scene, **not** `application(_:open:)` on the delegate:
`@NSApplicationDelegateAdaptor` puts SwiftUI's own delegate in front of ours and it
consumes the URL event without forwarding. Measured — the delegate method was never
called for a URL LaunchServices had already matched to this bundle.

**⌃Q is XON.** In a terminal it is the key that resumes output after ⌃S paused it, and a
Carbon hotkey is registered ahead of every app — so binding this takes ⌃Q from Terminal,
iTerm and tmux. ⌃⇧Q and ⌃⌥Space are offered beside it for anyone who uses flow control.

Nothing here needs Accessibility. A bare modifier chord (hold ⌃⇧, the way Wispr Flow
does) would need an event tap, and that means a permission prompt this app has already
spent enough of its owner's patience on.

### The deactivate key (Esc)

The mirror of the wake key, and the same one-direction rule: it only ever **stops**. It
hangs up, clears the captions and keeps the wake phrase and the clap quiet for
`hushSeconds` afterwards — because whatever set the session off by accident is usually
still happening. It never connects, which is what makes it safe to hit without knowing
what state anything is in. The connect key (⌃⇧F) *toggles*, and a toggle is the wrong
shape for a panic key.

**Escape is not bound the way the other chords are, and it must not be.** Carbon
registers ahead of every app, so a permanent process-wide Escape would break dismissing a
dialog, leaving a vim insert, cancelling a Spotlight query and closing FlowState's own
settings panel — for the whole time the app is running, which is all day. So it is bound
to a *moment* instead. `HotkeyCombo.isSessionScoped` is true for any chord with no
modifier on it, and `AppState.applyHushHotkey` registers such a chord only while both of
these hold:

1. **A session is live or connecting.** The 99% of the day with nothing running, Escape
   is nobody's but the user's.
2. **FlowState is not the frontmost app.** Inside our own window Escape already means
   "cancel this edit" and "close this panel", and Carbon would beat those — the user
   would be pressing a key that does the wrong thing in the one place they can see us.
   The Disconnect button, ⌃Q on it, and the Session menu cover stopping from in here.

`AppState.refreshSessionScopedHotkeys` re-applies on the `connection` `didSet` and on
`NSApplication.didBecomeActive` / `didResignActive` — the four edges where either
condition can move. It is a no-op for the three modifier alternates (⌃⇧Esc, ⌘⇧Esc, ⌘⇧.),
which stay bound permanently and therefore also work while idle, where they still start
the wake-phrase snooze without a session having to exist.

### When a shortcut does not work

Every rebindable row can fail in three different ways, and they need different words:

| What happened | How it is found | What is shown |
|---|---|---|
| Another app owns the chord | `RegisterEventHotKey` returns non-`noErr`; `bind` reports it up through `AppState.report` | "⌥Space could not be registered for Show the window — another app already owns it." |
| Two FlowState rows on one chord | `HotkeyConflict.clashes(among:)`, from settings alone — before anything is pressed | "⌃Q is set for both Wake it up and Stop everything…" |
| The chord works but costs something | `HotkeyConflict.advisory(for:)` | ⌃Q is XON in a terminal; ⌥Space is Alfred's and Raycast's default |

The second case has no runtime symptom at all — Carbon refuses the second registration
and the pane goes on showing both rows set — so it is detected from the settings rather
than waited for. No winner is named: which of the two survives depends on the order the
slots happened to be bound in, and guessing would be a fact-shaped guess.


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

Covered by `Tests/FlowStateCoreTests` — 24 tests over the collision, deferral,
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
- Conversation recording: both halves mixed to one WAV, on the mic's timeline, from the
  real-time audio thread without a data race (`Scripts/verify-recorder.sh`).
- Video recording, up to the point where a real capture starts: a playable `.mov` with a
  video track at the planned size and the whole mixdown as its audio track, plus the
  composited picture-in-picture path (`Scripts/verify-video.sh`).
- The recording result panel: metadata, spoken labels and where "Open in Finder" lands
  when the file has been moved or deleted (`RecordingFileTests`, 17 cases).
- Transcript persistence across a restart: written at 0600, read back, corrected and
  deleted line by line, pinned through a retention purge, trimmed by the keep-last limit,
  held out of disk by manual-save mode, and finally deleted for real
  (`Scripts/verify-transcript.sh`, 26 checks over two "launches").
- The caption strip's shape: one width per display, held constant across every delta of a
  sentence being spoken, and a height that grows and shrinks with the wrapped text
  (`Scripts/verify-caption-size.sh`, measuring the real view; `CaptionLayoutTests` for the
  arithmetic).

## Which screen it sees

Multi-monitor setups make "look at my screen" ambiguous, so the display is an explicit,
persisted choice. All displays stay available; exactly one is shared at a time, and it
applies to single shots (⌘⇧2 / **Show screen**) and continuous mode alike.

Pick it from either place:

- the **Showing …** pill under the buttons on the main window — it names the display
  currently being shared, so the answer is on screen without opening anything;
- **Settings › Screen › Screen FlowState sees** — every attached display as a row, with its
  resolution and a `(main)` marker so two identical monitors are still tellable apart.

Two modes:

| Choice | Behaviour |
|---|---|
| **Active display** (default) | Whichever display the FlowState window is on. Drag the window to another monitor and the capture follows it. |
| A specific display | Pinned. Moving the window does not change what is shared. |

Details worth knowing:

- CoreGraphics display ids are **not** stable across unplug/replug or a reboot, so the
  saved pick is re-validated against the live display list on launch, on activation, and
  on every `didChangeScreenParameters`. A pin that no longer matches anything silently
  reverts to Active display and says so in the transcript.
- If the pinned display vanishes between the pick and the capture, `ScreenCapture.capture`
  falls back to the active display rather than throwing — unplugging a monitor must not
  break a running watch loop.
- With more than one display attached, the display name is included in the prompt sent
  with each frame. Without it the model has no way to know it is being shown one screen
  of several and will answer "what's on my screen" questions about the wrong one.
- The list is empty until Screen Recording is usable, which is the same gate everything
  else in this section sits behind.

## Theme — dark, light, or whatever macOS is doing

Three choices: **System** (the default), **Light**, **Dark**. Pick one from any of:

- the sun/moon button in the header — one click steps System → Light → Dark, and the
  icon is always the mode you are currently in;
- **Settings → Look → Appearance**, which shows all three at once;
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

## The Settings pane

Settings is a **floating pane inside the window**, not a sheet. Half of what it changes —
backdrop, appearance, the orb, the transcript — can only be judged while you can still see
it, so the app stays visible and live underneath, and the pane can be dragged out of the
way of whatever you are looking at. Drag it by the title bar, double-click that bar to put
it back, or focus it and use the arrow keys.

Six tabs, in the order the questions arrive:

| Tab | What is in it |
|---|---|
| **General** | Personality prompt, voice, model, speaking speed, turn detection, cost mode |
| **Look** | Appearance, backdrops, moving backgrounds, the floating widget |
| **Screen** | Continuous screen mode, permission, which display |
| **Access** | Menu bar, wake key (⌃Q), deactivate key (Esc), start at login, summon/connect/record shortcuts — each with its conflicts and costs named under it — native tools, Notion |
| **Dev** | Dev Mode — the one tab where a switch can change files on this Mac |
| **Data** | Recordings, conversations, retention, summaries |

**The pane resizes to the tab.** Each tab measures itself and reports its height up
(`PanelContentHeight`), and the pane springs to it, capped at 620 points and at whatever
the window can spare. Screen is a short pane; Data is a tall one with a scroll. Nothing in
that path is a constant: the title bar, the tab strip and the page each measure themselves
and the heights are summed, because a constant standing in for one of them is wrong the
first time a font or a padding changes.

Three things that were specifically wrong before, and what they were:

- **Dragging ran at half speed and jittered.** The drag gesture was measured in the pane's
  *own* coordinate space, which travels with the pane — so every point it moved cancelled a
  point of translation. It is measured in global space now, which does not move.
- **Every pixel of a drag re-ran the whole settings body** and wrote the new position to
  `UserDefaults`. The live drag is a local offset on the view; the controller and the disk
  hear about it once, on release.
- **A blue perimeter.** AppKit's focus ring is drawn outside the control and is the
  loudest thing in the pane the moment you click into a text field. Focus is shown in the
  app's own colour instead — a warmed hairline on fields, a two-point bar under the title —
  and selection in the swatch grids is a ring plus a checkmark rather than a heavy stroke.

The geometry — sizing, clamping, dragging, and deciding whether a new measurement is worth
animating to — is `PanelLayout` in `FlowStateCore`, with tests. The view layer owns none of
those decisions.

### Looking at it without a screenshot

`Scripts/snapshot-ui.sh [outdir]` renders every tab in both appearances, the moving-backdrop
picker for each of the nine styles, a contact sheet of all nine, and the transcript column
in the states it is otherwise hard to get it into — live, pinned, hidden — straight to PNG:

```
swiftui/Scripts/snapshot-ui.sh /tmp/flowstate-ui
```

No window has to be visible, the display can be asleep, and nothing needs a Screen
Recording grant — the app renders the views with `ImageRenderer`, writes the files and
quits. It is the only way to check this pane's layout on a machine you are not sitting at,
and the fastest way to see that a shader has come out as a flat gradient.

Two known blanks: `TextEditor` and `SecureField` are AppKit-backed and render as a yellow
placeholder rather than as themselves. Everything around them is real.

## Moving backdrops

**Settings → Look → Moving backgrounds**, then pick one of nine: **Ocean**, **Clouds**,
**Aurora**, **Fluid**, **Silk**, **Nebula**, **Rain**, **Embers**, **Prism**. Every tile in
the picker is the real thing running at preview size, because these differ almost entirely
in *how they move* — a still grid of them would be nine coloured rectangles and a guess.

The last three are the newest, and they were chosen for their *motion* rather than for
another palette: Rain falls, Embers rise, Prism slides across. Embers is also the only
warm-dark one in the set. A tenth style that drifted like Clouds in a different colour
would add a row to the grid and nothing to the choice.

The Look tab has two galleries and both are always on screen: **Still backdrops**
(Midnight, Paper, the six painted places, your own photo) and **Moving backgrounds**.
Clicking a moving tile is a complete choice — it switches the backdrop as well as the
style — so there is no mode to enter first. Above the thumbnails the chosen style runs at
full width, so it can be judged at something like the size it will actually be seen at
without closing Settings.

This used to be one grid with a **Motion** tile in it that revealed a second grid below,
which made the moving backdrops a mode rather than a choice — and a click on one of their
tiles while a still backdrop was showing set a value nothing was reading, so the whole
section looked dead. `LookSelection` (`Sources/FlowStateCore/LookBackdrop.swift`) is where
both halves of the choice now move together, and `LookBackdropTests` is why that stays
true.

The **Motion** slider under the grid is amplitude and contrast. It deliberately does not
touch speed: a backdrop that speeds up is a backdrop you start watching instead of the
person you are talking to.

These are darker and flatter than they could be, on purpose. A transcript in 11-point grey
has to stay readable on top of whatever this draws, so each style keeps its bright end
away from the top and bottom of the window where the header, the buttons and the sidebar
live. Ambient mode (fade the chrome after 45 seconds of quiet) works with these as well as
with the painted places, and is the best thing to pair them with — it sits at the top of
the Look tab, above both galleries.

### Three renderers, in this order

| | When | Cost |
|---|---|---|
| **A video loop** | `Motion/<style>.mp4` exists, plays, and the switch is on | Cheapest — the media engine decodes it |
| **A Metal shader** | Normal case. `Contents/Resources/default.metallib` is in the bundle | ~1% CPU over an idle window |
| **Drawn in `Canvas`** | No metallib — a bare SPM binary, or a build made without the Metal toolchain | A little less than the painted places |

Underneath all three, always, is a **palette gradient** — three stops of the style's own
colours, one fill, drawn on the first frame and covered a moment later. It is what a tile
is before its renderer has anything, and what is left if a renderer never produces
anything at all. Nothing here is ever an empty rectangle.

The `Canvas` fallback exists because `ShaderLibrary.default` does not fail politely: it
resolves lazily and dies at draw time if the library or the function is not there, and
there are two ordinary ways to be in that position. So the app checks for the metallib
rather than assuming it, and falls back to a simpler drawing of the same idea — not a
degraded shader. `swift run` gets you this path; `./build.sh` gets you the shader.

**A loop that does not play** falls through the same chain. Resolution picks a loop by
asking whether the file is *there*, which is the wrong question about half the ways a video
goes wrong — a truncated download, an audio-only `.mp4`, a container this Mac has no
decoder for. All three resolve happily and then draw black, full screen, behind the
conversation. So playability is checked at the player (`isPlayable`, and whether there is a
video track at all) and at the poster-frame generator, and a file that fails is remembered
for the rest of the launch: the next redraw takes that style back to the shader, and
Settings says which file failed and why. In memory only — a file that failed because it was
still being copied in deserves another try next launch.

Which one you are on is stated in Settings, under the buttons.

### Using your own video loop

**Settings → Look → Moving background → Use a video loop…** takes a `.mov`, `.mp4` or `.m4v` and
copies it in as the chosen style's backdrop. Copied, not referenced — a backdrop that
points into `~/Downloads` is a backdrop that disappears the week you tidy up.

They live in `~/Library/Application Support/FlowState/Motion/`, named after the style, so
you can also just drop files there:

```
Motion/ocean.mp4      Motion/aurora.mov     Motion/nebula.m4v
```

Seamless loops look best; the file is played muted and on repeat, and it is explicitly
stopped from keeping your display awake. The toggle beside the button goes back to the
shader without deleting anything.

Two things are refused before anything is copied, and both say why: a container that is not
`.mov`, `.mp4` or `.m4v`, and anything over **512 MB**. The size cap is the safe default —
this folder sits beside your transcripts and is filled from a file picker, and a decorative
backdrop has no business quietly putting the 4K master a stock site offered into
Application Support. A seamless loop is a few seconds long.

Nothing ships with the app — the bundle is about two megabytes and video is not. Free,
properly licensed loops are easy to find: [Pexels](https://www.pexels.com/videos/),
[Coverr](https://coverr.co) and [Mixkit](https://mixkit.co/free-stock-video/) all publish
under licences that allow this use. Check the licence on the individual clip.

### Where these pictures come from

Every built-in style is a calculation — a shader, or gradients in a `Canvas`. No stock
footage, no bundled media, nothing with a licence attached and nobody to attribute. That is
not incidental; it is the constraint a new style has to meet, and it is why the app is two
megabytes and why every one of these is sharp at 6K. A loop you add yourself is the only
asset that ever reaches disk, it stays on your Mac, and it stays yours. Settings says so,
under the picker, rather than leaving it to this file.

### Performance

Measured on this Mac, average CPU over 8 seconds with the window frontmost and idle:

| Backdrop | CPU |
|---|---|
| Midnight (flat) | 13.3% |
| Motion — video loop | 9.4% |
| Motion — shader | 14.2% |
| Bali (painted place) | 16.4% |

Most of that is the orb, which redraws at 60fps regardless. The shader costs about a
point over a flat background and less than the existing painted scenes.

Three things keep it that way, all in `MotionBudget`:

- **Nothing animates behind another window.** `NSApplication.didChangeOcclusionStateNotification`
  says when the app is covered, minimised or on another Space, and the frame budget goes
  to zero — the single most important number here, and the one nobody would ever see
  going wrong.
- **The budget is per renderer**: 30fps for a shader, 20 for the drawn fallback, half of
  each for the preview tiles, and none at all for a video loop, which has its own clock.
- **Reduce Motion means a still picture**, not a slower one. Every style is composed to
  look like something mid-flow, so the frozen frame is a real frame.

### Adding a style

1. A case in `MotionStyle` (`Sources/FlowStateCore/MotionBackdrop.swift`) with a label,
   a blurb, four palette stops and a speed.
2. A `[[stitchable]]` function in `Resources/Shaders/Motion.metal` named `motion_<case>`.
   That name is the entire contract between the two files and nothing checks it at compile
   time, in either language — `MotionBackdropTests` at least checks it is unique and
   prefixed.
3. A `PaintedForm` for it, if none of `swell` / `drift` / `ribbons` / `streaks` / `motes` /
   `bands` fits. Group by *movement*, not by palette: something falling, something rising
   and something sliding across are three drawings, and painting a new one as drifting
   blobs in a new colour is how a fallback stops being a picture of the same idea.

Everything else follows: the picker, the thumbnail, the still under Reduce Motion, the
snapshot contact sheet and the loop filename all come off `MotionStyle.allCases`. The tests
will hold you to four palette stops, a unique shader name, a unique label, a dark first
stop, and a palette that runs monotonically dark to bright — the last two because the
transcript has to stay readable on top of whatever you drew.

Two traps worth knowing about, both of which produced a wrong picture that compiled:

- **Do not derive two coordinates from one hash.** A field of particles whose x and its
  phase both come from `hash(i)` puts every particle on a perfect diagonal. Use independent
  offsets — `hash(i)`, `hash(i + 4001)`, `hash(i + 977)`.
- **Compose for `stillPhase`, not for t = 0.** Every still in the app — Reduce Motion, an
  occluded window, the thumbnails — is taken at `12 × speed` seconds. If your style is one
  object crossing an otherwise empty frame, make sure it is *in shot* at that moment.

`build.sh` compiles the shaders. If your Mac says `missing Metal Toolchain`, that is a
separate Xcode component and the build says so rather than failing:

```
xcodebuild -downloadComponent MetalToolchain
```

## Dev Mode — talk to your code

Settings → **Dev**, plus a repo path. When on, the model gets one tool,
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
- **The video capture path has not been exercised against a live session.** The muxer,
  the encoder settings, the audio track and the composite are verified by
  `Scripts/verify-video.sh` with synthetic frames — but ScreenCaptureKit actually
  delivering frames, the camera actually opening, and what an hour of HEVC does to a warm
  laptop all need a real Mac with real permissions and a real conversation. In particular:
  Continuity Camera warm-up, a display unplugged mid-recording, and the composited mode's
  CPU cost on Intel are coded and logged but unobserved.
- The camera permission prompt has not been seen first-hand. `.denied` and `.restricted`
  render their own lines in Settings but were not reproduced against a real refusal
  (`tccutil reset Camera com.jackmielke.vibevoice`).
- No unit tests.
- `swiftLanguageMode(.v5)` in `Package.swift` — Swift 6 strict-concurrency was not fought
  through for the audio callback paths, which use explicit `NSLock` instead.
