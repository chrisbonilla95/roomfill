import Testing
@testable import RoomfillCore

@Test func playingOnlyAfterClockReady() {
    var s = SessionStatus()
    #expect(s.apply(.playing(elapsedMs: 700)) == .connecting)
    #expect(s.apply(.clockReady(state: .probing, readyAtUnixMs: 1)) == .connecting)
    #expect(s.apply(.clockReady(state: .ready, readyAtUnixMs: 1)) == .ready)
    #expect(s.apply(.playing(elapsedMs: 4700)) == .playing)
}

@Test func stalledClockReportsNotResponding() {
    var s = SessionStatus()
    _ = s.apply(.clockReady(state: .ready, readyAtUnixMs: 1))
    _ = s.apply(.playing(elapsedMs: 1000))
    #expect(s.apply(.clockReady(state: .stalled, readyAtUnixMs: 0)) == .notResponding)
    #expect(s.apply(.playing(elapsedMs: 2000)) == .notResponding)
    #expect(s.apply(.clockReady(state: .ready, readyAtUnixMs: 1)) == .ready)
    #expect(s.apply(.playing(elapsedMs: 3000)) == .playing)
}
