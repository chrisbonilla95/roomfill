import Foundation
import Testing
@testable import RoomfillCore

private struct SeededNoise {
    var state: UInt64
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
    }
}

private let rate = 44100.0

private func noise(_ count: Int, seed: UInt64) -> [Float] {
    var g = SeededNoise(state: seed)
    return (0..<count).map { _ in g.next() * 0.3 }
}

private func mix(_ ref: [Float], delaysMs: [(Double, Float)], noiseSeed: UInt64) -> [Float] {
    var mic = noise(ref.count, seed: noiseSeed).map { $0 * 0.01 }   // about -40 dB below the reference
    for (ms, gain) in delaysMs {
        let d = Int(ms / 1000 * rate)
        for i in d..<ref.count { mic[i] += gain * ref[i - d] }
    }
    return mic
}

@Test func findsTwoSpeakers() throws {
    let ref = noise(Int(8 * rate), seed: 42)
    let mic = mix(ref, delaysMs: [(680, 0.5), (1000, 0.3)], noiseSeed: 9)
    let m = try measureLags(reference: ref, mic: mic, sampleRate: rate).get()
    #expect(m.lagsMs.count == 2)
    #expect(abs(m.lagsMs[0] - 680) <= 2)
    #expect(abs(m.lagsMs[1] - 1000) <= 2)
    #expect(m.confidence.allSatisfy { $0 > 4 })
}

@Test func offsetFromInjection() throws {
    let ref = noise(Int(8 * rate), seed: 42)
    let mic = mix(ref, delaysMs: [(680, 0.5), (1000, 0.3)], noiseSeed: 9)
    let m = try measureLags(reference: ref, mic: mic, sampleRate: rate).get()
    let offset = try #require(idealOffsetMs(m, injectedSoundbarDelayMs: 400))
    #expect(abs(offset - -80) <= 2)
}

@Test func oneSpeakerOnly() throws {
    let ref = noise(Int(8 * rate), seed: 42)
    let mic = mix(ref, delaysMs: [(680, 0.5)], noiseSeed: 9)
    let m = try measureLags(reference: ref, mic: mic, sampleRate: rate).get()
    #expect(idealOffsetMs(m, injectedSoundbarDelayMs: 400) == nil)
}

@Test func silentInputs() {
    let ref = noise(Int(8 * rate), seed: 42)
    let zeros = [Float](repeating: 0, count: ref.count)
    #expect(measureLags(reference: zeros, mic: ref, sampleRate: rate) == .failure(.referenceSilent))
    #expect(measureLags(reference: ref, mic: zeros, sampleRate: rate) == .failure(.micSilent))
    #expect(measureLags(reference: Array(ref[0..<1000]), mic: Array(ref[0..<1000]), sampleRate: rate) == .failure(.tooShort))
}
