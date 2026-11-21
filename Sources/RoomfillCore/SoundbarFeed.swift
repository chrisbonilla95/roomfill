import Foundation

public enum SoundbarState: Equatable, Sendable {
    case connecting, ready, playing, released, notResponding, lost(String), off
}

/// Moves audio from the engine's soundbar ring to an airplay-cli session, unchanged except for dithered
/// 16-bit conversion, and releases the soundbar after `idleTimeout` seconds of silence.
/// Public methods must be called on the main thread.
public final class SoundbarFeed: @unchecked Sendable {
    /// Called on the main queue.
    public var onState: ((SoundbarState) -> Void)?
    /// Called on the main queue with the receiver's model once it is known.
    public var onModel: ((String) -> Void)?
    /// Called on the main queue with a diagnostic line about the stream.
    public var onLog: ((String) -> Void)?
    public private(set) var state: SoundbarState = .off

    private let engine: Engine
    private let receiverName: String
    private let binaryURL: URL
    private var volume: Int
    private var idleTimeout: TimeInterval   // guarded by lock

    private let lock = NSLock()
    private var sender: AirPlaySender?          // guarded by lock
    private var senderRate: Double = 0           // guarded by lock
    private var framesWritten: Int = 0           // guarded by lock
    private var depthSamples = 0                 // main thread
    private var stallRetries = 0
    private var session = SessionStatus()
    private var connectRetried = false
    private var active = false
    private var writer: Thread?
    private var released = false
    private var generation = 0
    private var lastTarget: AirPlayTarget?
    private var nowPlaying: NowPlaying?
    private var watchGeneration = 0
    private var idleResetRequested = false   // guarded by lock
    private var rateReconnectQueued = false  // guarded by lock

    /// Idle release and resume never override a soundbar another device has taken.
    static func idleActionAllowed(in state: SoundbarState) -> Bool {
        if case .lost = state { return false }
        return true
    }

    public init(engine: Engine, receiverName: String, binaryURL: URL, volume: Int, idleTimeout: TimeInterval) {
        self.engine = engine
        self.receiverName = receiverName
        self.binaryURL = binaryURL
        self.volume = volume
        self.idleTimeout = idleTimeout
    }

    public func start() {
        guard !active else { return }
        active = true
        released = false
        let t = Thread { [weak self] in self?.writerLoop() }
        t.name = "Roomfill.soundbar-writer"
        t.qualityOfService = .userInteractive
        writer = t
        t.start()
        connect()
    }

    public func stop() {
        active = false
        watchGeneration += 1
        disconnect()
        setState(.off)
    }

    /// Track details for the soundbar's display; resent automatically after reconnects.
    public func setNowPlaying(_ info: NowPlaying?) {
        if let old = nowPlaying, let info, old.sameTrack(as: info) { return }
        if info == nil && nowPlaying == nil { return }
        nowPlaying = info
        pushNowPlaying()
    }

    private func pushNowPlaying() {
        guard let info = nowPlaying else { return }
        lock.lock(); let s = sender; lock.unlock()
        for line in metadataCommands(info) { s?.send(command: line) }
    }

    public func setVolume(_ v: Int) {
        volume = v
        lock.lock(); let s = sender; lock.unlock()
        s?.setVolume(v)
    }

    /// Changes how long the soundbar may stay silent before it is released. Takes effect on the next
    /// audio block, counting silence that has already elapsed; the stream is not interrupted.
    public func setIdleTimeout(_ seconds: TimeInterval) {
        lock.lock(); idleTimeout = seconds; lock.unlock()
    }

    /// Starts a fresh session, e.g. after the soundbar was taken by another sender.
    public func reconnect() {
        guard active else { return }
        disconnect()
        stallRetries = 0
        connectRetried = false
        released = false
        lock.lock(); idleResetRequested = true; rateReconnectQueued = false; lock.unlock()
        connect()
    }

    // MARK: - Session control (main thread)

    private func setState(_ s: SoundbarState) {
        guard s != state else { return }
        state = s
        onState?(s)
        if case .lost = s { startTakeoverWatch() }
    }

    /// While the soundbar is lost, poll its status and reconnect once it is free: two polls in a row
    /// without another sender's session, or simply retry when it could not be reached.
    private func startTakeoverWatch() {
        watchGeneration += 1
        pollTakeover(generation: watchGeneration, watch: TakeoverWatch())
    }

