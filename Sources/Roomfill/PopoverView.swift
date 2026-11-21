import RoomfillCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @State private var showSettings = false
    @State private var didAppear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("Roomfill").font(.headline)
                Spacer()
                Toggle("On", isOn: Binding(get: { model.settings.isOn }, set: { model.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if model.macAirPlayWarning {
                Text("macOS is also sending to an AirPlay speaker; pick MacBook speakers or AirPods in Control Center")
                    .foregroundStyle(.orange).font(.caption)
            }
            if model.soundEffectsWarning {
                HStack {
                    Text("Alert sounds play directly on a speaker, bypassing your app selection")
                        .foregroundStyle(.orange).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("Fix") { model.fixSoundEffectsOutput() }.font(.caption)
                        .help("Plays alerts and sound effects on the MacBook speakers")
                }
            }
            if model.captureWarning {
                HStack {
                    Text("No audio captured from the selected apps").foregroundStyle(.orange).font(.caption)
                    Button("Allow recording") { model.openPrivacyPane("Privacy_AudioCapture") }.font(.caption)
                }
            }
            Divider()
            volumeRow(title: "All speakers", detail: nil, value: model.mix.overall, muted: nil) { model.setOverallVolume($0) }
            volumeRow(title: model.settings.soundbarName, detail: "AirPlay, \(model.soundbarText)",
                      value: model.mix.effectiveSoundbar, muted: model.settings.muteSoundbar,
                      toggleMute: { model.toggleMuteSoundbar() }) { model.setSoundbarVolume($0) }
            if case .lost = model.soundbarState {
                Button("Reconnect soundbar") { model.reconnectSoundbar() }.font(.caption)
            }
            volumeRow(title: model.settings.boseName, detail: "Bluetooth, \(model.boseText)",
                      value: model.mix.effectiveBose, muted: model.settings.muteBose,
                      toggleMute: { model.toggleMuteBose() }) { model.setBoseVolume($0) }
            Divider()
            HStack {
                Text("Sync").bold()
                Text(model.offsetText).monospacedDigit()
                Spacer()
                Button("-") { model.nudge(-10) }
                Button("+") { model.nudge(10) }
            }
            HStack {
                Button(model.syncRunning ? "Listening..." : "Run sync test") { model.runSyncTest() }
                    .disabled(model.syncRunning || model.soundbarState != .playing || model.settings.muteSoundbar || model.settings.muteBose)
                    .help(model.settings.muteSoundbar || model.settings.muteBose ? "Unmute both speakers first"
                          : model.soundbarState == .playing ? "Silences each speaker in turn for a few seconds while the microphone times the other"
                          : "Needs the soundbar playing")
                if model.syncRunning { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let msg = model.syncMessage {
                let full = msg + (model.syncDate.map { " (" + $0.formatted(date: .omitted, time: .shortened) + ")" } ?? "")
                Text(full)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(full)
            }
            if model.micDenied {
                Button("Allow microphone for the sync test") { model.openPrivacyPane("Privacy_Microphone") }.font(.caption)
            }
            Divider()
            Text("Send to speakers").bold()
            ForEach(model.appRows, id: \.id) { row in
                Toggle(isOn: Binding(get: { model.settings.selectedBundleIDs.contains(row.id) },
                                     set: { _ in model.toggleApp(row.id) })) {
                    Text(row.name).foregroundStyle(row.running ? .primary : .secondary)
                }
            }
            Divider()
            DisclosureGroup("Settings", isExpanded: $showSettings) {
                settings
            }
            .onChange(of: showSettings) { _, open in if open { model.refreshDevices() } }
            HStack {
                Text(model.playingText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") {
                    model.setOn(false)
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            if !model.settings.speakersChosen { showSettings = true; model.refreshDevices() }
        }
    }

    private func volumeRow(title: String, detail: String?, value: Int, muted: Bool?, toggleMute: (() -> Void)? = nil,
                           set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                if let muted, let toggleMute {
                    Button(action: toggleMute) {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(muted ? .red : .primary)
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(muted ? "Unmute \(title)" : "Mute \(title)")
                }
                Text(title).bold().foregroundStyle(muted == true ? .secondary : .primary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(detail)
                }
                Spacer()
                Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(value) }, set: { set(Int($0.rounded())) }), in: 0...100, step: 1)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("AirPlay speaker", selection: Binding(get: { model.settings.soundbarName }, set: { model.chooseSoundbar($0) })) {
                Text("Choose...").tag("")
                ForEach(Array(Set(model.receivers + [model.settings.soundbarName])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("Bluetooth speaker", selection: Binding(get: { model.settings.boseName }, set: { model.chooseBose($0) })) {
                Text("Choose...").tag("")
                ForEach(Array(Set(model.bluetoothOutputs + [model.settings.boseName])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
            }
            Stepper("Release soundbar after \(Int(model.settings.idleTimeoutSec / 60)) min of silence",
                    value: Binding(get: { Int(model.settings.idleTimeoutSec / 60) }, set: { model.setIdleMinutes($0) }),
                    in: 1...60)
        }
        .padding(.top, 4)
    }
}
