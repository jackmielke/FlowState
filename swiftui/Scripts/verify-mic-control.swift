// Control for verify-mic-chain: same capture, voice processing OFF (1 channel).
// If this ALSO reports silence, the problem is mic permission for this process,
// not the 9-channel downmix.
//   swift Scripts/verify-mic-control.swift
import AVFoundation

print("TCC authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")

let engine = AVAudioEngine()
let input = engine.inputNode
let hw = input.outputFormat(forBus: 0)
print(String(format: "tap format : %.0f Hz x %d ch  (voice processing OFF)", hw.sampleRate, hw.channelCount))

final class Acc: @unchecked Sendable {
    let lock = NSLock(); var peak: Float = 0; var sumSq: Double = 0; var n: Double = 0
}
let acc = Acc()

input.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
    guard let ch = buf.floatChannelData?[0] else { return }
    acc.lock.lock(); defer { acc.lock.unlock() }
    for i in 0..<Int(buf.frameLength) {
        let v = abs(ch[i])
        if v > acc.peak { acc.peak = v }
        acc.sumSq += Double(ch[i]) * Double(ch[i]); acc.n += 1
    }
}

do { engine.prepare(); try engine.start() } catch {
    print("FAIL: engine.start: \(error.localizedDescription)"); exit(1)
}
print("capturing 3s...")
Thread.sleep(forTimeInterval: 3.0)
engine.stop(); input.removeTap(onBus: 0)

let rms = acc.n > 0 ? (acc.sumSq / acc.n).squareRoot() : 0
let dbfs = rms > 0 ? 20 * log10(rms) : -999
print(String(format: "peak: %.5f   rms: %.1f dBFS", acc.peak, dbfs))
if dbfs < -70 {
    print("VERDICT: mic delivers SILENCE even without voice processing")
    print("         -> this process lacks mic permission; the 9ch result was inconclusive")
} else {
    print("VERDICT: mic works here without voice processing")
    print("         -> the silence WITH voice processing is a real 9-channel downmix bug")
}
