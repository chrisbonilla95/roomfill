import Testing
@testable import RoomfillCore

@Test func fourCCRoundTrip() {
    #expect(fourCC(0x64707274) == "dprt")
}
