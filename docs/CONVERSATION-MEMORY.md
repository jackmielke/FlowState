# Conversation memory — transcript capture, privacy, and rolling summaries

What Vantage keeps of a conversation, what it refuses to keep, and how a long session
gets condensed into something it can still refer to an hour later.

Implemented in `swiftui/`. The other two stacks (`electron/`, `tauri/`) are built to the
same product spec and would need the same feature; the type names below are the contract.

## The problem

Two of them, and they turn out to be the same problem.

1. **The user's words are transient.** The realtime API returns them
   (`conversation.item.input_audio_transcription.completed`) and the app draws them in a
   `LazyVStack` and then they are gone when the process exits. Nothing can be asked of
   them afterwards, and nothing else in the app can act on them.
2. **A long conversation is expensive and eventually incoherent.** Every turn stays in
   the session's context and is re-billed. Screen frames are already evicted for exactly
   this reason (`maxScreenFrames`); the words are not.

A durable transcript solves the first and enables the answer to the second: summarise the
old part, keep the summary, stop needing the rest.

But a voice assistant that quietly writes down everything said near a microphone is a
different product from the one anybody asked for. So privacy is not a section at the end
of this document — it is the type that every write goes through.

## Shape

```
AVAudioEngine tap ──▶ AudioEngine.onMicPCM ──┬──▶ RealtimeClient.appendAudio  (the socket)
                                             └──▶ UtteranceRecorder            (metering only)
                                                        │
 realtime socket ──▶ .userTranscript ──────────────┐    │ UtteranceAudio
                     .assistantDelta ──────────────┤    │ (duration, peak, RMS, bytes)
                                                   ▼    ▼
                                        ConversationStore.record(...)
                                                   │
                                        TranscriptPrivacy  ← admits? redacts? expires?
                                                   │
                                      ┌────────────┴────────────┐
                                      ▼                         ▼
                              ConversationLog          <session>.jsonl on disk
                              (bounded, in memory)
                                      │
                                      ▼
                              SummaryJob   ← decides WHEN (tested, no clock of its own)
                                      │
                                      ▼
                              Summarizer   ← decides WHAT it says (injectable)
                                      │
                          ┌───────────┴───────────┐
                          ▼                       ▼
                    NoteSink (markdown)    system note back into the session
```

The split down the middle is the one the rest of this codebase already uses:
**anything decidable from its arguments lives in `VibeVoiceCore` and is tested; anything
that touches the world lives in the app target.** `ResponseCoordinator` is the precedent.

### VibeVoiceCore — the rules

| Type | Answers |
|---|---|
| `ConversationEntry` | One line: who, what, **when**, **which session**, where the text came from, what the audio looked like. |
| `UtteranceAudio` | The shape of an utterance — duration, sample rate, byte count, peak and RMS. Never samples. |
| `TranscriptPrivacy` | What may be recorded, what gets rewritten, how long it lives. |
| `ConversationLog` | The bounded in-memory record. Every write goes through privacy here, and nowhere else. |
| `SummaryJob` | When a summary is due, what window it covers, and what prompt describes it. |
| `SummaryPolicy` | Cadence and destination. |
| `Summarizer` | The seam a real model plugs into. `ExtractiveSummarizer` is the offline default. |

### App target — the world

| Type | Owns |
|---|---|
| `ConversationStore` | The clock, the JSONL files, session lifecycle, deletion. |
| `UtteranceRecorder` | Metering on the audio thread. Lock-based, like `LevelBox` beside it. |
| `UserTranscriber` | The transcription seam. `RealtimeAPITranscriber` (live) / `LocalTranscriber` (placeholder). |
| `AudioClipRecorder` | Where audio *would* be written. Currently refuses, on purpose. |
| `SummaryService` | Runs the job, calls the summariser, delivers the result. |
| `NoteSink` | `MarkdownNoteSink` (real) / `NotionNoteSink` (placeholder). |

## Privacy

Defaults, and why they are not "record nothing":

| Setting | Default | Reasoning |
|---|---|---|
| `captureUserSpeech` | on | The transcript is already on screen. Keeping it is what makes the assistant able to refer back. |
| `captureAssistantSpeech` | on | Half a conversation summarises badly. |
| `captureSystemNotes` | **off** | Tool results and task progress are the app talking to itself. Letting them in turns a summary into a changelog. |
| `captureAudioMetadata` | on | Duration and level answer the questions actually asked of a voice log ("was the mic even on?") without keeping a recording of a room. |
| `keepAudioClips` | **off** | The only switch here that would put real audio on disk. Not implemented, and refuses at the call site rather than being a TODO. |
| `persistToDisk` | on | Turning it off also deletes what is already there — otherwise it is a lie. |
| `retentionHours` | 168 (a week) | Enforced on every purge, not only at write time, so turning it down deletes. |
| `redactSensitiveText` | on | An API key read aloud should not end up in a plain-text file. |
| `paused` | off | The mute switch. Overrides everything else. |

**One boundary, stated because it is a choice rather than an oversight:** these govern the
*durable* record and what a summary may see. They do not govern the live transcript on
screen, which shows what was actually said and vanishes when the app quits. Redacting the
user's own words back at them, in the window they are looking at, protects nobody.

Redaction is deliberately conservative — a net for the obvious accident (an API key, a
dictated email address), not a claim to catch everything. Over-redacting a voice
transcript makes it useless, which is its own failure. `port 8080` is left alone.

All of it is reachable by voice, because the moment somebody wants recording to stop is a
moment they are already talking: `pause_recording`, `resume_recording`,
`forget_conversation`, `memory_status`, `summarize_conversation`. Pausing needs no
confirmation; resuming and forgetting do (`ToolSpec.Effect.writes`).

