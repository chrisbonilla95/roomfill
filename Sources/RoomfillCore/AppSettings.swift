import Foundation

/// Everything the app remembers between launches, stored as one JSON value.
public struct AppSettings: Codable, Equatable, Sendable {
    public var selectedBundleIDs: Set<String> = ["com.spotify.client"]
    public var offset = SyncOffset(ms: 0)
    /// Soundbar level on the scale its own app shows (see `VolumeScale`), 0...100.
    public var soundbarLevel = 40
    public var boseVolume: Float? = nil
    /// AirPlay receiver name; empty until chosen.
    public var soundbarName = ""
    /// Bluetooth speaker name; empty until chosen.
    public var boseName = ""
    /// Receiver model from its AirPlay info, which selects the volume scale.
    public var soundbarModel: String? = nil
    public var idleTimeoutSec: Double = 300
    public var isOn = false
    /// Shared offset added to both speakers by the overall volume control.
    public var volumeOffset = 0
    public var muteSoundbar = false
    public var muteBose = false

    public init() {}

    public var speakersChosen: Bool { !soundbarName.isEmpty && !boseName.isEmpty }

    /// Missing keys (settings saved by older versions) fall back to the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        selectedBundleIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedBundleIDs) ?? d.selectedBundleIDs
        offset = try c.decodeIfPresent(SyncOffset.self, forKey: .offset) ?? d.offset
        if let level = try c.decodeIfPresent(Int.self, forKey: .soundbarLevel) {
            soundbarLevel = level
        } else if let legacy = try c.decodeIfPresent(Int.self, forKey: .soundbarVolume) {
            // Stored on the AirPlay scale with the shared offset applied on top: keep what was playing.
            let offset = try c.decodeIfPresent(Int.self, forKey: .volumeOffset) ?? 0
            soundbarLevel = samsungLevel(fromAirPlay: min(max(legacy + offset, 0), 100)) - offset
        } else {
            soundbarLevel = d.soundbarLevel
        }
        boseVolume = try c.decodeIfPresent(Float.self, forKey: .boseVolume) ?? d.boseVolume
        soundbarName = try c.decodeIfPresent(String.self, forKey: .soundbarName) ?? d.soundbarName
        boseName = try c.decodeIfPresent(String.self, forKey: .boseName) ?? d.boseName
        idleTimeoutSec = try c.decodeIfPresent(Double.self, forKey: .idleTimeoutSec) ?? d.idleTimeoutSec
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? d.isOn
        volumeOffset = try c.decodeIfPresent(Int.self, forKey: .volumeOffset) ?? d.volumeOffset
        muteSoundbar = try c.decodeIfPresent(Bool.self, forKey: .muteSoundbar) ?? d.muteSoundbar
        muteBose = try c.decodeIfPresent(Bool.self, forKey: .muteBose) ?? d.muteBose
        soundbarModel = try c.decodeIfPresent(String.self, forKey: .soundbarModel)
    }

    static let key = "settings.v1"

    enum CodingKeys: String, CodingKey {
        case selectedBundleIDs, offset, soundbarLevel, soundbarVolume, boseVolume, soundbarName, boseName,
             idleTimeoutSec, isOn, volumeOffset, muteSoundbar, muteBose, soundbarModel
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selectedBundleIDs, forKey: .selectedBundleIDs)
        try c.encode(offset, forKey: .offset)
        try c.encode(soundbarLevel, forKey: .soundbarLevel)
        try c.encodeIfPresent(boseVolume, forKey: .boseVolume)
        try c.encode(soundbarName, forKey: .soundbarName)
        try c.encode(boseName, forKey: .boseName)
        try c.encode(idleTimeoutSec, forKey: .idleTimeoutSec)
        try c.encode(isOn, forKey: .isOn)
        try c.encode(volumeOffset, forKey: .volumeOffset)
        try c.encode(muteSoundbar, forKey: .muteSoundbar)
        try c.encode(muteBose, forKey: .muteBose)
        try c.encodeIfPresent(soundbarModel, forKey: .soundbarModel)
    }

    public static func load(_ defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(_ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: AppSettings.key) }
    }
}
