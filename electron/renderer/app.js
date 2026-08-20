import { Orb } from './orb.js';

const $ = (id) => document.getElementById(id);
const vv = window.vv;
const VOICES = ['alloy','ash','ballad','coral','echo','sage','shimmer','verse','marin','cedar'];

const S = {
  settings: null,
  boot: null,
  phase: 'idle',            // idle | connecting | live | error
  pc: null,
  dc: null,
  mic: null,
  actx: null,
  micAnalyser: null,
  botAnalyser: null,
  micBuf: null, botBuf: null, micSpec: null, botSpec: null,
  userSpeaking: false,
  botSpeaking: false,
  streamEl: null,           // in-flight assistant bubble
  streamText: '',
  contTimer: null,
  capturing: false,
  // Response lifecycle. A response.create sent while one is already running is
  // rejected ("Conversation already has an active response in progress"), and the
  // window opens when WE send — not when response.created comes back — so
  // 'requested' has to be its own state.
  responsePhase: 'idle',   // idle | requested | active
  pendingResponse: null,   // reason string, coalesced; deferred rather than dropped
};

const orb = new Orb($('orb'));

// ---------------------------------------------------------------- utilities
function say(msg) { vv.log('app', msg); }
function fail(msg) { vv.log('err', msg); showError(msg); }

function showError(msg) {
  $('errText').textContent = msg;
  $('errBar').classList.remove('hidden');
}
$('errClose').onclick = () => $('errBar').classList.add('hidden');

function setPhase(p, detail) {
  S.phase = p;
  orb.set(p);
  const pill = $('statusPill');
  pill.className = `pill ${p}`;
  $('statusText').textContent = detail || p;
  const on = p === 'live';
  $('connectBtn').classList.toggle('on', on);
  $('connectBtn').classList.toggle('busy', p === 'connecting');
  $('connectLabel').textContent = on ? 'Disconnect' : (p === 'connecting' ? 'Connecting…' : 'Connect');
  if (!on) { $('speakerLabel').textContent = p === 'error' ? 'disconnected' : 'not connected'; $('speakerLabel').className = 'speaker'; }
}

function setSpeaker(who) {
  orb.setWho(who);
  const el = $('speakerLabel');
  if (who === 'user') { el.textContent = 'listening'; el.className = 'speaker user'; }
  else if (who === 'assistant') { el.textContent = 'speaking'; el.className = 'speaker assistant'; }
  else { el.textContent = 'ready'; el.className = 'speaker'; }
}

// ---------------------------------------------------------------- transcript
function killEmpty() { const e = $('emptyState'); if (e) e.remove(); }

function addMsg(role, text, opts = {}) {
  killEmpty();
  const log = $('log');
  const m = document.createElement('div');
  m.className = `msg ${role}`;
  const who = document.createElement('div');
  who.className = 'who';
  who.textContent = opts.label || role;
  m.appendChild(who);
  if (opts.img) {
    const box = document.createElement('div');
    box.className = 'shot';
    const img = document.createElement('img');
    img.src = opts.img;
    box.appendChild(img);
    m.appendChild(box);
    const meta = document.createElement('div');
    meta.className = 'shotmeta';
    meta.textContent = opts.meta || '';
    m.appendChild(meta);
  }
  if (text != null) {
    const b = document.createElement('div');
    b.className = 'body';
    b.textContent = text;
    m.appendChild(b);
  }
  log.appendChild(m);
  log.scrollTop = log.scrollHeight;
  return m;
}

function streamDelta(delta) {
  if (!S.streamEl) {
    S.streamText = '';
    S.streamEl = addMsg('assistant', '', { label: 'assistant' });
    S.streamEl.querySelector('.body').classList.add('streaming');
  }
  S.streamText += delta;
  const b = S.streamEl.querySelector('.body');
  b.textContent = S.streamText;
  $('log').scrollTop = $('log').scrollHeight;
}
function endStream() {
  if (S.streamEl) {
    const b = S.streamEl.querySelector('.body');
    b.classList.remove('streaming');
    if (!S.streamText.trim()) S.streamEl.remove();
  }
  S.streamEl = null; S.streamText = '';
}

