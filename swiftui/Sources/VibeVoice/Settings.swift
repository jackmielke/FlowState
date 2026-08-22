import Foundation
import Combine
import CoreGraphics
import VibeVoiceCore

let kVoices = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"]
let kModels = ["gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-realtime-2", "gpt-realtime-1.5", "gpt-realtime", "gpt-realtime-mini"]

let kDefaultPrompt = """
You are Flow, a warm and quick voice companion living on this Mac. \
Keep replies short and conversational — a sentence or two unless asked for more. \
When you are shown a screenshot, describe what actually matters on it, concretely, \
and never pretend to see something you cannot.
"""

/// Prompts shipped by earlier builds, under earlier names.
///
/// The personality prompt is stored in the user's settings, so renaming the app cannot
/// reach a prompt already on disk — it would keep introducing itself as Vibe or Vantage
/// forever. Any of these, untouched, is silently upgraded to the current default; a
/// prompt the user has actually edited is left completely alone.
let kSupersededPrompts: [String] = [
    kDefaultPrompt
        .replacingOccurrences(of: "You are Flow,", with: "You are Vibe,"),
    kDefaultPrompt
        .replacingOccurrences(of: "You are Flow,", with: "You are FlowState,"),
    kDefaultPrompt
        .replacingOccurrences(of: "You are Flow,", with: "You are Vantage,"),
]

struct AppSettings: Codable, Equatable {
    var voice: String = "marin"
    var model: String = "gpt-realtime-2.1"
    var systemPrompt: String = kDefaultPrompt
    var speed: Double = 1.0
    var continuousScreen: Bool = false
    var screenInterval: Double = 5.0      // 2...30 s
    var vadThreshold: Double = 0.5        // 0...1
    var silenceDurationMs: Double = 500   // 200...1500
    var transcribeUser: Bool = true

    /// The microphone gate, remembered between launches.
    ///
    /// Persisted because a mute you have to re-apply every launch is not a mute — the
    /// case for it is "this Mac is in a room where I do not want an open microphone",
    /// and that is a fact about the room, not about this session. The cost of persisting
    /// it is a launch where the app hears nothing and the user has forgotten why, which
    /// is why muted state is carried loudly rather than quietly: the orb changes, the
    /// widget shows a slashed mic, and the status line says Muted rather than Live.
    var micMuted: Bool = false

    /// Dev Mode — lets the model dispatch coding tasks to headless Claude Code.
    /// Off by default: it edits files with `--permission-mode acceptEdits`, so a
    /// misheard sentence can change your code.
    var devMode: Bool = false
    var devRepo: String = "~/dev/vibe-voice"

    /// How much Claude Code is allowed to do without asking.
    ///
    /// `acceptEdits` auto-approves file edits only — MCP tools (Notion, Slack) and shell
    /// commands still prompt, and in headless mode nobody can answer, so the task stalls.
    /// `bypassPermissions` approves everything, which is what makes connectors usable by
    /// voice, and also means a misheard sentence can run anything.
    var devPermissionMode: String = "acceptEdits"

    /// Native tools the user has switched OFF. Stored as the exceptions rather than the
    /// enabled list, so a tool added in a later build is on by default instead of
    /// silently missing for everyone who already has a settings file.
    var disabledTools: [String] = []

    /// Speak progress aloud while Claude Code works, instead of going quiet until it
    /// finishes. Steps are always filed silently so the model can answer "what are you
    /// doing?" — this only controls whether it volunteers updates unprompted.
    var devNarrate: Bool = true
    /// Seconds between spoken updates. Each one is a real spoken turn, so this is a
    /// direct cost dial.
    var devNarrateInterval: Double = 25
    /// Hard ceiling on spoken updates per task, so a long run cannot narrate forever.
    var devNarrateMax: Int = 8

    /// Which display the assistant looks at. `0` — the sentinel, since no real display
    /// has id 0 — means "whichever display FlowState is on right now", which is the
    /// behaviour every build before this one had.
    ///
    /// Persisted, but never trusted on its own: CoreGraphics display ids do not survive
    /// an unplug or a reboot, so `AppState` re-resolves this against the live display
    /// list and falls back to the active display if it no longer matches anything.
    var screenDisplayID: UInt32 = DisplayOption.followsActiveID

