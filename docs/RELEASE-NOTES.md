# Release notes

Newest first. Each entry says what it does, and — because that is the half that usually
goes missing — what it does *not* do yet.

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

Same folder (`~/Library/Application Support/VibeVoice/Recordings`), same `.wav`, same
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
| `VibeVoiceCore/CaptureMode.swift` | The modes, the profiles, codec choice, frame geometry, bit rate |
| `VibeVoiceCore/CaptureStorage.swift` | Rates, thresholds, and every warning string |
| `VibeVoiceCore/RecordingName.swift` | One file-naming rule, shared by both writers |
| `VibeVoice/SessionRecorder.swift` | The timeline, the mixdown, every outcome — no ScreenCaptureKit |
| `VibeVoice/VideoCapture.swift` | ScreenCaptureKit, AVAssetWriter, the composite |
| `VibeVoice/CameraCapture.swift` | Which cameras exist, and whether we may use one |

Tests: `CaptureModeTests`, `CaptureStorageTests`, `RecordingNameTests` (`swift test`),
plus `Scripts/verify-recorder.sh` §6 for the audio/video contract and
`Scripts/verify-video.sh` for the muxer.
