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

## Useful inbound events
session.created / session.updated
input_audio_buffer.speech_started | speech_stopped   -> mic VU / "listening" state
conversation.item.input_audio_transcription.completed -> user transcript
response.output_audio_transcript.delta               -> assistant transcript (streaming)
response.output_text.delta                           -> text delta (text modality)
response.done                                        -> check .response.status
error                                                -> ALWAYS log these, they're specific