    /// How many screen frames stay in context. Older ones are deleted so their image
    /// tokens stop being re-billed every turn. 0 = keep everything (expensive).
    var maxScreenFrames: Int = 3
    /// Long edge of a screenshot in pixels. Fewer pixels = fewer image tokens.
    var screenshotSize: Int = 1280

    var qualityMode: QualityMode = .quality

    /// Dark / light / follow-the-system. Persisted like everything else here, so the
    /// choice is restored on launch.
    var appearance: AppearanceMode = .system

    /// The scene behind the orb. Midnight and Paper follow the existing theme; the place
    /// presets and a custom photo are painted by `BackdropView`.
    var backdrop: Backdrop = .midnight
    var backdropImagePath: String = ""
    /// "auto" follows the local clock; otherwise a pinned Daylight raw value.
    var daylightMode: String = "auto"
    /// Seconds between photos when the backdrop points at a folder. 0 = never rotate.
    var photoRotateSeconds: Double = 120

    /// Which moving backdrop `Backdrop.motion` shows.
    var motionStyle: MotionStyle = .fluid
    /// 0…1 — how much the motion moves. Amplitude and contrast only: nothing here
    /// changes the speed, because a backdrop you notice speeding up is a backdrop you
    /// start watching instead of the person you are talking to.
    var motionIntensity: Double = 0.6
    /// Prefer a video loop from the Motion folder over the shader, when one is there.
    /// On by default — someone who went to the trouble of installing a loop meant it —
    /// and the switch is how you get back to the drawn version without deleting the file.
    var motionAssets: Bool = true
    /// Fade the chrome away when nothing has happened for a while, leaving the scene.
    var ambientMode: Bool = true

    /// Show Flow in the menu bar, so it is reachable without hunting for its window.
    var menuBarEnabled: Bool = true
    /// Summon hotkey. Empty string = off.
    var summonHotkey: String = "cmdShiftSpace"

    /// Commit what each task changed, on the current branch, when it finishes.
    ///
    /// Without this Dev Mode edits the working tree and stops, so a session's work is
    /// invisible to anyone but whoever is sitting at this Mac.
    var devAutoCommit: Bool = true
    /// And push it. This is the only way work reaches a Claude Code running in the cloud,
    /// which can see the remote and nothing else.
    var devAutoPush: Bool = true

    /// The floating widget: a small always-on-top panel that follows you between apps
    /// and Spaces, so FlowState is reachable without its window in front.
    var hudEnabled: Bool = false
    var hudStyle: HUDStyle = .pill

    /// Set once the Dev Mode offer has been declined. Permanent on purpose.
    var devNudgeDismissed: Bool = false

    /// What FlowState is allowed to remember, and for how long. See `TranscriptPrivacy` —
    /// every switch in it is honoured in one place, `ConversationLog.append`.
    var privacy: TranscriptPrivacy = TranscriptPrivacy()

    /// When a running conversation gets summarised, and where the summary goes.
    var summaries: SummaryPolicy = SummaryPolicy()

    // MARK: - Capture

    /// What the record button captures: audio, audio + screen, audio + camera, or both.
    ///
    /// Audio-only by default, and that is not merely a conservative default — it is the
    /// behaviour of every build before video existed, written to the same folder with the
    /// same name and the same extension. Someone who never opens this setting cannot tell
    /// that video was added.
    var captureMode: CaptureMode = .audioOnly

    /// How hard the encoder is allowed to work and how much disk it may spend. Ignored
    /// entirely when `captureMode` is `.audioOnly` — a WAV has no profile.
    var capturePerformance: PerformanceProfile = .balanced

    /// `AVCaptureDevice.uniqueID` of the camera to record. Empty means "whichever one
    /// macOS would pick", which is what a laptop with one built-in camera wants and what
    /// a Mac whose external camera is currently unplugged has to fall back to anyway.
    ///
    /// Unlike a display id, a camera's unique id survives unplugging and rebooting, so
    /// this one is safe to persist — it is still re-resolved against the live list before
    /// every recording, because "safe to persist" is not "guaranteed to be attached".
    var cameraDeviceID: String = ""

