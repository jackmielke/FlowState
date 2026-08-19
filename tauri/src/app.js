/* Vibe Voice — webview side.
 *
 * Transport: WebRTC straight from WKWebView to OpenAI (verified working, see README).
 * The webview only ever holds an ek_ ephemeral token; the sk-proj key stays in Rust.
 */

const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);
const listen = (evt, cb) => window.__TAURI__.event.listen(evt, cb);

const rlog = (level, message) => {
  try { invoke("js_log", { level, message: String(message) }); } catch (_) {}
};
window.onerror = (m, src, line) => rlog("error", `${m} @${src}:${line}`);
window.onunhandledrejection = (e) => rlog("error", `unhandled rejection: ${e.reason}`);

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- state ----

const S = {
  settings: null,
  pc: null,
  dc: null,
  micStream: null,
  audioCtx: null,
  micAnalyser: null,
  outAnalyser: null,
  conn: "idle",           // idle | connecting | live | error
  userSpeaking: false,
  assistantSpeaking: false,
  micLevel: 0,
  outLevel: 0,
  liveTurn: null,         // streaming assistant DOM node
  contTimer: null,
  shotsInFlight: 0,
};

// ---------------------------------------------------------------- chrome ---

function setConn(state, text) {
  S.conn = state;
  $("state-pill").dataset.state = state;
  $("state-text").textContent = text || state[0].toUpperCase() + state.slice(1);
  const live = state === "live";
  $("btn-connect").textContent = live ? "Disconnect" : state === "connecting" ? "Connecting…" : "Connect";
  $("btn-connect").classList.toggle("primary", !live);
  $("btn-connect").classList.toggle("danger", live);
  $("btn-connect").disabled = state === "connecting";
  $("btn-shot").disabled = !live;
  $("btn-watch").disabled = !live;
  if (!live) {
    $("who").dataset.who = "none";
    $("who").textContent = state === "error" ? "Disconnected" : "Not connected";
    $("hint").textContent = state === "connecting"
      ? "Minting a token and opening the peer connection…"
      : "Press Connect and just start talking.";
  }
}

function showError(msg) {
  rlog("error", msg);
  $("banner-text").innerHTML = `<b>Error</b>&nbsp; ${escapeHtml(String(msg))}`;
  $("banner").classList.add("show");
}
$("banner-close").onclick = () => $("banner").classList.remove("show");

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// ------------------------------------------------------------ transcript ---

function clearEmpty() {
  const e = $("transcript").querySelector(".empty");
  if (e) e.remove();
}

function addTurn(role, text, opts = {}) {
  clearEmpty();
  const wrap = document.createElement("div");
  wrap.className = `turn ${role}`;
  const label = document.createElement("div");
  label.className = "role";
  label.textContent = opts.label || (role === "user" ? "You" : role === "assistant" ? "Vibe" : "");
  if (label.textContent) wrap.appendChild(label);
  const body = document.createElement("div");
  body.className = "body";
  if (opts.image) {
    const img = document.createElement("img");
    img.className = "shot";
    img.src = opts.image;
    body.appendChild(img);
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.style.marginTop = "6px";
    meta.textContent = text;
    body.appendChild(meta);
  } else {
    body.textContent = text;
  }
  wrap.appendChild(body);
  $("transcript").appendChild(wrap);
  $("transcript").scrollTop = $("transcript").scrollHeight;
  return { wrap, body };
}

function assistantDelta(chunk) {
  if (!S.liveTurn) {
    S.liveTurn = addTurn("assistant", "");
    S.liveTurn.body.classList.add("cursor-blink");
  }
  S.liveTurn.body.textContent += chunk;
  $("transcript").scrollTop = $("transcript").scrollHeight;
}

function assistantDone() {
  if (S.liveTurn) S.liveTurn.body.classList.remove("cursor-blink");
  S.liveTurn = null;
}

// ------------------------------------------------------------- settings ----

const VOICES = ["alloy","ash","ballad","coral","echo","sage","shimmer","verse","marin","cedar"];

async function loadSettings() {
  S.settings = await invoke("load_settings");
  const s = S.settings;
  $("s-voice").value = VOICES.includes(s.voice) ? s.voice : "marin";
  $("s-model").value = s.model;
  $("s-instructions").value = s.instructions;
  $("s-speed").value = s.speed;
  $("s-interval").value = s.interval_s;
  $("s-vad").value = s.vad_threshold;
  $("s-silence").value = s.silence_ms;
  $("s-continuous").classList.toggle("on", s.continuous);
  $("s-transcribe").classList.toggle("on", s.transcribe);
  paintSettingLabels();
  applyContinuous();
}

