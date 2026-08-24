import XCTest
@testable import VibeVoiceCore

final class SettingCommandTests: XCTestCase {

    private let catalogue = [
        SettingChoice(key: "backdrop", spoken: "the backdrop",
                      values: ["midnight", "paper", "cape town", "motion"],
                      aliases: ["background", "wallpaper"]),
        SettingChoice(key: "motionStyle", spoken: "the moving background",
                      values: ["ocean", "clouds", "aurora", "fluid"]),
        SettingChoice(key: "cameraSize", spoken: "the camera size",
                      values: ["small", "medium", "large", "full"]),
        SettingChoice(key: "hudEnabled", spoken: "the floating widget"),
    ]

    func testFindsASettingByEveryNameItHas() {
        for said in ["backdrop", "Backdrop", "background", "the wallpaper", "back drop"] {
            XCTAssertEqual(SettingCommand.find(said, in: catalogue)?.key, "backdrop", "missed \(said)")
        }
    }

    /// "camera size" must not resolve to something shorter that also matches.
    func testPrefersTheLongerMatch() {
        XCTAssertEqual(SettingCommand.find("camera size", in: catalogue)?.key, "cameraSize")
    }

    func testMatchesValuesLoosely() {
        let backdrop = catalogue[0]
        XCTAssertEqual(SettingCommand.value("Cape Town", in: backdrop), "cape town")
        XCTAssertEqual(SettingCommand.value("capetown", in: backdrop), "cape town")
        XCTAssertEqual(SettingCommand.value("MOTION", in: backdrop), "motion")
    }

    /// Everything a person says instead of "true".
    func testUnderstandsTheManyWaysOfSayingYes() {
        let widget = catalogue[3]
        for yes in ["on", "yes", "yeah", "enable", "please", "true"] {
            XCTAssertEqual(SettingCommand.value(yes, in: widget), "on", "missed \(yes)")
        }
        for no in ["off", "no", "nope", "disable", "stop"] {
            XCTAssertEqual(SettingCommand.value(no, in: widget), "off", "missed \(no)")
        }
    }

    /// A refusal has to say what would have worked — the user cannot see the list.
    func testABadValueNamesTheChoices() {
        let r = SettingCommand.resolve(setting: "backdrop", value: "purple", catalogue: catalogue)
        guard case .failed(let e) = r else { return XCTFail("expected a refusal") }
        XCTAssertTrue(e.spoken.contains("midnight"), e.spoken)
        XCTAssertTrue(e.spoken.contains("purple"), e.spoken)
    }

    func testAnUnknownSettingSaysSo() {
        let r = SettingCommand.resolve(setting: "flux capacitor", value: "on", catalogue: catalogue)
        guard case .failed(let e) = r else { return XCTFail("expected a refusal") }
        XCTAssertTrue(e.spoken.contains("flux capacitor"), e.spoken)
    }

    func testAGoodRequestResolvesToTheCanonicalValue() {
        let r = SettingCommand.resolve(setting: "the moving background", value: "Ocean", catalogue: catalogue)
        guard case .ok(let choice, let value) = r else { return XCTFail("expected success") }
        XCTAssertEqual(choice.key, "motionStyle")
        XCTAssertEqual(value, "ocean")
    }

    /// A long list must not be read out in full — nobody listens to twenty options.
    func testLongChoiceListsAreTruncatedWhenSpoken() {
        let many = SettingChoice(key: "voice", spoken: "the voice",
                                 values: (1...20).map { "voice\($0)" })
        let e = SettingCommandError.badValue(setting: many.spoken, given: "bob", allowed: many.values)
        XCTAssertTrue(e.spoken.contains("and a few more"), e.spoken)
    }
}
