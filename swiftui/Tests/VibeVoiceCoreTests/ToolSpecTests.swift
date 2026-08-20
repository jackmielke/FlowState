import XCTest
@testable import VibeVoiceCore

final class ToolSpecTests: XCTestCase {

    private let readTool = ToolSpec(
        name: "read_clipboard",
        summary: "Clipboard",
        description: "Read what is on the clipboard.")

    private let writeTool = ToolSpec(
        name: "send_message",
        summary: "Send a message",
        description: "Send an iMessage.",
        parameters: [ToolParameter("to", description: "Recipient", required: true),
                     ToolParameter("body", description: "Message text", required: true)],
        effect: .writes(confirmation: "Want me to send that?"))

    func test_schemaMatchesTheRealtimeFunctionShape() {
        let s = writeTool.realtimeSchema()
        XCTAssertEqual(s["type"] as? String, "function")
        XCTAssertEqual(s["name"] as? String, "send_message")

        let params = s["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertEqual((params?["required"] as? [String])?.sorted(), ["body", "to"])

        let props = params?["properties"] as? [String: Any]
        let to = props?["to"] as? [String: Any]
        XCTAssertEqual(to?["type"] as? String, "string")
        XCTAssertEqual(to?["description"] as? String, "Recipient")
    }

    func test_optionalParametersAreNotRequired() {
        let t = ToolSpec(name: "x", summary: "x", description: "x",
                         parameters: [ToolParameter("a", description: "a", required: true),
                                      ToolParameter("b", description: "b")])
        let required = ((t.realtimeSchema()["parameters"] as? [String: Any])?["required"] as? [String])
        XCTAssertEqual(required, ["a"])
    }

    /// A tool that takes a real action must carry its confirmation into the description,
    /// so the model asks first rather than discovering the rule by being refused.
    func test_writeToolsCarryTheirConfirmationToTheModel() {
        let d = writeTool.realtimeSchema()["description"] as? String ?? ""
        XCTAssertTrue(d.contains("Want me to send that?"), d)
        XCTAssertFalse(writeTool.isReadOnly)

        let r = readTool.realtimeSchema()["description"] as? String ?? ""
        XCTAssertEqual(r, "Read what is on the clipboard.", "read-only tools stay clean")
        XCTAssertTrue(readTool.isReadOnly)
    }

    func test_disabledToolsAreNotOfferedToTheModel() {
        let r = ToolRegistry(specs: [readTool, writeTool])
        XCTAssertEqual(r.realtimeTools().count, 2)

        r.setEnabled(false, for: "send_message")
        let names = r.realtimeTools().compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["read_clipboard"])
        XCTAssertFalse(r.isEnabled("send_message"))

        r.setEnabled(true, for: "send_message")
        XCTAssertEqual(r.realtimeTools().count, 2)
    }

    func test_extraToolsAreAppendedAfterNativeOnes() {
        let r = ToolRegistry(specs: [readTool])
        let extra: [[String: Any]] = [["type": "function", "name": "dispatch_to_claude_code"]]
        let names = r.realtimeTools(extra: extra).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["read_clipboard", "dispatch_to_claude_code"])
    }

    func test_disabledSetSurvivesAsAList() {
        let r = ToolRegistry(specs: [readTool, writeTool], disabled: ["send_message"])
        XCTAssertEqual(r.disabledNames, ["send_message"])
        XCTAssertEqual(r.enabled.map(\.name), ["read_clipboard"])
    }
}