function paintSettingLabels() {
  const s = S.settings;
  $("s-speed-val").textContent = Number(s.speed).toFixed(2) + "×";
  $("s-interval-val").textContent = s.interval_s + "s";
  $("s-vad-val").textContent = Number(s.vad_threshold).toFixed(2);
  $("s-silence-val").textContent = s.silence_ms + " ms";
}

let saveTimer = null;
function persist(pushToSession = true) {
  paintSettingLabels();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    invoke("save_settings", { settings: S.settings }).catch((e) => showError("Could not save settings: " + e));
  }, 250);
  if (pushToSession && S.dc && S.dc.readyState === "open") sendSessionUpdate();
}

function bindSettings() {
  $("s-voice").onchange = (e) => { S.settings.voice = e.target.value; persist(); };
  $("s-model").onchange = (e) => { S.settings.model = e.target.value; persist(false); };
  $("s-instructions").oninput = (e) => { S.settings.instructions = e.target.value; persist(); };
  $("s-speed").oninput = (e) => { S.settings.speed = parseFloat(e.target.value); persist(); };
  $("s-interval").oninput = (e) => { S.settings.interval_s = parseInt(e.target.value); persist(false); applyContinuous(); };
  $("s-vad").oninput = (e) => { S.settings.vad_threshold = parseFloat(e.target.value); persist(); };
  $("s-silence").oninput = (e) => { S.settings.silence_ms = parseInt(e.target.value); persist(); };
  $("s-continuous").onclick = () => {
    S.settings.continuous = !S.settings.continuous;
    $("s-continuous").classList.toggle("on", S.settings.continuous);
    persist(false); applyContinuous();
  };
  $("s-transcribe").onclick = () => {
    S.settings.transcribe = !S.settings.transcribe;
    $("s-transcribe").classList.toggle("on", S.settings.transcribe);
    persist();
  };
  $("btn-privacy-screen").onclick = () => invoke("open_privacy_pane", { which: "screen" });
  $("btn-privacy-mic").onclick = () => invoke("open_privacy_pane", { which: "mic" });

  const open = (v) => { $("drawer").classList.toggle("show", v); $("scrim").classList.toggle("show", v); };
  $("btn-settings").onclick = () => open(true);
  $("btn-close-settings").onclick = () => open(false);
  $("scrim").onclick = () => open(false);
}

// ------------------------------------------------------- continuous mode ---

function applyContinuous() {
  const on = S.settings.continuous;
  $("btn-watch").classList.toggle("on", on);
  $("btn-watch").textContent = on ? "Watching" : "Watch";
  $("watching").classList.toggle("show", on && S.conn === "live");
  clearInterval(S.contTimer);
  S.contTimer = null;
  if (on) {
    S.contTimer = setInterval(() => {
      if (S.conn === "live" && !S.assistantSpeaking && !S.userSpeaking) sendScreenshot(true);
    }, Math.max(2, S.settings.interval_s) * 1000);
  }
}

// -------------------------------------------------------------- connect ----

