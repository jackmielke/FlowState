import XCTest
import Foundation

/// Numbers going onto the realtime socket must survive JSON serialisation.
///
/// The API rejects a request whose numbers carry more than sixteen decimal places,
/// and it rejects the WHOLE request — so one badly rounded float takes the tools,
/// the instructions and the turn detection with it. The observable symptom was an
/// assistant insisting it had no way to go to sleep, which points nowhere near a
/// slider.
final class JSONPrecisionTests: XCTestCase {

    private func decimals(_ value: Double) throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: ["v": value])
        let text = String(decoding: data, as: UTF8.self)
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        let after = text[text.index(after: dot)...].prefix { $0.isNumber }
        return after.count
    }

    /// The raw values a 0.5...1.5 slider lands on, unrounded. Several of these are
    /// the bug.
    func testRawSliderValuesCanExceedTheLimit() throws {
        var worst = 0
        for step in 0...20 {
            worst = max(worst, try decimals(0.5 + Double(step) * 0.05))
        }
        XCTAssertGreaterThan(worst, 16, "if this no longer overflows, the rounding below is untested")
    }

    /// Rounding the Double is NOT enough, and this is why the first attempt failed:
    /// 0.55 has no exact binary form, so it still writes seventeen digits.
    func testRoundingTheDoubleIsNotEnough() throws {
        XCTAssertGreaterThan(try decimals((0.55 * 100).rounded() / 100), 16)
    }

    /// Changing the type is. This is what the app sends.
    func testDecimalValuesAreAlwaysAccepted() throws {
        for step in 0...20 {
            let raw = 0.5 + Double(step) * 0.05
            let sent = NSDecimalNumber(string: String(format: "%.2f", raw))
            let data = try JSONSerialization.data(withJSONObject: ["v": sent])
            let text = String(decoding: data, as: UTF8.self)
            let after = text.firstIndex(of: ".").map {
                text[text.index(after: $0)...].prefix { $0.isNumber }.count
            } ?? 0
            XCTAssertLessThanOrEqual(after, 16, "\(raw) serialised as \(text)")
        }
    }

    /// And it must still be the speed somebody chose.
    func testTheValueSurvives() {
        for raw in [0.5, 0.85, 1.0, 1.05, 1.25, 1.5] {
            let sent = NSDecimalNumber(string: String(format: "%.2f", raw))
            XCTAssertEqual(sent.doubleValue, raw, accuracy: 0.0001)
        }
    }
}
