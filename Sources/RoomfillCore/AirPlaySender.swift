import Foundation

public struct AirPlayTarget: Equatable, Sendable {
    public var ip: String
    public var port: Int
    public var name: String

    public init(ip: String, port: Int, name: String) {
        self.ip = ip
        self.port = port
        self.name = name
    }
}

public struct SenderConfig {
    public var binaryURL: URL
    public var target: AirPlayTarget
    public var volume: Int
    public var sampleRate: Int
    public var bitDepth: Int

    public init(binaryURL: URL, target: AirPlayTarget, volume: Int, sampleRate: Int, bitDepth: Int = 16) {
        self.binaryURL = binaryURL
        self.target = target
        self.volume = volume
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }
}

/// Command line for airplay-cli: native AirPlay 2 with PTP timing, PCM on stdin.
/// 16-bit is the default because the soundbar distorts 24-bit ALAC.
public func senderArguments(_ c: SenderConfig, cmdPipePath: String) -> [String] {
    ["--protocol", "airplay2", "--ptp", "--port", String(c.target.port), "--volume", String(c.volume),
     "--name", "Roomfill", "--samplerate", String(c.sampleRate), "--bitdepth", String(c.bitDepth),
     "--channels", "2", "--cmdpipe", cmdPipePath, c.target.ip]
}

public enum SenderError: Error {
    case fifo(Int32)
    case commandPipeNotOpened
}

/// Runs one airplay-cli session. `writePCM` must be called from a single non-realtime thread.
public final class AirPlaySender {
    public let config: SenderConfig
    /// Called on a background queue for every `[STATUS]` line.
    public var onEvent: ((AirPlayEvent) -> Void)?
    /// Called on a background queue for every output line, parsed or not.
    public var onLog: ((String) -> Void)?
    /// Called once when the process exits; the flag says whether `stop()` requested it.
    public var onExit: ((_ requested: Bool) -> Void)?

    private var process: Process?
    private var stdinFD: Int32 = -1
    private var cmdFD: Int32 = -1
    /// Path of the command fifo; removed when the sender is deallocated.
    public private(set) var cmdPipePath = ""
    private var lineBuffer = Data()
    private var startSent = false
    private var stopRequested = false
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    public init(config: SenderConfig) {
        self.config = config
    }

    deinit {
        if cmdFD >= 0 { close(cmdFD) }
        if stdinFD >= 0 { close(stdinFD) }
        if !cmdPipePath.isEmpty { unlink(cmdPipePath) }
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    /// Launches airplay-cli and opens its command pipe. Playback starts by itself once audio is buffered.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN)
        cmdPipePath = NSTemporaryDirectory() + "Roomfill-\(UUID().uuidString).cmd"
        guard mkfifo(cmdPipePath, 0o600) == 0 else { throw SenderError.fifo(errno) }

        let p = Process()
        p.executableURL = config.binaryURL
        p.arguments = senderArguments(config, cmdPipePath: cmdPipePath)
        let input = Pipe()
        let output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in self?.handleExit() }
        try p.run()
        process = p
        stdinFD = dup(input.fileHandleForWriting.fileDescriptor)
        try? input.fileHandleForWriting.close()

        // The reader end appears once airplay-cli opens the pipe; poll with a non-blocking open.
        let deadline = Date().addingTimeInterval(5)
        while cmdFD < 0 && Date() < deadline && p.isRunning {
            let fd = open(cmdPipePath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                cmdFD = fd
            } else {
                usleep(20_000)
            }
        }
        if cmdFD < 0 {
            p.terminate()
            throw SenderError.commandPipeNotOpened
        }
    }

    /// Writes interleaved s16le samples to airplay-cli's stdin, blocking while its buffer is full.
    /// Returns false once the process has gone away.
    public func writePCM(_ samples: UnsafePointer<Int16>, count: Int) -> Bool {
        guard stdinFD >= 0 else { return false }
        var raw = UnsafeRawPointer(samples)
        var remaining = count * MemoryLayout<Int16>.size
        while remaining > 0 {
            let n = write(stdinFD, raw, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            raw += n
            remaining -= n
        }
        return true
    }

    /// Sends one `KEY=VALUE` line on the command pipe.
    public func send(command: String) {
        lock.lock(); defer { lock.unlock() }
        guard cmdFD >= 0 else { return }
        let line = command + "\n"
        _ = line.withCString { write(cmdFD, $0, strlen($0)) }
    }

    public func setVolume(_ v: Int) {
        send(command: "VOLUME=\(min(max(v, 0), 100))")
    }

    /// Ends the session: asks airplay-cli to stop, waits up to 2 s, then terminates it. Later
    /// `writePCM` calls fail; the stdin descriptor stays open until deinit so it cannot be reused
    /// by another file while a writer thread still holds it.
    public func stop() {
        guard let p = process else { return }
        stopRequested = true
        if p.isRunning {
            send(command: "ACTION=STOP")
            if stopped.wait(timeout: .now() + 2) == .timedOut, p.isRunning { p.terminate() }
        }
        closeCommandPipe()
    }

    private func consume(_ data: Data) {
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<nl]
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            onLog?(line)
            guard let event = parseStatusLine(line) else { continue }
            if case .audioBuffered = event, !startSent {
                startSent = true
                send(command: "START_UNIX_MS=0")
                send(command: "ACTION=START")
            }
            if event == .stopped { stopped.signal() }
            onEvent?(event)
        }
    }

    private func handleExit() {
        stopped.signal()
        closeCommandPipe()
        onExit?(stopRequested)
    }

    private func closeCommandPipe() {
        lock.lock(); defer { lock.unlock() }
        if cmdFD >= 0 { close(cmdFD); cmdFD = -1 }
    }
}
