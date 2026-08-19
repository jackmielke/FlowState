// Verifies acoustic echo cancellation can actually be enabled on this machine,
// and reports how enabling it changes the input format. No network, no speakers.
//   swift Scripts/verify-aec.swift
import AVFoundation

let engine = AVAudioEngine()
let input = engine.inputNode

let before = input.outputFormat(forBus: 0)
print(String(format: "before : %.0f Hz x %d ch", before.sampleRate, before.channelCount))

var ok = false
do {
    try input.setVoiceProcessingEnabled(true)
    try engine.outputNode.setVoiceProcessingEnabled(true)
    ok = true
} catch {
    print("FAIL   : \(error.localizedDescription)")
}

let after = input.outputFormat(forBus: 0)
print(String(format: "after  : %.0f Hz x %d ch", after.sampleRate, after.channelCount))
print("input.isVoiceProcessingEnabled  = \(input.isVoiceProcessingEnabled)")
print("output.isVoiceProcessingEnabled = \(engine.outputNode.isVoiceProcessingEnabled)")

guard ok, after.sampleRate > 0 else {
    print("RESULT : FAIL — echo cancellation unavailable, headphones required")
    exit(1)
}

// The converter the app builds must survive the post-VPIO format.
let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
                         channels: 1, interleaved: true)!
guard AVAudioConverter(from: after, to: wire) != nil else {
    print("RESULT : FAIL — no converter from \(after) to 24k mono PCM16")
    exit(1)
}

if before.sampleRate != after.sampleRate || before.channelCount != after.channelCount {
    print("NOTE   : format changed when VPIO engaged — reading it before enabling would")
    print("         have built the converter against the wrong rate.")
}
print("RESULT : PASS — echo cancellation ON, converter valid")
