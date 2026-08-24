import Foundation
import VibeVoiceCore

/// Every setting worth changing out loud, and what to do when one is.
///
/// The pane has six tabs and twenty-six sections. That is a reasonable amount of pane and
/// an unreasonable amount of hunting, and it is a strange thing to make somebody hunt
/// through in an app whose entire premise is that saying what you want is faster. So the
/// settings are a tool now.
///
/// Not every setting: the API key is not here, nor anything under Memory & privacy.
/// A misheard sentence should not be able to turn off the thing that limits what is kept,
/// and "change my privacy settings" is a sentence worth walking to a checkbox for.
@MainActor
enum SettingsTools {

    /// Fixed: every list here comes from a `CaseIterable` enum, so it does not depend
    /// on what any setting currently is.
    static func catalogue() -> [SettingChoice] {
        [
            SettingChoice(key: "voice", spoken: "the voice", values: kVoices,
                          aliases: ["accent", "how it sounds"]),
            SettingChoice(key: "backdrop", spoken: "the backdrop",
                          values: Backdrop.allCases.map { $0.label.lowercased() },
                          aliases: ["background", "wallpaper", "scene"]),
            SettingChoice(key: "motionStyle", spoken: "the moving background",
                          values: MotionStyle.allCases.map { $0.label.lowercased() },
                          aliases: ["motion", "animation"]),
            SettingChoice(key: "appearance", spoken: "the appearance",
                          values: ["dark", "light", "system"],
                          aliases: ["theme", "dark mode"]),
            SettingChoice(key: "captureMode", spoken: "what recordings capture",
                          values: CaptureMode.allCases.map { $0.label.lowercased() },
                          aliases: ["recording mode", "capture"]),
            SettingChoice(key: "cameraSize", spoken: "the camera size",
                          values: CameraSize.allCases.map { $0.label.lowercased() }),
            SettingChoice(key: "cameraShape", spoken: "the camera shape",
                          values: CameraShape.allCases.map { $0.label.lowercased() }),
            SettingChoice(key: "qualityMode", spoken: "the cost mode",
                          values: ["budget", "quality"], aliases: ["quality"]),
            SettingChoice(key: "hudEnabled", spoken: "the floating widget", aliases: ["widget", "overlay"]),
            SettingChoice(key: "cameraBubble", spoken: "the camera bubble", aliases: ["camera", "my face"]),
            SettingChoice(key: "continuousScreen", spoken: "watching my screen",
                          aliases: ["screen watching", "continuous screen"]),
            SettingChoice(key: "wakeWord", spoken: "the wake phrase", aliases: ["hey flow", "wake word"]),
            SettingChoice(key: "clapToWake", spoken: "clap to wake", aliases: ["clapping", "claps"]),
            SettingChoice(key: "voiceCommands", spoken: "the recording commands",
                          aliases: ["voice commands", "spoken commands", "hands free"]),
            SettingChoice(key: "proactive", spoken: "proactive updates",
                          aliases: ["speaking first", "interrupting me"]),
            SettingChoice(key: "ambientMode", spoken: "ambient mode"),
            SettingChoice(key: "devMode", spoken: "dev mode", aliases: ["coding", "claude code"]),
            SettingChoice(key: "devNarrate", spoken: "narrating what it is coding",
                          aliases: ["narration", "progress updates"]),
            SettingChoice(key: "menuBarEnabled", spoken: "the menu bar icon", aliases: ["menu bar"]),

            // Numbers. Every one of these is a slider somewhere, and every one of them is
            // the kind of thing you want to adjust while looking at the result rather
            // than while looking for the slider.
            SettingChoice(key: "speed", spoken: "how fast it talks",
                          aliases: ["speaking speed", "talking speed", "speech rate"],
                          range: 0.5...1.5, unit: nil),
            SettingChoice(key: "screenInterval", spoken: "how often it looks at the screen",
                          aliases: ["screen interval", "watch interval"],
                          range: 2...30, unit: "seconds"),
            SettingChoice(key: "motionIntensity", spoken: "how much the background moves",
                          aliases: ["motion intensity", "movement"],
                          range: 0...1, asPercent: true),
            SettingChoice(key: "clapSensitivity", spoken: "how easily clapping wakes it",
                          aliases: ["clap sensitivity"],
                          range: 0...1, asPercent: true),
            SettingChoice(key: "vadThreshold", spoken: "how sensitive its hearing is",
                          aliases: ["voice detection", "mic sensitivity"],
                          range: 0...1, asPercent: true),
            SettingChoice(key: "silenceDurationMs", spoken: "how long it waits before replying",
                          aliases: ["silence duration", "pause before replying"],
                          range: 200...1500, unit: "milliseconds"),
            SettingChoice(key: "maxScreenFrames", spoken: "how many screenshots it remembers",
                          aliases: ["screen frames"],
                          range: 0...10, unit: nil),
            SettingChoice(key: "screenshotSize", spoken: "how detailed the screenshots are",
                          aliases: ["screenshot size", "screenshot detail"],
                          range: 640...2560, unit: "pixels"),
            SettingChoice(key: "photoRotateSeconds", spoken: "how often the photo changes",
                          aliases: ["photo rotation"],
                          range: 0...900, unit: "seconds"),
        ]
    }

