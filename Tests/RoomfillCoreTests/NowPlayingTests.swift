import Foundation
import Testing
@testable import RoomfillCore

@Test func metadataCommandsForATrack() {
    let info = NowPlaying(title: "The Thrill", artist: "Wiz Khalifa", album: "Kush & Orange Juice",
                          durationSec: 241, positionSec: 30, itemID: "spotify:track:1", artworkFile: "/tmp/a.jpg")
    #expect(metadataCommands(info) == [
        "TITLE=The Thrill", "ARTIST=Wiz Khalifa", "ALBUM=Kush & Orange Juice",
        "DURATION=241", "PROGRESS=30", "ITEMID=spotify:track:1", "ARTWORKFILE=/tmp/a.jpg", "ACTION=SENDMETA",
    ])
}

@Test func metadataCommandsWithoutTrackDetails() {
    let info = NowPlaying(title: "Firefox", artist: "Roomfill")
    #expect(metadataCommands(info) == ["TITLE=Firefox", "ARTIST=Roomfill", "ALBUM=", "ITEMID=Firefox", "ARTWORKFILE=", "ACTION=SENDMETA"])
}

@Test func newlinesCannotBreakTheCommandPipe() {
    let info = NowPlaying(title: "Line1\nACTION=STOP", artist: "a")
    #expect(metadataCommands(info).first == "TITLE=Line1 ACTION=STOP")
}

@Test func describesPlayingAppsWhenNoTrackInfo() {
    #expect(fallbackNowPlaying(playingAppNames: ["Firefox"]) == NowPlaying(title: "Firefox", artist: "Roomfill"))
    #expect(fallbackNowPlaying(playingAppNames: ["Firefox", "QuickTime Player"]) == NowPlaying(title: "Firefox + QuickTime Player", artist: "Roomfill"))
    #expect(fallbackNowPlaying(playingAppNames: []) == nil)
}

@Test func muteSettingsDefaultOffAndRoundTrip() throws {
    let old = #"{"selectedBundleIDs":["com.spotify.client"],"isOn":true}"#
    let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
    #expect(s.muteSoundbar == false && s.muteBose == false)
    var t = s
    t.muteBose = true
    let back = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(t))
    #expect(back.muteBose && !back.muteSoundbar)
}