$('clearBtn').onclick = () => {
  $('log').innerHTML = '';
  S.streamEl = null; S.streamText = '';
};

// ------------------------------------------------------------- audio meters
function rms(buf) {
  let sum = 0;
  for (let i = 0; i < buf.length; i++) { const v = (buf[i] - 128) / 128; sum += v * v; }
  return Math.sqrt(sum / buf.length);
}

function ensureCtx() {
  if (!S.actx) S.actx = new AudioContext({ latencyHint: 'interactive' });
  if (S.actx.state === 'suspended') S.actx.resume();
  return S.actx;
}

function attachAnalyser(stream, which) {
  const ctx = ensureCtx();
  const src = ctx.createMediaStreamSource(stream);
  const an = ctx.createAnalyser();
  an.fftSize = 1024;
  an.smoothingTimeConstant = 0.72;
  src.connect(an); // deliberately NOT connected to destination
  if (which === 'mic') {
    S.micAnalyser = an;
    S.micBuf = new Uint8Array(an.fftSize);
    S.micSpec = new Uint8Array(an.frequencyBinCount);
  } else {
    S.botAnalyser = an;
    S.botBuf = new Uint8Array(an.fftSize);
    S.botSpec = new Uint8Array(an.frequencyBinCount);
  }
}

let uLvl = 0, bLvl = 0;
function meterLoop() {
  requestAnimationFrame(meterLoop);
  let u = 0, b = 0;
  if (S.micAnalyser) {
    S.micAnalyser.getByteTimeDomainData(S.micBuf);
    S.micAnalyser.getByteFrequencyData(S.micSpec);
    u = Math.min(1, rms(S.micBuf) * 6.5);
  }
  if (S.botAnalyser) {
    S.botAnalyser.getByteTimeDomainData(S.botBuf);
    S.botAnalyser.getByteFrequencyData(S.botSpec);
    b = Math.min(1, rms(S.botBuf) * 6.5);
  }
  uLvl += (u - uLvl) * (u > uLvl ? 0.5 : 0.09);
  bLvl += (b - bLvl) * (b > bLvl ? 0.5 : 0.09);
  orb.push(uLvl, bLvl, S.micSpec, S.botSpec);

  $('meterFill').style.width = `${Math.min(100, uLvl * 118).toFixed(1)}%`;
  $('meterDb').textContent = uLvl > 0.004
    ? `${Math.max(-60, 20 * Math.log10(uLvl)).toFixed(0)} dB` : '—';

  // fall back to amplitude for the "speaking" label when the assistant streams
  if (S.phase === 'live') {
    if (bLvl > 0.035) { S.botSpeaking = true; setSpeaker('assistant'); }
    else if (S.userSpeaking) setSpeaker('user');
    else if (S.botSpeaking) { S.botSpeaking = false; setSpeaker(null); }
  }
}
requestAnimationFrame(meterLoop);

