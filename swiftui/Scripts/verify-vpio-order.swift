// VPIO alone works (mic capture succeeded). VPIO + an attached player node fails
// with -10875 regardless of format or destination. So test ORDER of operations.
// Plays only digital silence.
//   swift Scripts/verify-vpio-order.swift
import AVFoundation

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}

let mono24 = { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                             channels: 1, interleaved: false)! }

func result(_ body: () throws -> AVAudioEngine) -> String {
    do {
        let e = try body()
        let ok = e.isRunning
        e.stop()
        return ok ? "OK" : "not-running"
    } catch let err as NSError { return "FAIL \(err.code)" }
}

// A: enable VPIO, then attach+connect player, then start   (what the app does)
print(pad("A vpio -> attach -> start", 34) + result {
    let e = AVAudioEngine()
    try e.inputNode.setVoiceProcessingEnabled(true)
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    e.prepare(); try e.start(); p.play(); return e
})

// B: attach+connect player, then enable VPIO, then start
print(pad("B attach -> vpio -> start", 34) + result {
    let e = AVAudioEngine()
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    try e.inputNode.setVoiceProcessingEnabled(true)
    e.prepare(); try e.start(); p.play(); return e
})

// C: touch mainMixer first (instantiates it), then vpio, then attach
print(pad("C mixer -> vpio -> attach", 34) + result {
    let e = AVAudioEngine()
    _ = e.mainMixerNode
    try e.inputNode.setVoiceProcessingEnabled(true)
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    e.prepare(); try e.start(); p.play(); return e
})

// D: start the engine first, then enable VPIO
print(pad("D start -> vpio", 34) + result {
    let e = AVAudioEngine()
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    e.prepare(); try e.start(); p.play()
    try e.inputNode.setVoiceProcessingEnabled(true)
    return e
})

// E: also install a mic tap, closest to the real app
print(pad("E vpio + tap + player", 34) + result {
    let e = AVAudioEngine()
    try e.inputNode.setVoiceProcessingEnabled(true)
    let hw = e.inputNode.outputFormat(forBus: 0)
    e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: hw) { _, _ in }
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    e.prepare(); try e.start(); p.play(); return e
})

// F: B + tap
print(pad("F attach -> vpio -> tap", 34) + result {
    let e = AVAudioEngine()
    let p = AVAudioPlayerNode(); e.attach(p)
    e.connect(p, to: e.mainMixerNode, format: mono24())
    try e.inputNode.setVoiceProcessingEnabled(true)
    let hw = e.inputNode.outputFormat(forBus: 0)
    e.inputNode.installTap(onBus: 0, bufferSize: 2048, format: hw) { _, _ in }
    e.prepare(); try e.start(); p.play(); return e
})