    private func pollTakeover(generation gen: Int, watch: TakeoverWatch) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.active, gen == self.watchGeneration, case .lost = self.state else { return }
            let target = self.lastTarget
            DispatchQueue.global(qos: .utility).async {
                let flags = target.flatMap { fetchReceiverStatusFlags($0) }
                DispatchQueue.main.async {
                    guard self.active, gen == self.watchGeneration, case .lost = self.state else { return }
                    guard let flags else {
                        self.reconnect()
                        return
                    }
                    var w = watch
                    if w.observe(busy: receiverIsBusy(statusFlags: flags)) {
                        self.onLog?("soundbar free again, reconnecting")
                        self.reconnect()
                    } else {
                        self.pollTakeover(generation: gen, watch: w)
                    }
                }
            }
        }
    }

    private func connect() {
        generation += 1
        let gen = generation
        setState(.connecting)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let target = try await resolveAirPlayReceiver(named: self.receiverName, timeout: 5)
                guard self.active, gen == self.generation else { return }
                self.launch(target: target, generation: gen)
            } catch {
                guard self.active, gen == self.generation else { return }
                self.setState(.lost("not found on the network"))
            }
        }
    }

    private func launch(target: AirPlayTarget, generation gen: Int) {
        lastTarget = target
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let model = fetchReceiverInfo(target)?.model else { return }
            DispatchQueue.main.async { self?.onModel?(model) }
        }
        let rate = engine.sampleRate
        let s = AirPlaySender(config: SenderConfig(binaryURL: binaryURL, target: target, volume: volume, sampleRate: Int(rate)))
        s.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e, generation: gen) } }
        s.onLog = { [weak self] line in
            guard line.contains("artwork") || line.contains("mrp") || line.contains("metadata") else { return }
            DispatchQueue.main.async { self?.onLog?("airplay-cli: " + line) }
        }
        s.onExit = { [weak self] requested in DispatchQueue.main.async { self?.handleExit(requested: requested, generation: gen) } }
        do {
            try s.start()
        } catch {
            setState(.lost("could not start AirPlay (\(error))"))
            return
        }
        depthSamples = 0
        session = SessionStatus()
        lock.lock()
        sender = s
        senderRate = rate
        framesWritten = 0
        lock.unlock()
    }

    private func disconnect() {
        generation += 1
        lock.lock()
        let s = sender
        sender = nil
        lock.unlock()
        s?.stop()
    }

    private func handle(_ e: AirPlayEvent, generation gen: Int) {
        guard gen == generation else { return }
        if case .playing(let elapsedMs) = e { updateDepth(elapsedMs: elapsedMs) }
        let next = session.apply(e)
        switch e {
        case .clockReady(state: .ready, _):
            stallRetries = 0
        case .clockReady(state: .stalled, _):
            guard stallRetries < 5 else { break }
            stallRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.active, self.state == .notResponding else { return }
                self.disconnect()
                self.connect()
            }
        default:
            break
        }
        let becamePlaying = next == .playing && state != .playing
        if next != .connecting { setState(next) }
        if becamePlaying { pushNowPlaying() }
    }

    private func handleExit(requested: Bool, generation gen: Int) {
        guard gen == generation, active, !requested else { return }
        lock.lock(); sender = nil; lock.unlock()
        if state == .connecting && !connectRetried {
            // A receiver still releasing another sender's session closes the first attempt.
            connectRetried = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.active, gen == self.generation else { return }
                self.connect()
            }
            return
        }
        setState(.lost("taken by another device"))
    }

    /// Logs airplay-cli's queue (audio written minus audio played) for diagnostics. It is not used for
    /// steering: `elapsed_ms` counts played samples, so the queue cannot reveal clock drift, and a
    /// controller chasing it only stretched the audio.
    private func updateDepth(elapsedMs: Int) {
        lock.lock()
        let written = framesWritten
        let rate = senderRate
        lock.unlock()
        guard rate > 0 else { return }
        depthSamples += 1
        if depthSamples % 10 == 0 {
            let depthMs = (Double(written) / rate - Double(elapsedMs) / 1000) * 1000
            onLog?(String(format: "soundbar queue %.0f ms", depthMs))
        }
    }

    private func idleAction(_ action: IdleAction) {
        guard active, Self.idleActionAllowed(in: state) else { return }
        switch action {
        case .release:
            released = true
            disconnect()
            setState(.released)
        case .resume:
            released = false
            stallRetries = 0
            connectRetried = false
            connect()
        }
    }

    // MARK: - Writer thread

    private func writerLoop() {
        let blockFrames = 1024
        var block = [Float](repeating: 0, count: blockFrames * 2)
        var pcm = [Int16](repeating: 0, count: blockFrames * 2)
        var dither = TPDFDither()
        lock.lock(); var idle = IdleMonitor(timeout: idleTimeout); lock.unlock()
        let clockStart = ProcessInfo.processInfo.systemUptime
        var gaps = GapFiller(threshold: 0.05, margin: 0.1)
        var dropFrames = 0
        gaps.dataArrived(at: clockStart)
        let silence = [Int16](repeating: 0, count: blockFrames * 2)
        while active {
            let n = block.withUnsafeMutableBufferPointer { engine.soundbarRing.read(into: $0.baseAddress!, count: blockFrames * 2) }
            if n == 0 {
                // The engine stops delivering while it rebuilds. Keep airplay-cli's input continuous with
                // silence, otherwise its timeline pauses and the soundbar ends up later for good.
                let now = ProcessInfo.processInfo.systemUptime
                if let action = idle.observe(peak: 0, now: now - clockStart) {
                    DispatchQueue.main.async { [weak self] in self?.idleAction(action) }
                }
                lock.lock(); let s = sender; let rate = senderRate; lock.unlock()
                if let s, rate > 0 {
                    if gaps.framesOwed(at: now, rate: rate) >= blockFrames {
                        if silence.withUnsafeBufferPointer({ s.writePCM($0.baseAddress!, count: blockFrames * 2) }) {
                            gaps.padded(blockFrames)
                            lock.lock(); framesWritten += blockFrames; lock.unlock()
                        }
                        continue
                    }
                }
                usleep(2000)
                continue
            }
            // Settle a stall exactly: the engine measured how much audio time passed while it rebuilt, so
            // pad what is still missing or drop surplus silence. The soundbar's timing stays put.
            do {
                let now = ProcessInfo.processInfo.systemUptime
                lock.lock(); let s = sender; lock.unlock()
                if let gapFrames = engine.takeRestartGapFrames() {
                    let fix = gapCorrection(gapFrames: gapFrames, alreadyPadded: gaps.paddedFrames)
                    dropFrames += fix.drop
                    var remaining = s == nil ? 0 : fix.pad
                    while remaining > 0, let s {
                        let chunk = min(remaining, blockFrames)
                        guard silence.withUnsafeBufferPointer({ s.writePCM($0.baseAddress!, count: chunk * 2) }) else { break }
                        remaining -= chunk
                        lock.lock(); framesWritten += chunk; lock.unlock()
                    }
                }
                gaps.dataArrived(at: now)
            }
            let frames = n / 2
            lock.lock()
            if idleResetRequested { idleResetRequested = false; idle = IdleMonitor(timeout: idleTimeout) }
            idle.timeout = idleTimeout
            lock.unlock()
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(block[i])) }
            if let action = idle.observe(peak: peak, now: ProcessInfo.processInfo.systemUptime - clockStart) {
                DispatchQueue.main.async { [weak self] in self?.idleAction(action) }
            }

            lock.lock()
            let s = sender
            let rateMismatch = s != nil && senderRate != engine.sampleRate
            let queueReconnect = rateMismatch && !rateReconnectQueued
            if queueReconnect { rateReconnectQueued = true }
            lock.unlock()
            if rateMismatch {
                if queueReconnect { DispatchQueue.main.async { [weak self] in self?.reconnect() } }
                continue
            }
            guard let s else { continue }
            let skip = min(dropFrames, frames)
            dropFrames -= skip
            let keep = frames - skip
            guard keep > 0 else { continue }
            block.withUnsafeBufferPointer { src in
                pcm.withUnsafeMutableBufferPointer {
                    floatToS16LE(src.baseAddress! + 2 * skip, count: keep * 2, into: $0.baseAddress!, dither: &dither)
                }
            }
            if pcm.withUnsafeBufferPointer({ s.writePCM($0.baseAddress!, count: keep * 2) }) {
                lock.lock(); framesWritten += keep; lock.unlock()
            }
        }
    }
}
