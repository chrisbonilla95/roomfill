import Accelerate
import Foundation

public struct SyncMeasurement: Equatable, Sendable {
    /// Speaker arrival lags behind the reference, ascending, in milliseconds.
    public var lagsMs: [Double]
    /// Peak height over the median correlation magnitude, per lag.
    public var confidence: [Double]
    /// Confidence of the strongest remaining peak, which is correlation noise.
    public var noiseConfidence: Double

    public init(lagsMs: [Double], confidence: [Double], noiseConfidence: Double) {
        self.lagsMs = lagsMs
        self.confidence = confidence
        self.noiseConfidence = noiseConfidence
    }
}

public enum SyncMathError: Error, Equatable {
    case tooShort, referenceSilent, micSilent, fftSetupFailed
}

/// Finds how far behind the reference the microphone hears each of up to two speakers,
/// using a phase-transform weighted cross-correlation (GCC-PHAT) at about 8 kHz.
public func measureLags(reference: [Float], mic: [Float], sampleRate: Double,
                        maxLagMs: Double = 4000) -> Result<SyncMeasurement, SyncMathError> {
    let factor = max(1, Int(sampleRate / 8000))
    let rate = sampleRate / Double(factor)
    let n = min(reference.count, mic.count) / factor
    guard n > Int(rate * 3) else { return .failure(.tooShort) }

    var a = [Float](repeating: 0, count: n)
    var b = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var sa: Float = 0, sb: Float = 0
        for j in 0..<factor { sa += reference[i * factor + j]; sb += mic[i * factor + j] }
        a[i] = sa / Float(factor)
        b[i] = sb / Float(factor)
    }
    if vDSP.rootMeanSquare(a) < 1e-4 { return .failure(.referenceSilent) }
    if vDSP.rootMeanSquare(b) < 1e-6 { return .failure(.micSilent) }
    vDSP.add(-vDSP.mean(a), a, result: &a)
    vDSP.add(-vDSP.mean(b), b, result: &b)

    var size = 8
    while size < 2 * n { size <<= 1 }
    guard let fwd = vDSP.DFT(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self),
          let inv = vDSP.DFT(count: size, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
    else { return .failure(.fftSetupFailed) }
    let zeros = [Float](repeating: 0, count: size)
    a += [Float](repeating: 0, count: size - n)
    b += [Float](repeating: 0, count: size - n)
    let y = fwd.transform(inputReal: a, inputImaginary: zeros)
    let x = fwd.transform(inputReal: b, inputImaginary: zeros)
    var rr = [Float](repeating: 0, count: size)
    var ri = [Float](repeating: 0, count: size)
    for k in 0..<size {
        let re = x.real[k] * y.real[k] + x.imaginary[k] * y.imaginary[k]
        let im = x.imaginary[k] * y.real[k] - x.real[k] * y.imaginary[k]
        let m = (re * re + im * im).squareRoot() + 1e-12
        rr[k] = re / m
        ri[k] = im / m
    }
    let c = inv.transform(inputReal: rr, inputImaginary: ri).real   // c[k]: mic lags reference by k samples

    let lo = Int(0.02 * rate), hi = min(n - 1, Int(maxLagMs / 1000 * rate))
    let median = Double(c[lo..<hi].map { abs($0) }.sorted()[(hi - lo) / 2]) + 1e-12
    let guardBand = Int(0.06 * rate)
    var peaks: [(lag: Int, value: Float)] = []
    for _ in 0..<3 {
        var best = -1
        for k in lo..<hi where peaks.allSatisfy({ abs($0.lag - k) > guardBand }) {
            if best < 0 || c[k] > c[best] { best = k }
        }
        if best >= 0 { peaks.append((best, c[best])) }
    }
    let noise = peaks.count == 3 ? Double(peaks[2].value) / median : 0
    let sorted = peaks.prefix(2).sorted { $0.lag < $1.lag }
    return .success(SyncMeasurement(lagsMs: sorted.map { Double($0.lag) / rate * 1000 },
                                    confidence: sorted.map { Double($0.value) / median },
                                    noiseConfidence: noise))
}

/// Offset that lines the speakers up, from a measurement taken with the soundbar side held back by
/// `injectedSoundbarDelayMs` and the Bose undelayed (so the later peak is the soundbar).
/// Nil when the two speakers are not both clearly heard above the correlation noise.
public func idealOffsetMs(_ m: SyncMeasurement, injectedSoundbarDelayMs: Double,
                          minConfidence: Double = 4, minAboveNoise: Double = 1.25,
                          minSeparationMs: Double = 150) -> Double? {
    let threshold = max(minConfidence, minAboveNoise * m.noiseConfidence)
    guard m.lagsMs.count == 2, m.confidence.allSatisfy({ $0 > threshold }),
          m.lagsMs[1] - m.lagsMs[0] > minSeparationMs else { return nil }
    return m.lagsMs[1] - injectedSoundbarDelayMs - m.lagsMs[0]
}

/// Lag of the one speaker heard in a single-speaker measurement: the strongest peak, provided it
/// stands clearly above the other candidate and the correlation noise (repetitive music produces
/// weaker copies of the true peak one beat away).
public func strongestLagMs(_ m: SyncMeasurement, minConfidence: Double = 4, minAboveRest: Double = 1.25) -> Double? {
    guard let best = m.confidence.indices.max(by: { m.confidence[$0] < m.confidence[$1] }) else { return nil }
    let rest = m.confidence.indices.filter { $0 != best }.map { m.confidence[$0] } + [m.noiseConfidence]
    let c = m.confidence[best]
    guard c > minConfidence, c > minAboveRest * (rest.max() ?? 0) else { return nil }
    return m.lagsMs[best]
}

/// Offset from the two speakers' separately measured lags; positive holds the Bose back.
public func offsetMs(soundbarLagMs: Double, boseLagMs: Double) -> Double {
    soundbarLagMs - boseLagMs
}
