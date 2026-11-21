import Foundation
import Testing
@testable import RoomfillCore

private let apps = [
    RunningAppInfo(pid: 10, bundleID: "com.spotify.client", name: "Spotify"),
    RunningAppInfo(pid: 20, bundleID: "org.mozilla.firefox", name: "Firefox"),
    RunningAppInfo(pid: 30, bundleID: "com.google.Chrome", name: "Google Chrome"),
]
private let parents: [pid_t: pid_t] = [11: 10, 21: 20, 31: 1]

@Test func spotifyHelperJoinsSpotify() {
    let records = [
        AudioProcessRecord(objectID: 100, pid: 10, bundleID: "com.spotify.client", isRunningOutput: false),
        AudioProcessRecord(objectID: 101, pid: 11, bundleID: "com.spotify.client.helper", isRunningOutput: false),
    ]
    let grouped = groupIntoApps(records, runningApps: apps, parentOf: { parents[$0] })
    #expect(grouped == [AudioApp(id: "com.spotify.client", name: "Spotify", processObjectIDs: [100, 101], isPlaying: false)])
}

@Test func firefoxContentProcessByParent() {
    let records = [AudioProcessRecord(objectID: 200, pid: 21, bundleID: "org.mozilla.plugincontainer", isRunningOutput: true)]
    let grouped = groupIntoApps(records, runningApps: apps, parentOf: { parents[$0] })
    #expect(grouped.map(\.id) == ["org.mozilla.firefox"])
}

@Test func helperWithoutAppParentGroupsByPrefix() {
    let records = [AudioProcessRecord(objectID: 300, pid: 31, bundleID: "com.google.Chrome.helper", isRunningOutput: false)]
    let grouped = groupIntoApps(records, runningApps: apps, parentOf: { parents[$0] })
    #expect(grouped.map(\.id) == ["com.google.Chrome"])
}

@Test func daemonDropped() {
    let records = [AudioProcessRecord(objectID: 400, pid: 40, bundleID: "com.apple.something", isRunningOutput: true)]
    #expect(groupIntoApps(records, runningApps: apps, parentOf: { _ in 1 }).isEmpty)
}

@Test func isPlayingIfAnyProcessOutputs() {
    let records = [
        AudioProcessRecord(objectID: 100, pid: 10, bundleID: "com.spotify.client", isRunningOutput: false),
        AudioProcessRecord(objectID: 101, pid: 11, bundleID: "com.spotify.client.helper", isRunningOutput: true),
    ]
    #expect(groupIntoApps(records, runningApps: apps, parentOf: { parents[$0] }).first?.isPlaying == true)
}

@Test func ownAppExcludedAndSortedByName() {
    let withSelf = apps + [RunningAppInfo(pid: 50, bundleID: ownBundleID, name: "Roomfill")]
    let records = [
        AudioProcessRecord(objectID: 1, pid: 50, bundleID: ownBundleID, isRunningOutput: true),
        AudioProcessRecord(objectID: 2, pid: 10, bundleID: "com.spotify.client", isRunningOutput: false),
        AudioProcessRecord(objectID: 3, pid: 20, bundleID: "org.mozilla.firefox", isRunningOutput: false),
    ]
    #expect(groupIntoApps(records, runningApps: withSelf, parentOf: { _ in nil }).map(\.name) == ["Firefox", "Spotify"])
}

@Test func ownProcessDroppedEvenUnderAnotherApp() {
    let terminal = [RunningAppInfo(pid: 60, bundleID: "com.cmuxterm.app", name: "cmux")]
    let records = [AudioProcessRecord(objectID: 5, pid: 61, bundleID: ownBundleID, isRunningOutput: true)]
    #expect(groupIntoApps(records, runningApps: terminal, parentOf: { $0 == 61 ? 60 : nil }).isEmpty)
}