    /// What each voice sounds like.
    ///
    /// Because "a guy's voice" is how somebody actually asks, and `alloy`, `ash`, `verse`
    /// tells the model nothing about which of those to pick. It guessed "casual guy",
    /// which is not a value, and had to be corrected. A word each is enough.
    static let voiceCharacter: [String: String] = [
        "alloy": "neutral, even",
        "ash": "male, warm",
        "ballad": "male, soft and lilting",
        "cedar": "male, low and calm",
        "coral": "female, bright",
        "echo": "male, flat and clear",
        "marin": "female, warm",
        "sage": "female, measured",
        "shimmer": "female, light",
        "verse": "male, expressive",
    ]

    /// The whole catalogue, spelled out for the model.
    ///
    /// Long, and worth it: it is sent once when the session opens, and the alternative is
    /// a guess per request. Values are listed exactly as `change_setting` accepts them.
    static func briefing() -> String {
        catalogue().map { c -> String in
            if c.isNumber, let r = c.range {
                let lo = SettingCommand.say(r.lowerBound, c)
                let hi = SettingCommand.say(r.upperBound, c)
                return "\(c.key) (\(c.spoken)): a number from \(lo) to \(hi), or "
                     + "\"a bit more\" / \"a bit less\""
            }
            if c.values.isEmpty { return "\(c.key) (\(c.spoken)): on or off" }
            if c.key == "voice" {
                let described = c.values.map { v in
                    voiceCharacter[v].map { "\(v) — \($0)" } ?? v
                }
                return "voice (the voice): \(described.joined(separator: "; "))"
            }
            return "\(c.key) (\(c.spoken)): \(c.values.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    static var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "change_setting",
                summary: "Change a setting",
                description: "Change one of FlowState's own settings. Use whenever the user "
                           + "asks for the app itself to look or behave differently. "
                           + "ALWAYS pass a value from the list below — never invent one, and "
                           + "never ask the user which option they want when what they said "
                           + "clearly points at one of these. If they ask for \"a man's voice\" "
                           + "or \"something calmer\", pick the closest listed value and say "
                           + "which you picked. Say what you changed in a few words.\n\n"
                           + briefing(),
                parameters: [
                    ToolParameter("setting", description: "The setting key, from the list.",
                                  required: true,
                                  allowed: catalogue().map(\.key)),
                    ToolParameter("value", description: "One of that setting's listed values, "
                                                     + "or a number, or on/off.", required: true),
                ]),
            ToolSpec(
                name: "open_settings",
                summary: "Open Settings",
                description: "Open the settings window, optionally at one of its tabs. The "
                           + "wake-word tuning display is on the access tab.",
                parameters: [
                    ToolParameter("tab", description: "Which tab to open.",
                                  allowed: SettingsTab.allCases.map(\.rawValue))
                ]),
        ]
    }
}