// ------------------------------------------------------------------ connect
async function connect() {
  if (S.phase === 'live' || S.phase === 'connecting') return disconnect();
  $('errBar').classList.add('hidden');
  setPhase('connecting', 'minting token');

  try {
    const model = S.settings.model;

    // 1) ephemeral token, minted in the MAIN process. The renderer never sees sk-.
    const tok = await vv.mintToken(model);
    if (!tok.ok) throw new Error(`token mint failed — ${tok.error}`);
    say(`ephemeral token ${tok.redacted} (expires_at ${tok.expiresAt})`);

    // 2) mic
    setPhase('connecting', 'microphone');
    await vv.askMic();
    const mic = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true,
               channelCount: 1 },
    });
    S.mic = mic;
    attachAnalyser(mic, 'mic');
    say('mic acquired: ' + mic.getAudioTracks()[0].label);

    // 3) peer connection
    setPhase('connecting', 'negotiating');
    const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
    S.pc = pc;

    pc.ontrack = (e) => {
      say('remote track: ' + e.track.kind);
      const el = $('remoteAudio');
      el.srcObject = e.streams[0];
      el.play().catch(() => {});
      attachAnalyser(e.streams[0], 'bot');
    };
    pc.onconnectionstatechange = () => {
      say('pc state: ' + pc.connectionState);
      if (pc.connectionState === 'failed') { fail('WebRTC connection failed'); teardown('error'); }
      if (pc.connectionState === 'disconnected' && S.phase === 'live') setPhase('error', 'dropped');
    };
    pc.oniceconnectionstatechange = () => say('ice: ' + pc.iceConnectionState);

    pc.addTrack(mic.getAudioTracks()[0], mic);

    const dc = pc.createDataChannel('oai-events');
    S.dc = dc;
    dc.onopen = () => { say('data channel open'); sendSessionUpdate(); };
    dc.onclose = () => say('data channel closed');
    dc.onerror = (e) => fail('data channel error: ' + (e.error?.message || 'unknown'));
    dc.onmessage = (e) => handleEvent(JSON.parse(e.data));

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await waitForIce(pc, 1800);

    // 4) SDP exchange
    setPhase('connecting', 'sdp exchange');
    const url = `https://api.openai.com/v1/realtime/calls?model=${encodeURIComponent(model)}`;
    const res = await fetch(url, {
      method: 'POST',
      headers: { Authorization: `Bearer ${tok.value}`, 'Content-Type': 'application/sdp' },
      body: pc.localDescription.sdp,
    });
    const answer = await res.text();
    say(`POST /v1/realtime/calls -> HTTP ${res.status} (${answer.length} bytes)`);
    if (!res.ok) throw new Error(`SDP exchange ${res.status}: ${answer.slice(0, 400)}`);

    await pc.setRemoteDescription({ type: 'answer', sdp: answer });
    setPhase('connecting', 'waiting for session');
  } catch (err) {
    fail(err.message || String(err));
    teardown('error');
  }
}

function waitForIce(pc, ms) {
  if (pc.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => { pc.removeEventListener('icegatheringstatechange', check); clearTimeout(t); resolve(); };
    const check = () => { if (pc.iceGatheringState === 'complete') done(); };
    const t = setTimeout(done, ms);
    pc.addEventListener('icegatheringstatechange', check);
  });
}

function sendSessionUpdate() {
  const s = S.settings;
  const input = {
    format: { type: 'audio/pcm', rate: 24000 },
    noise_reduction: { type: s.noiseReduction || 'near_field' },
    turn_detection: {
      type: 'server_vad',
      threshold: Number(s.vadThreshold),
      prefix_padding_ms: Number(s.prefixPaddingMs),
      silence_duration_ms: Number(s.silenceDurationMs),
      create_response: true,
      interrupt_response: true,     // barge-in
    },
  };
  if (s.transcribeInput) input.transcription = { model: 'gpt-4o-mini-transcribe' };

  send({
    type: 'session.update',
    session: {
      type: 'realtime',
      instructions: s.instructions,
      output_modalities: ['audio'],
      audio: {
        input,
        output: { format: { type: 'audio/pcm', rate: 24000 }, voice: s.voice, speed: Number(s.speed) },
      },
    },
  });
}

function send(obj) {
  if (!S.dc || S.dc.readyState !== 'open') return false;
  S.dc.send(JSON.stringify(obj));
  return true;
}

// ------------------------------------------------------- response lifecycle
//
// Exactly one response may be in flight. Everything that wants the model to speak
// goes through requestResponse(); nothing else may send response.create. A request
// made while one is running is deferred to response.done — not dropped, and not
// stacked, since a second create is what earns the "already has an active response
// in progress" rejection.

function requestResponse(reason) {
  if (S.responsePhase !== 'idle') {
    S.pendingResponse = S.pendingResponse ? `${S.pendingResponse} + ${reason}` : reason;
    say(`response queued (${reason}) — ${S.responsePhase}`);
    return false;
  }
  S.responsePhase = 'requested';
  say(`response.create sent (${reason})`);
  if (!send({ type: 'response.create' })) {
    S.responsePhase = 'idle';
    say(`response.create dropped, channel closed (${reason})`);
    return false;
  }
  return true;
}

