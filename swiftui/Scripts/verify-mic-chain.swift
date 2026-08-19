// Captures ~3s of real mic audio with voice processing ON and pushes it through the
// exact conversion the app uses (VPIO format -> 24 kHz mono PCM16), reporting whether
// the converter errors and whether the resulting samples carry real signal.
// Opens the mic. Plays nothing, so it cannot feed back.
//   swift Scripts/verify-mic-chain.swift
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode
do {
    try input.setVoiceProcessingEnabled(true)
    try engine.outputNode.setVoiceProcessingEnabled(true)
} catch {
    print("FAIL: could not enable voice processing: \(error.localizedDescription)"); exit(1)
}

let hw = input.outputFormat(forBus: 0)
print(String(format: "tap format : %.0f Hz x %d ch", hw.sampleRate, hw.channelCount))

let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                         channels: 1, interleaved: true)!
guard let conv = AVAudioConverter(from: hw, to: wire) else {
    print("FAIL: no converter"); exit(1)
}
conv.sampleRateConverterQuality = .max
if hw.channelCount > 1 { conv.channelMap = [0] }   // must match AudioEngine.swift

final class Acc: @unchecked Sendable {
    let lock = NSLock()
    var bytes = 0, buffers = 0, errors = 0, peak: Int16 = 0
    var sumSq: Double = 0, n: Double = 0
}
let acc = Acc()

input.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
    let ratio = 24000.0 / hw.sampleRate
    let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 128
    guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: cap) else { return }
    var supplied = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buf
    }
    acc.lock.lock(); defer { acc.lock.unlock() }
    if err != nil { acc.errors += 1; return }
    acc.buffers += 1
    acc.bytes += Int(out.frameLength) * 2
    if let p = out.int16ChannelData?[0] {
        for i in 0..<Int(out.frameLength) {
            let v = p[i]
            if abs(Int(v)) > abs(Int(acc.peak)) { acc.peak = v }
            acc.sumSq += Double(v) * Double(v); acc.n += 1
        }
    }
}

do { engine.prepare(); try engine.start() } catch {
    print("FAIL: engine.start: \(error.localizedDescription)")
    print("      (mic permission is likely denied for this process)")
    exit(1)
}
print("capturing 3s — say something...")
Thread.sleep(forTimeInterval: 3.0)
engine.stop(); input.removeTap(onBus: 0)

acc.lock.lock()
let rms = acc.n > 0 ? (acc.sumSq / acc.n).squareRoot() : 0
let dbfs = rms > 0 ? 20 * log10(rms / 32768.0) : -999
print("buffers    : \(acc.buffers)  converter errors: \(acc.errors)")
print("pcm16 bytes: \(acc.bytes)  (expect ~144000 for 3s @ 24k mono)")
print(String(format: "peak       : %d   rms: %.1f dBFS", acc.peak, dbfs))
if acc.errors > 0 { print("RESULT: FAIL — converter errored"); exit(1) }
if acc.bytes < 100_000 { print("RESULT: FAIL — far too few samples; rate/channel mismatch"); exit(1) }
if dbfs < -70 { print("RESULT: FAIL — silence; 9ch downmix likely landed on empty channels"); exit(1) }
print("RESULT: PASS — real signal through the VPIO chain")
