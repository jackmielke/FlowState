# Conversation memory — sessions, transcript capture, privacy, and rolling summaries

What FlowState keeps of a conversation, what it refuses to keep, how you get back to one
you had yesterday, and how a long session gets condensed into something it can still
refer to an hour later.

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
**anything decidable from its arguments lives in `FlowStateCore` and is tested; anything
that touches the world lives in the app target.** `ResponseCoordinator` is the precedent.

### FlowStateCore — the rules

| Type | Answers |
|---|---|
| `ConversationEntry` | One line: who, what, **when**, **which session**, where the text came from, what the audio looked like. |
| `UtteranceAudio` | The shape of an utterance — duration, sample rate, byte count, peak and RMS. Never samples. |
| `TranscriptPrivacy` | What may be recorded, what gets rewritten, how long it lives. |
| `TranscriptRetention` | How MANY conversations live, and whether they are written without being asked. |
| `TranscriptEdit` | A correction to a line already on disk — or, with no text, a deletion of one. |
| `ConversationLog` | The bounded in-memory record. Every write goes through privacy here, and nowhere else. |
| `SessionMeta` / `SessionCatalog` | The list of saved conversations: what each is called, when it was last touched, how many turns it holds, which realtime sessions it ran under, and whether it is **pinned**. |
| `SessionTitle` | What a conversation is called, from what was said in it — or from the clock, when nothing was. |
| `SessionID` | Minting a conversation id that is safe to use as a file name. |
| `ConversationArchive` | The JSONL format, in both directions, plus rebuilding the session list from the files alone. |
| `SummaryJob` | When a summary is due, what window it covers, and what prompt describes it. |
| `SummaryPolicy` | Cadence and destination. |
| `Summarizer` | The seam a real model plugs into. `ExtractiveSummarizer` is the offline default. |

### App target — the world

| Type | Owns |
|---|---|
| `ConversationStore` | The clock, the JSONL files, the index, session lifecycle, deletion. |
| `UtteranceRecorder` | Metering on the audio thread. Lock-based, like `LevelBox` beside it. |
| `UserTranscriber` | The transcription seam. `RealtimeAPITranscriber` (live) / `LocalTranscriber` (placeholder). |
| `AudioClipRecorder` | Where audio *would* be written. Currently refuses, on purpose. |
| `TranscriptLog` | Every lifecycle event on the console, in one format. `log stream --predicate 'category == "transcript"'`. |
| `SummaryService` | Runs the job, calls the summariser, delivers the result. |
| `NoteSink` | `MarkdownNoteSink` (real) / `NotionNoteSink` (placeholder). |

## Sessions

A session is one conversation. It is the unit everything else here is filed under — a
transcript file, a set of summaries, a name in the switcher, a "forget this" that means
something specific.

### Why it is not the API's session id

It used to be. `session.created` arrives on the socket, and entries were filed under
whatever id it carried. That is wrong in three ways, and the third one was losing data:

1. It does not exist until a socket opens. A conversation has to be able to own a file
   before anybody has connected — a note filed before connecting, a summary asked for
   after disconnecting.
2. It changes on every reconnect. A dropped socket in the middle of a sentence started a
   **second transcript file**, and neither half knew about the other. Nothing was
   corrupted; the conversation was simply cut in two, silently.
3. It is absent entirely when somebody is reading back a saved conversation with nothing
   connected — which is now a thing you can do.

So the app mints its own: `SessionID.mint` → `chat-20260821-150412-9f3a`. Sortable,
readable in a directory listing, and safe as a file name. The API's ids are kept
alongside in `SessionMeta.realtimeIDs`, appended rather than replaced, so a transcript can
still be lined up with anything the API reports later.

### Default behaviour

