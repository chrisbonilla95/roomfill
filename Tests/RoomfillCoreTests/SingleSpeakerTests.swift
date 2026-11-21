import Foundation
import Testing
@testable import RoomfillCore

private struct Rng {
    var s: UInt64
    mutating func next() -> Float { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Float(Double(s >> 11) / Double(1 << 53) * 2 - 1) }
}

/// Music-like reference: the same drum pattern every 429 ms (140 BPM) plus a little varying noise.
private func beatReference(seconds: Double, rate: Double) -> [Float] {
    var g = Rng(s: 11)
    let period = Int(0.429 * rate)
    let pattern = (0..<period).map { i -> Float in i < 2000 ? g.next() * 0.8 : g.next() * 0.02 }
    return (0..<Int(seconds * rate)).map { pattern[$0 % period] + g.next() * 0.05 }
}

@Test func strongestPeakIsTheSpeakerNotTheBeatGhost() throws {
    let rate = 44100.0
    let ref = beatReference(seconds: 5, rate: rate)
    let d = Int(0.655 * rate)
    var mic = [Float](repeating: 0, count: ref.count)
    for i in d..<ref.count { mic[i] = 0.5 * ref[i - d] }
    let m = try measureLags(reference: ref, mic: mic, sampleRate: rate).get()
    let lag = try #require(strongestLagMs(m))
    #expect(abs(lag - 655) <= 2)
}

@Test func strongestLagNeedsAClearPeak() {
    let weak = SyncMeasurement(lagsMs: [300, 700], confidence: [7, 6], noiseConfidence: 6.5)
    #expect(strongestLagMs(weak) == nil)
    let clear = SyncMeasurement(lagsMs: [300, 700], confidence: [7, 30], noiseConfidence: 6.5)
    #expect(strongestLagMs(clear) == 700)
}

@Test func offsetFromSeparateMeasurements() {
    // Soundbar 600 ms, Bose 680 ms: the soundbar is faster, so it is held back by 80 ms.
    #expect(offsetMs(soundbarLagMs: 600, boseLagMs: 680) == -80)
    #expect(offsetMs(soundbarLagMs: 700, boseLagMs: 680) == 20)
}
