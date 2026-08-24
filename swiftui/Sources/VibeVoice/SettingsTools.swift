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

    static func catalogue(_ s: AppSettings) -> [SettingChoice] {
        [
            SettingChoice(key: "voice", spoken: "the voice", values: kVoices),
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
            SettingChoice(key: "proactive", spoken: "proactive updates",
                          aliases: ["speaking first", "interrupting me"]),
            SettingChoice(key: "ambientMode", spoken: "ambient mode"),
            SettingChoice(key: "devMode", spoken: "dev mode", aliases: ["coding", "claude code"]),
            SettingChoice(key: "devNarrate", spoken: "narrating what it is coding",
                          aliases: ["narration", "progress updates"]),
            SettingChoice(key: "menuBarEnabled", spoken: "the menu bar icon", aliases: ["menu bar"]),
        ]
    }

    static var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "change_setting",
                summary: "Change a setting",
                description: "Change one of FlowState's own settings — the backdrop, the "
                           + "voice, the camera, the widget, dev mode, the wake phrase. Use "
                           + "whenever the user asks for the app itself to look or behave "
                           + "differently. Say what you changed in a few words; do not read "
                           + "the list of options back unless they got it wrong.",
                parameters: [
                    ToolParameter("setting", description: "What to change, in the user's own words.", required: true),
                    ToolParameter("value", description: "What to change it to, or on/off for a switch.", required: true),
                ]),
            ToolSpec(
                name: "list_settings",
                summary: "What can be changed",
                description: "The settings that can be changed by voice, and their current "
                           + "values. Use when the user asks what you can change, or what "
                           + "the options are for something."),
            ToolSpec(
                name: "open_settings",
                summary: "Open Settings",
                description: "Open the settings window, optionally at one of its tabs: "
                           + "general, look, screen, access, dev, data. Use when the user "
                           + "asks to see a setting rather than change it — the wake-word "
                           + "tuning display is on the access tab.",
                parameters: [
                    ToolParameter("tab", description: "general, look, screen, access, dev or data.")
                ]),
        ]
    }
}
