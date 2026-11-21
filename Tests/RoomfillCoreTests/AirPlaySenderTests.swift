import Foundation
import Testing
@testable import RoomfillCore

@Test func argumentsMatchProvenInvocation() {
    let config = SenderConfig(binaryURL: URL(fileURLWithPath: "/bin/cliairplay"),
                              target: AirPlayTarget(ip: "192.0.2.10", port: 42419, name: "Soundbar"),
                              volume: 45, sampleRate: 44100)
    #expect(senderArguments(config, cmdPipePath: "/tmp/x") == [
        "--protocol", "airplay2", "--ptp", "--port", "42419", "--volume", "45", "--name", "Roomfill",
        "--samplerate", "44100", "--bitdepth", "16", "--channels", "2", "--cmdpipe", "/tmp/x", "192.0.2.10",
    ])
}
