import Testing
@testable import RoomfillCore

@Test func releasesOnceAfterTimeoutThenResumes() {
    var m = IdleMonitor(timeout: 300)
    for t in 0..<300 { #expect(m.observe(peak: 0, now: Double(t)) == nil) }
    #expect(m.observe(peak: 0, now: 300) == .release)
    #expect(m.observe(peak: 0, now: 300.5) == nil)
    #expect(m.observe(peak: 0.1, now: 301) == .resume)
    #expect(m.observe(peak: 0.1, now: 302) == nil)
}

@Test func continuousSoundNeverReleases() {
    var m = IdleMonitor(timeout: 300)
    for t in 0..<2000 { #expect(m.observe(peak: 0.1, now: Double(t)) == nil) }
}

@Test func shortSoundResetsTimer() {
    var m = IdleMonitor(timeout: 300)
    for t in 0..<150 { _ = m.observe(peak: 0, now: Double(t)) }
    _ = m.observe(peak: 0.1, now: 150)
    for t in 151..<450 { #expect(m.observe(peak: 0, now: Double(t)) == nil) }
    #expect(m.observe(peak: 0, now: 450) == .release)
}

@Test func quietNoiseCountsAsSilence() {
    var m = IdleMonitor(timeout: 10)
    for t in 0..<10 { _ = m.observe(peak: 1e-6, now: Double(t)) }
    #expect(m.observe(peak: 1e-6, now: 10) == .release)
}

@Test func shorterTimeoutAppliesToSilenceAlreadyElapsed() {
    var m = IdleMonitor(timeout: 300)
    _ = m.observe(peak: 0.1, now: 0)
    #expect(m.observe(peak: 0, now: 100) == nil)
    m.timeout = 60
    #expect(m.observe(peak: 0, now: 101) == .release)
}
