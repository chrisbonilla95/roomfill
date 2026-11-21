import Foundation

/// Maps between AirPlay volume (0...100, linear in dB over -30...0 dB) and the level a speaker's own
/// app shows. Linear between points.
public struct VolumeScale: Equatable, Sendable {
    public let airPlay: [Double]
    public let level: [Double]

    /// The speaker shows the AirPlay volume itself.
    public static let airPlay = VolumeScale(airPlay: [0, 100], level: [0, 100])

    /// Samsung HW-Q800D, as its SmartThings app reports levels for each AirPlay volume (measured).
    public static let samsungQ800D = VolumeScale(airPlay: [0, 20, 41, 60, 80, 90, 100],
                                                 level: [0, 3, 10, 23, 48, 70, 100])

    /// The scale for a receiver model as reported in its AirPlay info; plain AirPlay when unknown.
    public static func forModel(_ model: String?) -> VolumeScale {
        switch model {
        case "HW-Q800D": return .samsungQ800D
        default: return .airPlay
        }
    }

    private static func interpolate(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        let x = min(max(x, xs.first!), xs.last!)
        for i in 1..<xs.count where x <= xs[i] {
            return xs[i] == xs[i - 1] ? ys[i] : ys[i - 1] + (x - xs[i - 1]) / (xs[i] - xs[i - 1]) * (ys[i] - ys[i - 1])
        }
        return ys.last!
    }

    public func level(fromAirPlay volume: Int) -> Int {
        Int(Self.interpolate(Double(volume), airPlay, level).rounded())
    }

    /// The AirPlay volume that shows `level`, as close as whole AirPlay steps allow.
    public func airPlayVolume(forLevel level: Int) -> Int {
        Int(Self.interpolate(Double(level), self.level, airPlay).rounded())
    }
}

/// Samsung HW-Q800D level for an AirPlay volume.
public func samsungLevel(fromAirPlay volume: Int) -> Int {
    VolumeScale.samsungQ800D.level(fromAirPlay: volume)
}

/// AirPlay volume for a Samsung HW-Q800D level.
public func airPlayVolume(forSamsungLevel level: Int) -> Int {
    VolumeScale.samsungQ800D.airPlayVolume(forLevel: level)
}
