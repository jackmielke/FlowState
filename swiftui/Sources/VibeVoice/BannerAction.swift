import Foundation

/// A one-click fix offered alongside an error banner.
///
/// Exists mainly for the case that actually stops you mid-sentence: running out of
/// OpenAI credit. The API says only "you exceeded your current quota", which is true
/// but useless when your hands are busy and the fix is a specific page you now have to
/// go find. So we recognise those errors and put the button right on the banner.
struct BannerAction: Equatable {
    var label: String
    var url: URL

    /// OpenAI's billing page — where credit is actually added.
    static let addCredits = BannerAction(
        label: "Add credits",
        url: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)

    static let usageLimits = BannerAction(
        label: "Check limits",
        url: URL(string: "https://platform.openai.com/settings/organization/limits")!)

    /// Matches on the API's own vocabulary for "you have no money left" and its
    /// neighbours. Deliberately broad: a false positive costs the user a stray button,
    /// a false negative costs them the one moment they needed the link.
    static func forAPIError(_ message: String) -> BannerAction? {
        let m = message.lowercased()

        let outOfCredit = [
            "insufficient_quota", "insufficient quota",
            "exceeded your current quota", "billing", "payment",
            "credit balance", "out of credits", "hard limit",
        ]
        if outOfCredit.contains(where: m.contains) { return .addCredits }

        // Rate limits are a different problem with a different page — sending someone
        // to the billing screen when they simply need to slow down is worse than useless.
        let rateLimited = ["rate limit", "rate_limit", "too many requests", "429"]
        if rateLimited.contains(where: m.contains) { return .usageLimits }

        return nil
    }

    /// A plain-language sentence to show instead of the raw API text.
    static func explanation(for message: String) -> String? {
        guard let a = forAPIError(message) else { return nil }
        return a == .addCredits
            ? "Your OpenAI account is out of credit, so the voice session can't continue."
            : "OpenAI is rate-limiting this account right now — wait a moment, then reconnect."
    }
}
