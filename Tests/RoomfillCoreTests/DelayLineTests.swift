import Testing
@testable import RoomfillCore

@Test func offsetSplit() {
    #expect(SyncOffset(ms: 40).boseDelayFrames(sampleRate: 44100) == 1764)
    #expect(SyncOffset(ms: 40).soundbarDelayFrames(sampleRate: 44100) == 0)
    #expect(SyncOffset(ms: -40).boseDelayFrames(sampleRate: 44100) == 0)
    #expect(SyncOffset(ms: -40).soundbarDelayFrames(sampleRate: 44100) == 1764)
    #expect(SyncOffset(ms: 0).boseDelayFrames(sampleRate: 44100) == 0)
    #expect(SyncOffset(ms: 0).soundbarDelayFrames(sampleRate: 44100) == 0)
}

private func run(_ line: StereoDelayLine, _ input: [Float]) -> [Float] {
    var out = [Float](repeating: .nan, count: input.count)
    input.withUnsafeBufferPointer { i in
        out.withUnsafeMutableBufferPointer { o in line.process(i.baseAddress!, o.baseAddress!, frames: input.count / 2) }
    }
    return out
}

@Test func delayShiftsSignal() {
    let line = StereoDelayLine(capacityFrames: 1000)
    line.delayFrames = 100
    var impulse = [Float](repeating: 0, count: 400)
    impulse[0] = 1
    impulse[1] = -1
    let out = run(line, impulse)
    #expect(out[200] == 1 && out[201] == -1)
    #expect(out.enumerated().allSatisfy { $0.offset == 200 || $0.offset == 201 || $0.element == 0 })
}

@Test func changingDelayNeverReadsUninitialisedData() {
    let line = StereoDelayLine(capacityFrames: 1000)
    line.delayFrames = 900
    let ones = [Float](repeating: 1, count: 200)
    let first = run(line, ones)
    #expect(first.allSatisfy { $0 == 0 })
    line.delayFrames = 50
    let second = run(line, ones)
    #expect(second.allSatisfy { $0 == 0 || $0 == 1 })
    line.delayFrames = 5000
    let third = run(line, ones)
    #expect(third.allSatisfy { !$0.isNaN })
}
