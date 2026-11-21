import Testing
@testable import RoomfillCore

@Test func scalesAndClipsTo16Bit() {
    let input: [Float] = [0, 1, -1, 0.5, 2, -2]
    var out = [Int16](repeating: 7, count: input.count)
    var dither = TPDFDither(seed: 1)
    input.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            floatToS16LE(src.baseAddress!, count: input.count, into: dst.baseAddress!, dither: &dither)
        }
    }
    let want: [Int] = [0, 32767, -32767, 16384, 32767, -32767]
    for (got, exp) in zip(out, want) {
        #expect(abs(Int(Int16(littleEndian: got)) - exp) <= 1)
    }
}

@Test func ditherAveragesToTheTrueValue() {
    // A level a third of an LSB must survive as its average, not round to zero.
    let level = Float(1.0 / 3.0 / 32767.0)
    let input = [Float](repeating: level, count: 100_000)
    var out = [Int16](repeating: 0, count: input.count)
    var dither = TPDFDither(seed: 7)
    input.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            floatToS16LE(src.baseAddress!, count: input.count, into: dst.baseAddress!, dither: &dither)
        }
    }
    let mean = out.reduce(0.0) { $0 + Double(Int16(littleEndian: $1)) } / Double(out.count)
    #expect(abs(mean - 1.0 / 3.0) < 0.02)
}
