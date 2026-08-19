// Headless proof that the realtime contract is reachable — no microphone,
// no speaker, no app window. Mints an ek_ token exactly the way the Rust
// backend does, then opens the WebSocket transport and waits for
// session.created.
//
//   node scripts/verify-session.mjs
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const MODEL = process.argv[2] || "gpt-realtime-2.1";
const cfg = JSON.parse(readFileSync(join(homedir(), ".config/vibe-voice/config.json"), "utf8"));

const r = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
  method: "POST",
  headers: { Authorization: `Bearer ${cfg.OPENAI_API_KEY}`, "Content-Type": "application/json" },
  body: JSON.stringify({ session: { type: "realtime", model: MODEL } }),
});
if (!r.ok) { console.error("mint failed", r.status, await r.text()); process.exit(1); }
const tok = await r.json();
console.log(`ok  mint      ${tok.value.slice(0, 8)}… expires_at=${tok.expires_at}`);

const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${MODEL}`, {
  headers: { Authorization: `Bearer ${tok.value}` },
});
const timer = setTimeout(() => { console.error("timed out waiting for session.created"); process.exit(1); }, 15000);
ws.onopen = () => console.log("ok  websocket open");
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.type === "session.created") {
    console.log(`ok  session.created  id=${m.session.id}`);
    console.log(`    model=${m.session.model} voice=${m.session?.audio?.output?.voice}`);
    clearTimeout(timer); ws.close(); process.exit(0);
  }
  if (m.type === "error") { console.error("error", JSON.stringify(m.error)); process.exit(1); }
};
ws.onerror = (e) => { console.error("ws error", e.message || e); process.exit(1); };
