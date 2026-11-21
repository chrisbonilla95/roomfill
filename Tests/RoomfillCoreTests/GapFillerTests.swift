import Testing
@testable import RoomfillCore

@Test func noPaddingWhileDataFlows() {
    var g = GapFiller(threshold: 0.05)
    g.dataArrived(at: 0)
    #expect(g.framesOwed(at: 0.03, rate: 44100) == 0)
}

@Test func padsTheWholeGapOnceThresholdPassed() {
    var g = GapFiller(threshold: 0.05)
    g.dataArrived(at: 10)
    #expect(g.framesOwed(at: 10.1, rate: 44100) == 4410)
    g.padded(4410)
    #expect(g.framesOwed(at: 10.1, rate: 44100) == 0)
    #expect(g.framesOwed(at: 10.3, rate: 44100) == 8820)
}

@Test func newDataResetsTheGap() {
    var g = GapFiller(threshold: 0.05)
    g.dataArrived(at: 0)
    g.padded(1000)
    g.dataArrived(at: 1)
    #expect(g.framesOwed(at: 1.04, rate: 44100) == 0)
    #expect(g.framesOwed(at: 1.1, rate: 44100) == 4410)
}
