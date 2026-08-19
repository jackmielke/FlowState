'use strict';

const {
  app, BrowserWindow, ipcMain, desktopCapturer, screen,
  systemPreferences, globalShortcut, shell, session, nativeImage,
} = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const CONFIG_PATH = path.join(os.homedir(), '.config', 'vibe-voice', 'config.json');
const OPENAI_BASE = 'https://api.openai.com/v1';
const SCREEN_PREF_URL =
  'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture';
const HOTKEY = 'CommandOrControl+Shift+2';

const DEFAULT_SETTINGS = {
  model: 'gpt-realtime-2.1',
  voice: 'marin',
  speed: 1.0,
  instructions:
    "You are Vibe, a warm, quick-witted voice companion running locally on the user's Mac. " +
    'Keep answers short and conversational unless asked to go deep. ' +
    'When you are shown a screenshot, describe what actually matters on it, not every pixel.',
  vadThreshold: 0.5,
  silenceDurationMs: 500,
  prefixPaddingMs: 300,
  continuousScreen: false,
  continuousIntervalSec: 5,
  transcribeInput: true,
  noiseReduction: 'near_field',
};

// ---------------------------------------------------------------------------
// Tiny logger (everything lands on main-process stdout so `npm start` shows it)
// ---------------------------------------------------------------------------
function log(scope, ...args) {
  const t = new Date().toISOString().slice(11, 23);
  console.log(`[${t}] [${scope}]`, ...args);
}
function redact(tok) {
  if (!tok || typeof tok !== 'string') return String(tok);
  if (tok.length <= 12) return tok.slice(0, 3) + '…';
  return `${tok.slice(0, 6)}…${tok.slice(-4)} (len ${tok.length})`;
}

// ---------------------------------------------------------------------------
// Settings persistence (userData/settings.json)
// ---------------------------------------------------------------------------
function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}
function readSettings() {
  try {
    const raw = fs.readFileSync(settingsPath(), 'utf8');
    return { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}
function writeSettings(patch) {
  const next = { ...readSettings(), ...(patch || {}) };
  try {
    fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
    fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2), 'utf8');
  } catch (e) {
    log('settings', 'write failed:', e.message);
  }
  return next;
}

// ---------------------------------------------------------------------------
// API key — main process ONLY. Never crosses the bridge.
// ---------------------------------------------------------------------------
function readApiKey() {
  const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
  const key = JSON.parse(raw).OPENAI_API_KEY;
  if (!key || typeof key !== 'string' || !key.startsWith('sk-')) {
    throw new Error(`No usable OPENAI_API_KEY in ${CONFIG_PATH}`);
  }
  return key.trim();
}

async function mintEphemeralToken(model) {
  const key = readApiKey();
  const body = JSON.stringify({ session: { type: 'realtime', model } });
  const res = await fetch(`${OPENAI_BASE}/realtime/client_secrets`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body,
  });
  const text = await res.text();
  if (!res.ok) {
    let msg = text;
    try { msg = JSON.parse(text).error?.message || text; } catch {}
    throw new Error(`client_secrets ${res.status}: ${msg}`);
  }
  const json = JSON.parse(text);
  log('mint', 'ok ->', redact(json.value), 'expires_at', json.expires_at, 'model', json.session?.model);
  return { value: json.value, expiresAt: json.expires_at, sessionId: json.session?.id || null };
}

// ---------------------------------------------------------------------------
// Screen capture via desktopCapturer (thumbnail == the frame, no canvas needed)
// ---------------------------------------------------------------------------
function screenAccess() {
  try { return systemPreferences.getMediaAccessStatus('screen'); }
  catch { return 'unknown'; }
}