async function connect() {
  if (S.conn === "live") return disconnect();
  setConn("connecting");
  try {
    // 1. mic first — a failure here is the clearest error to report.
    S.micStream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });

    // 2. ephemeral token from Rust (sk-proj never reaches this process)
    const tok = await invoke("mint_ephemeral_token", { model: S.settings.model });
    rlog("info", `minted ${tok.value.slice(0, 6)}… for ${tok.model}`);

    // 3. peer connection
    const pc = new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.l.google.com:19302" }] });
    S.pc = pc;

    pc.ontrack = (e) => {
      const el = $("remote-audio");
      el.srcObject = e.streams[0];
      el.play().catch(() => {});
      attachOutputAnalyser(e.streams[0]);
      rlog("info", "remote audio track attached");
    };
    pc.onconnectionstatechange = () => {
      rlog("info", "pc.connectionState=" + pc.connectionState);
      if (["failed", "closed"].includes(pc.connectionState) && S.conn === "live") {
        setConn("error", "Dropped");
        showError("Peer connection " + pc.connectionState);
      }
    };

    pc.addTrack(S.micStream.getAudioTracks()[0], S.micStream);
    attachMicAnalyser(S.micStream);

    const dc = pc.createDataChannel("oai-events");
    S.dc = dc;
    dc.onopen = () => { rlog("info", "oai-events open"); sendSessionUpdate(); };
    dc.onmessage = (ev) => handleEvent(JSON.parse(ev.data));
    dc.onclose = () => rlog("info", "oai-events closed");

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    const res = await fetch(
      `https://api.openai.com/v1/realtime/calls?model=${encodeURIComponent(S.settings.model)}`,
      {
        method: "POST",
        headers: { Authorization: `Bearer ${tok.value}`, "Content-Type": "application/sdp" },
        body: offer.sdp,
      }
    );
    const answer = await res.text();
    if (!res.ok) throw new Error(`OpenAI ${res.status}: ${answer.slice(0, 300)}`);
    await pc.setRemoteDescription({ type: "answer", sdp: answer });
    rlog("info", "SDP answer applied (" + res.status + ")");
  } catch (e) {
    setConn("error", "Error");
    if (e && (e.name === "NotAllowedError" || e.name === "SecurityError")) {
      showError("Microphone access was denied. Open System Settings › Privacy & Security › Microphone and enable Vibe Voice, then reconnect.");
    } else {
      showError(e && e.message ? e.message : e);
    }
    teardown();
  }
}

function teardown() {
  try { S.dc && S.dc.close(); } catch (_) {}
  try { S.pc && S.pc.close(); } catch (_) {}
  try { S.micStream && S.micStream.getTracks().forEach((t) => t.stop()); } catch (_) {}
  S.dc = S.pc = S.micStream = null;
  S.micAnalyser = S.outAnalyser = null;
  S.userSpeaking = S.assistantSpeaking = false;
  $("watching").classList.remove("show");
}

function disconnect() {
  teardown();
  setConn("idle");
  addTurn("system", "Session ended.");
}

// ------------------------------------------------------------- protocol ----

function sendSessionUpdate() {
  const s = S.settings;
  const input = {
    format: { type: "audio/pcm", rate: 24000 },
    noise_reduction: { type: "near_field" },
    turn_detection: {
      type: "server_vad",
      threshold: s.vad_threshold,
      prefix_padding_ms: 300,
      silence_duration_ms: s.silence_ms,
      create_response: true,
      interrupt_response: true,
    },
  };
  if (s.transcribe) input.transcription = { model: "gpt-4o-mini-transcribe" };

  send({
    type: "session.update",
    session: {
      type: "realtime",
      instructions: s.instructions,
      output_modalities: ["audio"],
      audio: {
        input,
        output: { format: { type: "audio/pcm", rate: 24000 }, voice: s.voice, speed: s.speed },
      },
    },
  });
}

function send(obj) {
  if (!S.dc || S.dc.readyState !== "open") return false;
  S.dc.send(JSON.stringify(obj));
  return true;
}

function handleEvent(m) {
  switch (m.type) {
    case "session.created":
      setConn("live", "Live");
      $("who").dataset.who = "none";
      $("who").textContent = "Listening";
      $("hint").textContent = "Just talk — server VAD handles the turns. Interrupt any time.";
      $("watching").classList.toggle("show", S.settings.continuous);
      addTurn("system", `Session live · ${S.settings.model} · voice ${S.settings.voice}`);
      rlog("ok", "SESSION.CREATED — realtime session is live");
      break;

    case "session.updated":
      rlog("info", "session.updated applied");
      break;

    case "input_audio_buffer.speech_started":
      S.userSpeaking = true;
      $("who").dataset.who = "user";
      $("who").textContent = "You're speaking";
      // barge-in: drop whatever is still buffered locally
      if (S.assistantSpeaking) { assistantDone(); S.assistantSpeaking = false; }
      break;

    case "input_audio_buffer.speech_stopped":
      S.userSpeaking = false;
      $("who").dataset.who = "none";
      $("who").textContent = "Thinking…";
      break;

    case "conversation.item.input_audio_transcription.completed":
      if (m.transcript && m.transcript.trim()) addTurn("user", m.transcript.trim());
      break;

    case "response.output_audio.delta":
      S.assistantSpeaking = true;
      $("who").dataset.who = "assistant";
      $("who").textContent = "Vibe is speaking";
      break;

    case "response.output_audio_transcript.delta":
    case "response.audio_transcript.delta":
      S.assistantSpeaking = true;
      $("who").dataset.who = "assistant";
      $("who").textContent = "Vibe is speaking";
      assistantDelta(m.delta || "");
      break;

    case "response.output_text.delta":
      assistantDelta(m.delta || "");
      break;

    case "response.done":
      assistantDone();
      S.assistantSpeaking = false;
      $("who").dataset.who = "none";
      $("who").textContent = "Listening";
      if (m.response && m.response.status === "failed") {
        const err = m.response.status_details && m.response.status_details.error;
        showError("Response failed: " + (err ? `${err.type}: ${err.message}` : JSON.stringify(m.response.status_details)));
      }
      break;

    case "error":
      showError(m.error ? `${m.error.type || "error"}: ${m.error.message}` : JSON.stringify(m));
      break;

    default:
      break;
  }
}

