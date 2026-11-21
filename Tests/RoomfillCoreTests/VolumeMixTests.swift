import Foundation
import Testing
@testable import RoomfillCore

@Test func overallMovesBothBySameAmount() {
    var mix = VolumeMix(soundbar: 20, bose: 30, offset: 0)
    #expect(mix.overall == 25)
    mix.setOverall(30)
    #expect(mix.effectiveSoundbar == 25)
    #expect(mix.effectiveBose == 35)
}

@Test func clampingKeepsTheGapWhenMovingBack() {
    var mix = VolumeMix(soundbar: 10, bose: 40, offset: 0)
    mix.setOverall(5)            // offset -20
    #expect(mix.effectiveSoundbar == 0)
    #expect(mix.effectiveBose == 20)
    mix.setOverall(25)           // back to offset 0
    #expect(mix.effectiveSoundbar == 10)
    #expect(mix.effectiveBose == 40)
}

@Test func settingOneSpeakerKeepsTheOffset() {
    var mix = VolumeMix(soundbar: 20, bose: 30, offset: 5)
    mix.setEffectiveSoundbar(50)
    #expect(mix.soundbar == 45)
    #expect(mix.effectiveSoundbar == 50)
    #expect(mix.effectiveBose == 35)
}

@Test func overallStaysInRange() {
    var mix = VolumeMix(soundbar: 90, bose: 95, offset: 0)
    mix.setOverall(100)          // +8 to both: the Bose caps at 100, the soundbar keeps the gap
    #expect(mix.effectiveSoundbar == 98)
    #expect(mix.effectiveBose == 100)
    #expect(mix.overall == 100)
}

@Test func oldSettingsWithoutNewKeysStillLoad() throws {
    let old = #"{"selectedBundleIDs":["org.mozilla.firefox"],"offset":{"ms":-78},"soundbarVolume":43,"boseVolume":0.42,"soundbarName":"Soundbar","boseName":"Porta Party","idleTimeoutSec":300,"isOn":true}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    #expect(s.selectedBundleIDs == ["org.mozilla.firefox"])
    #expect(s.offset == SyncOffset(ms: -78))
    #expect(s.soundbarLevel == samsungLevel(fromAirPlay: 43))
    #expect(s.volumeOffset == 0)
}
