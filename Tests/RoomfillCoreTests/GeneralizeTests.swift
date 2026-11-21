import Foundation
import Testing
@testable import RoomfillCore

@Test func emptyDeviceNameMatchesNothing() {
    #expect(!deviceNameMatches("Porta Party", wanted: ""))
    #expect(deviceNameMatches("Porta Party", wanted: "porta party"))
    #expect(!deviceNameMatches("MacBook Pro Speakers", wanted: "Porta"))
}

@Test func freshSettingsHaveNoSpeakersChosen() {
    let s = AppSettings()
    #expect(s.soundbarName.isEmpty && s.boseName.isEmpty)
    #expect(!s.speakersChosen)
}

@Test func defaultScaleIsPlainAirPlay() {
    let scale = VolumeScale.forModel(nil)
    #expect(scale.level(fromAirPlay: 37) == 37)
    #expect(scale.airPlayVolume(forLevel: 37) == 37)
    #expect(VolumeScale.forModel("SomeOtherSpeaker") == .airPlay)
}

@Test func samsungQ800DPresetUsesMeasuredPoints() {
    let scale = VolumeScale.forModel("HW-Q800D")
    #expect(scale.level(fromAirPlay: 41) == 10)
    #expect(scale.level(fromAirPlay: 80) == 48)
    #expect(scale.airPlayVolume(forLevel: 23) == 60)
}

