import XCTest
@testable import FlowStateCore

/// The rule that decides where a line goes. The whole point is that the live screen and
/// a transcript read back off disk use this same rule, so the two can no longer disagree
/// about who spoke first.
final class TranscriptOrderTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_755_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: - Insertion

    func test_aLineStampedNowGoesAtTheEnd() {
        let stamps = [t(0), t(1), t(2)]
        XCTAssertEqual(TranscriptOrder.insertionIndex(for: t(9), in: stamps), 3)
    }

    func test_theFirstLineGoesAtTheFront() {
        XCTAssertEqual(TranscriptOrder.insertionIndex(for: t(5), in: []), 0)
    }

    /// The bug this file exists for: the user's words are stamped when they were spoken
    /// and arrive after the reply has already started streaming.
    func test_aLateUserLineLandsAboveTheReplyItPrompted() {
        // "user stopped speaking at 10" … reply began streaming at 11 … transcript of the
        // utterance arrives at 12.
        let stamps = [t(0), t(11)]
        XCTAssertEqual(TranscriptOrder.insertionIndex(for: t(10), in: stamps), 1)
    }

    func test_tiesGoAfterTheLinesTheyMatch() {
        // A system note written in the same instant as the line it is about must stay
        // below it.
        let stamps = [t(0), t(5), t(5), t(9)]
        XCTAssertEqual(TranscriptOrder.insertionIndex(for: t(5), in: stamps), 3)
    }

    func test_insertingEverythingOutOfOrderStillProducesAnOrderedTranscript() {
        var stamps: [Date] = []
        for s in [7.0, 1.0, 9.0, 3.0, 3.0, 0.0, 12.0, 5.0] {
            stamps.insert(t(s), at: TranscriptOrder.insertionIndex(for: t(s), in: stamps))
        }
        XCTAssertTrue(TranscriptOrder.isOrdered(stamps))
        XCTAssertEqual(stamps.count, 8)
        XCTAssertEqual(stamps.first, t(0))
        XCTAssertEqual(stamps.last, t(12))
    }

    // MARK: - The invariant

    func test_isOrdered() {
        XCTAssertTrue(TranscriptOrder.isOrdered([]))
        XCTAssertTrue(TranscriptOrder.isOrdered([t(4)]))
        XCTAssertTrue(TranscriptOrder.isOrdered([t(0), t(0), t(1)]))
        XCTAssertFalse(TranscriptOrder.isOrdered([t(0), t(2), t(1)]))
    }

    // MARK: - Re-stamping

    func test_aPlaceholderRestampedEarlierIsReportedUnsettled() {
        // The placeholder sat last in the transcript. A system note landed at 11 above
        // it, then the transcription came back saying the utterance began at 6 — so the
        // line is now below something that happened after it.
        let stamps = [t(0), t(11), t(6)]
        XCTAssertFalse(TranscriptOrder.isSettled(index: 2, in: stamps))
        XCTAssertFalse(TranscriptOrder.isSettled(index: 1, in: stamps))
        // Re-inserting by timestamp puts it back.
        XCTAssertEqual(TranscriptOrder.insertionIndex(for: t(6), in: [t(0), t(11)]), 1)
    }

    func test_aLineThatDidNotMoveIsSettled() {
        let stamps = [t(0), t(5), t(9)]
        for i in stamps.indices {
            XCTAssertTrue(TranscriptOrder.isSettled(index: i, in: stamps))
        }
        XCTAssertTrue(TranscriptOrder.isSettled(index: 99, in: stamps))
    }
}
