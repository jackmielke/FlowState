// -10875 hit on every connect format, so the format is not the variable.
// Matrix over {which node gets voice processing} x {where the player connects}.
// Plays only digital silence, so it cannot feed back.
//   swift Scripts/verify-vpio-matrix.swift
import AVFoundation

enum Vp: String, CaseIterable { case none, inputOnly, outputOnly, both }
enum Dest: String, CaseIterable { case mainMixer, outputNode }

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

func run(_ vp: Vp, _ dest: Dest, mono24: Bool) -> String {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
        if vp == .inputOnly || vp == .both { try input.setVoiceProcessingEnabled(true) }
        if vp == .outputOnly || vp == .both { try engine.outputNode.setVoiceProcessingEnabled(true) }
    } catch let e as NSError { return "vpio-fail \(e.code)" }

    let player = AVAudioPlayerNode()
    engine.attach(player)

    let fmt: AVAudioFormat? = mono24
        ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        : nil   // nil = let the engine adopt the destination's format
    let target: AVAudioNode = (dest == .mainMixer) ? engine.mainMixerNode : engine.outputNode
    engine.connect(player, to: target, format: fmt)

    engine.prepare()
    do {
        try engine.start()
        player.play()
        let ok = engine.isRunning
        engine.stop()
        return ok ? "OK" : "not-running"
    } catch let e as NSError {
        return "FAIL \(e.code)"
    }
}

for mono in [true, false] {
    print(mono ? "\nplayer format = 24 kHz mono float" : "\nplayer format = nil (engine adopts destination)")
    print(pad("vpio", 12) + pad("->mainMixer", 14) + "->outputNode")
    for vp in Vp.allCases {
        let a = run(vp, .mainMixer, mono24: mono)
        let b = run(vp, .outputNode, mono24: mono)
        print(pad(vp.rawValue, 12) + pad(a, 14) + b)
    }
}
