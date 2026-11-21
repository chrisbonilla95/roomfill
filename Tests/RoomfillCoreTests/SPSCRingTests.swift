import Foundation
import Testing
@testable import RoomfillCore

@Test func ringWrapsAround() {
    let ring = SPSCFloatRing(capacity: 8)
    let a: [Float] = [0, 1, 2, 3, 4, 5]
    #expect(a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
    var out = [Float](repeating: -1, count: 8)
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) } == 4)
    #expect(Array(out[0..<4]) == [0, 1, 2, 3])
    #expect(a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 6)
    #expect(ring.availableToRead == 8)
    #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) } == 8)
    #expect(out == [4, 5, 0, 1, 2, 3, 4, 5])
}

@Test func ringDropsWhenFull() {
    let ring = SPSCFloatRing(capacity: 4)
    let a: [Float] = [1, 2, 3, 4, 5, 6]
    #expect(a.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) } == 4)
    #expect(ring.availableToRead == 4)
}

@Test func ringConcurrentIntegrity() async {
    let ring = SPSCFloatRing(capacity: 4096)
    let total = 2_000_000
    let producer = Thread {
        var next = 0
        var rng = SystemRandomNumberGenerator()
        var chunk = [Float](repeating: 0, count: 700)
        while next < total {
            let n = min(Int.random(in: 1...700, using: &rng), total - next)
            for i in 0..<n { chunk[i] = Float(next + i) }
            let w = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: n) }
            next += w
            if w < n { usleep(50) }
        }
    }
    producer.start()
    var expected = 0
    var ok = true
    var buf = [Float](repeating: 0, count: 900)
    while expected < total {
        let n = buf.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: Int.random(in: 1...900)) }
        for i in 0..<n where buf[i] != Float(expected + i) { ok = false }
        expected += n
        if n == 0 { usleep(50) }
    }
    #expect(ok)
}
