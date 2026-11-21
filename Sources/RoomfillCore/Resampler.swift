import Foundation

/// Streaming band-limited resampler for ratios close to 1 (clock correction, not rate conversion).
/// Kaiser-windowed sinc, polyphase table with linear blending between adjacent phases.
/// Phase 0 is an exact unit impulse, so a ratio of exactly 1 passes audio through unchanged.
public final class SincResampler {
    public let channels: Int
    private let taps: Int
    private let half: Int
    private let phases: Int
    private let table: [Float]          // (phases + 1) rows of `taps` coefficients
    private var history: [Float]        // interleaved input not yet fully consumed
    private var position: Double        // read position in frames, relative to history start

    public init(channels: Int, taps: Int = 32, phases: Int = 256, kaiserBeta: Double = 8.6) {
        self.channels = channels
        self.taps = taps
        half = taps / 2
        self.phases = phases
        var t = [Float](repeating: 0, count: (phases + 1) * taps)
        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum {
                term *= (x / (2 * k)) * (x / (2 * k))
                sum += term
                k += 1
            }
            return sum
        }
        let i0Beta = besselI0(kaiserBeta)
        for p in 0...phases {
            let frac = Double(p) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            for k in 0..<taps {
                let x = Double(k - (taps / 2 - 1)) - frac
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let r = x / Double(taps / 2)
                let window = abs(r) >= 1 ? 0 : besselI0(kaiserBeta * (1 - r * r).squareRoot()) / i0Beta
                row[k] = sinc * window
            }
            let sum = row.reduce(0, +)
            for k in 0..<taps { t[p * taps + k] = Float(row[k] / sum) }
        }
        table = t
        history = [Float](repeating: 0, count: (taps / 2 - 1) * channels)
        position = Double(taps / 2 - 1)
    }

    /// Consumes `frames` interleaved input frames and replaces `output` with the frames now computable.
    /// `ratio` is output frames per input frame.
    public func process(_ input: UnsafePointer<Float>, frames: Int, ratio: Double, output: inout [Float]) {
        output.removeAll(keepingCapacity: true)
        history.append(contentsOf: UnsafeBufferPointer(start: input, count: frames * channels))
        let available = history.count / channels
        let step = 1 / ratio
        history.withUnsafeBufferPointer { h in
            table.withUnsafeBufferPointer { c in
                while true {
                    let i = Int(position)
                    if i + half >= available { break }
                    let pf = (position - Double(i)) * Double(phases)
                    let p0 = Int(pf)
                    let blend = Float(pf - Double(p0))
                    let row0 = p0 * taps, row1 = (p0 + 1) * taps
                    let base = i - (half - 1)
                    for ch in 0..<channels {
                        var acc: Float = 0
                        for k in 0..<taps {
                            let coeff = c[row0 + k] + (c[row1 + k] - c[row0 + k]) * blend
                            acc += h[(base + k) * channels + ch] * coeff
                        }
                        output.append(acc)
                    }
                    position += step
                }
            }
        }
        let drop = Int(position) - (half - 1)
        if drop > 0 {
            history.removeFirst(drop * channels)
            position -= Double(drop)
        }
    }
}

/// PI controller that turns a queue fill level into a resampling ratio (output per input frame).
/// Fill above the target gives a ratio below 1, draining the queue.
public struct FillController {
    public let targetFrames: Double
    private let maxDeviation: Double
    private let kp: Double
    private let ki: Double
    private var integral = 0.0

    public init(targetFrames: Int, maxPPM: Double = 500, kp: Double = 2e-7, ki: Double = 2e-10) {
        self.targetFrames = Double(targetFrames)
        maxDeviation = maxPPM * 1e-6
        self.kp = kp
        self.ki = ki
    }

    public mutating func ratio(fillFrames: Int) -> Double {
        let error = Double(fillFrames) - targetFrames
        integral += error
        let integralLimit = maxDeviation / ki
        integral = min(max(integral, -integralLimit), integralLimit)
        let adjustment = min(max(kp * error + ki * integral, -maxDeviation), maxDeviation)
        return 1 - adjustment
    }
}
