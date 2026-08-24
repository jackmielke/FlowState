# OpenAI Realtime API — VERIFIED CONTRACT (probed live 2026-08-19)

Everything below was tested against the live API with the real key. Do NOT guess or
"correct" these from memory — training data is stale. If something fails, re-probe.

## Key location
`~/.config/vibe-voice/config.json` -> `{"OPENAI_API_KEY": "sk-proj-..."}` (chmod 600, OUTSIDE the repo)
NEVER hardcode the key. NEVER commit it. NEVER ship it to the renderer/webview.

## Model
`gpt-realtime-2.1`   <- latest, use this
Also available: gpt-realtime-2.1-mini, gpt-realtime-2, gpt-realtime-1.5, gpt-realtime,
gpt-realtime-mini, gpt-realtime-translate

## Voices (VERIFIED exact list)
alloy, ash, ballad, coral, echo, sage, shimmer, verse, marin, cedar
Default: marin.  `marin` and `cedar` are the newest/best.

## 1) Mint ephemeral token (server-side / main process ONLY)
POST https://api.openai.com/v1/realtime/client_secrets
  Authorization: Bearer <STANDARD sk-proj KEY>
  Content-Type: application/json
  {"session":{"type":"realtime","model":"gpt-realtime-2.1"}}
-> 200 {"value":"ek_...","expires_at":<unix>,"session":{...}}
The `value` (ek_...) is the ephemeral token. ~60s TTL to USE it; mint fresh per connection.

NOTE: legacy `POST /v1/realtime/sessions` is REMOVED -> 404 "Invalid URL". Do not use it.

## 2a) Connect via WebRTC (best for Electron/Tauri webviews)
POST https://api.openai.com/v1/realtime/calls?model=gpt-realtime-2.1
  Authorization: Bearer ek_...
  Content-Type: application/sdp
  body: <your SDP offer>
-> body is the SDP answer (set as remote description)
Add a `oai-events` data channel for JSON events. Attach mic track before creating offer.
Remote audio arrives on pc.ontrack -> attach to an <audio autoplay> element.

## 2b) Connect via WebSocket (best for Swift/native)
wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1
  Header: Authorization: Bearer <key or ek_>
Audio in/out = base64 PCM16 mono @ 24000 Hz.
  input_audio_buffer.append {audio: <b64 pcm16>}
  response.audio.delta / response.output_audio.delta -> b64 pcm16 to play

## Session config (VERIFIED default shape)
{"type":"session.update","session":{
  "type":"realtime",
  "instructions":"<system prompt>",
  "output_modalities":["audio"],           // or ["text"]
  "audio":{
    "input":{
      "format":{"type":"audio/pcm","rate":24000},
      "transcription":{"model":"gpt-4o-mini-transcribe"},   // opt-in, gives you user text
      "noise_reduction":{"type":"near_field"},              // optional
      "turn_detection":{"type":"server_vad","threshold":0.5,
        "prefix_padding_ms":300,"silence_duration_ms":500,
        "create_response":true,"interrupt_response":true}
    },
    "output":{"format":{"type":"audio/pcm","rate":24000},
              "voice":"marin","speed":1.0}
  }}}
NOTE the nesting: voice/turn_detection live under `audio`, NOT at session root.
`session.type:"realtime"` is REQUIRED in session.update.

## 3) Screenshots / vision — VERIFIED WORKING
Send an image as a conversation item, then request a response:
{"type":"conversation.item.create","item":{"type":"message","role":"user","content":[
   {"type":"input_image","image_url":"data:image/png;base64,<B64>"},
   {"type":"input_text","text":"What's on my screen?"}]}}
{"type":"response.create"}
TESTED: model correctly described the image. Works over WebSocket and over the
WebRTC `oai-events` data channel.
Downscale to ~1280px wide JPEG q0.7 before sending — full retina PNGs are huge and slow.

## One response at a time (VERIFIED — this is a hard rule, not a race)

A conversation may have exactly ONE response in flight. A second `response.create`
is refused:

```
{"type":"error","error":{"message":"Conversation already has an active response in progress"}}
```

The forbidden window opens when YOU send `response.create` — not when the server
answers `response.created`. Tracking only the server's event leaves a round trip in
which a second create looks legal, which is exactly how two land back to back.

Responses start from more places than you send them from. With
`turn_detection.create_response: true` the server opens a turn on its own every time
the user stops speaking, so the app can be busy without having asked for anything.

The rules that follow:

- Route every `response.create` through ONE gate. Queue anything asked for while busy
  and send it on `response.done` — deferred, coalesced into a single create, not dropped.
- Release the lock on `response.done` for EVERY status (`completed`, `cancelled`,
  `failed`, `incomplete`). Waiting for `completed` alone wedges the client.
- Hold queued creates while the user is speaking, and briefly after they stop — that
  is the window server VAD uses for its own turn.
- `{"type":"response.cancel"}` with nothing running answers
  `Cancellation failed: no active response found`. It is harmless, but it means a
  cancel is not a reliable way to "make sure" the conversation is idle.

## Useful inbound events
session.created / session.updated
input_audio_buffer.speech_started | speech_stopped   -> mic VU / "listening" state
conversation.item.input_audio_transcription.completed -> user transcript
response.output_audio_transcript.delta               -> assistant transcript (streaming)
response.output_text.delta                           -> text delta (text modality)
response.created                                     -> a response is now running (yours OR server VAD's)
response.done                                        -> check .response.status; ALWAYS releases the lock
error                                                -> ALWAYS log these, they're specific

## GPT-5 on /v1/chat/completions (summaries)

Live-probed 2026-08-22 against this account. All three of these differ from the
gpt-4.x request the summariser was built around, and two of them fail silently
enough to be worth writing down.

- `max_tokens` is REJECTED outright: *"Unsupported parameter: 'max_tokens' is not
  supported with this model. Use 'max_completion_tokens' instead."*
- `temperature: 0.3` is REJECTED: *"Only the default (1) value is supported."*
  Any non-default temperature, not just this one.
- **The reasoning tokens are billed against `max_completion_tokens`.** This is the
  dangerous one. Measured: a three-bullet summary request with
  `max_completion_tokens: 220` came back `finish_reason: "length"`, 220 reasoning
  tokens, and `content: ""`. Not an error — an empty string. Anything that treats
  "no content" as "the model had nothing to say" will silently fall through to its
  fallback and never report a problem.

  A real summary of an eight-line transcript spent **1,856 reasoning tokens** before
  writing 158 of output, so the budget has to be thousands, not hundreds.
  `ModelSummarizer.Grade.maxOutputTokens` uses 4,000.

- Latency is the other consequence: that same call took **26.7 s**. The 45 s timeout
  that was fine for `gpt-4.1-mini` is not obviously fine here; the summariser uses
  120 s for reasoning models.

Models confirmed available on this key: `gpt-5`, `gpt-5-mini`, `gpt-5-nano`,
`gpt-5-pro`, `gpt-5-codex`, `o3`, `o3-pro`, `o4-mini`, the `gpt-4.1` family.