function responseStarted() { S.responsePhase = 'active'; }

function responseFinished(status) {
  S.responsePhase = 'idle';
  say(`response.done status=${status || '?'}`);
  const pending = S.pendingResponse;
  S.pendingResponse = null;
  if (pending) requestResponse(pending);
}

// Local only — for a socket that is gone or a session that is new. A create left
// queued here would otherwise fire into the next session.
function resetResponses(reason) {
  if (S.responsePhase !== 'idle' || S.pendingResponse) say(`response state reset (${reason})`);
  S.responsePhase = 'idle';
  S.pendingResponse = null;
}

function handleEvent(ev) {
  switch (ev.type) {
    case 'session.created':
      say(`EVENT session.created — id=${ev.session?.id} model=${ev.session?.model}`);
      setPhase('live', 'live');
      setSpeaker(null);
      $('subLabel').textContent = 'server VAD is on — just start talking';
      addMsg('system', `connected · ${ev.session?.model || S.settings.model} · voice ${S.settings.voice}`, { label: 'session' });
      resetResponses('new session');
      startContinuous(S.settings.continuousScreen);
      break;

    case 'response.created':
      responseStarted();
      break;

    case 'session.updated':
      say('EVENT session.updated');
      break;

    case 'input_audio_buffer.speech_started':
      S.userSpeaking = true; setSpeaker('user');
      break;
    case 'input_audio_buffer.speech_stopped':
      S.userSpeaking = false; setSpeaker(null);
      break;

    case 'conversation.item.input_audio_transcription.completed':
      if (ev.transcript && ev.transcript.trim()) addMsg('user', ev.transcript.trim(), { label: 'you' });
      break;

    case 'response.output_audio_transcript.delta':
    case 'response.audio_transcript.delta':
    case 'response.output_text.delta':
      streamDelta(ev.delta || '');
      break;

    case 'response.output_audio_transcript.done':
    case 'response.output_text.done':
      endStream();
      break;

    case 'response.done': {
      endStream();
      const st = ev.response?.status;
      if (st && st !== 'completed') {
        const d = ev.response?.status_details;
        say(`response.done status=${st} ${JSON.stringify(d || {})}`);
        if (st === 'failed') showError(d?.error?.message || `response ${st}`);
      }
      // Runs for every status, including failed and cancelled: a response that ends
      // badly still ends, and holding the lock open is what makes the app go mute.
      responseFinished(st);
      break;
    }

    case 'error': {
      const m = ev.error?.message || JSON.stringify(ev);
      say('EVENT error: ' + m);
      // A duplicate create is ours to repair, not the user's to read: the server is
      // telling us a response IS running, so take the lock and carry on.
      if (/already has an active response/i.test(m)) {
        S.responsePhase = 'active';
        say('create rejected as duplicate — adopting the server\'s active response');
        break;
      }
      showError(m);
      break;
    }
    default:
      break;
  }
}

function teardown(phase) {
  stopContinuous();
  try { S.dc && S.dc.close(); } catch {}
  try { S.pc && S.pc.close(); } catch {}
  try { S.mic && S.mic.getTracks().forEach((t) => t.stop()); } catch {}
  S.dc = null; S.pc = null; S.mic = null;
  S.micAnalyser = null; S.botAnalyser = null;
  S.micSpec = null; S.botSpec = null;
  $('remoteAudio').srcObject = null;
  endStream();
  resetResponses('teardown');
  setPhase(phase || 'idle', phase === 'error' ? 'error' : 'idle');
  $('subLabel').textContent = 'press connect and just talk';
}

function disconnect() {
  say('disconnect requested');
  teardown('idle');
  addMsg('system', 'disconnected', { label: 'session' });
}

$('connectBtn').onclick = connect;

