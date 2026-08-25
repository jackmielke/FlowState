import SwiftUI
import VibeVoiceCore

/// What the window becomes when nobody has touched it for a while.
///
/// Ambient mode already fades the chrome away and leaves the scene. That is restful and
/// slightly pointless: a beautiful empty rectangle is a screensaver you cannot use for
/// anything. Given that this app is the kind of thing left open on a second monitor all
/// day, the fade may as well leave something worth glancing at.
///
/// So: the time, large and thin; the date under it; and one line of what was last talked
/// about, if there was anything. Nothing interactive, nothing that moves on its own —
/// the backdrop is already moving, and two things competing for attention is how a
/// restful screen stops being restful.
struct AmbientClock: View {
    @ObservedObject var state: AppState

    /// `TimelineView`, not a `Timer`.
    ///
    /// A clock in ambient mode is a clock in an app that is, by definition, doing
    /// nothing — which is precisely the condition macOS App Nap looks for. A repeating
    /// `Timer` gets throttled or suspended outright, and the display freezes at whatever
    /// minute it was when the system decided the app was idle. Reported from the room:
    /// it sat on 12:26 AM.
    ///
    /// `TimelineView` schedules its own redraws through SwiftUI rather than through a
    /// run-loop timer, and `.everyMinute` exists for exactly this — it is aligned to the
    /// minute boundary and it recovers after the machine sleeps and wakes, which a timer
    /// started an hour ago does not.
    private func time(_ now: Date) -> String {
        let f = DateFormatter()
        // The user's own clock, 12- or 24-hour, without seconds.
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f.string(from: now)
    }

    private func date(_ now: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f.string(from: now)
    }

    /// The last thing discussed, if a summary has been written. One line, because this is
    /// something to notice rather than something to read.
    private var lastTopic: String? {
        guard let text = state.latestSummary?.text else { return nil }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? text
        let cleaned = firstLine
            .replacingOccurrences(of: "About:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 3 else { return nil }
        return cleaned.count > 90 ? String(cleaned.prefix(90)) + "…" : cleaned
    }

    var body: some View {
        TimelineView(.everyMinute) { tl in
            clockFace(at: tl.date)
        }
    }

    private func clockFace(at now: Date) -> some View {
        VStack(spacing: 6) {
            Text(time(now))
                // Thin and huge: at this size a regular weight reads as a dashboard, and
                // this is meant to read as a room.
                .font(.system(size: 84, weight: .thin, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.92))
            Text(date(now))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
            if let lastTopic {
                Text(lastTopic)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.top, 14)
                    .padding(.horizontal, 40)
            }
        }
        // The scene behind it can be any brightness, and thin white text on a bright sky
        // is unreadable without this.
        .shadow(color: .black.opacity(0.55), radius: 22, y: 2)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(time(now)), \(date(now))")
    }
}
