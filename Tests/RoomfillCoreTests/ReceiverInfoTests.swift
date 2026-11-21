import Foundation
import Testing
@testable import RoomfillCore

private func rtspResponse(statusFlags: Int) throws -> Data {
    let body = try PropertyListSerialization.data(fromPropertyList: ["statusFlags": statusFlags, "name": "Soundbar"],
                                                  format: .binary, options: 0)
    var d = Data("RTSP/1.0 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/x-apple-binary-plist\r\nCSeq: 1\r\n\r\n".utf8)
    d.append(body)
    return d
}

@Test func parsesStatusFlagsFromInfoResponse() throws {
    #expect(parseReceiverStatusFlags(try rtspResponse(statusFlags: 0x804)) == 0x804)
    #expect(parseReceiverStatusFlags(try rtspResponse(statusFlags: 0x4)) == 0x4)
}

@Test func incompleteOrGarbageResponseIsNil() throws {
    let full = try rtspResponse(statusFlags: 0x4)
    #expect(parseReceiverStatusFlags(full.prefix(full.count - 3)) == nil)
    #expect(parseReceiverStatusFlags(Data("hello".utf8)) == nil)
}

@Test func busyBitIsSessionActive() {
    #expect(receiverIsBusy(statusFlags: 0x804))
    #expect(!receiverIsBusy(statusFlags: 0x4))
}

@Test func reconnectAfterTwoIdlePolls() {
    var w = TakeoverWatch()
    let results = [true, false, true, false, false].map { w.observe(busy: $0) }
    #expect(results == [false, false, false, false, true])
}

@Test func parsesModelFromInfoResponse() throws {
    let body = try PropertyListSerialization.data(fromPropertyList: ["statusFlags": 4, "model": "HW-Q800D"], format: .binary, options: 0)
    var d = Data("RTSP/1.0 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    d.append(body)
    #expect(parseReceiverInfo(d)?.model == "HW-Q800D")
    #expect(parseReceiverInfo(d)?.statusFlags == 4)
}
