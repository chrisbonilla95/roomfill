import Foundation
import Testing
@testable import RoomfillCore

@Test func measuredPointsMapExactly() {
    let pairs = [(0, 0), (20, 3), (41, 10), (60, 23), (80, 48), (90, 70), (100, 100)]
    for (airplay, samsung) in pairs {
        #expect(samsungLevel(fromAirPlay: airplay) == samsung)
    }
}

@Test func inverseLandsOnTheRequestedLevel() {
    for level in [0, 3, 10, 15, 20, 23, 48, 70, 100] {
        #expect(abs(samsungLevel(fromAirPlay: airPlayVolume(forSamsungLevel: level)) - level) <= 2)
    }
}

@Test func scaleIsMonotonic() {
    let levels = (0...100).map { samsungLevel(fromAirPlay: $0) }
    #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
}

@Test func oldSettingsConvertTheSoundbarLevel() throws {
    let old = #"{"soundbarVolume":41,"isOn":true}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    #expect(s.soundbarLevel == 10)
}

@Test func nowPlayingChangesIgnorePosition() {
    let a = NowPlaying(title: "T", artist: "A", positionSec: 10, itemID: "1")
    var b = a
    b.positionSec = 14
    #expect(a.sameTrack(as: b))
    b.artworkFile = "/tmp/x.jpg"
    #expect(!a.sameTrack(as: b))
}

@Test func migrationKeepsTheEffectiveSoundbarLevel() throws {
    // Old: AirPlay base 76 with a shared offset of -33 -> AirPlay 43 actually playing.
    let old = #"{"soundbarVolume":76,"volumeOffset":-33,"boseVolume":0.53}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    let mix = VolumeMix(soundbar: s.soundbarLevel, bose: 53, offset: s.volumeOffset)
    #expect(mix.effectiveSoundbar == samsungLevel(fromAirPlay: 43))
    #expect(mix.effectiveBose == 20)
}
