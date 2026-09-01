import Foundation

/// The handful of things you should never have to reach for the window to do.
///
/// Recording is the one part of this app you use *while doing something else* — while
/// presenting, while pairing, while walking away from the desk — and every one of those
/// is a moment when finding a button is the whole cost of the feature. So the transport
/// (start, stop, pause, resume) and the camera bubble are sayable, and they are sayable
/// through ONE vocabulary rather than one per route.
///
/// There are two routes and they must not disagree:
///
///  * With a session open, the model calls these as tools — `toolName` is what it calls,
///    `modelDescription` is what it reads to decide.
///  * With no session open and the wake listener running, the on-device recogniser
///    matches the same `phrases` directly, so the commands still work with no socket,
///    no API key and nothing leaving the Mac. See `VoiceCommandListener`.
///
/// Both routes end at the same `VoiceCommandGate.decide`, which is why a command that is
/// refused is refused for the same reason and in the same words either way.
public enum VoiceCommand: String, CaseIterable, Sendable, Identifiable {
    case startRecording
    case stopRecording
    case pauseRecording
    case resumeRecording
    case showFace
    case hideFace

    public var id: String { rawValue }

    /// What the realtime model calls it. Snake case, like every other tool.
    public var toolName: String {
        switch self {
        case .startRecording:  return "start_recording"
        case .stopRecording:   return "stop_recording"
        case .pauseRecording:  return "pause_recording"
        case .resumeRecording: return "resume_recording"
        case .showFace:        return "show_face"
        case .hideFace:        return "hide_face"
        }
    }

    /// The command a tool call names, or nil for anything else. The other direction of
    /// `toolName`, so the dispatcher does not need a second switch that can fall out of
    /// step with the first.
    public init?(toolName: String) {
        guard let match = VoiceCommand.allCases.first(where: { $0.toolName == toolName }) else {
            return nil
        }
        self = match
    }

    /// Shown in Settings, and in the transcript line each command leaves behind.
    public var summary: String {
        switch self {
        case .startRecording:  return "Start recording"
        case .stopRecording:   return "Stop recording"
        case .pauseRecording:  return "Pause recording"
        case .resumeRecording: return "Resume recording"
        case .showFace:        return "Show my face"
        case .hideFace:        return "Hide my face"
        }
    }

    /// What the model reads.
    ///
    /// Each one says which *kind* of recording it means, because this app has two and
    /// they are easy to confuse: a take — a file being written — and the transcript of
    /// the conversation. Saying "off the record" is not the same request as "stop
    /// recording", and the tool that stops a screen recording must never be the one that
    /// silently switches off what is kept about somebody.
    public var modelDescription: String {
        switch self {
        case .startRecording:
            return "Start recording a take — the audio, or the screen and camera, written "
                 + "to a file the user keeps. Use when they say start recording, record "
                 + "this, or begin capture. Captures whatever the current capture mode "
                 + "says; do not ask them to confirm."
        case .stopRecording:
            return "Stop the take that is running and save the file. Use when they say "
                 + "stop recording, that's enough, or end the recording. This does NOT "
                 + "change what is kept about the conversation — for \"off the record\" "
                 + "or \"don't write this down\", call stop_transcript instead."
        case .pauseRecording:
            return "Pause the take without ending it. Nothing said or shown while paused "
                 + "reaches the file, and resuming continues the same file rather than "
                 + "starting a second one. Use for hold on, pause that, one moment."
        case .resumeRecording:
            return "Continue a paused take. Use for resume, carry on, unpause, we're back."
        case .showFace:
            return "Show the user's camera in the floating bubble, so their face is on "
                 + "screen and in anything being recorded. Use for show my face, camera "
                 + "on, put me on screen."
        case .hideFace:
            return "Hide the floating camera bubble. Use for hide my face, camera off, "
                 + "take me off screen. A take that is running keeps running — this only "
                 + "removes the face from it."
        }
    }