async function captureScreen({ maxWidth = 1280, budgetBytes = 170 * 1024 } = {}) {
  const status = screenAccess();
  const display = screen.getPrimaryDisplay();
  const { width: dw, height: dh } = display.size;
  const tw = Math.min(maxWidth, dw);
  const th = Math.max(1, Math.round((tw * dh) / dw));

  const sources = await desktopCapturer.getSources({
    types: ['screen'],
    thumbnailSize: { width: tw, height: th },
    fetchWindowIcons: false,
  });
  if (!sources.length) throw new Error('desktopCapturer returned no screen sources');

  const src =
    sources.find((s) => String(s.display_id) === String(display.id)) || sources[0];
  let img = src.thumbnail;
  if (!img || img.isEmpty()) throw new Error('captured frame was empty');

  // Fit under the WebRTC data-channel message ceiling (~256 KiB) by walking
  // quality down, then resolution down. base64 inflates bytes by ~4/3.
  const ladder = [
    { w: tw, q: 70 }, { w: tw, q: 55 }, { w: tw, q: 42 },
    { w: Math.round(tw * 0.75), q: 55 }, { w: Math.round(tw * 0.6), q: 50 },
    { w: Math.round(tw * 0.5), q: 45 },
  ];
  let jpeg = null, used = ladder[0];
  for (const step of ladder) {
    const scaled = step.w === tw ? img : img.resize({ width: step.w, quality: 'good' });
    const buf = scaled.toJPEG(step.q);
    jpeg = buf; used = step;
    if (buf.length * 1.37 <= budgetBytes) break;
  }

  const thumbBuf = img.resize({ width: 320, quality: 'good' }).toJPEG(55);
  const size = img.getSize();

  const out = {
    dataUrl: `data:image/jpeg;base64,${jpeg.toString('base64')}`,
    thumbUrl: `data:image/jpeg;base64,${thumbBuf.toString('base64')}`,
    width: used.w,
    height: Math.round((used.w * size.height) / size.width),
    bytes: jpeg.length,
    quality: used.q,
    permission: status,
    sourceName: src.name,
  };
  log('capture', `${out.width}x${out.height} q${out.quality} ${(out.bytes / 1024).toFixed(0)}KB perm=${status}`);
  return out;
}

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------
let win = null;

function createWindow() {
  win = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 900,
    minHeight: 620,
    show: false,
    // NOT `frame:false` and NOT `transparent:true` — either one costs us the
    // system corner rounding on macOS. hiddenInset gives the frameless look
    // while AppKit keeps the rounded window shape + shadow.
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 18, y: 18 },
    roundedCorners: true,
    vibrancy: 'under-window',
    visualEffectState: 'active',
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      backgroundThrottling: false,   // keep the visualizer + meters alive in the background
    },
  });

  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.show());

  // Surface every renderer-side signal on main stdout.
  win.webContents.on('console-message', (...a) => {
    // Electron >= 37 passes (event, details); older passes (event, level, message, line, source)
    const d = a[1];
    if (d && typeof d === 'object' && 'message' in d) {
      log('renderer', `${d.level}:`, d.message, d.sourceId ? `(${d.sourceId}:${d.lineNumber})` : '');
    } else {
      log('renderer', `${a[1]}:`, a[2], `(${a[4]}:${a[3]})`);
    }
  });
  win.webContents.on('did-fail-load', (_e, code, desc, url) =>
    log('renderer', 'DID-FAIL-LOAD', code, desc, url));
  win.webContents.on('preload-error', (_e, file, err) =>
    log('renderer', 'PRELOAD-ERROR', file, err && err.message));
  win.webContents.on('render-process-gone', (_e, details) =>
    log('renderer', 'PROCESS-GONE', JSON.stringify(details)));
  win.webContents.on('unresponsive', () => log('renderer', 'UNRESPONSIVE'));

  // dev: `npm start -- --shot=/path/out.png` snapshots the window (no TCC needed)
  const shotArg = process.argv.find((a) => a.startsWith('--shot='));
  if (shotArg) {
    const out = shotArg.slice('--shot='.length);
    const delay = Number((process.argv.find((a) => a.startsWith('--shot-delay=')) || '').split('=')[1] || 4000);
    setTimeout(async () => {
      try {
        app.focus({ steal: true });
        win.show(); win.focus();
        if (process.argv.includes('--shot-settings')) {
          await win.webContents.executeJavaScript("document.getElementById('settingsBtn').click()");
        }
        await new Promise((r) => setTimeout(r, 900));
        const img = await win.webContents.capturePage();
        fs.writeFileSync(out, img.toPNG());
        fs.writeFileSync(out.replace(/\.png$/, '.jpg'), img.toJPEG(92));
        log('shot', 'wrote ' + out);
      } catch (e) { log('shot', 'FAILED ' + e.message); }
      if (process.argv.includes('--shot-quit')) { log('shot', 'quitting'); app.quit(); }
    }, delay);
  }

  win.on('closed', () => { win = null; });
}

