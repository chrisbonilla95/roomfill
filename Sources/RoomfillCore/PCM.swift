/// Triangular (TPDF) dither source of plus or minus one LSB, deterministic for a given seed.
public struct TPDFDither {
    private var state: UInt64

    public init(seed: UInt64 = 0x9E3779B97F4A7C15) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    private mutating func uniform() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }

    /// Next dither value in LSB units, triangular on (-1, 1).
    public mutating func next() -> Double {
        uniform() - uniform()
    }
}

/// Converts float samples to signed 16-bit little-endian with TPDF dither, clipping to [-1, 1].
public func floatToS16LE(_ src: UnsafePointer<Float>, count: Int, into dst: UnsafeMutablePointer<Int16>,
                         dither: inout TPDFDither) {
    for i in 0..<count {
        let x = Double(min(max(src[i], -1), 1)) * 32767.0 + dither.next()
        dst[i] = Int16(clamping: Int(x.rounded())).littleEndian
    }
}
