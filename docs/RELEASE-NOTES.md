# Release notes

Newest first. Each entry says what it does, and — because that is the half that usually
goes missing — what it does *not* do yet.

---

## ⌃Q on, Esc off

The two ends of a conversation now have a key each, and both are rebindable in
Settings › Access.

| | Key | What it does |
|---|---|---|
| **Activate** | ⌃Q | Brings FlowState forward, ends any hush snooze, unmutes the microphone and opens a session. Never hangs up, so it can be hit without knowing what state anything is in. Held, it dictates instead; pressed twice, it starts talking. |
| **Deactivate** | Esc | Hangs up, clears the captions, and keeps the wake phrase and the clap quiet for 90 seconds afterwards. Never connects. |

Alternates for both, since neither chord is free on every Mac: ⌃⇧Q and ⌃⌥Space for
activate, ⌃⇧Esc / ⌘⇧Esc / ⌘⇧. for deactivate. Either row can be switched off entirely —
"Off" is one of the choices rather than a separate switch, because turning a shortcut off
and moving it are the same decision.

### Escape is only listened for when it is wanted

A shortcut registered the ordinary way is registered ahead of every app on the machine,
for as long as FlowState runs. Doing that to a bare Escape would break dismissing a
dialog, leaving a vim insert mode, cancelling a Spotlight query — all day, for one
feature. So this one is bound to a moment rather than to the app: **only while a session
is live, and only while FlowState is not the app in front.**

That is where you would reach for it — you are in another app, something is talking, you
want it to stop. Inside FlowState's own window Escape keeps its ordinary meaning (cancel
this edit, close this panel) and stopping is the Disconnect button, ⌃Q on it, or Session ›
Stop Everything. If you would rather have a stop key that is always listening — including
while idle, where it starts the quiet period with no session open — pick one of the three
modifier chords instead. Those are bound permanently, exactly as before.

### A shortcut that does not work now says so

Before, a chord another app already owned failed silently: Settings went on showing the
row as set, the key did nothing, and the app looked broken. Three failures are now named
under the row that caused them.

- **Another app owns it.** Caught from what `RegisterEventHotKey` returns, at the moment
  it returns it — "⌥Space could not be registered for Show the window."
- **Two rows on one chord.** Caught from the settings themselves, before anything is
  pressed. macOS gives a chord to one owner, so the other row is dead; neither is named
  as the winner, because which one survives depends on the order they happened to be
  bound in.
- **It works, but it costs something.** ⌃Q is also XON in a terminal, the key that
  resumes output after ⌃S. ⌥Space is Alfred's and Raycast's default. The note appears
  only when that chord is the one selected.

### What it does not do yet

- **No arbitrary chords.** Each row offers three or four fixed choices plus Off, not a
  record-any-keystroke field. A recorder needs an event tap, and that means an
  Accessibility prompt this app has so far avoided entirely.
- **No conflict check against other apps' shortcuts before you pick.** macOS exposes no
  list of who owns what; the only way to find out is to ask for it and be refused, which
  is what the first warning above reports.
- **Click activation and the wake phrase are untouched.** The Connect button, ⌘K, the
  menu bar, `flowstate://connect`, "Hey Flow" and the two claps all still work exactly as
  they did — the keys are one more route in, not a replacement for any of them.

---

## The overlays follow the active screen

The two things FlowState draws over everybody else's windows — the caption strip and the
floating widget — now go to the screen you are working on, and stay off when they cannot
tell which one that is.

### What "follows the active screen" means

The active screen is the display the **pointer** has settled on, not the one holding
FlowState's window. That distinction is the whole feature: this is a voice assistant, so
its own window is usually parked on a monitor you are not looking at, and following it
means putting the subtitles for what you are doing on the screen where you are not doing
it. A display counts as active only once the pointer has held still on it for half a
second, so dragging a window across a shared edge does not drag the captions with it —
that rule is `ActiveDisplayGate`, and it is the same one the camera bubble and a running
recording already use.

| | Before | Now |
|---|---|---|
| Caption strip | Moved on the next line spoken, and only after the pointer had settled on a *different* display at least once. Until then it fell back to `NSScreen.main` — FlowState's own window. | Placed on the active screen from launch, and a caption already on screen moves with you mid-sentence. |
| Floating widget | Picked a corner of whichever screen the pointer was on when it was switched on, then stayed there forever. | Follows the active screen, keeping the corner you dragged it to — 24 points in from the bottom-right of a laptop display is 24 points in from the bottom-right of a 5K one. |