// ---------------------------------------------------------------------------
// IPC surface — deliberately narrow. No key, ever.
// ---------------------------------------------------------------------------
function wireIpc() {
  ipcMain.handle('vv:bootstrap', async () => {
    let keyState = 'ok', keyError = null;
    try { readApiKey(); } catch (e) { keyState = 'missing'; keyError = e.message; }
    return {
      settings: readSettings(),
      configPath: CONFIG_PATH,
      keyState,
      keyError,
      screenPermission: screenAccess(),
      micPermission: (() => {
        try { return systemPreferences.getMediaAccessStatus('microphone'); } catch { return 'unknown'; }
      })(),
      hotkey: '⌘⇧2',
      versions: {
        electron: process.versions.electron,
        chrome: process.versions.chrome,
        node: process.versions.node,
      },
    };
  });

  ipcMain.handle('vv:mint', async (_e, model) => {
    try {
      const t = await mintEphemeralToken(model || readSettings().model);
      return { ok: true, ...t, redacted: redact(t.value) };
    } catch (e) {
      log('mint', 'FAILED:', e.message);
      return { ok: false, error: e.message };
    }
  });

  ipcMain.handle('vv:capture', async (_e, opts) => {
    try { return { ok: true, ...(await captureScreen(opts || {})) }; }
    catch (e) {
      log('capture', 'FAILED:', e.message);
      return { ok: false, error: e.message, permission: screenAccess() };
    }
  });

  ipcMain.handle('vv:screenPermission', async () => screenAccess());
  ipcMain.handle('vv:openScreenPrefs', async () => {
    await shell.openExternal(SCREEN_PREF_URL);
    return true;
  });
  ipcMain.handle('vv:askMic', async () => {
    try { return await systemPreferences.askForMediaAccess('microphone'); }
    catch { return false; }
  });

  ipcMain.handle('vv:getSettings', async () => readSettings());
  ipcMain.handle('vv:setSettings', async (_e, patch) => writeSettings(patch));

  ipcMain.on('vv:log', (_e, scope, msg) => log(`ui:${scope}`, msg));
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
app.whenReady().then(() => {
  // Auto-grant mic/display-capture prompts originating from our own renderer.
  session.defaultSession.setPermissionRequestHandler((wc, permission, cb) => {
    const allow = ['media', 'audioCapture', 'display-capture', 'clipboard-sanitized-write'];
    log('perm', 'request:', permission, allow.includes(permission) ? 'ALLOW' : 'DENY');
    cb(allow.includes(permission));
  });
  session.defaultSession.setPermissionCheckHandler((_wc, permission) =>
    ['media', 'audioCapture', 'display-capture'].includes(permission));

  wireIpc();
  createWindow();

  const ok = globalShortcut.register(HOTKEY, () => {
    log('hotkey', `${HOTKEY} fired`);
    if (win && !win.isDestroyed()) win.webContents.send('vv:hotkey-screenshot');
  });
  log('hotkey', `${HOTKEY} registered: ${ok}`);

  log('boot', `Vibe Voice ready — electron ${process.versions.electron}, chrome ${process.versions.chrome}`);
  log('boot', `config: ${CONFIG_PATH} (exists: ${fs.existsSync(CONFIG_PATH)})`);
  log('boot', `screen recording permission: ${screenAccess()}`);
  log('boot', `settings: ${settingsPath()}`);

  if (process.argv.includes('--test-capture')) {
    captureScreen({})
      .then((r) => log('test-capture', `OK ${r.width}x${r.height} q${r.quality} ` +
        `${(r.bytes / 1024).toFixed(0)}KB dataUrl=${r.dataUrl.length}B thumb=${r.thumbUrl.length}B ` +
        `source="${r.sourceName}" (budget ok: ${r.dataUrl.length < 240 * 1024})`))
      .catch((e) => log('test-capture', 'FAILED ' + e.message));
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('will-quit', () => globalShortcut.unregisterAll());
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });

process.on('uncaughtException', (e) => log('main', 'UNCAUGHT', e && e.stack));
process.on('unhandledRejection', (e) => log('main', 'UNHANDLED REJECTION', e && (e.stack || e)));
