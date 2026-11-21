import Foundation

/// Signed speaker offset: positive holds the Bose back, negative holds the soundbar back.
public struct SyncOffset: Codable, Equatable, Sendable {
    public var ms: Double

    public init(ms: Double) {
        self.ms = ms
    }

    public func boseDelayFrames(sampleRate: Double) -> Int {
        ms > 0 ? Int((ms / 1000 * sampleRate).rounded()) : 0
    }

    public func soundbarDelayFrames(sampleRate: Double) -> Int {
        ms < 0 ? Int((-ms / 1000 * sampleRate).rounded()) : 0
    }
}

/// Interleaved stereo delay. Realtime safe: no allocation after init.
/// `delayFrames` may change between `process` calls and is clamped to `0..<capacityFrames`.
public final class StereoDelayLine: @unchecked Sendable {
    public let capacityFrames: Int
    public var delayFrames = 0
    private let ring: UnsafeMutablePointer<Float>
    private var writeIndex = 0

    public init(capacityFrames: Int) {
        self.capacityFrames = capacityFrames
        ring = .allocate(capacity: capacityFrames * 2)
        ring.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        ring.deallocate()
    }

    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) {
        let d = min(max(delayFrames, 0), capacityFrames - 1)
        var w = writeIndex
        for f in 0..<frames {
            ring[2 * w] = input[2 * f]
            ring[2 * w + 1] = input[2 * f + 1]
            var r = w - d
            if r < 0 { r += capacityFrames }
            output[2 * f] = ring[2 * r]
            output[2 * f + 1] = ring[2 * r + 1]
            w += 1
            if w == capacityFrames { w = 0 }
        }
        writeIndex = w
    }
}