    /// Everything a person might say for it, lowercased and already stripped by
    /// `WakePhrase.normalise`.
    ///
    /// Deliberately short phrases and deliberately no bare verbs. "Start" on its own is a
    /// word that appears in ordinary sentences all day; "start recording" is not. The
    /// same rule the wake phrase is built on, for the same reason — this listener is open
    /// while you are talking to somebody else.
    public var phrases: [String] {
        switch self {
        case .startRecording:
            return ["start recording", "start the recording", "begin recording",
                    "start recording this", "record this", "start capture"]
        case .stopRecording:
            return ["stop recording", "stop the recording", "end recording",
                    "end the recording", "finish recording", "stop capture"]
        case .pauseRecording:
            return ["pause recording", "pause the recording", "hold the recording",
                    "pause capture"]
        case .resumeRecording:
            return ["resume recording", "resume the recording", "unpause recording",
                    "unpause the recording", "continue recording", "carry on recording",
                    "resume capture"]
        case .showFace:
            return ["show my face", "show face", "show the camera", "camera on",
                    "turn on the camera", "turn the camera on", "put me on screen"]
        case .hideFace:
            return ["hide my face", "hide face", "hide the camera", "camera off",
                    "turn off the camera", "turn the camera off", "take me off screen"]
        }
    }

    /// True for the four transport commands. The face ones do not touch a take.
    public var isTransport: Bool {
        switch self {
        case .showFace, .hideFace: return false
        default: return true
        }
    }

    public var isCamera: Bool { !isTransport }

    /// What this command means given where the app actually is.
    ///
    /// One case, and it earns itself: "start recording" said over a PAUSED take means
    /// continue it. Refusing — "there's already a recording" — is technically true and
    /// useless, and the alternative reading (stop that one and begin a second file) is
    /// the one nobody means. Resolving here rather than in either caller is what keeps
    /// the spoken route and the model route from disagreeing about it.
    public func resolved(in context: VoiceCommandContext) -> VoiceCommand {
        if self == .startRecording, context.isRecording, context.isPaused { return .resumeRecording }
        return self
    }

    /// Matched longest-first everywhere, so "resume recording" cannot be read as the
    /// shorter "record this" hiding inside somebody's sentence.
    static var allPhrases: [(phrase: String, command: VoiceCommand)] {
        allCases
            .flatMap { c in c.phrases.map { (WakePhrase.normalise($0), c) } }
            .filter { !$0.0.isEmpty }
            .sorted { $0.0.count > $1.0.count }
    }
}

/// Where a command came from. Four routes reach the same door, and the difference
/// between them is not bookkeeping: the master switch turns off *saying* things, not the
/// button and not the keyboard shortcut, so a user who wants nothing listening for
/// phrases does not thereby lose the record button.
public enum VoiceCommandSource: String, Sendable {
    /// Heard by the on-device recogniser, with no session open.
    case speech
    /// The assistant called it as a tool, mid-conversation.
    case model
    /// The global record shortcut.
    case hotkey
    /// A button in the window.
    case ui

    /// Whether this route is somebody talking. The two that are get gated by the
    /// `voiceCommands` switch; the two that are not are direct manipulation and are
    /// nobody's business but the user's.
    public var isSpoken: Bool { self == .speech || self == .model }
}

/// Turning a line of recognised speech into one of the commands above, or into nothing.
///
/// Pure and separately testable on purpose: this is the half that can be wrong in ways
/// worth proving — a phrase said inside a longer sentence, a phrase said with "don't" in
/// front of it, two commands in one breath.
public enum VoiceCommandVocabulary {

    /// Words that turn a command into its opposite when they come straight before it.
    ///
    /// "Don't stop recording" used to be a stop, which is the single worst way for this
    /// feature to fail: it does the thing you just said not to do, and it does it to a
    /// file you cannot get back. Normalisation strips the apostrophe, so "don't" arrives
    /// as "don t" and the two-word forms have to be listed as well.
    private static let negations: Set<String> = [
        "not", "never", "dont", "cant", "wont", "didnt", "stopped",
    ]
    private static let negationPairs: Set<String> = [
        "don t", "do not", "did not", "can t", "won t", "does not", "rather than",
    ]

    /// The command in `text`, or nil.
    ///
    /// - Parameter tailCharacters: how much of the end of the transcript counts. A
    ///   continuous recognition task reports one transcript that grows for a minute, so
    ///   without this a command said once is "in the text" forever. Same rule, and the
    ///   same reason, as `WakeListenerState.tailCharacters`.
    /// - Returns: the command that was said LAST. Somebody who says "pause recording —
    ///   no, stop recording" meant the second one, and the alternative is obeying a
    ///   sentence they audibly corrected.
    public static func match(_ text: String, tailCharacters: Int = 60) -> VoiceCommand? {
        let normalised = WakePhrase.normalise(text)
        guard !normalised.isEmpty else { return nil }
        let hay = String(normalised.suffix(max(0, tailCharacters)))
        guard !hay.isEmpty else { return nil }

        var best: (end: Int, length: Int, command: VoiceCommand)?
        for (phrase, command) in VoiceCommand.allPhrases {
            guard let range = hay.range(of: phrase, options: .backwards) else { continue }
            guard !isNegated(hay, before: range.lowerBound) else { continue }
            // Word-boundary check on the left only. The right-hand side is open on
            // purpose: the recogniser writes "start recordings" and "show my faces" often
            // enough that requiring a boundary there loses more than it protects.
            guard startsAWord(hay, at: range.lowerBound) else { continue }
            let end = hay.distance(from: hay.startIndex, to: range.upperBound)
            if let current = best, (current.end, current.length) >= (end, phrase.count) { continue }
            best = (end, phrase.count, command)
        }
        return best?.command
    }

