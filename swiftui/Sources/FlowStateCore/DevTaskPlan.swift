import Foundation

/// How one dispatched Claude Code run should be launched.
///
/// Every dispatch used to launch the same way: whatever model the CLI defaults to, full
/// effort, every MCP server on this Mac connected before the first token. Measured on a
/// trivial prompt, that costs about three seconds of pure startup — the MCP handshake —
/// before Claude Code has read a single file, and it is paid again on every follow-up.
///
/// The three seconds are spent for nothing when the task is "tighten that padding". So a
/// plan is chosen from the words of the instruction:
///
/// - a **question** about the code ("where is the orb drawn?") gets a small model, low
///   effort and read-only tools, because it is a lookup, not an edit;
/// - a **small** mechanical change (typo, colour, wording) gets low effort;
/// - the **default** is what the app always did, minus the MCP wait;
/// - **large** work — refactors, investigations, anything asking *why* — gets the big
///   model and high effort, because the slow part there is thinking, not starting.
///
/// MCP servers are connected only when the instruction actually names something that
/// lives behind one. That is the single biggest win and also the riskiest guess, which is
/// why `Settings.devFastStart` can turn it off wholesale.
public struct DevTaskPlan: Equatable, Sendable {

    /// What kind of job the words describe. Named for the shape of the work, not for a
    /// model, so the mapping below can change without the classifier meaning anything
    /// different.
    public enum Shape: String, Sendable, Equatable {
        /// A question about the repo. Nothing is meant to change on disk.
        case question
        /// A small, local, mechanical edit.
        case small
        /// Ordinary feature work — the default when nothing says otherwise.
        case medium
        /// Design, investigation, or a change that spans the codebase.
        case large
    }

    public var shape: Shape
    /// `--model` alias.
    public var model: String
    /// `--effort`, or nil to leave the session default alone.
    public var effort: String?
    /// `--fallback-model`, so an overloaded big model degrades instead of stalling a
    /// conversation that is waiting out loud.
    public var fallbackModel: String?
    /// When false the run is launched with `--strict-mcp-config` and no config, which
    /// skips connecting every MCP server on this Mac.
    public var loadsMCP: Bool
    /// `--tools`, or nil for the full built-in set. Only set for questions, where
    /// withholding the edit tools is both faster and safer.
    public var tools: [String]?

    public init(shape: Shape,
                model: String,
                effort: String? = nil,
                fallbackModel: String? = nil,
                loadsMCP: Bool = false,
                tools: [String]? = nil) {
        self.shape = shape
        self.model = model
        self.effort = effort
        self.fallbackModel = fallbackModel
        self.loadsMCP = loadsMCP
        self.tools = tools
    }

    /// A one-line label for the transcript and the log: "sonnet · low · no mcp".
    public var summary: String {
        var parts = [model]
        if let effort { parts.append(effort) }
        parts.append(loadsMCP ? "mcp" : "no mcp")
        return parts.joined(separator: " · ")
    }

    // MARK: - Choosing

    /// Words that mean the answer is going to take real thinking, whatever else is in
    /// the sentence. Matched anywhere, because "and while you're there, work out why the
    /// orb stutters" is a large task wearing a small task's clothes.
    private static let heavy = [
        "refactor", "rearchitect", "architecture", "redesign", "rewrite", "migrate",
        "investigate", "why is", "why does", "why isn't", "why doesn't", "root cause",
        "figure out", "work out why", "track down", "debug", "diagnose",
        "across the codebase", "across the app", "whole app", "everywhere",
        "test suite", "audit", "optimise", "optimize", "performance", "race condition",
        "memory leak", "deadlock", "plan ", "design a", "design the",
    ]

    /// Cosmetic or mechanical edits: one file, one obvious change, no judgement.
    private static let mechanical = [
        "typo", "spelling", "rename", "comment", "padding", "spacing", "margin",
        "colour", "color", "font size", "wording", "copy", "label", "placeholder",
        "capitalise", "capitalize", "bump", "whitespace", "indent", "tooltip",
        "button text", "title to", "text to",
    ]

    /// Openers that mean a question rather than an instruction.
    private static let questioning = [
        "what ", "what's", "where ", "where's", "which ", "who ", "when does",
        "how does", "how do", "how many", "how much", "is there", "are there",
        "does the", "do we", "did we", "find ", "show me", "list ", "explain ",
        "tell me about", "look at", "check whether", "check if", "remind me",
    ]

    /// Things that only exist behind an MCP server. If none of these are named, the
    /// servers are not worth the wait.
    private static let connectors = [
        "notion", "slack", "linear", "jira", "figma", "supabase", "granola",
        "supermemory", "gmail", "google doc", "google sheet", "calendar",
        "sentry", "vercel", "quickbooks", "stripe", "mcp", "connector",
    ]

    /// Reads the instruction and picks a launch plan.
    ///
    /// - Parameter fastStart: the user's `devFastStart` switch. False means "connect the
    ///   MCP servers whatever the words say" — the escape hatch for a repo whose tasks
    ///   routinely need a connector this classifier cannot see coming.
    public static func plan(for instruction: String, fastStart: Bool = true) -> DevTaskPlan {
        let text = instruction.lowercased()
        let mentionsConnector = connectors.contains { text.contains($0) }
        let mcp = !fastStart || mentionsConnector

        if heavy.contains(where: { text.contains($0) }) {
            return DevTaskPlan(shape: .large, model: "opus", effort: "high",
                               fallbackModel: "sonnet", loadsMCP: mcp)
        }

        // A question has to look like one AND not ask for a change: "show me where the
        // padding is set" is a question; "show me a tighter layout" is not.
        let asks = questioning.contains { text.hasPrefix($0) || text.contains(" " + $0) }
        if asks && !changesSomething(text) {
            return DevTaskPlan(shape: .question, model: "sonnet", effort: "low",
                               loadsMCP: mcp, tools: ["Read", "Grep", "Glob"])
        }

        // Short, single-clause and mechanical. Both guards matter: "rename the button,
        // then pull the whole settings pane apart" contains "rename", is one sentence,
        // and is not a small job.
        if instruction.count <= 120, !isCompound(text),
           mechanical.contains(where: { text.contains($0) }) {
            return DevTaskPlan(shape: .small, model: "sonnet", effort: "low", loadsMCP: mcp)
        }

        return DevTaskPlan(shape: .medium, model: "sonnet", loadsMCP: mcp)
    }

    /// Two jobs wearing one sentence. Spoken instructions run on: the second half is
    /// where the real work usually is, and it is never the mechanical half.
    private static func isCompound(_ text: String) -> Bool {
        let joins = [" then ", ", then", " after that", " as well as", " and also ", " and make "]
        if joins.contains(where: { text.contains($0) }) { return true }
        // More than one sentence is more than one job.
        return text.split(whereSeparator: { ".!?".contains($0) })
                   .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count > 1
    }

    /// Verbs that turn a question-shaped sentence back into a job of work.
    private static func changesSomething(_ text: String) -> Bool {
        let verbs = ["fix", "change", "add", "remove", "delete", "make it", "make the",
                     "update", "tighten", "move", "rename", "write", "build", "implement",
                     "refactor", "replace", "set the", "turn the"]
        return verbs.contains { text.contains($0) }
    }
}