| | |
|---|---|
| **Launching** | The conversation you were last in, restored with its history — "Pick up where I left off" is **on** by default. |
| **Launching, with it off** | A new conversation. The previous one is saved, named, and one click away in the switcher. |
| **Launching, with a conversation pinned** | The pinned one, whatever that setting says. |
| **⌘N / New conversation** | A new one. Nothing is deleted. If a socket is open it is closed first — see below. |
| **Picking one from the switcher** | That conversation's transcript is read off disk and put back on screen. |
| **Connecting, disconnecting, reconnecting** | All the same conversation. Only the realtime id changes, and that is recorded, not acted on. |
| **Quitting** | Nothing to do. Every line was already written when it was said. |

New-every-launch was the default for a while, on the argument that what you say now
should not be silently appended to a conversation from Tuesday. It lost to what it looked
like: a transcript that is on screen one minute and gone after a relaunch reads as a
transcript that was thrown away, whatever the switcher says. Starting fresh is still one
click — and it is a click, which is the right way round. Nothing is lost either way; the
setting only decides which conversation is in front of you when FlowState opens.

**Switching closes an open socket, deliberately.** The realtime model carries the previous
conversation in its own context; keeping the socket open across a switch would produce a
conversation called "new" that still remembers the old one. That is the kind of quiet lie
that makes people stop trusting an app. A new socket is a genuinely clean slate, and the
Connect button is right there.

### Titles

A session id is the right name for a file and a useless name for a human, so every
conversation also carries a title. `SessionTitle` generates one from three sources, in
descending order of how much they actually say:

1. **What the user asked for.** The first substantive user line, with the throat-clearing
   taken off the front — "hey FlowState, could you tighten up the spacing on that button"
   becomes *Tighten up the spacing on that button*. Not simply the first line: openings
   are "hey" and "you there?" far more often than they are the question, and a sidebar
   full of conversations called "Hey" is a sidebar nobody reads twice.
2. **The running summary.** For conversations the user drove entirely in monosyllables —
   "yes", "do it", "no, the other one" — the summary is the only thing that knows what it
   was about.
3. **The clock.** *This afternoon*, *Yesterday morning*, *Friday evening*, *21 Jul
   afternoon*. Always available, so a conversation is never nameless, and honest about
   saying nothing when there is nothing to say.

Two rules keep a title findable rather than merely accurate:

- **It settles.** An auto title is regenerated while the conversation is under
  `SessionTitle.settlesAfter` (10) turns and then frozen. A title that keeps rewriting
  itself cannot be found twice.
- **A user's name is final.** Rename it and nothing regenerates it, ever. Clearing the
  field hands it back to the generator. Two conversations that generate the *same* title
  get the time appended — but only the duplicates pay for it.

All of it is decidable from its arguments — no clock it did not receive, no locale it did
not receive, no disk — which is why it is in Core and tested (`SessionTitleTests`).

### The index, and why losing it costs nothing

`sessions.json` holds one `SessionMeta` per conversation. It is a cache over the
transcripts and never the truth:

- A **file with no row** — from a build before this one, or an index that got lost — is
  parsed and given a row (`ConversationArchive.meta`). Only files the index does not
  already describe are read, so a normal launch parses no transcripts at all.
- A **row with no file** — deleted by retention, by `rm`, by "delete everything" — is
  dropped, so the switcher never offers a conversation that opens empty.

Deleting `sessions.json` therefore costs exactly one thing: the titles a user typed by
hand, which were never in the transcript to recover.

### Reading back

`ConversationArchive.parse` is deliberately forgiving. A truncated last line — the app
quit mid-write — or a record kind from a later version costs that line and nothing else.
Refusing the file would throw away a whole conversation to protect nobody from a missing
sentence. The count of what was skipped is surfaced in Settings rather than swallowed.

Restored lines go into `ConversationLog.restore`, **not** `append`. They were already
admitted, redacted and stored by the policy in force when they were said; running them
through the door a second time would re-redact redacted text and — worse — would drop the
user's entire history the moment they paused recording, because `append` refuses
everything while paused. The one thing privacy still governs on the way back in is
retention: a transcript past its window does not come back to life because somebody
clicked on it.

## Keeping a transcript

A transcript is only worth having if it is still there later. Four controls decide that,
and they are deliberately four rather than one, because they answer different questions.