    private static func startsAWord(_ hay: String, at index: String.Index) -> Bool {
        guard index != hay.startIndex else { return true }
        return hay[hay.index(before: index)] == " "
    }

    private static func isNegated(_ hay: String, before index: String.Index) -> Bool {
        let prefix = hay[hay.startIndex..<index].trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return false }
        let words = prefix.split(separator: " ").map(String.init)
        // A bare "t" is what is left of every n't contraction once the apostrophe has
        // been stripped — didn't, doesn't, couldn't, wouldn't. Listing the dozen of them
        // is a list to keep up to date; a lone "t" before a command is a negation in
        // every sentence anybody says.
        if let last = words.last, last == "t" || negations.contains(last) { return true }
        if words.count >= 2 {
            let pair = words[(words.count - 2)...].joined(separator: " ")
            if negationPairs.contains(pair) { return true }
        }
        return false
    }
}

/// Fires once per saying of a command, over a transcript that keeps growing.
///
/// The wake phrase learned all of this the hard way — see `WakeListenerState`, whose
/// shape this follows deliberately rather than inventing a second set of rules for the
/// same recogniser. The one difference is that this has six phrases rather than one, so
/// the cooldown is per command: "pause recording" and then "resume recording" two seconds
/// later is a real thing a person does, and must not be swallowed as a repeat.
public struct VoiceCommandListener: Equatable, Sendable {

    /// The shortest gap between two firings of the SAME command.
    public var cooldown: TimeInterval = 2.5

    /// How much of the tail of the transcript counts as "said just now".
    public var tailCharacters = 60

    /// Ignore everything until this moment. Shares the hush key with the wake phrase —
    /// one panic key that stops every ear at once, not one per feature.
    public private(set) var snoozedUntil: Date?

    private var lastFired: VoiceCommand?
    private var lastFiredAt: Date?
    /// Transcript length when it last fired, so growth past the match re-arms it without
    /// waiting for the recogniser to declare the utterance over — which, on device and
    /// mid-flow, it often does not.
    private var firedAtLength: Int?

    public init() {}

    public mutating func snooze(until: Date) { snoozedUntil = until }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return now < snoozedUntil
    }

    /// The recogniser started a fresh utterance, so nothing said before it is still being
    /// said now.
    public mutating func utteranceEnded() { firedAtLength = nil }

    /// - Parameter transcript: everything heard in the current utterance so far.
    /// - Returns: the command, exactly once per saying of it.
    public mutating func heard(_ transcript: String, now: Date) -> VoiceCommand? {
        let normalised = WakePhrase.normalise(transcript)
        guard let command = VoiceCommandVocabulary.match(normalised,
                                                         tailCharacters: tailCharacters) else {
            // Whatever was said has scrolled out of the tail; the next one starts clean.
            if let fired = firedAtLength, normalised.count > fired { firedAtLength = nil }
            return nil
        }
        guard !isSnoozed(at: now) else { return nil }
        if command == lastFired {
            if let fired = firedAtLength, normalised.count <= fired + tailCharacters { return nil }
            if let at = lastFiredAt, now.timeIntervalSince(at) < cooldown { return nil }
        }
        firedAtLength = normalised.count
        lastFired = command
        lastFiredAt = now
        return command
    }
}

/// Everything the gate needs to know, gathered by the caller in one go.
///
/// A struct rather than a pile of arguments because both routes — the model's tool call
/// and the on-device listener — have to hand over the *same* facts, and a parameter that
/// one of them forgets is a rule that silently applies to only half the app.
public struct VoiceCommandContext: Equatable, Sendable {

