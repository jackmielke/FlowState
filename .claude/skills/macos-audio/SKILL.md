---
name: macos-audio
description: Diagnosing and changing audio in this app — crackling, glitches, dropouts, distortion, echo, feedback, the wake word going deaf, clap detection, AVAudioEngine, voice processing / AEC / VPIO, CoreAudio device state, earcons, or anything that touches the capture tap or the player node. Use BEFORE reading audio source, and before claiming an audio bug is fixed.
---

# Audio in FlowState

This app has cost multiple days to audio bugs that were diagnosed correctly and fixed in
the wrong place. The rules below are each paid for by a specific one. Follow them in order.

## 1. Scope the symptom before you read a line of this app's code

**Play audio in another app — Spotify, YouTube, `afplay /System/Library/Sounds/Glass.aiff`.**

- Crackles there too → the cause is the **shared output device / `coreaudiod`**, not this
  app's render path. Go to §2. Do not touch the tap, the converter, or the engine.
- Clean there → it is ours. Go to §3.

This test takes fifteen seconds. Skipping it cost three consecutive "fixes" on 2026-08-25
(`09dda84`, `e8c69f9`), each a real bug, none of them the one the user was hearing.

Same shape for other symptoms: wake word deaf → does *any* app get the mic? Echo → does it
happen with the speakers muted? **The scope of the symptom bounds the scope of the cause.**

## 2. CoreAudio state is process-external and outlives us

Voice processing (VPIO) is an audio unit attached to the **shared** output device inside
`coreaudiod`. If this process dies without stopping the engine, that unit is orphaned and
its effects stay system-wide until `coreaudiod` restarts.

- **A Cocoa app never turns SIGTERM into `applicationWillTerminate`.** `pkill`, `kill`, and
  any dev-loop restart therefore skip every cleanup path you wrote. `AppState` installs a
  SIGTERM handler that stops the engine and then exits — do not remove it, and do not add a
  new system-wide audio resource without a matching release in it.
- `relaunch.sh` asks the app to quit properly and only falls back to `pkill -x`. Never
  reintroduce `pkill -f` (it matches "Wispr Flow" and has killed it before — see the comment
  in that script).
- **Recovery on a machine already in a bad state:** `sudo killall coreaudiod`, or reboot.
  Fixing the leak does not repair a device already polluted by earlier kills. Say so
  explicitly when reporting the fix, or the user will test on a dirty machine and conclude
  you failed.

## 3. If it is ours: the render thread is real-time

A capture tap and a player callback have one job — meet the buffer deadline. A missed
deadline is exactly what a crackle *is*: the hardware plays whatever was in the buffer.

Never on the audio thread: **allocation, locks, `Data`/`String` building, base64, JSON,
array append that can reallocate, or anything a lower-priority thread also locks** (that is
priority inversion and it is reliably audible). Hand the buffer to a serial queue and do the
work there. Ordering is the only guarantee downstream consumers of this app actually need;
a wake phrase noticed 100 ms later is a wake phrase noticed.

## 4. One `AVAudioEngine` in the whole app

Two engines contending for one output device sounds exactly like a crackle. `EarconPlayer`
was a second engine and is gone — chimes are scheduled on the existing player node as
float32 mono at the wire rate, needing no conversion and no second device client.

If you schedule a non-speech sound on the player node, **do not touch `pendingScheduled`** —
that counter means "the assistant is still speaking", and counting a beep makes barge-in and
the sleep timer treat a chime as a sentence.

## 5. VPIO ordering and format traps

All four were measured, not guessed. Changing this order breaks it:

```
touch engine.mainMixerNode   →   enable VPIO   →   read the format   →   build the converter
```

- **Touch `mainMixerNode` before enabling voice processing.** Creating it lazily afterwards
  makes `engine.start()` fail with **-10875**. This is ordering, not format: a full
  format × destination matrix showed every format failing with VPIO on and every one
  succeeding with it off.
- **Enabling VPIO changes the input format** (1ch → 9ch on this hardware). Read
  `inputNode.outputFormat` *after* enabling, or the converter is built against a stale layout.
- **`AVAudioConverter` cannot derive that 9→1 downmix and silently emits digital zero** —
  tap at -55 dBFS, converted stream at -999. Set `conv.channelMap = [0]`. VPIO duplicates its
  processed mono across all nine channels, so ch0 is correct.
- **VPIO is on for a conversation and off the rest of the time.** It can only be set before
  the engine starts, so each transition rebuilds the engine. Leaving it on all day put every
  sound on the Mac through a voice processor and flattened claps — the detector's threshold
  moved 0.06 → 0.13 once it was scoped to conversations.
- **Defer the restart after a conversation by one turn of the run loop.** The voice-processing
  unit does not tear down synchronously; starting on top of a half-stopped one throws. Do not
  swallow that with `try?` — a swallowed throw here leaves the wake word with no microphone
  and nothing said about it.
- **Guards must check the engine, not a published mirror.** `running` is set on the next turn
  of the main queue so SwiftUI sees a change rather than a write during view evaluation, which
  makes it stale for exactly the stop-then-immediately-restart case — and a session opened
  with no microphone at all.

## 6. Verify against the symptom, not against your mechanism

`swiftui/Scripts/` has isolation harnesses that do not open the speakers and cannot feed back:

| Script | Answers |
|---|---|
| `verify-full-duplex.swift` | the whole pipeline in the real order — AEC on, 9ch tap, channelMap, mic level, converter errors, playback accepted |
| `verify-vpio-order.swift`, `verify-vpio-matrix.swift` | is -10875 ordering or format? |
| `verify-vpio-channels.swift` | is the converter emitting digital zero? |
| `verify-aec.swift`, `verify-mic-chain.swift`, `verify-mic-control.swift` | echo cancellation and the capture chain in isolation |

These prove *a mechanism works*. They do **not** prove the user's crackle is gone. Before
saying it is fixed: rebuild, relaunch through `relaunch.sh`, and re-run the §1 scope test on
a machine whose `coreaudiod` you have restarted. Four fixes were reported as done without
that step.