// --------------------------------------------------------------- screenshot
async function doScreenshot(auto = false) {
  if (S.capturing) return;
  S.capturing = true;
  try {
    const perm = await vv.screenPermission();
    if (perm !== 'granted') {
      renderPermBox(perm);
      openSettings();
      showError(`Screen Recording permission is "${perm}". Grant it in System Settings, then relaunch Vibe Voice.`);
      return;
    }
    const shot = await vv.capture({});
    if (!shot.ok) { showError('capture failed: ' + shot.error); return; }

    if (!auto) {
      addMsg('user', null, {
        label: 'you · screenshot',
        img: shot.thumbUrl,
        meta: `${shot.width}×${shot.height} · jpeg q${shot.quality} · ${(shot.bytes / 1024).toFixed(0)} KB`,
      });
    }

    if (!send({
      type: 'conversation.item.create',
      item: {
        type: 'message', role: 'user',
        content: [
          { type: 'input_image', image_url: shot.dataUrl },
          { type: 'input_text', text: auto
              ? 'Screen frame for context. Do not reply unless I ask.'
              : "Here's my screen. What am I looking at?" },
        ],
      },
    })) {
      showError('not connected — hit Connect first');
      return;
    }
    // Deferred, not dropped: if the model is mid-sentence the frame is filed now and
    // answered on the next turn. Sending the create here regardless is what produced
    // "Conversation already has an active response in progress".
    if (!auto) requestResponse('screenshot');
    say(`screenshot sent (${(shot.bytes / 1024).toFixed(0)} KB${auto ? ', silent context' : ''})`);
  } finally {
    S.capturing = false;
  }
}
$('shotBtn').onclick = () => doScreenshot(false);
vv.onHotkeyScreenshot(() => doScreenshot(false));

function startContinuous(on) {
  stopContinuous();
  $('watchPill').classList.toggle('hidden', !on || S.phase !== 'live');
  if (!on || S.phase !== 'live') return;
  const ms = Math.max(2, Number(S.settings.continuousIntervalSec)) * 1000;
  S.contTimer = setInterval(() => doScreenshot(true), ms);
  say(`continuous screen ON every ${ms / 1000}s`);
}
function stopContinuous() {
  if (S.contTimer) clearInterval(S.contTimer);
  S.contTimer = null;
  $('watchPill').classList.add('hidden');
}

// ----------------------------------------------------------------- settings
function openSettings() { $('settings').classList.add('open'); $('scrim').classList.remove('hidden'); }
function closeSettings() { $('settings').classList.remove('open'); $('scrim').classList.add('hidden'); }
$('settingsBtn').onclick = openSettings;
$('closeSettings').onclick = closeSettings;
$('scrim').onclick = closeSettings;
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeSettings();
  if (e.key === ',' && e.metaKey) { e.preventDefault(); openSettings(); }
});

async function save(patch, live = true) {
  S.settings = await vv.setSettings(patch);
  if (live && S.phase === 'live') sendSessionUpdate();
}

function paintRange(el) {
  const pct = ((el.value - el.min) / (el.max - el.min)) * 100;
  el.style.setProperty('--pct', `${pct}%`);
}

function renderPermBox(status) {
  const box = $('permBox');
  box.innerHTML = '';
  const granted = status === 'granted';
  box.classList.toggle('warn', !granted);
  const p = document.createElement('div');
  if (granted) {
    p.innerHTML = '<b>Granted.</b> Screenshots capture your primary display.';
    box.appendChild(p);
  } else {
    p.innerHTML = `<b>Not granted</b> (status: ${status}). macOS blocks screen capture until you allow it. ` +
      'Enable <b>Vibe Voice</b> (or your terminal, if you launched from one) under Screen &amp; System Audio Recording, then relaunch the app.';
    box.appendChild(p);
    const btn = document.createElement('button');
    btn.textContent = 'Open System Settings →';
    btn.onclick = () => vv.openScreenPrefs();
    box.appendChild(btn);
  }
}