// ------------------------------------------------------------ screenshot ---

async function sendScreenshot(auto = false) {
  if (S.conn !== "live") return;
  if (S.shotsInFlight > 0) return;
  S.shotsInFlight++;
  try {
    const shot = await invoke("capture_screen", { maxWidth: 1280 });
    const prompt = auto
      ? "Here is my screen again. Only speak up if something meaningful changed or if I asked you something."
      : "Here's my screen. What do you see?";
    const ok = send({
      type: "conversation.item.create",
      item: {
        type: "message",
        role: "user",
        content: [
          { type: "input_image", image_url: shot.data_url },
          { type: "input_text", text: prompt },
        ],
      },
    });
    if (!ok) throw new Error("Data channel not open");
    send({ type: "response.create" });
    addTurn("user", `${shot.width}×${shot.height} · ${(shot.bytes / 1024).toFixed(0)} KB${auto ? " · auto" : ""}`, {
      image: shot.data_url,
      label: auto ? "Screen (auto)" : "Screen",
    });
  } catch (e) {
    showError(String(e));
  } finally {
    S.shotsInFlight--;
  }
}

// --------------------------------------------------------------- audio -----

function ensureCtx() {
  if (!S.audioCtx) S.audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  if (S.audioCtx.state === "suspended") S.audioCtx.resume();
  return S.audioCtx;
}

function attachMicAnalyser(stream) {
  const ctx = ensureCtx();
  const src = ctx.createMediaStreamSource(stream);
  const an = ctx.createAnalyser();
  an.fftSize = 1024;
  an.smoothingTimeConstant = 0.75;
  src.connect(an);
  S.micAnalyser = an;
}

function attachOutputAnalyser(stream) {
  const ctx = ensureCtx();
  try {
    const src = ctx.createMediaStreamSource(stream);
    const an = ctx.createAnalyser();
    an.fftSize = 1024;
    an.smoothingTimeConstant = 0.7;
    const mute = ctx.createGain();
    mute.gain.value = 0;             // the <audio> element does the actual playback
    src.connect(an);
    an.connect(mute);
    mute.connect(ctx.destination);   // Safari needs a sink or the graph never pulls
    S.outAnalyser = an;
  } catch (e) {
    rlog("warn", "output analyser unavailable: " + e);
  }
}

const buf = new Uint8Array(512);
function levelOf(an) {
  if (!an) return 0;
  an.getByteTimeDomainData(buf);
  let sum = 0;
  for (let i = 0; i < buf.length; i++) {
    const v = (buf[i] - 128) / 128;
    sum += v * v;
  }
  return Math.sqrt(sum / buf.length);
}

function bandsOf(an, out) {
  if (!an) { out.fill(0); return out; }
  const freq = new Uint8Array(an.frequencyBinCount);
  an.getByteFrequencyData(freq);
  const per = Math.floor(freq.length * 0.55 / out.length);
  for (let i = 0; i < out.length; i++) {
    let s = 0;
    for (let j = 0; j < per; j++) s += freq[i * per + j];
    out[i] = s / per / 255;
  }
  return out;
}

// ----------------------------------------------------------------- orb -----

const canvas = $("orb");
const g = canvas.getContext("2d");
const NB = 24;
const micBands = new Float32Array(NB);
const outBands = new Float32Array(NB);
let smoothed = new Float32Array(NB);
let t = 0;
let dpr = 1;

function sizeCanvas() {
  dpr = Math.min(window.devicePixelRatio || 1, 2);
  const css = 340;
  canvas.width = css * dpr;
  canvas.height = css * dpr;
  canvas.style.width = css + "px";
  canvas.style.height = css + "px";
}
sizeCanvas();
window.addEventListener("resize", sizeCanvas);

