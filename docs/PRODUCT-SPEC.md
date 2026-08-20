# Vibe Voice — shared product spec (all 3 implementations must match)

A local-only macOS app for talking to OpenAI's realtime voice model, which can also
look at your screen. Three parallel implementations (electron/, swiftui/, tauri/)
built to the SAME spec so they can be compared head-to-head.

## Core features (required in all three)
1. **Push-to-talk-free voice chat** — open the app, hit Connect, just talk.
   Server VAD handles turn-taking. Barge-in (interrupting the model) must work.
2. **Live transcript** — scrolling conversation view, user + assistant turns,
   assistant text streams in as it speaks.
3. **Screenshot on demand** — a visible button AND a global hotkey (default ⌘⇧2).
   Captures the screen, downscales to ~1280px JPEG, sends to the model, model talks
   about it. Show a thumbnail of what was sent in the transcript.
4. **Continuous screen mode** — settings toggle + interval slider (2–30s, default 5s).
   When ON, auto-sends a frame on that interval. Must show a clear "watching" indicator
   so it is never ambiguous that the screen is being streamed.
5. **Settings panel** — persisted to disk across launches:
   - voice (alloy/ash/ballad/coral/echo/sage/shimmer/verse/marin/cedar)
   - model (default gpt-realtime-2.1)
   - system prompt / personality (multiline)
   - speaking speed (0.5–1.5)
   - continuous screen on/off + interval
   - VAD threshold + silence duration
6. **Connection state** — obvious idle / connecting / live / error states. Errors from
   the API must surface in the UI with the real message, not a generic "failed".
7. **Mic level meter** — live input level so you can tell it's hearing you.

## Design direction
Dark, modern, "state-of-the-art". Think Linear / Raycast / Arc.
- Deep near-black background, not pure #000. Subtle depth.
- ONE accent color used with restraint. Suggested: a warm signal color.
- A central voice orb/visualizer that reacts to real audio amplitude — this is the
  centerpiece, make it genuinely beautiful. Reacts differently when the user is
  speaking vs when the assistant is speaking.
- Typography: SF Pro / system font. Tight, confident spacing. No cramped rows.
- Motion: everything eases. Nothing snaps. 150–250ms curves.
- Frameless / vibrancy window where the stack allows it.
- **Rounded window corners are mandatory.** A hard square perimeter instantly reads
  as unfinished on macOS. Note that going frameless/transparent often *removes* the
  system rounding, so it must be restored explicitly and then verified — screenshot
  against a LIGHT background, because dark square corners on a dark desktop look
  rounded when they are not. No child element may paint past the corner radius.
- Must look intentional, not bootstrap-y. No default-looking form controls.

## Hard constraints
- **One response at a time, and never a collision.** The API allows a single response
  per conversation and refuses a second `response.create` with "Conversation already
  has an active response in progress". Every request for a spoken turn must go through
  one gate that knows whether a response is running — counting from the moment the
  create is SENT, not from `response.created`. A request made while busy is deferred to
  `response.done` and coalesced, never dropped and never stacked. This one error is
  therefore exempt from rule 6 above: it means the app got its own bookkeeping wrong,
  so it is repaired silently and logged, not shown to the user. Every other API error
  still surfaces verbatim.
- **The app can always get unstuck.** If a response never finishes, the client must
  recover on its own (deadline → cancel → force idle) and offer the user an explicit
  Stop that works without disconnecting. Going permanently mute is a failure.
- **Boots IDLE. Never auto-connect.** The app must open disconnected, with no mic
  capture and no audio output, until a human explicitly clicks Connect. Learned the
  hard way: all three implementations auto-connected at once and started talking to
  each other through the speakers. There is no auto-connect flag, ever.
- **Only one implementation may hold a live session at a time.** They share one pair
  of speakers and one mic. Launch them one at a time.
- Local only. No servers, no telemetry, no analytics.
- API key read from ~/.config/vibe-voice/config.json at runtime.
  NEVER hardcoded, NEVER committed, NEVER exposed to a renderer/webview process —
  mint an ephemeral ek_ token in the trusted process and pass only that.
- Must actually RUN and CONNECT. A pretty UI that doesn't talk to the API is a failure.
- macOS permissions (mic, screen recording) must be requested with clear prompts and
  the app must degrade gracefully + tell the user how to fix it if denied.
