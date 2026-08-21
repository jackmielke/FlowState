# The task queue — dispatching code work while code work is running

What happens when you ask for a second change to the same repo before the first one has
finished. Implemented in `swiftui/`.

## The problem

Two Claude Code runs in one checkout genuinely break each other. It is not caution: a
build started by one fails with *"input file was modified during the build"* when the
other writes mid-compile. `DevTaskRegistry` has enforced one job per repo from the start,
and that rule is not going anywhere.

What was wrong was the *answer*. A dispatch that broke the rule was **refused**, and the
assistant said some version of "task one is already working in vibe-voice — wait for it,
or point this one at a different repo." That hands scheduling back to somebody whose
hands are the reason they are talking to a voice assistant. The user has to remember the
idea, notice when the first task finishes, and say it again.

So the rule stayed and the answer changed: **not now** became **next**.

## Shape

```
dispatch_to_claude_code
        │
        ▼
DevTaskRegistry.rejectionFor(repo:)   ← unchanged: one job per repo, maxConcurrent overall
        │
   ┌────┴─────┐
   │          │
 clear      blocked
   │          │
   ▼          ▼
 start     enqueue(label:repo:request:)   ← DevTaskRequest: what to run, kept with the task
   │          │
   └──▶ launchDevTask(...)  ◀─────────────┐
              │                           │
         run finishes                     │
              │                           │
              ▼                           │
      startQueuedTasks() ─────────────────┘
      (registry.startNextQueued(), in a loop, until nothing else may start)
```

`DevTaskRequest` exists because a queued task is a promise to run something later, and a
promise that has forgotten what it promised is worthless. The instruction, the permission
mode and the task being resumed all travel with the task instead of staying in the call
that dispatched it.

`launchDevTask` is shared by both paths on purpose. A queue whose jobs skipped the git
snapshot would be a queue whose jobs cannot be undone.

## The rules, and where they are tested

All of them are decidable from their arguments, so all of them live in `VibeVoiceCore`
and are covered by `DevTaskRegistryTests`:

| Rule | Why |
|---|---|
| A queued task is neither running nor finished (`Status.isTerminal` is false for both `.queued` and `.running`) | It has no outcome yet. Counting it as finished would show it in the results list with no result. |
| `startNextQueued` asks the same `canStart(repo:)` everything else asks | The queue cannot smuggle a second job into a busy checkout, however it is called. |
| A queued task whose repo is busy is **skipped**, not blocking | The queue is an order, not a barrier — a job for a free repo goes now rather than waiting behind one that cannot start. |
| `maxConcurrent` (3) still caps the whole thing | The queue changes *when* things run, never *how many*. |
| `startedAt` is reset when a task actually starts; `queuedAt` records the wait | "Ran for 40s" must not silently include an hour spent waiting. |
| Cancelling a queued task drops it, and it never comes back | A queue you cannot take something out of is a trap. |
| Reordering rewrites only the slots queued tasks occupy | Running and finished tasks share one array with the queue and must keep their places and their history. |

## In the UI

`TaskPanel` grows a **NEXT UP** section between the running cards and the finished ones.
Each queued card shows its position, what it is waiting on ("waiting for T1", "waiting for
a free slot"), ▲▼ to move it, and ✕ to drop it. Reordering is the whole reason the queue
is visible: a queue you can watch but not change is just a slower refusal.

The header pill counts it too — `CODING · +2` — because a task that will run later is
still work the user asked for, and the pill may be the only thing they are looking at.

## What the model is told

The dev-mode instructions now say, in as many words: *when a task is queued, never tell
the user to wait, never offer to retry it later, and never ask them to pick a different
repo.* Say it is queued and what it is behind, in one sentence.

The tool result carries `status: "queued"`, the task id and the position. When a run
finishes and the queue moves on by itself, the finished-task note names what just started,
so the assistant can say "that's done, and the button spacing one has started" without
being asked.

## Not done

- Persisting the queue across a relaunch. A queued task is lost when the app quits, which
  is honest — the instruction was spoken into a session that no longer exists — but a
  crash mid-queue silently drops work the user believes is coming.
- Reordering by voice. The panel has ▲▼; there is no `reorder_task` tool yet. The ids
  are already spoken ("move T3 up") so the gap is a tool spec, not a design question.
- Drag-and-drop. `DevTaskRegistry.moveQueued(from:to:)` already takes SwiftUI's
  `onMove` insertion-index convention, so the view is the only missing part.