### Off beats guessing

With more than one display attached and no settled answer for which is active, the caption
strip **stays off** rather than appearing on one of them. There is no honest fallback: the
available one, `NSScreen.main`, is the screen holding the key window, which is the wrong
answer by construction. One display attached is the exception — there is no wrong answer
there, so an unresolved pointer is not a reason to withhold anything.

The same rule hides an overlay whose display has been unplugged, and re-places it when the
display list changes.

### What it does not change

- **The captions setting still defaults to on.** "Off unless it can resolve a screen" is a
  runtime guardrail, not a new default. The switch is in **Settings › Look › Captions**.
- **Which display the *model* is shown is a separate setting**, and it already followed the
  active display. `Settings › Screen › Display` pins a monitor for screenshots and for
  screen recordings; the overlays ignore that pin on purpose. It says which screen the
  assistant looks at, and these two are things *you* look at — a caption pinned to the
  monitor you are not sitting at is not a caption.
- **The widget is not gated on the captions switch.** It is not the transcript; it only
  needs a screen to be on.
- **Overlays are still captured by screen recordings.** Nothing excludes the caption strip
  or the widget from ScreenCaptureKit, so both appear in a `.audioScreen` movie of the
  display they are on. Turn them off before recording if that matters.
- **Nothing follows Spaces or full-screen state** beyond what `.canJoinAllSpaces` and
  `.fullScreenAuxiliary` already did.

### Accessibility

- The caption strip is now readable by VoiceOver: it carries the speaker's name and the
  line as an accessibility label and value. The panel ignores the mouse, which made it
  invisible to hit-testing — that was never a reason to make it invisible to a screen
  reader.
- Under **Reduce Transparency** the blur behind the strip is dropped for a near-opaque
  fill and a brighter border. That loses the look and keeps the words, which is the right
  way round for a strip whose entire job is being legible over content nobody chose.

### Where it lives

| | |
|---|---|
| `FlowStateCore/ActiveScreenOverlay.swift` | Which screen an overlay belongs on, and where on it |
| `FlowStateCore/ActiveDisplay.swift` | What makes a display active in the first place |
| `FlowState/CaptionBar.swift` | The strip, and its accessibility and Reduce Transparency fallbacks |
| `FlowState/HUDWindow.swift` | The widget, and the corner it keeps |
| `FlowState/AppState.swift` | `syncOverlayDisplays()` — the one place both are pointed |

Tests: `ActiveScreenOverlayTests`, `ActiveDisplayGateTests` (`swift test`). Placement on a
live second monitor is not unit-testable; `FLOWSTATE_CAPTION_TEST="some text"` puts a
caption up without a conversation for checking it by eye.

---

## Screen and camera recording

The record button can now capture pictures as well as sound.

### What you get

Four capture modes, chosen from the menu beside the record button or in
**Settings › Data › What to capture**:

| Mode | What lands on disk | Permission |
|---|---|---|
| **Audio** *(default)* | One 24 kHz WAV holding both halves of the conversation | Microphone |
| **Screen** | A QuickTime movie of the display you picked, with that same audio on it | + Screen Recording |
| **Camera** | The same, from your face camera | + Camera |
| **Both** | Screen with the camera composited into the bottom-right corner | + both |

Three performance profiles decide how hard the encoder works and how much disk it spends:

| Profile | Screen | Codec | An hour |
|---|---|---|---|
| **Small** | 1280 px @ 10 fps | HEVC | ≈0.3 GB |
| **Balanced** *(default)* | 1920 px @ 24 fps | HEVC | ≈1.6 GB |
| **Light** | 1600 px @ 24 fps | H.264 | ≈1.7 GB |

**Light is the biggest of the three, on purpose.** H.264 asks the least of the encoder and
plays on anything ever made, and it pays for that in bytes. Reach for it on an older Intel
Mac, or when something else is already pinning the machine. Reach for **Small** when the
disk is nearly full — a fifth of the size, and perfectly legible for anything that is
mostly text.

### Storage is stated, not discovered

The failure mode of a screen recorder is not a bad file. It is a full startup disk two
hours into a session, which takes the rest of the Mac down with it. So:

- The rate — `≈27 MB a minute · 1.6 GB an hour` — is shown under the mode picker, in the
  record button's tooltip and in the capture menu, before anything is recorded.
- Free space on the recordings volume is shown next to it.
- While a movie is being written, a chip beside the recording clock shows the **real file
  size read off disk**, not the estimate, and free space is re-checked every ten seconds.