function buildSettingsUI() {
  const s = S.settings;

  const chips = $('voices');
  chips.innerHTML = '';
  for (const v of VOICES) {
    const b = document.createElement('button');
    b.className = 'chip' + (v === s.voice ? ' sel' : '');
    b.textContent = v;
    b.onclick = () => {
      chips.querySelectorAll('.chip').forEach((c) => c.classList.remove('sel'));
      b.classList.add('sel');
      save({ voice: v });
    };
    chips.appendChild(b);
  }

  const model = $('model');
  if (![...model.options].some((o) => o.value === s.model)) {
    const o = document.createElement('option'); o.textContent = s.model; model.appendChild(o);
  }
  model.value = s.model;
  model.onchange = () => save({ model: model.value }, false);

  const ins = $('instructions');
  ins.value = s.instructions;
  ins.onchange = () => save({ instructions: ins.value });

  const speed = $('speed');
  speed.value = s.speed; paintRange(speed);
  $('speedOut').textContent = `${Number(s.speed).toFixed(2)}×`;
  speed.oninput = () => { paintRange(speed); $('speedOut').textContent = `${Number(speed.value).toFixed(2)}×`; };
  speed.onchange = () => save({ speed: Number(speed.value) });

  const iv = $('interval');
  iv.value = s.continuousIntervalSec; paintRange(iv);
  $('intervalOut').textContent = `${s.continuousIntervalSec}s`;
  iv.oninput = () => { paintRange(iv); $('intervalOut').textContent = `${iv.value}s`; };
  iv.onchange = async () => { await save({ continuousIntervalSec: Number(iv.value) }, false); startContinuous(S.settings.continuousScreen); };

  const tog = $('contToggle');
  tog.setAttribute('aria-checked', String(!!s.continuousScreen));
  tog.onclick = async () => {
    const next = tog.getAttribute('aria-checked') !== 'true';
    tog.setAttribute('aria-checked', String(next));
    await save({ continuousScreen: next }, false);
    startContinuous(next);
  };

  const vad = $('vad');
  vad.value = s.vadThreshold; paintRange(vad);
  $('vadOut').textContent = Number(s.vadThreshold).toFixed(2);
  vad.oninput = () => { paintRange(vad); $('vadOut').textContent = Number(vad.value).toFixed(2); };
  vad.onchange = () => save({ vadThreshold: Number(vad.value) });

  const sil = $('sil');
  sil.value = s.silenceDurationMs; paintRange(sil);
  $('silOut').textContent = `${s.silenceDurationMs}ms`;
  sil.oninput = () => { paintRange(sil); $('silOut').textContent = `${sil.value}ms`; };
  sil.onchange = () => save({ silenceDurationMs: Number(sil.value) });

  renderPermBox(S.boot.screenPermission);
  $('metaBox').textContent =
    `electron ${S.boot.versions.electron} · chromium ${S.boot.versions.chrome} · node ${S.boot.versions.node}\n` +
    `key: ${S.boot.configPath} (${S.boot.keyState})\n` +
    `mic permission: ${S.boot.micPermission} · screen: ${S.boot.screenPermission}\n` +
    `hotkey ${S.boot.hotkey} · transport WebRTC`;
}

// --------------------------------------------------------------------- boot
(async function init() {
  S.boot = await vv.bootstrap();
  S.settings = S.boot.settings;
  buildSettingsUI();
  setPhase('idle');
  say(`ui ready — key ${S.boot.keyState}, screen ${S.boot.screenPermission}, mic ${S.boot.micPermission}`);

  if (S.boot.keyState !== 'ok') {
    showError(`No API key: ${S.boot.keyError}`);
    setPhase('error', 'no api key');
  }
  if (S.boot.screenPermission !== 'granted') {
    addMsg('system',
      'Screen Recording permission is not granted yet — screenshots will fail until you allow it in System Settings (see Settings ▸ Screen recording).',
      { label: 'heads up' });
  }
  window.addEventListener('error', (e) => fail('renderer: ' + e.message));
  window.addEventListener('unhandledrejection', (e) => fail('renderer: ' + (e.reason?.message || e.reason)));
})();
