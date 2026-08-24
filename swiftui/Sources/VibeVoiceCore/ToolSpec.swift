import Foundation

/// One parameter of a tool the realtime model can call.
public struct ToolParameter: Equatable {
    public let name: String
    public let type: String          // JSON Schema type: "string", "number", "boolean"
    public let description: String
    public let required: Bool
    /// The exact values this will accept.
    ///
    /// Worth the schema space wherever the list is closed. Without it the model invents
    /// a plausible value, gets refused, and reads the real list back out of the error —
    /// which is a wasted round trip that sounds, from the other side, like an assistant
    /// that does not know its own app. Observed: it tried "casual guy" for a voice and
    /// "lighter" for a backdrop, both times learning the options only after failing.
    public let allowed: [String]

    public init(_ name: String,
                type: String = "string",
                description: String,
                required: Bool = false,
                allowed: [String] = []) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.allowed = allowed
    }
}

/// A tool FlowState answers itself, without going near Claude Code.
///
/// The distinction that matters is latency, and it changes the architecture rather than
/// just the speed. Claude Code takes minutes, so a dispatch has to return immediately
/// and report back later ("on it… okay, done"). A native tool answers in milliseconds,
/// so the model can simply speak the result in the same turn. Anything that can be
/// answered in one call belongs here; anything needing an agent belongs in Dev Mode.
public struct ToolSpec: Equatable, Identifiable {

    /// Read-only tools can fire on whatever the model thinks it heard. Anything that
    /// sends, writes or deletes has to be confirmed out loud first — a misheard sentence
    /// must never be able to message somebody.
    public enum Effect: Equatable {
        case readOnly
        case writes(confirmation: String)
    }

    public let name: String
    public let summary: String          // shown in Settings
    public let description: String      // shown to the model
    public let parameters: [ToolParameter]
    public let effect: Effect

    public var id: String { name }

    public init(name: String,
                summary: String,
                description: String,
                parameters: [ToolParameter] = [],
                effect: Effect = .readOnly) {
        self.name = name
        self.summary = summary
        self.description = description
        self.parameters = parameters
        self.effect = effect
    }

    public var isReadOnly: Bool { effect == .readOnly }

    /// The realtime API's function-tool shape (API-CONTRACT §"Session config").
    public func realtimeSchema() -> [String: Any] {
        var props: [String: Any] = [:]
        for p in parameters {
            var schema: [String: Any] = ["type": p.type, "description": p.description]
            if !p.allowed.isEmpty { schema["enum"] = p.allowed }
            props[p.name] = schema
        }
        var described = description
        if case .writes(let confirmation) = effect {
            // Belt and braces: the guard is enforced in code, but telling the model as
            // well means it asks naturally instead of being refused after the fact.
            described += " IMPORTANT: this takes a real action. Before calling it, say "
                       + "\"\(confirmation)\" and wait for the user to agree."
        }
        return [
            "type": "function",
            "name": name,
            "description": described,
            "parameters": [
                "type": "object",
                "properties": props,
                "required": parameters.filter(\.required).map(\.name),
            ],
        ]
    }
}

/// Which native tools are switched on, and what to hand the model.
public final class ToolRegistry {

    public private(set) var specs: [ToolSpec]
    private var disabled: Set<String>

    public init(specs: [ToolSpec] = [], disabled: Set<String> = []) {
        self.specs = specs
        self.disabled = disabled
    }

    public func replaceSpecs(_ s: [ToolSpec]) { specs = s }

    public var enabled: [ToolSpec] { specs.filter { !disabled.contains($0.name) } }

    public func isEnabled(_ name: String) -> Bool { !disabled.contains(name) }

    public func setEnabled(_ on: Bool, for name: String) {
        if on { disabled.remove(name) } else { disabled.insert(name) }
    }

    public var disabledNames: [String] { disabled.sorted() }

    public func spec(_ name: String) -> ToolSpec? { specs.first { $0.name == name } }

    /// The `tools` array for `session.update`, native tools plus anything else (Dev Mode)
    /// the caller wants to append.
    public func realtimeTools(extra: [[String: Any]] = []) -> [[String: Any]] {
        enabled.map { $0.realtimeSchema() } + extra
    }
}
