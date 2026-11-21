import Foundation
import Testing
@testable import RoomfillCore

@Test func settingsDefaults() {
    let d = UserDefaults(suiteName: "Roomfill-tests-\(UUID().uuidString)")!
    let s = AppSettings.load(d)
    #expect(s.selectedBundleIDs == ["com.spotify.client"])
    #expect(s.offset == SyncOffset(ms: 0))
    #expect(s.soundbarLevel == 40)
    #expect(s.boseVolume == nil)
    #expect(s.soundbarName == "")
    #expect(s.boseName == "")
    #expect(s.idleTimeoutSec == 300)
    #expect(s.isOn == false)
}

@Test func settingsRoundTrip() {
    let d = UserDefaults(suiteName: "Roomfill-tests-\(UUID().uuidString)")!
    var s = AppSettings()
    s.selectedBundleIDs = ["org.mozilla.firefox", "com.apple.QuickTimePlayerX"]
    s.offset = SyncOffset(ms: -70)
    s.soundbarLevel = 30
    s.boseVolume = 0.4
    s.soundbarName = "Kitchen"
    s.boseName = "Other Bose"
    s.idleTimeoutSec = 120
    s.isOn = true
    s.save(d)
    #expect(AppSettings.load(d) == s)
}
