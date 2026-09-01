import XCTest
@testable import FlowStateCore

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

final class SettingNumberTests: XCTestCase {

    private let speed = SettingChoice(key: "speed", spoken: "how fast it talks",
                                      range: 0.5...1.5)
    private let interval = SettingChoice(key: "screenInterval", spoken: "the screen interval",
                                        range: 2...30, unit: "seconds")
    private let intensity = SettingChoice(key: "motionIntensity", spoken: "the movement",
                                         range: 0...1, asPercent: true)

    func testPullsANumberOutOfASentence() {
        XCTAssertEqual(SettingCommand.number("about 8 seconds", in: interval), 8)
        XCTAssertEqual(SettingCommand.number("12", in: interval), 12)
        XCTAssertEqual(SettingCommand.number("1.2", in: speed), 1.2)
    }

    /// A value outside the range means "as far as it goes", not "no".
    func testClampsRatherThanRefusing() {
        XCTAssertEqual(SettingCommand.number("100 seconds", in: interval), 30)
        XCTAssertEqual(SettingCommand.number("0", in: interval), 2)
    }

    /// "Sixty percent" and "0.6" are the same request, and both get said.
    func testPercentagesAndFractionsBothWork() throws {
        XCTAssertEqual(try XCTUnwrap(SettingCommand.number("60%", in: intensity)), 0.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SettingCommand.number("0.6", in: intensity)), 0.6, accuracy: 0.001)
        XCTAssertEqual(SettingCommand.number("sixty", in: intensity), nil, "words are the model's job")
    }

    func testTheWordsPeopleUseInsteadOfNumbers() throws {
        XCTAssertEqual(SettingCommand.number("max", in: speed), 1.5)
        XCTAssertEqual(SettingCommand.number("slowest", in: speed), 0.5)
        XCTAssertEqual(try XCTUnwrap(SettingCommand.number("half", in: intensity)), 0.5, accuracy: 0.001)
    }

    /// The request this is really for: adjusting by ear, without knowing the number.
    func testRelativeChanges() throws {
        XCTAssertEqual(try XCTUnwrap(SettingCommand.nudge("a bit faster", in: speed, from: 1.0)),
                       1.15, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SettingCommand.nudge("slower", in: speed, from: 1.0)),
                       0.85, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(SettingCommand.nudge("much faster", in: speed, from: 1.0)),
                       1.3, accuracy: 0.001)
        XCTAssertNil(SettingCommand.nudge("purple", in: speed, from: 1.0))
    }

    func testRelativeChangesStopAtTheEnds() {
        XCTAssertEqual(SettingCommand.nudge("faster", in: speed, from: 1.5), 1.5)
        XCTAssertEqual(SettingCommand.nudge("slower", in: speed, from: 0.5), 0.5)
    }

    /// Read back the way a person would say it, not as a float.
    func testSpokenBack() {
        XCTAssertEqual(SettingCommand.say(0.6, intensity), "60%")
        XCTAssertEqual(SettingCommand.say(8, interval), "8 seconds")
        XCTAssertEqual(SettingCommand.say(1.2, speed), "1.2")
    }

    /// A relative request resolves through `resolve`, using the current value.
    func testResolveHandlesRelative() {
        let r = SettingCommand.resolve(setting: "speed", value: "a bit faster",
                                       catalogue: [speed], current: 1.0)
        guard case .number(_, let v) = r else { return XCTFail("expected a number") }
        XCTAssertEqual(v, 1.15, accuracy: 0.001)
    }
}