    /// What to open on launch.
    ///
    /// OFF — the default — means every launch starts a new conversation, and the last
    /// one is one click away in the switcher with its history intact. That is the
    /// honest default for a voice assistant: you sit down and start talking, and what
    /// you say now is not silently appended to a conversation from Tuesday. Nothing is
    /// lost either way; this only decides which conversation is in front of you.
    ///
    /// ON reopens the most recent non-empty conversation instead, for people who treat
    /// it as one long running thread.
    var resumeLastSession: Bool = false

    enum CodingKeys: String, CodingKey {
        case voice, model, systemPrompt, speed, continuousScreen, screenInterval
        case vadThreshold, silenceDurationMs, transcribeUser, micMuted, devMode, devRepo
        case maxScreenFrames, screenshotSize, qualityMode, appearance, screenDisplayID
        case devNarrate, devNarrateInterval, devNarrateMax, devPermissionMode
        case disabledTools, backdrop, backdropImagePath, daylightMode, ambientMode
        case photoRotateSeconds, menuBarEnabled, summonHotkey, devNudgeDismissed
        case motionStyle, motionIntensity, motionAssets
        case devAutoCommit, devAutoPush, hudEnabled, hudStyle
        case privacy, summaries, resumeLastSession
        case captureMode, capturePerformance, cameraDeviceID
    }
}

extension AppSettings {
    /// Hand-rolled so a missing key falls back to its default instead of throwing.
    ///
    /// The synthesised decoder does *not* use property defaults for absent keys, and
    /// `SettingsStore` decodes with `try?` — so adding a field to this struct would
    /// silently reset every existing user's whole settings file on first launch.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        // Missing key OR a value of the wrong shape both fall back, so one bad field
        // can never cost the user the other fourteen.
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens decodeIfPresent's own optional, so nil here already
            // covers both "key absent" and "value was the wrong shape".
            guard let found = try? c.decodeIfPresent(T.self, forKey: k) else { return fallback }
            return found
        }
        voice             = v(.voice, d.voice)
        model             = v(.model, d.model)
        systemPrompt      = v(.systemPrompt, d.systemPrompt)
        speed             = v(.speed, d.speed)
        continuousScreen  = v(.continuousScreen, d.continuousScreen)
        screenInterval    = v(.screenInterval, d.screenInterval)
        screenDisplayID   = v(.screenDisplayID, d.screenDisplayID)
        vadThreshold      = v(.vadThreshold, d.vadThreshold)
        silenceDurationMs = v(.silenceDurationMs, d.silenceDurationMs)
        transcribeUser    = v(.transcribeUser, d.transcribeUser)
        micMuted          = v(.micMuted, d.micMuted)
        devMode           = v(.devMode, d.devMode)
        devRepo           = v(.devRepo, d.devRepo)
        devNarrate        = v(.devNarrate, d.devNarrate)
        devPermissionMode = v(.devPermissionMode, d.devPermissionMode)
        disabledTools     = v(.disabledTools, d.disabledTools)
        devNarrateInterval = v(.devNarrateInterval, d.devNarrateInterval)
        devNarrateMax     = v(.devNarrateMax, d.devNarrateMax)
        maxScreenFrames   = v(.maxScreenFrames, d.maxScreenFrames)
        screenshotSize    = v(.screenshotSize, d.screenshotSize)
        qualityMode       = v(.qualityMode, d.qualityMode)
        appearance        = v(.appearance, d.appearance)
        backdrop          = v(.backdrop, d.backdrop)
        backdropImagePath = v(.backdropImagePath, d.backdropImagePath)
        daylightMode      = v(.daylightMode, d.daylightMode)
        photoRotateSeconds = v(.photoRotateSeconds, d.photoRotateSeconds)
        motionStyle       = v(.motionStyle, d.motionStyle)
        motionIntensity   = v(.motionIntensity, d.motionIntensity)
        motionAssets      = v(.motionAssets, d.motionAssets)
        menuBarEnabled    = v(.menuBarEnabled, d.menuBarEnabled)
        summonHotkey      = v(.summonHotkey, d.summonHotkey)
        devNudgeDismissed = v(.devNudgeDismissed, d.devNudgeDismissed)
        devAutoCommit     = v(.devAutoCommit, d.devAutoCommit)
        devAutoPush       = v(.devAutoPush, d.devAutoPush)
        hudEnabled        = v(.hudEnabled, d.hudEnabled)
        hudStyle          = v(.hudStyle, d.hudStyle)
        ambientMode       = v(.ambientMode, d.ambientMode)
        privacy           = v(.privacy, d.privacy)
        summaries         = v(.summaries, d.summaries)
        resumeLastSession = v(.resumeLastSession, d.resumeLastSession)
        captureMode       = v(.captureMode, d.captureMode)
        capturePerformance = v(.capturePerformance, d.capturePerformance)
        cameraDeviceID    = v(.cameraDeviceID, d.cameraDeviceID)
    }
}

