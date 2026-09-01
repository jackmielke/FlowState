import Foundation
import Combine

/// Per-million-token rates, in USD.
///
/// Token COUNTS below are ground truth — they come from `response.done.usage`, which
/// the API reports per turn. The RATES are transcribed from OpenAI's pricing page and
/// are the only guessed part of this file. If the meter looks wrong, check the rates
/// here against platform.openai.com/pricing first.
struct Rates: Codable, Equatable {
    var textIn: Double
    var textOut: Double
    var audioIn: Double
    var audioOut: Double
    var cachedIn: Double
    /// Images are billed as input tokens; the API reports them separately so the meter
    /// can attribute what screen-watching actually costs.
    var imageIn: Double

    static let quality = Rates(textIn: 4.00, textOut: 16.00,
                               audioIn: 32.00, audioOut: 64.00,
                               cachedIn: 0.40, imageIn: 4.00)

    static let budget = Rates(textIn: 0.60, textOut: 2.40,
                              audioIn: 10.00, audioOut: 20.00,
                              cachedIn: 0.30, imageIn: 0.60)

    static func of(_ model: String) -> Rates {
        model.contains("mini") ? .budget : .quality
    }
}

/// Running token + dollar total for one session, fed from `response.done.usage`.
@MainActor
final class CostMeter: ObservableObject {

    @Published private(set) var usd: Double = 0
    @Published private(set) var imageUSD: Double = 0     // what screen-watching alone cost
    @Published private(set) var turns = 0
    @Published private(set) var textIn = 0
    @Published private(set) var audioIn = 0
    @Published private(set) var imageIn = 0
    @Published private(set) var cachedIn = 0
    @Published private(set) var textOut = 0
    @Published private(set) var audioOut = 0

    private var startedAt: Date?

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// Dollars per minute so far. Meaningless for the first few seconds, so it is only
    /// reported once there is enough of a sample to not be wild noise.
    var usdPerMinute: Double? {
        let e = elapsed
        guard e > 20, usd > 0 else { return nil }
        return usd / (e / 60)
    }

    func startSession() {
        startedAt = Date()
        usd = 0; imageUSD = 0; turns = 0
        claudeCodeUSD = 0; claudeCodeRuns = 0
        textIn = 0; audioIn = 0; imageIn = 0; cachedIn = 0; textOut = 0; audioOut = 0
    }

    /// Stops the per-minute clock but KEEPS the totals.
    ///
    /// Called on disconnect, where the numbers are still the answer to "what did that
    /// conversation cost" — clearing them the moment the socket drops would throw away
    /// the thing the meter exists to tell you.
    func endSession() { startedAt = nil }

    /// Clears everything, for when the conversation itself changes.
    ///
    /// `endSession` alone left the previous conversation's dollars, turns and tokens on
    /// screen after switching, because it only stopped the clock. Same shape of bug as
    /// the summary panel showing another conversation's notes: a per-conversation number
    /// outliving the conversation.
    func reset() {
        startedAt = nil
        usd = 0; imageUSD = 0; turns = 0
        claudeCodeUSD = 0; claudeCodeRuns = 0
        textIn = 0; audioIn = 0; imageIn = 0; cachedIn = 0; textOut = 0; audioOut = 0
    }

    /// Applies one `response.done.usage` payload.
    func add(usage: [String: Any], rates: Rates) {
        let inDetails = usage["input_token_details"] as? [String: Any] ?? [:]
        let outDetails = usage["output_token_details"] as? [String: Any] ?? [:]

        let cached = inDetails["cached_tokens"] as? Int ?? 0
        // text_tokens/audio_tokens/image_tokens INCLUDE the cached ones, so cached is
        // subtracted off the text bucket and billed at the cheaper cached rate.
        let text = max(0, (inDetails["text_tokens"] as? Int ?? 0) - cached)
        let audio = inDetails["audio_tokens"] as? Int ?? 0
        let image = inDetails["image_tokens"] as? Int ?? 0
        let oText = outDetails["text_tokens"] as? Int ?? 0
        let oAudio = outDetails["audio_tokens"] as? Int ?? 0

        let m = 1_000_000.0
        let imageCost = Double(image) / m * rates.imageIn
        let cost = Double(text) / m * rates.textIn
            + Double(cached) / m * rates.cachedIn
            + Double(audio) / m * rates.audioIn
            + imageCost
            + Double(oText) / m * rates.textOut
            + Double(oAudio) / m * rates.audioOut

        usd += cost
        imageUSD += imageCost
        turns += 1
        textIn += text; audioIn += audio; imageIn += image; cachedIn += cached
        textOut += oText; audioOut += oAudio
    }

    /// Claude Code usage, tracked SEPARATELY from `usd` and deliberately not added to it.
    ///
    /// The `claude` CLI here authenticates by OAuth against a Claude Max subscription
    /// (`billingType: stripe_subscription`), not an API key. The `total_cost_usd` it
    /// reports is what the run *would* have cost at list API prices — an estimate of
    /// usage, not a charge. Folding it into the OpenAI total would overstate real spend
    /// by an order of magnitude on a heavy refactor.
    ///
    /// It is still worth showing: it is the honest measure of how much subscription
    /// capacity a task consumed, and overage can be billed when extra usage is enabled.
    @Published private(set) var claudeCodeUSD: Double = 0
    @Published private(set) var claudeCodeRuns = 0

    func addClaudeCode(_ dollars: Double) {
        claudeCodeUSD += dollars
        claudeCodeRuns += 1
    }

    /// Real money: OpenAI API only.
    var formatted: String {
        usd < 0.01 ? String(format: "%.3f", usd) : String(format: "%.2f", usd)
    }

    var claudeCodeFormatted: String {
        claudeCodeUSD < 0.01 ? String(format: "%.3f", claudeCodeUSD)
                             : String(format: "%.2f", claudeCodeUSD)
    }
}
