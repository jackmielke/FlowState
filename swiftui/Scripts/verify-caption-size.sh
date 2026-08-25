#!/usr/bin/env bash
# Proves the caption strip has ONE width and a height that comes from the text.
#
#   ./Scripts/verify-caption-size.sh
#
# WHY THIS EXISTS
# Captions arrive as streaming deltas, so `CaptionBarView` is measured and the window
# re-placed several times a second while the assistant is still talking. It used to be
# sized to its content in both directions, which meant both edges of the strip walked
# outwards under the words as the sentence grew and snapped back on every wrap — a
# failure that is invisible in a screenshot and unmissable in use.
#
# `CaptionLayoutTests` covers the arithmetic in Core. What it cannot cover is whether the
# SwiftUI view actually honours it: the width is only fixed if `.frame(width:)` is on the
# right side of the padding, and the height is only content-based if nothing downstream
# pins it. That needs a real text layout, so this measures the real view with
# `NSHostingView.fittingSize` — the same call `CaptionController` uses to size the panel.
#
# No window server, no microphone, no key. It renders nothing; it only measures.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/harness.swift" <<'SWIFT'
import SwiftUI
import AppKit
import VibeVoiceCore

/// Every prefix of a sentence, word by word — a caption being spoken.
private func deltas(_ s: String) -> [String] {
    let words = s.split(separator: " ")
    return (1...words.count).map { words.prefix($0).joined(separator: " ") }
}

@MainActor
private func measure(_ text: String, width: CGFloat) -> CGSize {
    let line = CaptionState.Line(speaker: .assistant, text: text)
    let host = NSHostingView(rootView: CaptionBarView(line: line, width: width))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
}

@MainActor
private func run() -> Int32 {
    var failed = false
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
        if !ok { failed = true }
    }

    // A sentence long enough to wrap several times at any of these widths.
    let sentence = "I have opened the file and the change is already in it, so there was "
                 + "nothing left for me to do except tell you that it is done."

    // 1728: a 16-inch laptop. 500: a small or heavily scaled display, where the strip has
    // to narrow to fit and the constant is a different constant — but still a constant.
    for visible in [CGFloat(1728), 500] {
        let width = CaptionLayout.width(visibleWidth: visible)
        let sizes = deltas(sentence).map { measure($0, width: width) }
        let widths = Set(sizes.map { Int($0.width.rounded()) })
        let heights = sizes.map { Int($0.height.rounded()) }

        print("screen \(Int(visible)): panel \(Int(width)) wide, "
              + "\(sizes.count) deltas, heights \(heights.min()!)…\(heights.max()!)")

        check(widths.count == 1,
              "the width never changes while the caption is being spoken (saw \(widths.sorted()))")
        check(widths.first == Int(width.rounded()),
              "the measured width is the width the window is sized to (\(Int(width)))")
        check(Set(heights).count > 1,
              "the height is content-based, not a fixed number (\(Set(heights).sorted()))")
        check(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 },
              "the height only ever grows as words are added — no jumping about")
        check(heights.last! > heights.first!,
              "a wrapped caption is taller than a one-line one (\(heights.first!) -> \(heights.last!))")
    }

    // The strip must come back down again: this is a live view of a conversation, not a
    // high-water mark.
    let w = CaptionLayout.width(visibleWidth: 1728)
    check(measure("Done.", width: w).height < measure(sentence, width: w).height,
          "a short caption after a long one is short again")

    return failed ? 1 : 0
}

@main
enum Main {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        exit(MainActor.assumeIsolated { run() })
    }
}
SWIFT

# Core as a real module, so the view is compiled against the same CaptionLayout the app
# uses rather than a copy of its numbers.
swiftc -emit-library -emit-module -module-name VibeVoiceCore Sources/VibeVoiceCore/*.swift \
    -o "$work/libVibeVoiceCore.dylib" -emit-module-path "$work/VibeVoiceCore.swiftmodule"

# CaptionBar.swift and exactly what it needs to compile. If this list has to grow, the
# caption strip has picked up a dependency on the rest of the app — worth knowing.
swiftc -parse-as-library "$work/harness.swift" \
    Sources/VibeVoice/CaptionBar.swift \
    Sources/VibeVoice/Theme.swift \
    Sources/VibeVoice/VisualEffect.swift \
    Sources/VibeVoice/Appearance.swift \
    -I "$work" -L "$work" -lVibeVoiceCore -Xlinker -rpath -Xlinker "$work" \
    -o "$work/verify-caption"

"$work/verify-caption"
echo "caption sizing OK"
