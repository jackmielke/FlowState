#!/usr/bin/env bash
# Proves a transcript survives — written to disk, read back, corrected, pinned, trimmed
# and deleted — against the real ConversationStore, not a copy.
#
#   ./Scripts/verify-transcript.sh
#
# WHY THIS EXISTS
# "Your conversation is still here after a restart" is a promise that can only be broken
# between two launches, which is exactly where a unit test cannot look: ConversationStore
# lives in the app target, owns the disk, and is @MainActor. So the rules it enforces are
# tested in Core (ConversationLog, ConversationArchive, TranscriptRetention) and the
# round trip is proved here, by writing files, throwing the store away, building a new
# one over the same folder and asking it what it remembers.
#
# Everything runs under FLOWSTATE_HOME in a temp folder, so this never touches the
# conversations on the machine it runs on.
#
# ConversationStore.swift imports Foundation, Combine and VibeVoiceCore, and nothing
# else. If this script stops compiling because it has acquired AppKit or SwiftUI, that is
# the point of it: persistence must stay testable without a window server.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
OUT="$WORK/verify-transcript"
DRIVER="$WORK/main.swift"
export FLOWSTATE_HOME="$WORK/home"

cat > "$DRIVER" <<'SWIFT'
import Foundation
import VibeVoiceCore

