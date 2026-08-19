// The whole app pipeline in one process, using the ordering that passed (C):
// touch mainMixer -> enable VPIO -> read format -> converter with channelMap
// -> tap mic -> attach/connect player -> start -> schedule playback.
// Schedules DIGITAL SILENCE, so it cannot feed back.
//   swift Scripts/verify-full-duplex.swift
import AVFoundation

let engine = AVAudioEngine()

// 1. Instantiate the mixer BEFORE voice processing. Touching it afterwards makes
//    engine.start() fail with -10875.
_ = engine.mainMixerNode

// 2. Voice processing (echo cancellation).
var aec = false
do {
    try engine.inputNode.setVoiceProcessingEnabled(true)
    try engine.outputNode.setVoiceProcessingEnabled(true)
    aec = true
} catch { print("VPIO failed: \(error.localizedDescription)") }
print("AEC enabled : \(aec)")

// 3. Read the format only after VPIO is on.
let hw = engine.inputNode.outputFormat(forBus: 0)
print("tap format  : \(Int(hw.sampleRate)) Hz x \(hw.channelCount) ch")

let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                         channels: 1, interleaved: true)!
guard let conv = AVAudioConverter(from: hw, to: wire) else { print("no converter"); exit(1) }
conv.sampleRateConverterQuality = .max
if hw.channelCount > 1 { conv.channelMap = [0] }

final class Acc: @unchecked Sendable {
    let lock = NSLock(); var bytes = 0; var errors = 0; var sumSq: Double = 0; var n: Double = 0
}
let acc = Acc()

engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
    let cap = AVAudioFrameCount(Double(buf.frameLength) * (24000.0 / hw.sampleRate)) + 128
    guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: cap) else { return }
    var supplied = false; var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buf
    }
    acc.lock.lock(); defer { acc.lock.unlock() }
    if err != nil { acc.errors += 1; return }
    acc.bytes += Int(out.frameLength) * 2
    if let p = out.int16ChannelData?[0] {
        for i in 0..<Int(out.frameLength) { let v = Double(p[i]); acc.sumSq += v * v; acc.n += 1 }
    }
}

// 4. Player.
let playback = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000,
                             channels: 1, interleaved: false)!
let player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: playback)

engine.prepare()
do { try engine.start() } catch let e as NSError {
    print("RESULT: FAIL — engine.start code=\(e.code)"); exit(1)
}
player.play()
print("engine      : running=\(engine.isRunning)")

// 5. Schedule silence, proving the playback path accepts buffers.
var scheduled = 0
for _ in 0..<3 {
    guard let b = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: 12000) else { continue }
    b.frameLength = 12000
    if let ch = b.floatChannelData?[0] {
        for i in 0..<12000 { ch[i] = 0 }   // digital silence
    }
    player.scheduleBuffer(b, completionHandler: nil)
    scheduled += 1
}
print("scheduled   : \(scheduled) playback buffers")

Thread.sleep(forTimeInterval: 3.0)
engine.stop(); engine.inputNode.removeTap(onBus: 0)

acc.lock.lock()
let rms = acc.n > 0 ? (acc.sumSq / acc.n).squareRoot() : 0
let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -999
print(String(format: "mic capture : %d bytes, %d convert errors, %.1f dBFS", acc.bytes, acc.errors, dbfs))

if acc.errors > 0 { print("RESULT: FAIL — converter errors"); exit(1) }
if acc.bytes < 100_000 { print("RESULT: FAIL — too few samples"); exit(1) }
if dbfs < -70 { print("RESULT: FAIL — mic silent"); exit(1) }
if !aec { print("RESULT: PARTIAL — pipeline works but AEC is OFF"); exit(1) }
print("RESULT: PASS — full duplex with echo cancellation")
