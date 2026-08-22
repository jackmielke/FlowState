# Screen Recording on this Mac — what we learned the hard way

## The 30-second fix

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**
2. Click the **`+`** button under the list
3. Choose **`/Applications/FlowState.app`**
4. Make sure its toggle is **on**
5. **Quit and reopen FlowState** — macOS only reads this grant at launch

The `+` button is the reliable path. Waiting for a prompt is not.

## Why there is no prompt

Current macOS does **not** offer an "Allow" button for screen recording. The system
dialog offers only **Open System Settings** or **Deny**. Permission is granted in
System Settings, never from the prompt.

Measured here against bundle ids macOS had never seen before:

| call | result |
|---|---|
| `CGRequestScreenCaptureAccess()` | `false` in ~10 ms, **no prompt** |
| `SCShareableContent…` | `-3801 the user declined TCCs` |

Both a certificate-signed probe and an ad-hoc probe behaved identically, so neither
the signature nor a stale TCC record explains it — this is just how the OS behaves.
An app becomes *listed* in that pane once it has attempted a capture and been
refused, which is why the app now makes a real ScreenCaptureKit attempt on launch.

## Three separate bugs produced the same symptom

Worth keeping straight, because they masked each other:

1. **Ad-hoc signing.** The designated requirement was a raw `cdhash`, so every rebuild
   looked like a brand-new app and voided the grant. Fixed by signing with a stable
   self-signed certificate (`Scripts/make-signing-id.sh`). Verified identical across
   rebuilds.
2. **Bundle-id collision.** All three implementations shipped
   `com.jackmielke.vibevoice`, so macOS had one privacy row for three differently
   signed apps and toggling it could grant the wrong one. Tauri is now
   `com.jackmielke.vibevoice-tauri`.
3. **Permission deadlock.** The only call that registers the app sat behind a
   "must be connected" guard, so pressing *Show screen* while idle did nothing at all
   and the row never appeared. Access is now requested on launch, from *Check again*,
   and before the connection guard.

## Diagnosing it again

`tccutil reset ScreenCapture com.jackmielke.vibevoice` removes the row entirely — the
app has to attempt a capture again before it reappears. Don't reset unless you mean it.

To see what the app actually concluded, watch its own log while launching it the way a
human does (the launch path matters — see below):

```bash
log stream --style compact --level debug --predicate 'subsystem == "com.jackmielke.vibevoice"'
```

**Launch path changes the answer.** Running the binary straight from a terminal reports
`preflight=true` because it inherits the terminal's TCC grant. Launching via
Finder/`open` reports the truth. Always trust the `open` path.
