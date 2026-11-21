/// Per-speaker volumes plus one shared offset, all on a 0...100 scale. The overall level moves both
/// speakers by the same amount; each speaker's own level is kept, so clamping at 0 or 100 is undone
/// when the overall level moves back.
public struct VolumeMix: Equatable, Sendable {
    public var soundbar: Int
    public var bose: Int
    public var offset: Int

    public init(soundbar: Int, bose: Int, offset: Int) {
        self.soundbar = soundbar
        self.bose = bose
        self.offset = offset
    }

    private static func clamp(_ v: Int) -> Int { min(max(v, 0), 100) }

    public var effectiveSoundbar: Int { Self.clamp(soundbar + offset) }
    public var effectiveBose: Int { Self.clamp(bose + offset) }

    /// The average of the two speakers' own levels plus the offset.
    public var overall: Int { Self.clamp((soundbar + bose) / 2 + offset) }

    public mutating func setOverall(_ value: Int) {
        offset = Self.clamp(value) - (soundbar + bose) / 2
    }

    public mutating func setEffectiveSoundbar(_ value: Int) {
        soundbar = Self.clamp(value) - offset
    }

    public mutating func setEffectiveBose(_ value: Int) {
        bose = Self.clamp(value) - offset
    }
}
