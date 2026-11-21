import AudioToolbox
import CoreAudio
import Foundation

public struct EngineConfig: Sendable {
    public var boseName: String
    public var selectedBundleIDs: Set<String>
    public var offset: SyncOffset
    public var soundbarRingSeconds: Double

    public init(boseName: String, selectedBundleIDs: Set<String>, offset: SyncOffset, soundbarRingSeconds: Double = 2) {
        self.boseName = boseName
        self.selectedBundleIDs = selectedBundleIDs
        self.offset = offset
        self.soundbarRingSeconds = soundbarRingSeconds
    }
}

public enum BoseState: Equatable, Sendable {
    case playing, missing
}

/// Remembers what was last built successfully, so a failed build is retried even with the same inputs.
struct RebuildGate {
    private var built: String?

    func shouldBuild(key: String, force: Bool) -> Bool {
        force || built != key
    }

    mutating func succeeded(key: String) {
        built = key
    }

    mutating func failed() {
        built = nil
    }
}

public enum EngineError: Error {
    case noClockDevice
    case tap(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
}

/// Captures the selected apps with one muted process tap and fans their audio out to the Bose
/// (through a delay line, on the aggregate's output) and to `soundbarRing` (through a second delay
/// line). The aggregate is clocked by the Bose when present, else by the built-in output, which then
/// receives silence. Rebuilds itself when the selection, the selected apps' audio processes, or the
/// device list change. All public methods must be called from one thread (the app's main thread).
public final class Engine: @unchecked Sendable {
    public private(set) var config: EngineConfig
    /// Called on the main queue whenever the Bose appears or disappears.
    public var onBoseState: ((BoseState) -> Void)?
    /// Called on the main queue with a failure description, or nil once a build succeeds again.
    public var onError: ((String?) -> Void)?
    /// Interleaved stereo at `sampleRate`, produced on the IO thread for the soundbar feed.
    public let soundbarRing: SPSCFloatRing
    public private(set) var sampleRate: Double = 44100
    public private(set) var boseState: BoseState = .missing

    private let maxFrames = 8192
    private let ioQueue = DispatchQueue(label: "Roomfill.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var gate = RebuildGate()
    private var builtClockUID = ""
    private var builtMicUID = ""
    private var retryDelay: TimeInterval = 1
    private var rebuildPending = false
    private var listenersInstalled = false
    private var micDevice: AudioDevice?

    // IO thread state. Allocated once; only touched by the IO thread while the IOProc runs.
    private let inBuffer: UnsafeMutablePointer<Float>
    private let boseBuffer: UnsafeMutablePointer<Float>
    private let soundbarBuffer: UnsafeMutablePointer<Float>
    private var boseDelay: StereoDelayLine
    private var soundbarDelay: StereoDelayLine
    private var tapChannel = 0
    private var micChannel = -1
    private var clockIsBose = false
    private var peakValue: Float = 0
    /// Input buffer layout seen by the IO thread, e.g. "[1,2]" channels per buffer (diagnostics).
    public private(set) var inputLayout = ""
    private var layoutCaptured = false

    // Sync test: silence one speaker while the other is measured.
    var muteBose = false
    var muteSoundbar = false
    /// User mutes; the speaker keeps its connection and timing and just plays silence.
    public var userMuteBose = false
    public var userMuteSoundbar = false

    // Sync test capture (IO thread writes, controller reads after `captureActive` turns false).
    var captureActive = false
    var captureCount = 0
    var captureCapacity = 0
    var captureReference: UnsafeMutablePointer<Float>?
    var captureMic: UnsafeMutablePointer<Float>?

    public init(config: EngineConfig) {
        self.config = config
        soundbarRing = SPSCFloatRing(capacity: Int(config.soundbarRingSeconds * 96000) * 2)
        inBuffer = .allocate(capacity: maxFrames * 2)
        boseBuffer = .allocate(capacity: maxFrames * 2)
        soundbarBuffer = .allocate(capacity: maxFrames * 2)
        inBuffer.initialize(repeating: 0, count: maxFrames * 2)
        boseBuffer.initialize(repeating: 0, count: maxFrames * 2)
        soundbarBuffer.initialize(repeating: 0, count: maxFrames * 2)
        boseDelay = StereoDelayLine(capacityFrames: Int(3 * 48000))
        soundbarDelay = StereoDelayLine(capacityFrames: Int(3 * 48000))
    }

    deinit {
        stop()
        inBuffer.deallocate()
        boseBuffer.deallocate()
        soundbarBuffer.deallocate()
    }

    /// Peak sample level seen since the last read; reading resets it.
    public var lastPeak: Float {
        let p = peakValue
        peakValue = 0
        return p
    }

    public func start() throws {
        running = true
        installListeners()
        try rebuild(force: true)
    }

    /// Tears everything down; the tapped apps return to their normal output immediately.
    public func stop() {
        running = false
        teardown()
        gate.failed()
    }

    public func setSelectedApps(_ ids: Set<String>) {
        config.selectedBundleIDs = ids
        scheduleRebuild()
    }

    public func setOffset(_ o: SyncOffset) {
        config.offset = o
        applyDelays()
    }

    public func setBoseVolume(_ v: Float) {
        if let bose = findBose() { setDeviceVolume(bose.id, v) }
    }

    public func boseVolume() -> Float? {
        findBose().flatMap { deviceVolume($0.id) }
    }

    /// Adds (or with nil removes) a microphone as an extra input of the aggregate.
    public func setMicrophone(_ mic: AudioDevice?) throws {
        micDevice = mic
        try rebuild(force: true)
    }

    // MARK: - Building

    private func findBose() -> AudioDevice? {
        allDevices().first { $0.hasOutput && deviceNameMatches($0.name, wanted: config.boseName) }
    }

    private func clockDevice() -> (AudioDevice, isBose: Bool)? {
        if let bose = findBose() { return (bose, true) }
        let devices = allDevices()
        if let builtIn = devices.first(where: { $0.hasOutput && $0.transport == kAudioDeviceTransportTypeBuiltIn }) {
            return (builtIn, false)
        }
        return nil
    }

    private func selectedProcessIDs() -> [AudioObjectID] {
        currentAudioApps().filter { config.selectedBundleIDs.contains($0.id) }.flatMap(\.processObjectIDs).sorted()
    }

    private func scheduleRebuild() {
        guard running, !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            self.rebuildReportingFailure()
        }
    }

