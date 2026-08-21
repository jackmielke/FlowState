import Foundation

/// What Vantage is allowed to remember about a conversation.
///
/// The default is deliberately not "record nothing" — a voice assistant that cannot
/// remember what you said two minutes ago is a worse assistant, and the transcript is
/// already on screen. The default is instead: keep the words, keep the SHAPE of the
/// audio, never keep the audio itself, redact the things that should not be sitting in
/// a plain-text file, and throw all of it away after a week.
///
/// Every switch here is honoured in exactly one place — `ConversationLog.append` — so
/// there is no second path that could quietly record around it.
///
/// One boundary worth stating plainly, because it is a choice rather than an oversight:
/// this governs the DURABLE record and what a summary may see. It does not govern the
/// live transcript on screen, which shows what was actually said and vanishes when the
/// app quits. Redacting the user's own words back at them, in the window they are
/// looking at, protects nobody.
public struct TranscriptPrivacy: Codable, Equatable, Sendable {

    /// The mute switch. While true, nothing at all is recorded — every other field here
    /// is irrelevant. Meant to be reachable in one click for "not this bit".
    public var paused: Bool

    public var captureUserSpeech: Bool
    public var captureAssistantSpeech: Bool
    /// Tool results, task progress, connection notes. Off by default: it is noise in a
    /// record of a conversation, and it is what makes summaries turn into changelogs.
    public var captureSystemNotes: Bool

    /// Duration and level per utterance. No samples — see `keepAudioClips`.
    public var captureAudioMetadata: Bool

    /// Writing real microphone audio to disk.
    ///
    /// OFF, and there is no code path that turns it on implicitly. `AudioClipRecorder`
    /// in the app target is the only thing that would ever write a file, and it refuses
    /// unless this is true.
    public var keepAudioClips: Bool

    /// Whether the record survives quitting the app. Off = the conversation lives in
    /// memory for the session and then is gone.
    public var persistToDisk: Bool

    /// How long anything is kept. 0 = forever (which is a real choice, and a bad
    /// default). Enforced on every purge, not just at write time, so turning it down
    /// deletes what is already there.
    public var retentionHours: Double

    /// Rewrite obvious secrets and contact details before storing. Cheap, and the
    /// alternative is an API key sitting in a plain-text log because it was read aloud.
    public var redactSensitiveText: Bool

    public init(paused: Bool = false,
                captureUserSpeech: Bool = true,
                captureAssistantSpeech: Bool = true,
                captureSystemNotes: Bool = false,
                captureAudioMetadata: Bool = true,
                keepAudioClips: Bool = false,
                persistToDisk: Bool = true,
                retentionHours: Double = 24 * 7,
                redactSensitiveText: Bool = true) {
        self.paused = paused
        self.captureUserSpeech = captureUserSpeech
        self.captureAssistantSpeech = captureAssistantSpeech
        self.captureSystemNotes = captureSystemNotes
        self.captureAudioMetadata = captureAudioMetadata
        self.keepAudioClips = keepAudioClips
        self.persistToDisk = persistToDisk
        self.retentionHours = retentionHours
        self.redactSensitiveText = redactSensitiveText
    }

    /// Nothing is written, nothing is kept, nothing is summarised.
    public static let recordNothing = TranscriptPrivacy(paused: true,
                                                        captureUserSpeech: false,
                                                        captureAssistantSpeech: false,
                                                        captureAudioMetadata: false,
                                                        persistToDisk: false,
                                                        retentionHours: 0)

    // MARK: - Decisions

    public func admits(speaker: TranscriptSpeaker) -> Bool {
        guard !paused else { return false }
        switch speaker {
        case .user:      return captureUserSpeech
        case .assistant: return captureAssistantSpeech
        case .system:    return captureSystemNotes
        }
    }

    public func hasExpired(_ date: Date, now: Date = Date()) -> Bool {
        guard retentionHours > 0 else { return false }
        return now.timeIntervalSince(date) > retentionHours * 3600
    }

    /// A short line for the UI, so the current policy is legible without reading five
    /// toggles. Spoken-plain, because the assistant may end up saying it.
    public var summaryLine: String {
        if paused { return "Recording is paused — nothing is being kept." }
        if !captureUserSpeech && !captureAssistantSpeech { return "Nothing is being kept." }
        var parts: [String] = []
        parts.append(captureUserSpeech && captureAssistantSpeech ? "both sides"
                     : (captureUserSpeech ? "your side only" : "my side only"))
        parts.append(keepAudioClips ? "audio clips kept"
                     : (captureAudioMetadata ? "no audio, levels only" : "no audio at all"))
        parts.append(persistToDisk ? "saved to disk" : "memory only")
        parts.append(retentionHours > 0
                     ? "kept \(Self.humanHours(retentionHours))"
                     : "kept forever")
        return parts.joined(separator: ", ") + "."
    }

    public static func humanHours(_ h: Double) -> String {
        if h < 1 { return "\(Int(h * 60)) minutes" }
        if h < 48 { return "\(Int(h)) hours" }
        return "\(Int(h / 24)) days"
    }

    // MARK: - Redaction

    /// Rewrites the things that should not end up in a plain-text log, and reports
    /// whether it had to.
    ///
    /// Kept conservative on purpose. This is a net for the obvious accident — reading a
    /// key out loud, dictating an email address — and not a claim to catch everything.
    /// Over-redacting a voice transcript makes it useless, which is its own failure.
    public func redact(_ text: String) -> (text: String, didRedact: Bool) {
        guard redactSensitiveText else { return (text, false) }
        var out = text
        for rule in Self.rules {
            out = rule.apply(to: out)
        }
        return (out, out != text)
    }

    struct RedactionRule {
        let regex: NSRegularExpression?
        let replacement: String

        init(_ pattern: String, _ replacement: String) {
            self.regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.replacement = replacement
        }

        func apply(to s: String) -> String {
            guard let regex else { return s }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            return regex.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
        }
    }

    /// Order matters: the key and bearer rules run before the number rule, so a token
    /// that happens to contain a long digit run is redacted as a key rather than being
    /// half-eaten as a phone number.
    static let rules: [RedactionRule] = [
        RedactionRule(#"\b(?:sk|ek|pk|ghp|xox[bpsa])[-_][A-Za-z0-9_\-]{12,}"#, "[api-key]"),
        RedactionRule(#"\bBearer\s+[A-Za-z0-9._\-]{12,}"#, "[token]"),
        RedactionRule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[email]"),
        // Ten or more digits, however they were spaced out when dictated. Short numbers
        // are left alone — "call me at 4" and "port 8080" are not secrets.
        RedactionRule(#"\b(?:\d[ \-().]{0,2}){9,}\d\b"#, "[number]"),
    ]
}
