// Voice orb — every deformation below is driven by real audio amplitude that
// app.js pushes in from two Web Audio AnalyserNodes (mic + remote WebRTC track).
// Nothing here is a canned CSS animation except the idle breathing floor.

const TAU = Math.PI * 2;
const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

export class Orb {
  constructor(canvas) {
    this.c = canvas;
    this.ctx = canvas.getContext('2d');
    this.state = 'idle';          // idle | connecting | live | error
    this.user = 0;                // smoothed 0..1 mic amplitude
    this.bot = 0;                 // smoothed 0..1 assistant amplitude
    this.who = null;              // 'user' | 'assistant' | null (set from server events)
    this.userSpec = null;         // Uint8Array frequency bins
    this.botSpec = null;
    this.t = 0;
    this._u = 0; this._b = 0;     // render-side extra smoothing
    this._blend = 0;              // 0 = cool/user, 1 = warm/assistant
    this._resize();
    window.addEventListener('resize', () => this._resize());
    this._raf = requestAnimationFrame(this._frame);
  }

  _resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const r = this.c.getBoundingClientRect();
    const w = r.width || 360, h = r.height || 360;
    this.c.width = Math.round(w * dpr);
    this.c.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = w; this.h = h;
  }

  set(state) { this.state = state; }
  setWho(who) { this.who = who; }
  push(user, bot, userSpec, botSpec) {
    this.user = user; this.bot = bot;
    this.userSpec = userSpec; this.botSpec = botSpec;
  }

  _frame = () => {
    this._raf = requestAnimationFrame(this._frame);
    this.t += 1 / 60;
    // asymmetric smoothing: snap up, ease down — feels responsive, not twitchy
    this._u = this.user > this._u ? lerp(this._u, this.user, 0.55) : lerp(this._u, this.user, 0.12);
    this._b = this.bot > this._b ? lerp(this._b, this.bot, 0.55) : lerp(this._b, this.bot, 0.12);

    // 0 = cool (you), 1 = warm (assistant). Resting bias sits warm — brand identity.
    // Server VAD wins; amplitude is only the tiebreaker when nobody has claimed the turn.
    const target = this.who === 'assistant' ? 1
      : this.who === 'user' ? 0
      : (this._b > 0.05 ? 1 : (this._u > 0.14 ? 0 : 0.78));
    this._blend = lerp(this._blend, target, 0.055);

    this._draw();
  };

  _palette() {
    const cool = [95, 212, 228], warm = [255, 155, 61];
    const k = this._blend;
    const base = [0, 1, 2].map((i) => Math.round(lerp(cool[i], warm[i], k)));
    // "hot" = the same hue pulled toward white for cores and highlights
    const hot = base.map((v) => Math.round(lerp(v, 255, 0.42)));
    return { base, hot };
  }

  _draw() {
    const { ctx, w, h } = this;
    const cx = w / 2, cy = h / 2;
    ctx.clearRect(0, 0, w, h);

    const idle = this.state !== 'live';
    const energy = clamp(Math.max(this._u, this._b) * (idle ? 0.25 : 1), 0, 1);
    const breathe = 0.5 + 0.5 * Math.sin(this.t * 0.9);
    const R = Math.min(w, h) * 0.235 * (1 + 0.03 * breathe + 0.30 * energy);
    const { base, hot } = this._palette();
    const B = `${base[0]},${base[1]},${base[2]}`;
    const H = `${hot[0]},${hot[1]},${hot[2]}`;

    // ---- ambient bloom (clipped to a disc so the canvas never shows a seam) --
    const maxR = Math.min(w, h) / 2;
    const bloom = ctx.createRadialGradient(cx, cy, R * 0.2, cx, cy, maxR);
    bloom.addColorStop(0, `rgba(${B},${0.30 + 0.34 * energy})`);
    bloom.addColorStop(0.34, `rgba(${B},${0.10 + 0.16 * energy})`);
    bloom.addColorStop(0.62, `rgba(${B},${0.028 + 0.05 * energy})`);
    bloom.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.save();
    ctx.beginPath(); ctx.arc(cx, cy, maxR, 0, TAU); ctx.clip();
    ctx.fillStyle = bloom;
    ctx.fillRect(0, 0, w, h);
    ctx.restore();

    ctx.save();
    ctx.globalCompositeOperation = 'lighter';

    // ---- spectrum ring (real FFT bins) ------------------------------------
    const spec = this._b > this._u ? this.botSpec : this.userSpec;
    const N = 108;
    const ringR = R * 1.42;
    if (spec && spec.length) {
      ctx.lineCap = 'round';
      for (let i = 0; i < N; i++) {
        // mirror about the vertical axis so the ring reads symmetric
        const m = Math.min(i, N - i) / (N / 2);            // 0..1
        const bin = Math.floor(2 + Math.pow(m, 1.6) * 62); // log-ish, voice band
        const v = (spec[bin] || 0) / 255;
        const len = 2.5 + Math.pow(v, 1.5) * 52 * (idle ? 0.18 : 1);
        const a = (i / N) * TAU - Math.PI / 2 + this.t * 0.045;
        const ca = Math.cos(a), sa = Math.sin(a);
        ctx.beginPath();
        ctx.moveTo(cx + ca * ringR, cy + sa * ringR);
        ctx.lineTo(cx + ca * (ringR + len), cy + sa * (ringR + len));
        ctx.strokeStyle = `rgba(${H},${0.14 + 0.62 * v})`;
        ctx.lineWidth = 1.6;
        ctx.stroke();
      }
    }

    // ---- wobbling blob layers ---------------------------------------------
    const layers = [
      { r: 1.06, amp: 0.15, sp: 0.42, lobes: 3, a: 0.30, ph: 0.0 },
      { r: 0.92, amp: 0.20, sp: -0.68, lobes: 4, a: 0.38, ph: 2.1 },
      { r: 0.76, amp: 0.26, sp: 0.95, lobes: 5, a: 0.44, ph: 4.3 },
      { r: 0.58, amp: 0.32, sp: -1.35, lobes: 6, a: 0.40, ph: 1.2 },
    ];
    for (const L of layers) {
      const rr = R * L.r;
      const wob = (0.28 + 1.5 * energy) * L.amp;
      ctx.beginPath();
      const steps = 120;
      let px = 0, py = 0;
      for (let i = 0; i <= steps; i++) {
        const a = (i / steps) * TAU;
        const n =
          Math.sin(a * L.lobes + this.t * L.sp + L.ph) * 0.6 +
          Math.sin(a * (L.lobes + 2) - this.t * L.sp * 1.4 + L.ph) * 0.28 +
          Math.sin(a * (L.lobes + 5) + this.t * L.sp * 0.7) * 0.12;
        const rad = rr * (1 + n * wob);
        const x = cx + Math.cos(a) * rad, y = cy + Math.sin(a) * rad;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.quadraticCurveTo(px, py, (px + x) / 2, (py + y) / 2);
        px = x; py = y;
      }
      ctx.closePath();
      const g = ctx.createRadialGradient(cx - rr * 0.3, cy - rr * 0.35, rr * 0.05, cx, cy, rr * 1.25);
      g.addColorStop(0, `rgba(${H},${L.a + 0.34 * energy})`);
      g.addColorStop(0.5, `rgba(${B},${L.a * 0.7})`);
      g.addColorStop(0.86, `rgba(${B},${L.a * 0.22})`);
      g.addColorStop(1, `rgba(${B},0)`);
      ctx.fillStyle = g;
      ctx.fill();
    }

    // ---- hot core ----------------------------------------------------------
    const coreR = R * (0.30 + 0.34 * energy);
    const core = ctx.createRadialGradient(cx, cy, 0, cx, cy, coreR);
    core.addColorStop(0, `rgba(255,255,255,${0.62 + 0.36 * energy})`);
    core.addColorStop(0.3, `rgba(${H},${0.50 + 0.3 * energy})`);
    core.addColorStop(0.62, `rgba(${B},${0.26 + 0.2 * energy})`);
    core.addColorStop(1, `rgba(${B},0)`);
    ctx.fillStyle = core;
    ctx.beginPath(); ctx.arc(cx, cy, coreR, 0, TAU); ctx.fill();
    ctx.restore();

    // ---- thin outline + state affordances ---------------------------------
    ctx.beginPath();
    ctx.arc(cx, cy, R * 1.42, 0, TAU);
    ctx.strokeStyle = `rgba(${B},0.16)`;
    ctx.lineWidth = 1;
    ctx.stroke();

    if (this.state === 'connecting') {
      const a0 = this.t * 2.4;
      ctx.beginPath();
      ctx.arc(cx, cy, R * 1.42, a0, a0 + 1.05);
      ctx.strokeStyle = `rgba(${H},0.85)`;
      ctx.lineWidth = 1.8; ctx.lineCap = 'round';
      ctx.stroke();
    }
    if (this.state === 'error') {
      ctx.beginPath();
      ctx.arc(cx, cy, R * 1.42, 0, TAU);
      ctx.setLineDash([3, 7]);
      ctx.strokeStyle = 'rgba(255,107,107,0.6)';
      ctx.lineWidth = 1.4; ctx.stroke();
      ctx.setLineDash([]);
    }
  }
}
