import XCTest
@testable import FlowStateCore

/// These strings are copied verbatim from real failures. The first version of this
/// matching shipped untested and the user hit an out-of-credit error that showed no
/// button, so the exact wording is now pinned.
final class BannerActionTests: XCTestCase {

    func test_theRealOutOfCreditMessageOffersAddCredits() {
        let real = "You have no credits remaining. Add credits to continue using the API "
                 + "at https://platform.openai.com/settings/organization/billing/."
        XCTAssertEqual(BannerAction.forAPIError(real), .addCredits)
        XCTAssertNotNil(BannerAction.explanation(for: real))
    }

    func test_classicQuotaWordingAlsoMatches() {
        for m in ["insufficient_quota",
                  "You exceeded your current quota, please check your plan and billing details.",
                  "Your credit balance is too low"] {
            XCTAssertEqual(BannerAction.forAPIError(m), .addCredits, m)
        }
    }

    /// Rate limits are a different problem with a different page. Sending someone to
    /// billing when they only need to wait is worse than showing nothing.
    func test_rateLimitsGoToLimitsNotBilling() {
        for m in ["Rate limit reached for gpt-realtime", "429 Too Many Requests"] {
            XCTAssertEqual(BannerAction.forAPIError(m), .usageLimits, m)
        }
    }

    /// Transport symptoms must not claim to be billing problems.
    func test_transportNoiseOffersNothing() {
        for m in ["send failed: The operation couldn't be completed. Socket is not connected",
                  "Could not connect: The operation couldn't be completed. Socket is not connected",
                  "Conversation already has an active response in progress"] {
            XCTAssertNil(BannerAction.forAPIError(m), m)
        }
    }
}
