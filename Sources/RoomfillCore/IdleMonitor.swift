import Foundation

public enum IdleAction: Equatable, Sendable {
    case release, resume
}

/// Decides when a silent stream should give up the soundbar and when sound should reclaim it.
public struct IdleMonitor {
    public let timeout: TimeInterval
    public let silenceThreshold: Float
    private var lastSound: TimeInterval?
    private var released = false

    public init(timeout: TimeInterval, silenceThreshold: Float = 1e-5) {
        self.timeout = timeout
        self.silenceThreshold = silenceThreshold
    }

    /// Feed the peak of each block with a monotonic timestamp in seconds.
    public mutating func observe(peak: Float, now: TimeInterval) -> IdleAction? {
        if lastSound == nil { lastSound = now }
        if peak > silenceThreshold {
            lastSound = now
            if released {
                released = false
                return .resume
            }
            return nil
        }
        if !released, let last = lastSound, now - last >= timeout {
            released = true
            return .release
        }
        return nil
    }
}

/// Tracks how much silence must be inserted to keep a real-time stream continuous while its source
/// is stalled: once nothing has arrived for `threshold` seconds, the whole gap since the last data is owed.
public struct GapFiller {
    public let threshold: TimeInterval
    private var lastData: TimeInterval = 0
    private var paddedFrames = 0

    public init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    public mutating func dataArrived(at now: TimeInterval) {
        lastData = now
        paddedFrames = 0
    }

    public mutating func padded(_ frames: Int) {
        paddedFrames += frames
    }

    /// Silence frames to write now; 0 while the gap is below the threshold.
    public func framesOwed(at now: TimeInterval, rate: Double) -> Int {
        let gap = now - lastData
        guard gap > threshold else { return 0 }
        return max(0, Int((gap * rate).rounded()) - paddedFrames)
    }
}