    private func rebuildReportingFailure() {
        do {
            try rebuild(force: false)
        } catch {
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            onError?("Audio capture failed (\(error)); retrying in \(Int(delay)) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleRebuild() }
        }
    }

    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.scheduleRebuild()
            }
        }
    }

    /// Rebuilds tap and aggregate when what they should contain has changed (or when forced).
    private func rebuild(force: Bool) throws {
        guard running else { return }
        guard let (clock, isBose) = clockDevice() else { throw EngineError.noClockDevice }
        let processes = selectedProcessIDs()
        let micUID = micDevice?.uid ?? ""
        let key = "\(clock.uid)|\(processes)|\(micUID)"
        guard gate.shouldBuild(key: key, force: force) else { return }

        // Only the selected apps' processes changed: retarget the live tap so the apps stay muted
        // and the speakers keep playing.
        if !force, tapID != kAudioObjectUnknown, aggregateID != kAudioObjectUnknown, !processes.isEmpty,
           clock.uid == builtClockUID, micUID == builtMicUID, retargetTap(processes) {
            gate.succeeded(key: key)
            return
        }

        teardown()
        gate.failed()
        do {
            try build(clock: clock, isBose: isBose, processes: processes, force: force)
        } catch {
            teardown()
            throw error
        }
        gate.succeeded(key: key)
        builtClockUID = clock.uid
        builtMicUID = micUID
        retryDelay = 1
        let cb = onError
        DispatchQueue.main.async { cb?(nil) }
    }

    private func tapDescription(_ processes: [AudioObjectID]) -> CATapDescription {
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = tapUUID
        desc.name = "Roomfill tap"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        return desc
    }

    private func retargetTap(_ processes: [AudioObjectID]) -> Bool {
        var addr = address(kAudioTapPropertyDescription)
        var desc = tapDescription(processes)
        let st = withUnsafeMutablePointer(to: &desc) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        return st == noErr
    }

    private func build(clock: AudioDevice, isBose: Bool, processes: [AudioObjectID], force: Bool) throws {

        if !processes.isEmpty {
            tapUUID = UUID()
            let st = AudioHardwareCreateProcessTap(tapDescription(processes), &tapID)
            guard st == noErr else { throw EngineError.tap(st) }
        }
        // Without the Bose, the built-in output clocks the aggregate. Keep the running rate so the
        // soundbar session (fixed sample rate) does not have to restart.
        if !isBose { setNominalRate(clock.id, sampleRate) }

        var subs: [[String: Any]] = [[kAudioSubDeviceUIDKey: clock.uid]]
        if let mic = micDevice {
            let rate = getValue(clock.id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
            if rate > 0 { setNominalRate(mic.id, rate) }
            subs.append([kAudioSubDeviceUIDKey: mic.uid, kAudioSubDeviceDriftCompensationKey: true])
        }
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Roomfill",
            kAudioAggregateDeviceUIDKey: "\(ownBundleID).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subs,
        ]
        if tapID != kAudioObjectUnknown {
            desc[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tapUUID.uuidString,
                                                      kAudioSubTapDriftCompensationKey: true]]
        }
        var st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID)
        guard st == noErr else { throw EngineError.aggregate(st) }

        let rate = getValue(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        if rate > 0 && rate != sampleRate {
            sampleRate = rate
            boseDelay = StereoDelayLine(capacityFrames: Int(3 * rate))
            soundbarDelay = StereoDelayLine(capacityFrames: Int(3 * rate))
        }
        let micChannels = micDevice.map { channelCount($0.id, kAudioObjectPropertyScopeInput) } ?? 0
        micChannel = micDevice == nil ? -1 : 0
        tapChannel = tapID == kAudioObjectUnknown ? -1 : micChannels
        clockIsBose = isBose
        layoutCaptured = false
        applyDelays()

        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [unowned self] _, input, _, output, _ in
            self.render(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                        output: UnsafeMutableAudioBufferListPointer(output))
        }
        guard st == noErr else { throw EngineError.ioProc(st) }
        st = AudioDeviceStart(aggregateID, procID)
        guard st == noErr else { throw EngineError.start(st) }

        // If a sub-device changes rate under the running aggregate, the stream and the soundbar
        // session would disagree on the rate; rebuild from scratch instead.
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
        let builtAggregate = aggregateID
        AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddr, DispatchQueue.main) { [weak self] _, _ in
            guard let self, self.running, self.aggregateID == builtAggregate else { return }
            let now = getValue(builtAggregate, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
            if now != self.sampleRate { try? self.rebuild(force: true) }
        }

        let newState: BoseState = isBose ? .playing : .missing
        if newState != boseState || force {
            boseState = newState
            let cb = onBoseState
            DispatchQueue.main.async { cb?(newState) }
        }
    }

    private func applyDelays() {
        boseDelay.delayFrames = config.offset.boseDelayFrames(sampleRate: sampleRate)
        soundbarDelay.delayFrames = config.offset.soundbarDelayFrames(sampleRate: sampleRate)
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let p = procID { AudioDeviceDestroyIOProcID(aggregateID, p) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    // MARK: - IO thread

    private func render(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        if !layoutCaptured {
            layoutCaptured = true
            inputLayout = "[" + input.map { String($0.mNumberChannels) }.joined(separator: ",") + "]"
        }
        let (outL, outLS, outFrames) = locate(output, channel: 0)
        let (outR, outRS, _) = locate(output, channel: 1)
        let frames = min(outFrames, maxFrames)

        var inL: UnsafeMutablePointer<Float>? = nil, inR: UnsafeMutablePointer<Float>? = nil
        var inLS = 0, inRS = 0, inFrames = 0
        if tapChannel >= 0 {
            (inL, inLS, inFrames) = locate(input, channel: tapChannel)
            (inR, inRS, _) = locate(input, channel: tapChannel + 1)
            if inR == nil { inR = inL; inRS = inLS }
        }
        var pk = peakValue
        for f in 0..<frames {
            var l: Float = 0, r: Float = 0
            if f < inFrames, let a = inL, let b = inR { l = a[f * inLS]; r = b[f * inRS] }
            inBuffer[2 * f] = l
            inBuffer[2 * f + 1] = r
            pk = max(pk, abs(l), abs(r))
        }
        peakValue = pk

        boseDelay.process(inBuffer, boseBuffer, frames: frames)
        let boseAudible = clockIsBose && !muteBose && !userMuteBose
        for f in 0..<frames {
            outL?[f * outLS] = boseAudible ? boseBuffer[2 * f] : 0
            outR?[f * outRS] = boseAudible ? boseBuffer[2 * f + 1] : 0
        }
        soundbarDelay.process(inBuffer, soundbarBuffer, frames: frames)
        if muteSoundbar || userMuteSoundbar { soundbarBuffer.update(repeating: 0, count: frames * 2) }
        _ = soundbarRing.write(soundbarBuffer, count: frames * 2)

        if captureActive, let ref = captureReference, let micOut = captureMic {
            let (mic, micS, _) = micChannel >= 0 ? locate(input, channel: micChannel) : (nil, 0, 0)
            var n = captureCount
            for f in 0..<frames where n < captureCapacity {
                ref[n] = 0.5 * (inBuffer[2 * f] + inBuffer[2 * f + 1])
                micOut[n] = mic?[f * micS] ?? 0
                n += 1
            }
            captureCount = n
        }
    }
}

/// Sample pointer, stride and frame count for one channel of an AudioBufferList.
@inline(__always)
func locate(_ abl: UnsafeMutableAudioBufferListPointer, channel: Int) -> (UnsafeMutablePointer<Float>?, Int, Int) {
    var ch = channel
    for buf in abl {
        let n = Int(buf.mNumberChannels)
        if ch < n, let data = buf.mData, n > 0 {
            return (data.assumingMemoryBound(to: Float.self) + ch, n, Int(buf.mDataByteSize) / (4 * n))
        }
        ch -= n
    }
    return (nil, 0, 0)
}
