import Foundation

public enum IdleAction: Equatable, Sendable {
    case release, resume
}

/// Decides when a silent stream should give up the soundbar and when sound should reclaim it.
public struct IdleMonitor {
    public var timeout: TimeInterval
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

/// Tracks how much silence to insert while a real-time stream's source is stalled: once nothing has
/// arrived for `threshold` seconds, the gap since the last data minus `margin` is owed. The margin keeps
/// the estimate from overshooting; the exact remainder is settled with `gapCorrection` when data resumes.
public struct GapFiller {
    public let threshold: TimeInterval
    public let margin: TimeInterval
    private var lastData: TimeInterval = 0
    public private(set) var paddedFrames = 0

    public init(threshold: TimeInterval, margin: TimeInterval = 0) {
        self.threshold = threshold
        self.margin = margin
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
        return max(0, Int(((gap - margin) * rate).rounded()) - paddedFrames)
    }
}

public struct GapCorrection: Equatable, Sendable {
    public var pad: Int
    public var drop: Int
}

/// Settles a stall once its exact length is known: pad what is still missing, or drop the surplus
/// silence already sent from the incoming audio.
public func gapCorrection(gapFrames: Int, alreadyPadded: Int) -> GapCorrection {
    gapFrames >= alreadyPadded ? GapCorrection(pad: gapFrames - alreadyPadded, drop: 0)
                               : GapCorrection(pad: 0, drop: alreadyPadded - gapFrames)
}
