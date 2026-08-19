// Reproduces the -10875 (kAudioUnitErr_FormatNotSupported) the app hits on Connect,
// then finds a player connect format that VPIO actually accepts.
// Opens the mic; plays only digital silence, so it cannot feed back.
//   swift Scripts/verify-playback-format.swift
import AVFoundation

func attempt(_ label: String, connectFormat: (AVAudioEngine) -> AVAudioFormat?) -> Bool {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
        try input.setVoiceProcessingEnabled(true)
        try engine.outputNode.setVoiceProcessingEnabled(true)
    } catch {
        print("  \(label): could not enable VPIO: \(error.localizedDescription)"); return false
    }
    let player = AVAudioPlayerNode()
    engine.attach(player)
    guard let fmt = connectFormat(engine) else { print("  \(label): no format"); return false }
    engine.connect(player, to: engine.mainMixerNode, format: fmt)
    engine.prepare()
    do {
        try engine.start()
        player.play()
        let ok = engine.isRunning
        engine.stop()
        print(String(format: "  %-28s OK   (%.0f Hz x %d ch)", (label as NSString).utf8String!,
                     fmt.sampleRate, fmt.channelCount))
        return ok
    } catch let e as NSError {
        print(String(format: "  %-28s FAIL code=%ld  (%.0f Hz x %d ch)",
                     (label as NSString).utf8String!, e.code, fmt.sampleRate, fmt.channelCount))
        return false
    }
}

// What the formats actually look like once VPIO is on.
do {
    let e = AVAudioEngine()
    try? e.inputNode.setVoiceProcessingEnabled(true)
    try? e.outputNode.setVoiceProcessingEnabled(true)
    let mix = e.mainMixerNode.outputFormat(forBus: 0)
    let out = e.outputNode.inputFormat(forBus: 0)
    print(String(format: "mainMixer out : %.0f Hz x %d ch", mix.sampleRate, mix.channelCount))
    print(String(format: "outputNode in : %.0f Hz x %d ch", out.sampleRate, out.channelCount))
    print("")
}

print("connect-format attempts:")
// The app's current choice — expected to fail.
_ = attempt("24k mono float (current)") { _ in
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
}
_ = attempt("24k stereo float") { _ in
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 2, interleaved: false)
}
_ = attempt("mainMixer's own format") { e in e.mainMixerNode.outputFormat(forBus: 0) }
_ = attempt("outputNode input format") { e in e.outputNode.inputFormat(forBus: 0) }
_ = attempt("device rate, mono") { e in
    let r = e.outputNode.inputFormat(forBus: 0).sampleRate
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: r, channels: 1, interleaved: false)
}