const ACCENT = [255, 122, 69];
const USER = [108, 198, 255];
const IDLE = [120, 120, 135];
let mixed = IDLE.slice();

const lerp = (a, b, k) => a + (b - a) * k;
const rgba = (c, a) => `rgba(${c[0] | 0},${c[1] | 0},${c[2] | 0},${a})`;

function draw() {
  requestAnimationFrame(draw);
  t += 0.016;

  const mic = levelOf(S.micAnalyser);
  const out = levelOf(S.outAnalyser);
  S.micLevel = lerp(S.micLevel, mic, 0.28);
  S.outLevel = lerp(S.outLevel, out, 0.28);
  $("meter-fill").style.width = Math.min(100, S.micLevel * 340) + "%";

  bandsOf(S.micAnalyser, micBands);
  bandsOf(S.outAnalyser, outBands);

  const assistantActive = S.outLevel > 0.012 || S.assistantSpeaking;
  const userActive = !assistantActive && S.micLevel > 0.02;
  const target = assistantActive ? ACCENT : userActive ? USER : S.conn === "live" ? [150, 150, 165] : IDLE;
  for (let i = 0; i < 3; i++) mixed[i] = lerp(mixed[i], target[i], 0.06);

  // energy 0..1 driving the whole thing
  const raw = assistantActive ? S.outLevel * 3.4 : S.micLevel * 3.0;
  // never let the orb look dead: a slow breath underlies the real signal
  const breath = 0.11 + 0.055 * Math.sin(t * 0.85) + 0.03 * Math.sin(t * 1.9 + 1.1);
  const energy = Math.min(1, Math.max(raw, breath));
  const src = assistantActive ? outBands : micBands;
  for (let i = 0; i < NB; i++) {
    const idle = 0.055 * (1 + Math.sin(t * 1.1 + i * 0.62)) * (1 - Math.min(1, raw * 2.2));
    smoothed[i] = lerp(smoothed[i], Math.max(src[i], idle), 0.22);
  }

  const w = canvas.width, h = canvas.height;
  const cx = w / 2, cy = h / 2;
  const base = 78 * dpr;
  const R = base * (1 + energy * 0.2);

  g.clearRect(0, 0, w, h);
  g.globalCompositeOperation = "lighter";

  // --- far halo -------------------------------------------------------
  const halo = g.createRadialGradient(cx, cy, R * 0.4, cx, cy, R * 2.5);
  halo.addColorStop(0, rgba(mixed, 0.20 + energy * 0.18));
  halo.addColorStop(0.45, rgba(mixed, 0.06 + energy * 0.06));
  halo.addColorStop(1, rgba(mixed, 0));
  g.fillStyle = halo;
  g.beginPath();
  g.arc(cx, cy, R * 2.5, 0, Math.PI * 2);
  g.fill();

  // --- three reactive blob layers -------------------------------------
  const layers = [
    { scale: 1.34, amp: 0.34, alpha: 0.10, speed: 0.30, phase: 0 },
    { scale: 1.16, amp: 0.26, alpha: 0.16, speed: -0.45, phase: 2.1 },
    { scale: 1.0,  amp: 0.18, alpha: 0.30, speed: 0.62, phase: 4.3 },
  ];

  for (const L of layers) {
    g.beginPath();
    const steps = 160;
    for (let i = 0; i <= steps; i++) {
      const a = (i / steps) * Math.PI * 2;
      const bandIdx = Math.floor(((a / (Math.PI * 2)) * NB * 2) % NB);
      const band = smoothed[bandIdx] || 0;
      const wob =
        Math.sin(a * 3 + t * L.speed * 2.2 + L.phase) * 0.5 +
        Math.sin(a * 5 - t * L.speed * 1.4 + L.phase) * 0.3 +
        Math.sin(a * 2 + t * L.speed * 0.9) * 0.2;
      const r = R * L.scale * (1 + wob * (0.035 + energy * 0.05) + band * L.amp * (0.35 + energy));
      const x = cx + Math.cos(a) * r;
      const y = cy + Math.sin(a) * r;
      i === 0 ? g.moveTo(x, y) : g.lineTo(x, y);
    }
    g.closePath();
    const grd = g.createRadialGradient(cx, cy, R * 0.2, cx, cy, R * L.scale * 1.3);
    grd.addColorStop(0, rgba(mixed, L.alpha * 0.9));
    grd.addColorStop(0.7, rgba(mixed, L.alpha * 0.5));
    grd.addColorStop(1, rgba(mixed, 0));
    g.fillStyle = grd;
    g.fill();
    g.strokeStyle = rgba(mixed, L.alpha * 0.55);
    g.lineWidth = 1 * dpr;
    g.stroke();
  }

  // --- bright core ----------------------------------------------------
  const coreR = R * (0.5 + energy * 0.16);
  const core = g.createRadialGradient(cx, cy - coreR * 0.18, 1, cx, cy, coreR);
  core.addColorStop(0, `rgba(255,255,255,${0.55 + energy * 0.4})`);
  core.addColorStop(0.35, rgba(mixed, 0.55 + energy * 0.3));
  core.addColorStop(1, rgba(mixed, 0));
  g.fillStyle = core;
  g.beginPath();
  g.arc(cx, cy, coreR, 0, Math.PI * 2);
  g.fill();

  // --- orbiting spark ring -------------------------------------------
  g.globalCompositeOperation = "lighter";
  for (let i = 0; i < NB; i++) {
    const a = (i / NB) * Math.PI * 2 + t * 0.18;
    const band = smoothed[i] || 0;
    const rr = R * 1.62 + band * R * 0.5;
    const x = cx + Math.cos(a) * rr;
    const y = cy + Math.sin(a) * rr;
    const s = (0.9 + band * 5) * dpr;
    g.fillStyle = rgba(mixed, 0.14 + band * 0.7);
    g.beginPath();
    g.arc(x, y, s, 0, Math.PI * 2);
    g.fill();
  }

  // --- thin outer ring ------------------------------------------------
  g.globalCompositeOperation = "source-over";
  g.strokeStyle = rgba(mixed, 0.16);
  g.lineWidth = 1 * dpr;
  g.beginPath();
  g.arc(cx, cy, R * 1.95, 0, Math.PI * 2);
  g.stroke();

  // sweeping arc when live
  if (S.conn === "live") {
    g.strokeStyle = rgba(mixed, 0.5);
    g.lineWidth = 1.6 * dpr;
    g.lineCap = "round";
    g.beginPath();
    g.arc(cx, cy, R * 1.95, t * 0.7, t * 0.7 + 0.5 + energy * 1.4);
    g.stroke();
  }
}
draw();