    /// The master switch. Off means every command here is ignored, both routes.
    public var commandsEnabled: Bool
    /// Whether recording can happen at all — microphone permission, chiefly. False is
    /// "this Mac will not let this app record", not "nothing is recording right now".
    public var recordingEnabled: Bool
    /// Why the *current capture mode* cannot start, if it cannot. Screen Recording off,
    /// camera denied, no camera plugged in. Nil when it can.
    public var recordingBlocked: String?

    public var isRecording: Bool
    public var isPaused: Bool

    /// Why the camera cannot be used, if it cannot.
    public var cameraBlocked: String?
    /// The bubble is up.
    public var isFaceVisible: Bool

    public init(commandsEnabled: Bool = true,
                recordingEnabled: Bool = true,
                recordingBlocked: String? = nil,
                isRecording: Bool = false,
                isPaused: Bool = false,
                cameraBlocked: String? = nil,
                isFaceVisible: Bool = false) {
        self.commandsEnabled = commandsEnabled
        self.recordingEnabled = recordingEnabled
        self.recordingBlocked = recordingBlocked
        self.isRecording = isRecording
        self.isPaused = isPaused
        self.cameraBlocked = cameraBlocked
        self.isFaceVisible = isFaceVisible
    }
}

/// What to do about a command that was heard.
public enum VoiceCommandDecision: Equatable, Sendable {
    /// Go ahead.
    case perform
    /// The app is already in that state. Nothing changes and nothing is wrong — say so
    /// and move on. Kept separate from `blocked` because the two read identically in a
    /// log and mean opposite things: one is the user repeating themselves, the other is
    /// the app refusing them.
    case redundant(String)
    /// Not allowed, and why — written to be read aloud.
    case blocked(String)

    public var isPerform: Bool { self == .perform }

    /// The sentence to say back. Nil when the command is about to run and the caller has
    /// something better to report.
    public var spoken: String? {
        switch self {
        case .perform:            return nil
        case .redundant(let why): return why
        case .blocked(let why):   return why
        }
    }

    /// One word for the log line, so a session's commands can be read back in order.
    public var logToken: String {
        switch self {
        case .perform:      return "performed"
        case .redundant:    return "ignored (already)"
        case .blocked:      return "ignored (blocked)"
        }
    }
}

/// The one place that decides whether a command may run.
///
/// Every rule here is "do nothing, and say why" rather than "do something surprising".
/// A voice command arrives from a recogniser that is sometimes wrong, so the failure it
/// has to be safe against is not the user changing their mind — it is the app acting on a
/// sentence that was never said.
public enum VoiceCommandGate {

    public static func decide(_ requested: VoiceCommand, in context: VoiceCommandContext) -> VoiceCommandDecision {
        let command = requested.resolved(in: context)
        guard context.commandsEnabled else {
            return .blocked("Recording commands are off — turn them on in Settings › Access.")
        }

        if command.isTransport {
            guard context.recordingEnabled else {
                return .blocked("Recording is not available — \(kMicrophoneFix)")
            }
        }

        switch command {
        case .startRecording:
            // A paused take has already been resolved to a resume by the time this runs;
            // see `VoiceCommand.resolved`. So this really is "start a second one".
            if context.isRecording { return .redundant("Already recording.") }
            if let why = context.recordingBlocked { return .blocked(why) }
            return .perform

        case .stopRecording:
            guard context.isRecording else { return .redundant("Nothing is being recorded.") }
            return .perform

        case .pauseRecording:
            guard context.isRecording else { return .redundant("Nothing is being recorded.") }
            guard !context.isPaused else { return .redundant("It's already paused.") }
            return .perform

        case .resumeRecording:
            guard context.isRecording else { return .redundant("Nothing is being recorded.") }
            guard context.isPaused else { return .redundant("The recording is already running.") }
            return .perform

        case .showFace:
            if let why = context.cameraBlocked { return .blocked(why) }
            guard !context.isFaceVisible else { return .redundant("Your camera is already showing.") }
            return .perform

        case .hideFace:
            // Deliberately not gated on the camera being usable. Hiding is the safe
            // direction, and refusing to take a face off screen because the permission
            // that put it there has since been revoked would be absurd.
            guard context.isFaceVisible else { return .redundant("The camera is already hidden.") }
            return .perform
        }
    }
}

/// Said whenever the microphone itself is the thing standing in the way. One string, so
/// the fix is described the same way wherever it comes up.
public let kMicrophoneFix = "the microphone is off for this app in System Settings › Privacy & Security › Microphone."