enum QualityMode: String, Codable, CaseIterable {
    case budget, quality

    var label: String { self == .budget ? "Budget" : "Quality" }

    var blurb: String {
        self == .budget
            ? "Mini model, smaller frames, tighter history. Roughly a third the cost."
            : "Full model, full-size frames. Best listening and vision."
    }

    var symbol: String { self == .budget ? "leaf.fill" : "sparkles" }

    /// There are only two, so the one-click header control just flips between them.
    var next: QualityMode { self == .budget ? .quality : .budget }

    /// Applied on top of whatever else is set, so switching modes is one control.
    func apply(to s: inout AppSettings) {
        s.qualityMode = self
        switch self {
        case .budget:
            s.model = "gpt-realtime-2.1-mini"
            s.screenshotSize = 960
            s.maxScreenFrames = 2
            s.screenInterval = max(s.screenInterval, 10)
            // Transcription STAYS ON in Budget mode.
            //
            // It was switched off here to save the separate per-utterance transcription
            // charge, which is a small fraction of what the audio itself costs — and the
            // price of it was half the transcript. The user's own words simply stopped
            // appearing, so the panel showed the assistant talking to nobody and read as
            // broken. Nobody would trade their own side of a conversation for a few
            // percent.
            s.transcribeUser = true
            // With no transcription there are no user words to record — the audio
            // metadata still lands, so a session is not silent in the record, but a
            // summary built from one side only is worth less. Left to the user rather
            // than forced: they may well want the assistant's half kept anyway.
        case .quality:
            s.model = "gpt-realtime-2.1"
            s.screenshotSize = 1280
            s.maxScreenFrames = 3
            s.transcribeUser = true
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    /// Writes only on a REAL change.
    ///
    /// Without the equality guard this is a loaded gun. SwiftUI writes to bindings during
    /// view evaluation, so a binding whose setter assigns here — MenuBarExtra's
    /// `isInserted` did exactly this — starts a loop: assign, save, @Published fires, body
    /// re-evaluates, assign again. It pegged a core at 99% and wrote settings.json
    /// continuously until the app stopped responding. AppSettings is Equatable precisely
    /// so this comparison is cheap and total.
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private static var fileURL: URL {
        // One root for everything FlowState keeps, so `VIBEVOICE_HOME` moves the settings
        // with the transcripts instead of half of each.
        let base = ConversationStore.root
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           var s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            // Carry an untouched older prompt forward under the new name.
            let migrated = kSupersededPrompts.contains(s.systemPrompt)
            if migrated { s.systemPrompt = kDefaultPrompt }
            settings = s
            // Property observers do NOT fire for assignments inside init, so didSet never
            // runs here and the migration would live only in memory — correct behaviour,
            // but the file on disk would still say Flow until some unrelated setting
            // happened to change. Write it now.
            if migrated { save() }
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(settings) { try? d.write(to: Self.fileURL, options: .atomic) }
    }
}