// ----------------------------------------------------------------- wire ----

$("btn-connect").onclick = connect;
$("btn-shot").onclick = () => sendScreenshot(false);
$("btn-watch").onclick = () => {
  S.settings.continuous = !S.settings.continuous;
  $("s-continuous").classList.toggle("on", S.settings.continuous);
  persist(false);
  applyContinuous();
};

listen("hotkey-screenshot", () => sendScreenshot(false));

document.addEventListener("keydown", (e) => {
  if (e.metaKey && e.shiftKey && e.key === "2") { e.preventDefault(); sendScreenshot(false); }
  if (e.key === "Escape") { $("drawer").classList.remove("show"); $("scrim").classList.remove("show"); }
});

(async () => {
  await loadSettings();
  bindSettings();
  setConn("idle");
  const info = await invoke("backend_info");
  rlog("info", "backend_info " + JSON.stringify(info));
  if (!info.config_exists) {
    showError(`No API key found at ${info.config_path}. Create it with {"OPENAI_API_KEY": "sk-proj-…"} and chmod 600.`);
  } else if (!info.screen_permission) {
    addTurn("system", "Screen Recording permission not granted yet — screenshots will fail until you allow it in Settings.");
  }
  rlog("info", "frontend ready");

  // Headless verification path: VIBE_SELFTEST=1 npx tauri dev
  if (info.selftest) {
    rlog("info", "SELFTEST: auto-connecting");
    await connect();
    setTimeout(() => {
      rlog("info", "SELFTEST: conn=" + S.conn);
      if (S.conn === "live") {
        rlog("info", "SELFTEST: sending screenshot");
        sendScreenshot(false);
      }
    }, 5000);
    setTimeout(() => {
      const turns = [...document.querySelectorAll('#transcript .turn')]
        .map((n) => (n.querySelector('.role')?.textContent || 'sys') + ': ' +
                    (n.querySelector('.body')?.textContent || '').slice(0, 220));
      rlog("info", "SELFTEST: final conn=" + S.conn + " turns=" + turns.length);
      turns.forEach((t2) => rlog("info", "SELFTEST| " + t2));
    }, 20000);
  }
})();