- Warnings escalate: under 4 hours of headroom is a caution, under 15 minutes is critical,
  and under 2 GB free is critical whatever the mode — that is where macOS itself starts
  failing. An hour over 1.7 GB is called out even on a terabyte drive, because "you will
  not run out of space" and "this file will be enormous" are different facts.

The default profile deliberately does not trip any of them. A warning the default trips is
a warning people learn to scroll past.

### Nothing about audio-only changed

Same folder (`~/Library/Application Support/FlowState/Recordings`), same `.wav`, same
name, same mixdown, same code path. The video writer is not in it. If you never open the
new setting, you cannot tell this release happened.

The movie's audio track is that *same* mixdown — the microphone and the model's voice,
teed from the streams the app already carries. Nothing is captured twice, no second
microphone is opened, and the audio in a screen recording is bit-for-bit the audio you
would have got from the same conversation recorded audio-only.

### Smaller things

- The recordings list in Settings shows movies as well as WAVs, with a film icon instead
  of a waveform. It filtered on `.wav` before, which would have made every video recording
  invisible: correctly saved, correctly named, and absent from the only list in the app
  that shows recordings.
- The result card after a recording shows a QuickLook poster frame for a movie, which it
  already knew how to do — it asks the system rather than drawing a glyph.
- Permissions are requested when you *pick* a mode, not when you press record. A camera
  prompt that appears three seconds into a recording is a prompt you dismiss, and then the
  recording has no camera in it.
- A capture that dies mid-recording — display unplugged, permission pulled — stops the
  recording, keeps what was captured and says why. Every ending that is not a saved file
  tears the capture down and deletes the partial movie.

### Limitations

- **Recording still requires a live session.** The recorder is fed from the microphone
  tap, which only exists while connected, so the record button is unavailable until you
  hit Connect. This is unchanged, and it means there is no "record my screen" mode
  independent of a conversation.
- **One display at a time.** The movie captures the display chosen in Settings › Screen,
  or whichever display is active. Recording two monitors into one file is not supported.
- **No window or region capture.** Whole display only.
- **No system audio.** What is recorded is your microphone and the model's voice. Music,
  a video call in another app, or anything else coming out of the speakers is not in the
  file.
- **The camera inset is fixed.** Bottom-right, a fifth of the frame width, square corners.
  Not movable, resizable or roundable — every one of those is another Core Image pass on
  every frame.
- **Idle frames are not encoded.** When nothing on screen changes, no frame is written and
  the previous one simply stays up for longer. The movie is correct and much smaller than
  the estimate; some strict editors dislike variable frame timing.
- **HEVC is not universal.** Files play everywhere on macOS and iOS. For a Windows machine
  from the middle of the last decade, or an upload form that refuses them, use the Light
  profile, which writes H.264.
- **Not exercised against a live capture.** The muxer, the encoder settings, the audio
  track, the file naming and the storage arithmetic are all covered by tests
  (`swift test`, `Scripts/verify-recorder.sh`, `Scripts/verify-video.sh`). ScreenCaptureKit
  actually delivering frames, a Continuity Camera warming up, a display being unplugged
  mid-recording, and the composited mode's CPU cost on an Intel Mac are coded and logged
  but have not been observed. Treat the first long recording as a test.
- **`finishWriting` blocks the main thread** while the index is written at the end of the
  file. That is milliseconds even for an hour of video, and it is bounded at 30 seconds so
  a wedged encoder cannot wedge the app — but it is a block, not a spinner.

### Where it lives

| | |
|---|---|
| `FlowStateCore/CaptureMode.swift` | The modes, the profiles, codec choice, frame geometry, bit rate |
| `FlowStateCore/CaptureStorage.swift` | Rates, thresholds, and every warning string |
| `FlowStateCore/RecordingName.swift` | One file-naming rule, shared by both writers |
| `FlowState/SessionRecorder.swift` | The timeline, the mixdown, every outcome — no ScreenCaptureKit |
| `FlowState/VideoCapture.swift` | ScreenCaptureKit, AVAssetWriter, the composite |
| `FlowState/CameraCapture.swift` | Which cameras exist, and whether we may use one |

Tests: `CaptureModeTests`, `CaptureStorageTests`, `RecordingNameTests` (`swift test`),
plus `Scripts/verify-recorder.sh` §6 for the audio/video contract and
`Scripts/verify-video.sh` for the muxer.
