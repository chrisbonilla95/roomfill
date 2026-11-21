import Foundation
import Testing
@testable import RoomfillCore

@Test func failedRebuildIsRetriedWithSameKey() {
    var gate = RebuildGate()
    #expect(gate.shouldBuild(key: "a", force: false))
    gate.failed()
    #expect(gate.shouldBuild(key: "a", force: false))
    gate.succeeded(key: "a")
    #expect(!gate.shouldBuild(key: "a", force: false))
    #expect(gate.shouldBuild(key: "a", force: true))
    #expect(gate.shouldBuild(key: "b", force: false))
}

@Test func idleActionsIgnoredWhileLost() {
    #expect(!SoundbarFeed.idleActionAllowed(in: .lost("taken")))
    #expect(SoundbarFeed.idleActionAllowed(in: .playing))
    #expect(SoundbarFeed.idleActionAllowed(in: .released))
}

private func fakeCLI() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cliairplay-\(UUID().uuidString)")
    let script = """
    #!/bin/sh
    while [ $# -gt 0 ]; do if [ "$1" = "--cmdpipe" ]; then P=$2; fi; shift; done
    exec 3< "$P"
    echo "[STATUS] audio buffered_ms=5"
    exec cat > /dev/null
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    chmod(url.path, 0o755)
    return url
}

@Test func writesFailCleanlyAfterStopAndFifoIsRemoved() throws {
    let config = SenderConfig(binaryURL: try fakeCLI(), target: AirPlayTarget(ip: "127.0.0.1", port: 1, name: "x"),
                              volume: 10, sampleRate: 44100)
    var sender: AirPlaySender? = AirPlaySender(config: config)
    try sender!.start()
    let fifo = sender!.cmdPipePath
    #expect(FileManager.default.fileExists(atPath: fifo))
    let samples = [Int16](repeating: 0, count: 4096)
    #expect(samples.withUnsafeBufferPointer { sender!.writePCM($0.baseAddress!, count: 4096) })
    sender!.stop()
    var failed = false
    for _ in 0..<50 where !failed {
        failed = !samples.withUnsafeBufferPointer { sender!.writePCM($0.baseAddress!, count: 4096) }
        usleep(20_000)
    }
    #expect(failed)
    sender = nil
    #expect(!FileManager.default.fileExists(atPath: fifo))
}
