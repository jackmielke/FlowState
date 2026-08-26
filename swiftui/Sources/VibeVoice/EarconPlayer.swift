import AVFoundation
import Foundation
import VibeVoiceCore

/// Plays an earcon whether or not a conversation is open.
///
/// `AppState.sound` routes through the conversation's `AudioEngine`, which is right for
/// everything that happens *during* a session and useless for dictation, which happens
/// while idle — `playTone` returns immediately unless the engine is already running.
///
/// So: render to WAV bytes once, hand them to `AVAudioPlayer`, keep the player alive until
/// it finishes. No engine, no audio unit, nothing attached to the shared output device,
/// and therefore none of the teardown hazard that made this Mac crackle.
@MainActor
final class EarconPlayer {

    static let shared = EarconPlayer()

    private var cache: [String: Data] = [:]
    /// Players are held until playback ends. Dropping the reference at the end of `play`
    /// stops the sound instantly — the classic AVAudioPlayer bug, and it presents as
    /// "the chime only sometimes plays", which is maddening to chase.
    private var inFlight: [AVAudioPlayer] = []

    private init() {}

    func play(_ earcon: Earcon, id: String, enabled: Bool) {
        guard enabled else { return }
        let data = cache[id] ?? {
            let rendered = earcon.wavData(sampleRate: 44_100)
            cache[id] = rendered
            return rendered
        }()
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        inFlight.append(player)

        let seconds = earcon.duration + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.inFlight.removeAll { $0 === player }
        }
    }
}