var failures = 0
func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    print("\(ok ? "  ok  " : "  FAIL") \(what)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}

/// Stands in for the real one in SpeechCapture.swift, which cannot be compiled here —
/// it reaches for `AudioEngine.targetRate`. Only the folder matters to this script:
/// `deleteAllOnDisk` empties it, and it must be the temporary home rather than the real
/// Application Support folder.
enum AudioClipRecorder {
    static var directory: URL {
        ConversationStore.root.appendingPathComponent("audio", isDirectory: true)
    }
}

let fm = FileManager.default
let root = ConversationStore.root
func conversationFiles() -> [String] {
    ((try? fm.contentsOfDirectory(atPath: ConversationStore.conversationsDirectory.path)) ?? [])
        .filter { $0.hasSuffix(".jsonl") }.sorted()
}

@MainActor
func run() {
    print("1. what is said is written, and the file is one line per record")
    let first = ConversationStore()
    let sessionA = first.currentSessionID
    first.record(speaker: .user, text: "pin this conversation for me", source: .realtimeAPI)
    first.record(speaker: .assistant, text: "pinned", source: .assistantStream)

    let fileA = first.transcriptURL(for: sessionA)
    check(fm.fileExists(atPath: fileA.path), "the transcript exists", fileA.lastPathComponent)
    let raw = (try? String(contentsOf: fileA, encoding: .utf8)) ?? ""
    check(raw.split(separator: "\n").count == 2, "two records on two lines",
          "\(raw.split(separator: "\n").count)")
    let perms = (try? fm.attributesOfItem(atPath: fileA.path)[.posixPermissions] as? NSNumber)??.intValue
    check(perms == 0o600, "and is readable only by its owner", String(perms ?? -1, radix: 8))

    print("\n2. a new store over the same folder reads it back — this is the restart")
    let second = ConversationStore()
    let load = second.openSession(sessionA)
    guard let archive = load.archive else {
        check(false, "the conversation came back", load.error ?? "unreadable")
        return
    }
    check(archive.entries.map(\.text) == ["pin this conversation for me", "pinned"],
          "both lines, in the order they were said")
    check(archive.entries.first?.speaker == .user, "and who said them")
    check(second.currentSessionID == sessionA, "and it is the conversation we are in")

    print("\n3. a correction is appended, not rewritten, and survives the next restart")
    let target = archive.entries[0].id
    check(second.edit(entryID: target, to: "pin this one for me")?.text == "pin this one for me",
          "the edit lands in memory")
    check(second.removeEntry(archive.entries[1].id), "and a line can be deleted")
    let afterEdit = ConversationStore().openSession(sessionA).archive
    check(afterEdit?.entries.map(\.text) == ["pin this one for me"],
          "read back: corrected, and the deleted line stayed deleted",
          (afterEdit?.entries.map(\.text) ?? []).joined(separator: " | "))
    check((afterEdit?.editCount ?? 0) == 2, "two corrections were folded in",
          "\(afterEdit?.editCount ?? 0)")

    print("\n4. a pin survives a restart, and retention steps around it")
    let third = ConversationStore()
    third.openSession(sessionA)
    check(third.setPinned(true, session: sessionA), "pinned")
    let fourth = ConversationStore()
    check(fourth.isPinned(sessionA), "still pinned after a restart — the index kept it")

    // A retention window of one second, then a purge: the pinned conversation must be
    // the only thing left standing.
    let old = fourth.startNewSession()
    fourth.record(speaker: .user, text: "an ordinary conversation", source: .realtimeAPI)
    check(conversationFiles().count == 2, "two transcripts on disk", conversationFiles().joined(separator: " "))
    Thread.sleep(forTimeInterval: 1.2)
    // Move off the new conversation first: the one on screen is never purged.
    fourth.startNewSession()
    var window = fourth.privacy
    window.retentionHours = 1.0 / 3600     // one second
    fourth.privacy = window
    fourth.purgeExpiredFiles()
    let left = conversationFiles()
    check(left.contains(sessionA + ".jsonl"), "the pinned transcript is still there")
    check(!left.contains(old + ".jsonl"), "the unpinned one aged out", left.joined(separator: " "))

    print("\n5. keep-last trims the oldest and never the pinned or the open one")
    let fifth = ConversationStore()
    var kept: [String] = []
    for i in 1...4 {
        let id = fifth.startNewSession()
        fifth.record(speaker: .user, text: "conversation \(i)", source: .realtimeAPI)
        kept.append(id)
    }
    fifth.startNewSession()                        // so nothing under test is "current"
    fifth.retention = TranscriptRetention(mode: .keepLast, keepLast: 2)
    let after = conversationFiles()
    check(after.contains(sessionA + ".jsonl"), "the pinned one is exempt from the limit")
    check(after.contains(kept[3] + ".jsonl") && after.contains(kept[2] + ".jsonl"),
          "the two newest are kept")
    check(!after.contains(kept[0] + ".jsonl") && !after.contains(kept[1] + ".jsonl"),
          "the two oldest are gone", after.joined(separator: " "))

    print("\n6. \"only what I save\" writes nothing until it is asked to")
    let sixth = ConversationStore()
    sixth.retention = TranscriptRetention(mode: .manualSave)
    let manual = sixth.startNewSession()
    sixth.record(speaker: .user, text: "this should not be on disk yet", source: .realtimeAPI)
    check(!fm.fileExists(atPath: sixth.transcriptURL(for: manual).path),
          "nothing was written")
    check(sixth.save(session: manual) == 1, "saving writes it")
    check(ConversationStore().openSession(manual).archive?.entries.first?.text
            == "this should not be on disk yet",
          "and it reads back after a restart")

    // Saving twice must not double the file — the merge is by record id.
    sixth.save(session: manual)
    check(ConversationStore().openSession(manual).archive?.entries.count == 1,
          "saving twice leaves one copy of each line")

    print("\n7. deleting deletes — file, row and lines")
    let seventh = ConversationStore()
    seventh.forget(session: manual)
    check(!fm.fileExists(atPath: seventh.transcriptURL(for: manual).path), "the file is gone")
    check(!seventh.sessions.contains { $0.id == manual }, "and so is the row")

    seventh.forgetEverything()
    check(conversationFiles().isEmpty, "delete everything leaves nothing behind",
          conversationFiles().joined(separator: " "))
    check(!fm.fileExists(atPath: ConversationStore.sessionsIndexURL.path),
          "including the index, which described files that no longer exist")
}

MainActor.assumeIsolated { run() }

print("")
if failures == 0 {
    print("PASS — transcripts are written, read back, corrected, pinned, trimmed and\n       deleted exactly as the settings say.")
} else {
    print("FAIL — \(failures) check\(failures == 1 ? "" : "s") did not hold.")
}
print("      home: \(root.path)")
exit(failures == 0 ? 0 : 1)
SWIFT

echo "==> building VibeVoiceCore (pure Foundation)"
swiftc -swift-version 5 -O -emit-module -emit-library -static \
  -module-name VibeVoiceCore \
  -emit-module-path "$WORK/VibeVoiceCore.swiftmodule" \
  -o "$WORK/libVibeVoiceCore.a" \
  Sources/VibeVoiceCore/*.swift

# ConversationStore needs the console logger it reports through, and one symbol from
# SpeechCapture — the audio-clip folder "delete everything" also empties. The logger is
# compiled for real; the clip folder is stubbed in the driver, because SpeechCapture
# itself reaches for AudioEngine and would drag the whole audio stack in behind it.
echo "==> compiling ConversationStore.swift on its own"
swiftc -swift-version 5 -O -I "$WORK" -L "$WORK" -lVibeVoiceCore \
  Sources/VibeVoice/ConversationStore.swift \
  Sources/VibeVoice/TranscriptLog.swift \
  "$DRIVER" -o "$OUT"

"$OUT"