## On disk

```
~/Library/Application Support/VibeVoice/
  conversations/<sessionID>.jsonl    one JSON object per line, 0600
  notes/<yyyy-MM-dd>.md              summaries, appended
  audio/                             would hold clips. Nothing writes here today.
```

JSONL rather than a database because the point of a privacy control is that the user can
go and look at what was kept and delete it with `rm`. A file they can read is worth more
here than an index they cannot. Session ids come from the API but are reduced to
`[A-Za-z0-9-_]` before becoming a path.

## Summarisation

`SummaryJob` decides when; it has no clock, no I/O and no opinion about what a summary
says, so all of its rules are tested:

- Not while the user is speaking or a turn is being generated — it competes for the
  moment the app should be listening, and the last line is usually half-finished.
- Not below `minimumEntries` (4). A one-line "summary" of one line is that line again.
- Due on **count OR time**: every 12 conversational turns, or every 5 minutes.
- Never twice over the same lines: each summary starts strictly after `coveredThrough`.
- Never two at once: `isRunning` is held across the async call.
- A run that straddles a reconnect does not advance the *new* session's window.
- A summariser that returns nothing gets a 2-minute backoff — because the cadence is
  count-or-time, a window that already meets the count would otherwise re-fire on every
  single tick.

The result goes two places, controlled by `SummaryPolicy.Destination`:

- **A note** — markdown, one file per day.
- **The conversation** — filed with `sendSystemNote` as *context only, no response
  requested*. This is the part that pays for itself: the model can refer to what was said
  an hour ago without the whole history still being on the wire. A summary that made the
  assistant start talking unprompted every few minutes would be a worse app.

### Asking for one — the Summary button

The cadence above is the background half. The other half is somebody wanting the recap
*now*, which is almost always the moment a conversation ends.

`SummaryJob.sessionDigest(_:from:)` is that path, and it differs from the scheduled one in
two ways that matter:

- It covers the session **from the beginning**, not from `coveredThrough`. Somebody
  pressing Summary after four rolling summaries wants the conversation, not the last four
  minutes of it. It carries no `previousSummary` for the same reason — telling the
  summariser "do not repeat this" would make it omit the start.
- It takes the session id **as an argument** rather than reading the live one, so it still
  works once the socket is gone (`ConversationStore.summarizableSessionID` is the live
  session, or the last one on record). That is the state the app is in when the question
  gets asked.

The cadence does not apply — this is a deliberate request — but the floor does, lowered to
`minimumForRecap` (2). A "summary" of one line is that line again.

One implementation serves both callers, so they cannot disagree about what "this
conversation" means:

| Caller | Behaviour |
|---|---|
| The **Summary** button on the home screen | Opens the panel, then writes one. |
| The `summarize_conversation` tool ("summarise this") | Writes one silently. The answer is going to be read aloud; a sheet appearing over an ambient scene because somebody said a sentence is the app interrupting itself. |

### Where they are kept

Summaries used to go three places, none of which is "show me the recap of what we just
did": spoken into the transcript once (it scrolls away within a minute), filed into the
session as silent context (the model can see it; the user cannot), and appended to a
markdown note (a file in Application Support).

`SummaryView` is the fourth, and the only one meant to be re-read: every summary held this
launch, newest first, with its time range, turn count and which generator wrote it. Two
ways in — the **Summary** button under the orb, and a count badge in the transcript header
that appears once there is something to go back to. It is not filtered to the current
session, because the reason to open it is usually a conversation that has already ended.

### The summariser

`ExtractiveSummarizer` is the shipped default: no network, no key, no subprocess. It
selects the load-bearing lines rather than writing prose, which means it cannot
hallucinate and also means it reads like notes. That is the right trade for a
placeholder — it works offline on first launch, and it is obviously a placeholder, so
nobody ships it believing it is a language model. Every summary records which generator
wrote it, so a placeholder one and a model-written one are never confused later.

Swapping it is one argument to `SummaryService.init`. The prompt is already built
(`SummaryJob.prompt`), already carries the previous summary for continuity, and is
already written for speech — no markdown, no ids, no file paths.

## Where the real dependencies go

Four seams, each a named type with a comment rather than a TODO:

1. **`LocalTranscriber`** — on-device transcription. Needs two things, both deliberate:
   a second consumer on `AudioEngine.onMicPCM` (the mic routing change), and a recogniser
   (`SFSpeechRecognizer` needs `NSSpeechRecognitionUsageDescription` and a TCC prompt; a
   bundled whisper needs the samples buffered to a file first). Returns an obvious
   stand-in today so a transcript built from it can never be mistaken for the real thing.
2. **`AudioClipRecorder`** — would open an `AVAudioFile` per utterance and return its path
   for `UtteranceAudio.clipPath`. Must re-check `keepAudioClips` on every call, not once
   at construction: the user can turn it off mid-session and expect that to bite.
3. **`Summarizer`** — a real model. See above.
4. **`NotionNoteSink`** — needs a destination page the user has chosen and shared with the
   integration, and there is nowhere to choose one yet. `Notion` in this app is read-only
   today; the write path is one request, not an auth project, but the page picker comes
   first. It says what is missing rather than failing silently.

## Not done

- The other two stacks.
- Re-reading summaries from a previous launch. `SummaryView` shows what is in memory; the
  `.md` notes and the `.jsonl` files on disk are still write-only. Reading them back is the
  same missing capability as transcript search, below.
- Reading a past conversation back — the files are written and never re-read. Search over
  them is the obvious next feature and needs no new capture work.
- Summaries across sessions. `SummaryJob` is per-session by design; a daily digest would
  read the JSONL rather than extend it.
