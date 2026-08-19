// With voice processing ON, reports RMS per input channel to find which one carries
// the echo-cancelled voice, then tests an explicit channelMap conversion.
//   swift Scripts/verify-vpio-channels.swift
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode
do {
    try input.setVoiceProcessingEnabled(true)
    try engine.outputNode.setVoiceProcessingEnabled(true)
} catch { print("FAIL enabling VPIO: \(error)"); exit(1) }

let hw = input.outputFormat(forBus: 0)
let nch = Int(hw.channelCount)
print(String(format: "tap format : %.0f Hz x %d ch", hw.sampleRate, hw.channelCount))
print("interleaved: \(hw.isInterleaved)")

final class Acc: @unchecked Sendable {
    let lock = NSLock()
    var sumSq: [Double]
    var n: Double = 0
    init(_ c: Int) { sumSq = Array(repeating: 0, count: c) }
}
let acc = Acc(nch)

input.installTap(onBus: 0, bufferSize: 2048, format: hw) { buf, _ in
    guard let data = buf.floatChannelData else { return }
    let frames = Int(buf.frameLength)
    acc.lock.lock(); defer { acc.lock.unlock() }
    acc.n += Double(frames)
    if buf.format.isInterleaved {
        let p = data[0]
        for f in 0..<frames {
            for c in 0..<nch {
                let v = Double(p[f * nch + c]); acc.sumSq[c] += v * v
            }
        }
    } else {
        for c in 0..<nch {
            let p = data[c]
            for f in 0..<frames { let v = Double(p[f]); acc.sumSq[c] += v * v }
        }
    }
}

do { engine.prepare(); try engine.start() } catch {
    print("FAIL: engine.start: \(error.localizedDescription)"); exit(1)
}
print("capturing 3s — say something...")
Thread.sleep(forTimeInterval: 3.0)
engine.stop(); input.removeTap(onBus: 0)

print("\nper-channel level:")
var best = -999.0, bestCh = -1
for c in 0..<nch {
    let rms = acc.n > 0 ? (acc.sumSq[c] / acc.n).squareRoot() : 0
    let db = rms > 0 ? 20 * log10(rms) : -999
    let mark = db > -70 ? "  <-- SIGNAL" : ""
    print(String(format: "  ch %d : %7.1f dBFS%@", c, db, mark))
    if db > best { best = db; bestCh = c }
}
print(String(format: "\nloudest: ch %d at %.1f dBFS", bestCh, best))
if best < -70 {
    print("RESULT: FAIL — every channel silent; VPIO is not delivering audio at all")
    exit(1)
}
print("RESULT: PASS — channel \(bestCh) carries the voice; converter must map to it explicitly")
