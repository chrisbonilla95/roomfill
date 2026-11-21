import AudioToolbox
import CoreAudio
import RoomfillCore
import Foundation
import Synchronization

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage: rfprobe devices
           rfprobe clock <device name> <seconds>
           rfprobe autostart <bundle id prefix> <seconds>
           rfprobe tone <ip> <port> | rfprobe tone <receiver name>
           rfprobe discover [receiver name]
           rfprobe apps
           rfprobe run --apps <id,id> [--offset ms] [--seconds N] [--bose-volume 0..1] --bose <bluetooth name>
                       [--soundbar name] [--volume 0..100] [--idle seconds]
                       [--synctest] [--apply] [--verify]
    """)
    exit(2)
}

switch args.first {
case "devices":
    let def = defaultOutputDevice()
    for d in allDevices() where d.hasOutput {
        let vol = deviceVolume(d.id).map { String(format: "%.2f", $0) } ?? "-"
        print(String(format: "[%@] %@%@ uid=%@ latency≈%.0f ms vol=%@", d.transportName, d.name,
                     d.id == def ? " (system output)" : "", d.uid, outputLatencyMs(d.id), vol))
    }
case "clock":
    guard args.count == 3, let secs = Double(args[2]) else { usage() }
    probeClock(deviceName: args[1], seconds: secs)
case "autostart":
    guard args.count == 3, let secs = Double(args[2]) else { usage() }
    probeAutostart(bundlePrefix: args[1], seconds: secs)
case "tone":
    if args.count == 3, let port = Int(args[2]) {
        playTone(target: AirPlayTarget(ip: args[1], port: port, name: args[1]))
    } else if args.count == 2 {
        playTone(target: resolveOrExit(args[1]))
    } else { usage() }
case "run":
    runEngine(Array(args.dropFirst()))
case "apps":
    for a in currentAudioApps() { print("\(a.id) \(a.name) playing=\(a.isPlaying) processes=\(a.processObjectIDs.count)") }
case "discover":
    let names = blocking { await browseAirPlayReceivers(timeout: 3) }
    for n in names { print("receiver: \(n)") }
    if args.count == 2 { let t = resolveOrExit(args[1]); print("resolved: \(t.name) -> \(t.ip):\(t.port)") }
default:
    usage()
}

func findOutput(_ name: String) -> AudioDevice {
    guard let d = allDevices().first(where: { $0.hasOutput && $0.name.localizedCaseInsensitiveContains(name) }) else {
        print("no output device matching \(name)"); exit(1)
    }
    return d
}

func hostSeconds(_ host: UInt64) -> Double {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(host) * Double(tb.numer) / Double(tb.denom) / 1e9
}

/// Plays silence on the device and compares its sample clock with the host clock.
func probeClock(deviceName: String, seconds: Double) {
    let dev = findOutput(deviceName)
    let rate = getValue(dev.id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, dev.id, DispatchQueue(label: "probe.io")) { _, _, _, out, _ in
        for b in UnsafeMutableAudioBufferListPointer(out) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
    AudioDeviceStart(dev.id, proc)
    Thread.sleep(forTimeInterval: 2)
    var first = AudioTimeStamp(), last = AudioTimeStamp()
    AudioDeviceGetCurrentTime(dev.id, &first)
    var t = 0.0
    while t < seconds {
        Thread.sleep(forTimeInterval: 1); t += 1
        AudioDeviceGetCurrentTime(dev.id, &last)
        let ds = last.mSampleTime - first.mSampleTime
        let dh = hostSeconds(last.mHostTime) - hostSeconds(first.mHostTime)
        if Int(t) % 10 == 0 { print(String(format: "t=%3.0fs rate_vs_host_ppm=%+.1f", t, ((ds / rate) / dh - 1) * 1e6)) }
    }
    let ds = last.mSampleTime - first.mSampleTime
    let dh = hostSeconds(last.mHostTime) - hostSeconds(first.mHostTime)
    print(String(format: "device=%@ nominal=%.0f rate_vs_host_ppm=%+.2f", dev.name, rate, ((ds / rate) / dh - 1) * 1e6))
    AudioDeviceStop(dev.id, proc)
    if let p = proc { AudioDeviceDestroyIOProcID(dev.id, p) }
}

/// Counts IO callbacks of a tap aggregate with TapAutoStart off while the tapped app may be silent.
func probeAutostart(bundlePrefix: String, seconds: Double) {
    let procs = getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter {
        (getString($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(bundlePrefix)
    }
    guard !procs.isEmpty else { print("no audio process for \(bundlePrefix)"); exit(1) }
    let playing = procs.contains { (getValue($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0 }
    let out = device(defaultOutputDevice())
    let desc = CATapDescription(stereoMixdownOfProcesses: procs)
    desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { print("tap failed"); exit(1) }
    let agg: [String: Any] = [
        kAudioAggregateDeviceNameKey: "rfprobe", kAudioAggregateDeviceUIDKey: "rfprobe.\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: out.uid, kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: out.uid]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
    ]
    var aggID = AudioObjectID(kAudioObjectUnknown)
    guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { print("aggregate failed"); exit(1) }
    var callbacks = 0
    var proc: AudioDeviceIOProcID?
    AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, DispatchQueue(label: "probe.io")) { _, _, _, o, _ in
        callbacks += 1
        for b in UnsafeMutableAudioBufferListPointer(o) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
    }
    let st = AudioDeviceStart(aggID, proc)
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(aggID, proc)
    if let p = proc { AudioDeviceDestroyIOProcID(aggID, p) }
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tap)
    print("target=\(bundlePrefix) processes=\(procs.count) target_playing=\(playing) clock=\(out.name) start=\(st) callbacks=\(callbacks)")
}

func airplayBinary() -> URL {
    if let env = ProcessInfo.processInfo.environment["ROOMFILL_AIRPLAY_CLI"] { return URL(fileURLWithPath: env) }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/vendor/cliairplay")
}

/// Streams 16 s of 1 kHz beeps (0.4 s every 2 s) to an AirPlay receiver and prints every event.
func playTone(target: AirPlayTarget) {
    let rate = Int(ProcessInfo.processInfo.environment["RFPROBE_RATE"] ?? "44100") ?? 44100
    let sender = AirPlaySender(config: SenderConfig(binaryURL: airplayBinary(), target: target, volume: 45, sampleRate: rate))
    let t0 = Date()
    sender.onEvent = { e in print(String(format: "%6.2fs %@", Date().timeIntervalSince(t0), String(describing: e))) }
    do { try sender.start() } catch { print("start failed: \(error)"); exit(1) }
    let frames = 352
    var block = [Float](repeating: 0, count: frames * 2)
    var pcm = [Int16](repeating: 0, count: frames * 2)
    var dither = TPDFDither()
    var n = 0
    let total = rate * 20
    while n < total {
        for f in 0..<frames {
            let t = Double(n + f) / Double(rate)
            let on = t < 16 && t.truncatingRemainder(dividingBy: 2) < 0.4
            let v = on ? Float(0.37 * sin(2 * Double.pi * 1000 * t)) : 0
            block[2 * f] = v; block[2 * f + 1] = v
        }
        block.withUnsafeBufferPointer { floatToS16LE($0.baseAddress!, count: frames * 2, into: &pcm, dither: &dither) }
        if !pcm.withUnsafeBufferPointer({ sender.writePCM($0.baseAddress!, count: frames * 2) }) { print("sender gone"); break }
        n += frames
    }
    sender.stop()
    print(String(format: "%6.2fs done", Date().timeIntervalSince(t0)))
}

func blocking<T>(_ body: @escaping () async throws -> T) rethrows -> T {
    var result: Result<T, Error>!
    let done = DispatchSemaphore(value: 0)
    Task { do { result = .success(try await body()) } catch { result = .failure(error) }; done.signal() }
    done.wait()
    return try! result.get()
}

func resolveOrExit(_ name: String) -> AirPlayTarget {
    var out: Result<AirPlayTarget, Error>!
    let done = DispatchSemaphore(value: 0)
    Task {
        do { out = .success(try await resolveAirPlayReceiver(named: name, timeout: 5)) } catch { out = .failure(error) }
        done.signal()
    }
    done.wait()
    switch out! {
    case .success(let t): return t
    case .failure(let e): print("resolve \(name) failed: \(e)"); exit(1)
    }
}

func option(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Runs the engine headless: selected apps go to the Bose and into the soundbar ring, which is drained here.
func runEngine(_ args: [String]) {
    let apps = Set((option(args, "--apps") ?? "com.spotify.client").split(separator: ",").map(String.init))
    let engine = Engine(config: EngineConfig(boseName: option(args, "--bose") ?? "", selectedBundleIDs: apps,
                                             offset: SyncOffset(ms: Double(option(args, "--offset") ?? "0") ?? 0)))
    engine.onBoseState = { print("bose=\($0)") }
    do { try engine.start() } catch { print("engine start failed: \(error)"); exit(1) }
    if let v = option(args, "--bose-volume").flatMap(Float.init) { engine.setBoseVolume(v) }
    print("sampleRate=\(engine.sampleRate) apps=\(apps.sorted())")
    let drained = Atomic<Int>(0)
    var feed: SoundbarFeed?
    if let soundbar = option(args, "--soundbar") {
        let f = SoundbarFeed(engine: engine, receiverName: soundbar, binaryURL: airplayBinary(),
                             volume: Int(option(args, "--volume") ?? "45") ?? 45,
                             idleTimeout: Double(option(args, "--idle") ?? "300") ?? 300)
        f.onState = { print("soundbar=\($0)") }
        f.onLog = { print($0) }
        f.start()
        feed = f
    } else { Thread.detachNewThread {
        var buf = [Float](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { engine.soundbarRing.read(into: $0.baseAddress!, count: 8192) }
            if n == 0 { usleep(5000) } else { drained.add(n / 2, ordering: .relaxed) }
        }
    } }
    let started = Date()
    let keepMic = args.contains("--keep-mic")
    if keepMic, let mic = syncTestMicrophone() { try? engine.setMicrophone(mic) }
    if args.contains("--synctest") {
        Task { @MainActor in
            for _ in 0..<40 where feed?.state != .playing { try? await Task.sleep(for: .milliseconds(500)) }
            try? await Task.sleep(for: .seconds(3))
            func show(_ label: String, _ r: SyncTestResult) {
                let lags = r.measurement.map { m in zip(m.lagsMs, m.confidence).map { String(format: "%.0f ms (x%.1f)", $0, $1) }.joined(separator: ", ") } ?? "-"
                print("\(label): \(r.message) | lags \(lags) | noise x\(String(format: "%.1f", r.measurement?.noiseConfidence ?? 0)) | offset \(r.offsetMs.map { String(format: "%+.0f", $0) } ?? "nil")")
            }
            let first = await runSyncTest(engine: engine, apply: args.contains("--apply"), manageMicrophone: !keepMic)
            show("synctest", first)
            if args.contains("--verify") {
                let repeats = Int(option(args, "--repeat") ?? "1") ?? 1
                for i in 1...repeats {
                    try? await Task.sleep(for: .seconds(2))
                    show("verify \(i) at \(Int(Date().timeIntervalSince(started)))s", await runSyncTest(engine: engine, apply: false, manageMicrophone: !keepMic))
                }
            }
            feed?.stop(); engine.stop(); print("stopped"); exit(0)
        }
    }
    let t0 = Date()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        let pk = engine.lastPeak
        let db = pk > 0 ? 20 * log10(pk) : -120
        let frames = drained.exchange(0, ordering: .relaxed)
        print(String(format: "t=%3.0fs bose=%@ peak=%6.1f dB ring_frames_per_s=%d soundbar=%@", Date().timeIntervalSince(t0),
                     String(describing: engine.boseState), db, frames, feed.map { String(describing: $0.state) } ?? "-"))
        if let limit = option(args, "--seconds").flatMap(Double.init), Date().timeIntervalSince(t0) >= limit {
            feed?.stop(); engine.stop(); print("stopped"); exit(0)
        }
    }
    timer.resume()
    signal(SIGINT, SIG_IGN)
    let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sig.setEventHandler { feed?.stop(); engine.stop(); print("stopped"); exit(0) }
    sig.resume()
    withExtendedLifetime((timer, sig)) { CFRunLoopRun() }
}