| Control | Where | What it does | What it does **not** do |
|---|---|---|---|
| **Pin** (⌘⇧P, or the pin in the transcript header) | Per conversation, in `SessionMeta.pinned` | Keeps it: retention skips it, the keep-last limit does not count it, launch reopens it, and in "Only what I save" it is written immediately. | Protect it from Delete, or from switching `persistToDisk` off. |
| **Hide** (⌘⇧H, the eye) | App-wide, `AppSettings.transcriptHidden` | Takes the column off screen for a screen share. | Stop recording, stop saving, or delete anything. |
| **Retention mode** | Settings › Conversations | *Keep everything* / *Keep last N* / *Only what I save*. | Change what is captured — that is `TranscriptPrivacy`. |
| **Retention hours** | Settings › Memory & privacy | Deletes anything older than the window, including what is already there. | Touch pinned conversations. |

### Pinning

A pin is a standing instruction about one conversation, and it is honoured in four
places — `ConversationLog.purgeExpired`, `ConversationStore.purgeExpiredFiles`,
`TranscriptRetention.sessionsToTrim` and `SessionCatalog.sessionToResume`. It is stored
in the index, which is the one thing in `sessions.json` that is not recoverable from the
transcripts, so `SessionMeta` decodes with `decodeIfPresent` throughout: an index written
by an older build has no `pinned` key, and the whole array is read with `try?`, so a
strict decoder would trade every custom title in the file for one absent boolean.

The state is visible in two places at once — a filled, tinted pin in the header and a
PINNED badge at the top of the column — because a lock you have to click to identify is
not a lock.

**Where a pin loses:** turning *Save to disk* off deletes every transcript, pinned ones
included. That is the user asking for nothing on disk at all, which is a bigger statement
than "keep this one". It is said out loud in the console log and in the Settings caption
rather than discovered afterwards.

### Retention modes

`TranscriptRetention` counts **conversations**, not lines. A transcript is the thing a
user names, reopens and deletes; trimming the conversation somebody is reading down to
its last N lines would silently rewrite it under them.

- **Keep everything** — written as it happens, kept until the hours window or the user
  removes it.
- **Keep last N** — the newest N survive. Pinned conversations are exempt *and* do not
  use up a place. The conversation on screen is never trimmed.
- **Only what I save** — nothing reaches disk until *Save transcript now* (⌘S) or a pin.
  Saving merges what is in memory with whatever is already in the file and rewrites it
  atomically, so saving twice leaves one copy of everything.

### Editing a line

Voice transcription gets names, jargon and accents wrong, and a record you cannot correct
is one that slowly stops matching what was said. Double-click any user or assistant line
to rewrite it; right-click for *Edit* / *Copy* / *Delete line*. System notes are not
editable — they are the app's own account of what it did, and a rewritable one would be
worthless as evidence.

Corrections do **not** rewrite the file. A `TranscriptEdit` is appended after the line it
corrects and folded over the top on the way back in (`ConversationArchive.apply`), which
keeps writing safe during a live conversation and keeps the cost of a truncated last line
at one sentence. Later edits beat earlier ones, deletion beats an earlier edit, and an
edit naming a line that is not in the file is dropped rather than resurrecting an entry
from nothing. An edited line keeps its original timestamp, so correcting something an
hour later does not move it to an hour later.

The text before the edit is not kept anywhere. An edit is the user changing what the
record says about them, and a history of that would defeat the point of offering it.

### Lifecycle on the console

Every one of these events goes through `TranscriptLog`, in one format, to both `os.Logger`
(category `transcript`) and stderr:

```
[transcript] appended · chat-20260824-101500-a1b2 · user, 42 chars, memory only
[transcript] saved · chat-20260824-101500-a1b2 · 6 lines, 1.4 kB → chat-….jsonl
[transcript] loaded · chat-20260824-101500-a1b2 · 34 lines, 1 summary, 2 corrections folded in
[transcript] pinned · chat-20260824-101500-a1b2 · locked — retention will skip it
[transcript] hidden · chat-20260824-101500-a1b2 · 34 lines hidden from view — nothing was deleted
[transcript] trimmed · chat-20260821-090000-77c1 · past the keep-last-20 limit
```

