import Foundation
import Testing
@testable import RoomfillCore

private func stereoSine(freq: Double, rate: Double, frames: Int, amp: Float = 0.5) -> [Float] {
    var x = [Float](repeating: 0, count: frames * 2)
    for n in 0..<frames {
        let v = amp * Float(sin(2 * Double.pi * freq * Double(n) / rate))
        x[2 * n] = v
        x[2 * n + 1] = v
    }
    return x
}

/// Feeds the input in uneven chunks so state carried across calls is exercised.
private func resample(_ input: [Float], ratio: Double) -> [Float] {
    let r = SincResampler(channels: 2)
    var out: [Float] = []
    var chunkOut: [Float] = []
    var start = 0
    let frames = input.count / 2
    var size = 37
    while start < frames {
        let n = min(size, frames - start)
        input.withUnsafeBufferPointer { r.process($0.baseAddress! + 2 * start, frames: n, ratio: ratio, output: &chunkOut) }
        out += chunkOut
        start += n
        size = size == 37 ? 512 : 37
    }
    return out
}

@Test func unityRatioIsTransparent() {
    let input = stereoSine(freq: 1000, rate: 44100, frames: 44100)
    let out = resample(input, ratio: 1.0)
    #expect(out.count / 2 >= 44100 - 32)
    var err = 0.0
    for n in 64..<(out.count / 2) { err = max(err, Double(abs(out[2 * n] - input[2 * n]))) }
    #expect(20 * log10(err + 1e-12) < -90)
}

@Test func offUnityKeepsQuality() {
    let rate = 44100.0, ratio = 1.0005, freq = 10000.0
    let frames = 44100
    let input = stereoSine(freq: freq, rate: rate, frames: frames)
    let out = resample(input, ratio: ratio)
    let produced = out.count / 2
    #expect(abs(Double(produced) - Double(frames - 16) * ratio) <= 2)
    var sq = 0.0
    var count = 0
    for n in 64..<(produced - 64) {
        let ideal = 0.5 * sin(2 * Double.pi * freq * (Double(n) / ratio) / rate)
        sq += pow(Double(out[2 * n]) - ideal, 2)
        count += 1
    }
    #expect(10 * log10(sq / Double(count) + 1e-20) < -80)
}

@Test func controllerDirection() {
    var c = FillController(targetFrames: 4410)
    #expect(c.ratio(fillFrames: 8820) < 1)
    var d = FillController(targetFrames: 4410)
    #expect(d.ratio(fillFrames: 0) > 1)
    var e = FillController(targetFrames: 4410)
    for _ in 0..<100_000 {
        let r = e.ratio(fillFrames: 0)
        #expect(r <= 1 + 500e-6 + 1e-12 && r >= 1 - 500e-6 - 1e-12)
        if r > 1 + 500e-6 + 1e-12 { break }
    }
}
