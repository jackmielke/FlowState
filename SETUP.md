# Install FlowState

**Paste this whole file into Claude Code (or Codex, or Cursor) from a terminal in
any empty folder, and let it work.**

---

You are installing FlowState: a macOS app you talk to. It listens, it can look at
your screen when asked, and it can edit its own source while you keep talking.

Do all of this yourself. Stop only for the things a human has to do — clicking a
permission dialog, supplying an API key.

## Before you build

- **macOS 14+** — `sw_vers -productVersion`
- **Xcode Command Line Tools** — `xcode-select -p`; if that fails, run
  `xcode-select --install` and wait for the user to click through it.
  No Xcode app, and **no Apple Developer account**, are needed.
- **An OpenAI API key with credit**, from platform.openai.com. It is the only
  thing here that costs money. If the user hasn't got one, stop and ask for it.
  Never substitute your own.

## Build it

```bash
git clone https://github.com/jackmielke/FlowState.git
cd FlowState/swiftui
./relaunch.sh
```

That compiles, assembles `FlowState.app`, ad-hoc signs it, installs it to
`/Applications`, and launches it. The first build takes a few minutes.

Ad-hoc signing is why no certificate appears anywhere in this file: it is enough
for an app built and run on the same Mac.

## First launch

The app opens and asks for the OpenAI key itself — the user pastes it into the
welcome sheet, and it goes into the macOS Keychain. Don't write it to a file, and
don't type it for them.

Then macOS asks, once each, as features get used. The user must click these; you
cannot:

| Permission | What stops working without it |
|---|---|
| Microphone | everything |
| Screen Recording | "show it my screen" only |
| Accessibility | the ⌃Q hotkey, and dictation into other apps |

## Check it

Press **⌃Q** and say something. It should answer out loud.

If it doesn't, the useful places to look are `~/Library/Logs/FlowState/`, and
`log stream --predicate 'subsystem == "com.jackmielke.vibevoice"'`. That identifier
is the app's old name, kept deliberately so upgrades don't lose permission grants.

## Making it yours

The app is meant to be changed while you talk to it. To keep your own work and
still take updates:

```bash
gh repo fork jackmielke/FlowState --clone --remote
git fetch upstream && git merge upstream/main   # whenever you want new work
```

Use `./dev.sh` while iterating — tests plus relaunch, about eight seconds.
`./relaunch.sh` does the optimised build, nearer thirty; use it for anything you
mean to keep.

## What it costs

The realtime model bills for audio, including the audio of an empty room, so a
session left open overnight is real money. Hang up when you're done — the widget
shows the running cost.
