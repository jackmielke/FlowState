"""Bridge: OpenAI realtime tool calls -> headless Claude Code -> spoken result.

Text-mode proof of the full chain. No audio, so it can't fight the apps for the mic.
"""
import asyncio, json, os, subprocess, websockets

KEY = json.load(open(os.path.expanduser('~/.config/vibe-voice/config.json')))['OPENAI_API_KEY']
MODEL = "gpt-realtime-2.1"
_session = {"id": None}   # persists across turns -> Claude Code keeps context

TOOLS = [{
    "type": "function", "name": "dispatch_to_claude_code",
    "description": ("Send a coding task to Claude Code running on the user's Mac. "
                    "Use whenever the user asks to change, build, fix, explain or inspect code. "
                    "Phrase `task` as a complete instruction — Claude Code cannot hear the conversation."),
    "parameters": {"type": "object", "properties": {
        "task": {"type": "string"},
        "repo": {"type": "string", "description": "Absolute repo path"}},
        "required": ["task"]}}]


def run_claude(task, repo=None):
    """Invoke headless Claude Code, resuming the same session each time."""
    cmd = ["claude", "-p", "--output-format", "json", "--permission-mode", "acceptEdits"]
    if _session["id"]:
        cmd += ["--resume", _session["id"]]
    cmd.append(task)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       cwd=os.path.expanduser(repo) if repo else None, timeout=900)
    try:
        d = json.loads(p.stdout)
    except json.JSONDecodeError:
        return {"status": "error", "detail": (p.stderr or p.stdout)[-400:]}
    _session["id"] = d.get("session_id") or _session["id"]
    return {"status": "error" if d.get("is_error") else "ok",
            "result": d.get("result", "")[:1500],
            "cost_usd": d.get("total_cost_usd"), "turns": d.get("num_turns")}


async def ask(user_text, repo):
    url = "wss://api.openai.com/v1/realtime?model=" + MODEL
    async with websockets.connect(url, extra_headers={"Authorization": "Bearer " + KEY},
                                  max_size=None) as ws:
        await ws.send(json.dumps({"type": "session.update", "session": {
            "type": "realtime", "output_modalities": ["text"],
            "instructions": ("You are a voice coding assistant. The user's repo is " + repo + ". "
                             "Dispatch code work to Claude Code, then summarise what changed "
                             "in one or two spoken sentences. Never read code aloud."),
            "tools": TOOLS, "tool_choice": "auto"}}))
        await ws.send(json.dumps({"type": "conversation.item.create", "item": {
            "type": "message", "role": "user",
            "content": [{"type": "input_text", "text": user_text}]}}))
        await ws.send(json.dumps({"type": "response.create"}))

        call = None
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=60))
            t = m.get("type", "")
            if t == "error":
                print("API ERROR:", json.dumps(m)[:300]); return
            if t == "response.function_call_arguments.done":
                call = (m["call_id"], m.get("name"), m.get("arguments"))
            if t == "response.done":
                break
        if not call:
            print("(no tool call)"); return

        cid, name, raw = call
        a = json.loads(raw)
        print("  TOOL  -> " + str(name))
        print("  TASK  -> " + a["task"][:160] + "...")
        print("  running Claude Code (this is a real edit)...")
        out = run_claude(a["task"], a.get("repo") or repo)
        print("  CLAUDE-> status=%s turns=%s cost=$%s" % (out["status"], out.get("turns"), out.get("cost_usd")))

        await ws.send(json.dumps({"type": "conversation.item.create", "item": {
            "type": "function_call_output", "call_id": cid, "output": json.dumps(out)}}))
        await ws.send(json.dumps({"type": "response.create"}))
        spoken = []
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=60))
            if m.get("type", "").endswith("output_text.delta"):
                spoken.append(m.get("delta", ""))
            if m.get("type") == "response.done":
                break
        print("  SPOKEN-> " + "".join(spoken).strip())


if __name__ == "__main__":
    import sys
    asyncio.run(ask(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.getcwd()))
