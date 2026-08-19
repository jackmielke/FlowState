import Foundation
import Combine

let kVoices = ["alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse", "marin", "cedar"]
let kModels = ["gpt-realtime-2.1", "gpt-realtime-2.1-mini", "gpt-realtime-2", "gpt-realtime-1.5", "gpt-realtime", "gpt-realtime-mini"]

let kDefaultPrompt = """
You are Vibe, a warm and quick voice companion living on this Mac. \
Keep replies short and conversational — a sentence or two unless asked for more. \
When you are shown a screenshot, describe what actually matters on it, concretely, \
and never pretend to see something you cannot.
"""

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
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings { didSet { save() } }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("settings.json")
    }

    init() {
        if let d = try? Data(contentsOf: Self.fileURL),
           let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
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