`appended … memory only` is the one worth knowing about: it is how "Only what I save"
looks while it is working, and it is the difference between a conversation that is being
kept and one that is merely on screen.

### Proving it

`Scripts/verify-transcript.sh` compiles the real `ConversationStore` on its own — it
imports Foundation, Combine and FlowStateCore and nothing else — over a temporary
`FLOWSTATE_HOME`, then writes, throws the store away, builds a new one over the same
folder and asks what it remembers. Seven groups: written to disk at 0600, read back after
a "restart", corrected and deleted per line, pinned across a restart and past its
retention window, trimmed by keep-last, held out of disk by manual-save, and finally
deleted for real. It is the only place the promise "your conversation is still here
after a restart" can actually be checked, because it is the only place there are two
launches.

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
| `retentionHours` | 168 (a week) | Enforced on every purge, not only at write time, so turning it down deletes. Pinned conversations are exempt. |
| `retention.mode` | Keep everything | Counting and manual-save live in `TranscriptRetention`, not here: they decide how many recordings are kept, not what is recorded. |
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
moment they are already talking: `stop_transcript`, `resume_transcript`,
`forget_conversation`, `memory_status`, `summarize_conversation`. Stopping needs no
confirmation; resuming and forgetting do (`ToolSpec.Effect.writes`).

The first two were called `pause_recording` and `resume_recording` until the recorder
itself became sayable — see `VoiceCommand`, which owns `start_recording`, `stop_recording`,
`pause_recording` and `resume_recording` now. Those names mean the FILE; these mean the
TRANSCRIPT. One name for both was a coin toss the model would eventually lose, and losing
it in the "don't write this down" direction is the expensive way round.

## On disk

```
~/Library/Application Support/FlowState/
  settings.json                      everything in AppSettings
  sessions.json                      the session index, 0600 — a cache, never the truth
  conversations/<sessionID>.jsonl    one JSON object per line, 0600
                                     kinds: entry, summary, edit, delete
  notes/<yyyy-MM-dd>.md              summaries, appended
  audio/                             would hold clips. Nothing writes here today.
```

JSONL rather than a database because the point of a privacy control is that the user can
go and look at what was kept and delete it with `rm`. A file they can read is worth more
here than an index they cannot. Session ids are minted by the app and reduced to
`[A-Za-z0-9-_]` before becoming a path (`SessionID.sanitize`).

`FLOWSTATE_HOME` moves the whole directory somewhere else for the length of one launch.
It exists so this half of the app can be exercised for real — quit it, start it again,
check the conversation came back — without a test run rummaging through actual
conversations.

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
- **Search across conversations.** The files are read back now, one conversation at a
  time, by name. Searching all of them is the obvious next feature and needs no new
  capture work — `ConversationArchive.parse` is already the whole reading half.
- **Switching conversations by voice.** Every other memory control is reachable by voice
  (`stop_transcript`, `forget_conversation`, …); "open the one about the release script"
  is not, and would need the title search above to be worth anything.
- Re-reading the `.md` note files from a previous launch. `SummaryView` shows summaries
  held in memory, which now includes the ones restored with a conversation — but the
  notes directory is still write-only.
- Summaries across sessions. `SummaryJob` is per-session by design; a daily digest would
  read the JSONL rather than extend it.
- Exporting a conversation as anything but the JSONL it already is.
- **Compacting a transcript.** Corrections accumulate as extra records; a file edited a
  hundred times is a hundred lines longer than the conversation in it. Nothing rewrites
  the file to fold them down, because the only safe moment to do that is one nobody is
  writing in, and "Save transcript now" already produces a clean file when it matters.
- **Undo.** A deleted line is gone from the record as well as the screen; the text before
  an edit is not kept. Both are deliberate — see above — and both mean the confirmation
  is the only safety there is.
