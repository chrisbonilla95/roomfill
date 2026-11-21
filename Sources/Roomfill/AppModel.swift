import AppKit
import AVFoundation
import CoreAudio
import RoomfillCore
import os
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    @Published private(set) var soundbarState: SoundbarState = .off
    @Published private(set) var boseState: BoseState = .missing
    /// Bose device volume (0...1) last read from the speaker; used when no level was saved yet.
    @Published private(set) var boseDeviceVolume: Float = 0.5
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var syncRunning = false
    @Published private(set) var syncMessage: String?
    @Published private(set) var syncDate: Date?
    @Published private(set) var macAirPlayWarning = false
    @Published private(set) var soundEffectsWarning = false
    @Published private(set) var captureWarning = false
    @Published private(set) var micDenied = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var receivers: [String] = []
    @Published private(set) var bluetoothOutputs: [String] = []

    private var engine: Engine?
    private var feed: SoundbarFeed?
    private var timer: Timer?
    private var silentWhilePlaying = 0
    private var ticks = 0
    private let scriptQueue = DispatchQueue(label: "Roomfill.nowplaying")
    private var artworkCache: [String: String] = [:]
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: ownBundleID, category: "soundbar")

    init() {
        settings = AppSettings.load(UserDefaults.standard)
        if Self.anotherInstanceIsRunning() {
            // A second copy would fight the first over the soundbar and the audio taps.
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            return
        }
        Self.killLeftoverSenders()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.turnOff(persist: false) }
        }
        refreshApps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Start after the menu bar item exists: the first capture can block on a permission prompt.
        if settings.isOn { DispatchQueue.main.async { [weak self] in self?.turnOn() } }
    }

    // MARK: - Derived text

    var offsetText: String {
        let ms = Int(settings.offset.ms.rounded())
        if ms > 0 { return "Bose held back \(ms) ms" }
        if ms < 0 { return "Soundbar held back \(-ms) ms" }
        return "No delay"
    }

    var soundbarText: String {
        switch soundbarState {
        case .off: return "off"
        case .connecting: return "connecting"
        case .ready: return "connected"
        case .playing: return "playing"
        case .released: return "released, reconnects on play"
        case .notResponding: return "not responding, retrying"
        case .lost(let why): return why
        }
    }

    var boseText: String {
        guard settings.isOn else { return "off" }
        return boseState == .playing ? "connected" : "not connected"
    }

    var playingText: String {
        let playing = apps.filter { settings.selectedBundleIDs.contains($0.id) && $0.isPlaying }.map(\.name)
        return playing.isEmpty ? "Nothing selected is playing" : "Playing " + playing.joined(separator: ", ")
    }

    /// Selected apps that are not currently running are still listed, greyed out.
    var appRows: [(id: String, name: String, running: Bool)] {
        var rows = apps.map { (id: $0.id, name: $0.name, running: true) }
        for id in settings.selectedBundleIDs.sorted() where !apps.contains(where: { $0.id == id }) {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            rows.append((id: id, name: name, running: false))
        }
        return rows
    }

    // MARK: - Actions

    func setOn(_ on: Bool) {
        on ? turnOn() : turnOff()
    }

    func toggleApp(_ id: String) {
        var s = settings
        if s.selectedBundleIDs.contains(id) { s.selectedBundleIDs.remove(id) } else { s.selectedBundleIDs.insert(id) }
        update(s)
        engine?.setSelectedApps(s.selectedBundleIDs)
    }

    func nudge(_ deltaMs: Double) {
        var s = settings
        s.offset = SyncOffset(ms: s.offset.ms + deltaMs)
        update(s)
        engine?.setOffset(s.offset)
    }

    /// Speaker levels on 0...100: each speaker's own level plus the shared overall offset.
    var mix: VolumeMix {
        VolumeMix(soundbar: settings.soundbarLevel,
                  bose: Int(((settings.boseVolume ?? boseDeviceVolume) * 100).rounded()),
                  offset: settings.volumeOffset)
    }

    var soundbarScale: VolumeScale { VolumeScale.forModel(settings.soundbarModel) }

    /// A newly reported receiver model may change the volume scale; keep the loudness that is playing.
    private func learnModel(_ model: String) {
        guard model != settings.soundbarModel else { return }
        let playing = soundbarScale.airPlayVolume(forLevel: mix.effectiveSoundbar)
        var s = settings
        s.soundbarModel = model
        let newLevel = VolumeScale.forModel(model).level(fromAirPlay: playing)
        s.soundbarLevel = newLevel - s.volumeOffset
        update(s)
        log.notice("soundbar model \(model, privacy: .public)")
    }

    func setOverallVolume(_ v: Int) {
        var m = mix
        m.setOverall(v)
        apply(m)
    }

    func setSoundbarVolume(_ v: Int) {
        var m = mix
        m.setEffectiveSoundbar(v)
        apply(m)
    }

    func setBoseVolume(_ v: Int) {
        var m = mix
        m.setEffectiveBose(v)
        apply(m)
    }

    private func apply(_ m: VolumeMix) {
        let before = mix
        var s = settings
        s.soundbarLevel = m.soundbar
        s.boseVolume = Float(m.bose) / 100
        s.volumeOffset = m.offset
        update(s)
        if m.effectiveSoundbar != before.effectiveSoundbar { feed?.setVolume(soundbarScale.airPlayVolume(forLevel: m.effectiveSoundbar)) }
        if m.effectiveBose != before.effectiveBose {
            boseDeviceVolume = Float(m.effectiveBose) / 100
            engine?.setBoseVolume(boseDeviceVolume)
        }
    }

    func setIdleMinutes(_ minutes: Int) {
        var s = settings
        s.idleTimeoutSec = Double(max(1, minutes) * 60)
        update(s)
        feed?.setIdleTimeout(s.idleTimeoutSec)
    }

    func chooseSoundbar(_ name: String) {
        var s = settings
        s.soundbarName = name
        update(s)
        restartIfOn()
    }

    func chooseBose(_ name: String) {
        var s = settings
        s.boseName = name
        update(s)
        restartIfOn()
    }

    func toggleMuteSoundbar() {
        var s = settings
        s.muteSoundbar.toggle()
        update(s)
        engine?.userMuteSoundbar = s.muteSoundbar
    }

    func toggleMuteBose() {
        var s = settings
        s.muteBose.toggle()
        update(s)
        engine?.userMuteBose = s.muteBose
    }

    func reconnectSoundbar() {
        feed?.reconnect()
    }

    func runSyncTest() {
        guard let engine, !syncRunning else { return }
        Task {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .audio) else { micDenied = true; return }
            case .denied, .restricted:
                micDenied = true
                return
            default:
                break
            }
            micDenied = false
            syncRunning = true
            let result = await RoomfillCore.runSyncTest(engine: engine, apply: true)
            syncRunning = false
            syncMessage = result.message
            syncDate = Date()
            let lags = result.measurement.map { String(format: "soundbar %.0f ms, Bose %.0f ms", $0.lagsMs[0], $0.lagsMs[1]) } ?? "-"
            log.notice("sync test: \(result.message, privacy: .public) (\(lags, privacy: .public))")
            if result.offsetMs != nil {
                var s = settings
                s.offset = engine.config.offset
                update(s)
            }
        }
    }

    func refreshDevices() {
        bluetoothOutputs = allDevices()
            .filter { $0.hasOutput && ($0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE) }
            .map(\.name)
        Task { receivers = await browseAirPlayReceivers(timeout: 2) }
    }

    /// Points macOS alert and sound-effect output at the built-in speakers.
    func fixSoundEffectsOutput() {
        if let builtIn = allDevices().first(where: { $0.hasOutput && $0.transport == kAudioDeviceTransportTypeBuiltIn }) {
            setSoundEffectsOutputDevice(builtIn.id)
        }
        soundEffectsWarning = false
    }

    func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    private func update(_ s: AppSettings) {
        settings = s
        s.save(defaults)
    }

    private static func anotherInstanceIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: ownBundleID)
            .contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Shows the Spotify track when Spotify is selected and playing, else the names of the playing apps.
    private func updateNowPlaying() {
        let playing = apps.filter { settings.selectedBundleIDs.contains($0.id) && $0.isPlaying }
        guard !playing.isEmpty else { return }
        let fallback = fallbackNowPlaying(playingAppNames: playing.map(\.name))
        guard playing.contains(where: { $0.id == "com.spotify.client" }) else {
            feed?.setNowPlaying(fallback)
            return
        }
        scriptQueue.async { [weak self] in
            let track = Self.spotifyTrack()
            DispatchQueue.main.async {
                guard let self else { return }
                guard var info = track else { self.feed?.setNowPlaying(fallback); return }
                if let url = info.artworkFile { info.artworkFile = self.cachedArtwork(url) }
                self.feed?.setNowPlaying(info)
            }
        }
    }

    /// Current Spotify track via AppleScript; `artworkFile` carries the artwork URL until cached.
    nonisolated private static func spotifyTrack() -> NowPlaying? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil else { return nil }
        let source = """
        tell application "Spotify"
            if player state is playing then
                set t to current track
                return (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) div 1000) & linefeed & (player position as integer) & linefeed & (id of t) & linefeed & (artwork url of t)
            end if
        end tell
        """
        var error: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return nil }
        let f = out.components(separatedBy: "\n")
        guard f.count >= 7 else { return nil }
        return NowPlaying(title: f[0], artist: f[1], album: f[2], durationSec: Int(f[3]), positionSec: Int(f[4]),
                          itemID: f[5], artworkFile: f[6].isEmpty ? nil : f[6])
    }

    /// Local file for an artwork URL; nil until the download finishes (the next update picks it up).
    private func cachedArtwork(_ url: String) -> String? {
        if let path = artworkCache[url] { return path }
        guard let remote = URL(string: url) else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Roomfill")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(remote.lastPathComponent + ".jpg")
        if FileManager.default.fileExists(atPath: file.path) {
            artworkCache[url] = file.path
            return file.path
        }
        URLSession.shared.downloadTask(with: remote) { [weak self] tmp, _, _ in
            guard let tmp else { return }
            try? FileManager.default.moveItem(at: tmp, to: file)
            DispatchQueue.main.async { self?.artworkCache[url] = file.path }
        }.resume()
        return nil
    }

    /// Ends airplay-cli processes left by a previous run that crashed or was force-quit; they would
    /// otherwise keep holding the soundbar.
    private static func killLeftoverSenders() {
        guard let bundled = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", bundled.path]
        try? p.run()
        p.waitUntilExit()
    }

    private func binaryURL() -> URL {
        if let bundled = Bundle.main.url(forResource: "cliairplay", withExtension: nil) { return bundled }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/vendor/cliairplay")
    }

    private func turnOn() {
        turnOff(persist: false)
        guard settings.speakersChosen else {
            errorMessage = "Choose your AirPlay soundbar and Bluetooth speaker under Settings first"
            refreshDevices()
            var s = settings
            s.isOn = false
            update(s)
            return
        }
        let e = Engine(config: EngineConfig(boseName: settings.boseName, selectedBundleIDs: settings.selectedBundleIDs,
                                            offset: settings.offset))
        e.onError = { [weak self] message in self?.errorMessage = message }
        e.onBoseState = { [weak self] state in
            guard let self else { return }
            self.boseState = state
            if state == .playing {
                if self.settings.boseVolume == nil, let v = self.engine?.boseVolume() { self.boseDeviceVolume = v }
                let effective = Float(self.mix.effectiveBose) / 100
                self.engine?.setBoseVolume(effective)
                self.boseDeviceVolume = effective
            }
        }
        do {
            try e.start()
        } catch {
            errorMessage = "Could not start audio capture: \(error)"
            return
        }
        errorMessage = nil
        e.userMuteBose = settings.muteBose
        e.userMuteSoundbar = settings.muteSoundbar
        engine = e
        let f = SoundbarFeed(engine: e, receiverName: settings.soundbarName, binaryURL: binaryURL(),
                             volume: soundbarScale.airPlayVolume(forLevel: mix.effectiveSoundbar), idleTimeout: settings.idleTimeoutSec)
        f.onState = { [weak self] state in
            self?.soundbarState = state
            self?.log.notice("soundbar state \(String(describing: state), privacy: .public)")
        }
        f.onLog = { [weak self] line in self?.log.notice("\(line, privacy: .public)") }
        f.onModel = { [weak self] model in self?.learnModel(model) }
        f.start()
        feed = f
        var s = settings
        s.isOn = true
        update(s)
    }

    private func turnOff(persist: Bool = true) {
        // Engine first: destroying the tap returns the apps to the Mac's output at once,
        // while stopping the AirPlay session can take up to 2 s.
        engine?.stop()
        feed?.stop()
        feed = nil
        engine = nil
        soundbarState = .off
        captureWarning = false
        macAirPlayWarning = false
        if persist {
            var s = settings
            s.isOn = false
            update(s)
        }
    }

    private func restartIfOn() {
        // Start after the menu bar item exists: the first capture can block on a permission prompt.
        if settings.isOn { DispatchQueue.main.async { [weak self] in self?.turnOn() } }
    }

    private func refreshApps() {
        apps = currentAudioApps()
    }

    private func tick() {
        refreshApps()
        guard let engine else { return }
        ticks += 1
        if ticks % 2 == 0 { updateNowPlaying() }
        let peak = engine.lastPeak
        let selectedPlaying = apps.contains { settings.selectedBundleIDs.contains($0.id) && $0.isPlaying }
        silentWhilePlaying = (selectedPlaying && peak == 0) ? silentWhilePlaying + 1 : 0
        captureWarning = silentWhilePlaying >= 5
        macAirPlayWarning = device(defaultOutputDevice()).transport == kAudioDeviceTransportTypeAirPlay
        // Follow level changes made with the Bose's own buttons.
        if boseState == .playing, let actual = engine.boseVolume(), abs(actual - boseDeviceVolume) > 0.015 {
            var m = mix
            m.setEffectiveBose(Int((actual * 100).rounded()))
            var s = settings
            s.boseVolume = Float(m.bose) / 100
            update(s)
            boseDeviceVolume = actual
        }
        let effects = device(soundEffectsOutputDevice())
        soundEffectsWarning = effects.name.localizedCaseInsensitiveContains(settings.boseName)
            || effects.transport == kAudioDeviceTransportTypeAirPlay
    }
}
