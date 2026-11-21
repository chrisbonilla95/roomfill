import Testing
@testable import RoomfillCore

@Test func parsesRealLog() {
    #expect(parseStatusLine("[STATUS] route protocol=airplay2 flow=native timing=ptp buffered=0") == .route(flow: "native", timing: "ptp"))
    #expect(parseStatusLine("[STATUS] latency lead_ms=2000 device_min_frames=0 device_max_frames=0 device_render_ms=0 warm_lead_ms=600") == .latency(warmLeadMs: 600))
    #expect(parseStatusLine("[STATUS] audio buffered_ms=92") == .audioBuffered(ms: 92))
    #expect(parseStatusLine("[STATUS] connected") == .connected)
    #expect(parseStatusLine("[STATUS] clock_ready mode=ptp state=probing streak_ms=179 exchanges=2 ready_in_ms=2121 ready_at_unix_ms=1795258776186") == .clockReady(state: .probing, readyAtUnixMs: 1795258776186))
    #expect(parseStatusLine("[STATUS] started requested_unix_ms=0 at_unix_ms=1795258773526") == .started(atUnixMs: 1795258773526))
    #expect(parseStatusLine("[STATUS] playing elapsed_ms=756") == .playing(elapsedMs: 756))
    #expect(parseStatusLine("[STATUS] flushed") == .flushed)
    #expect(parseStatusLine("[STATUS] eof") == .eof)
    #expect(parseStatusLine("[STATUS] stopped") == .stopped)
    #expect(parseStatusLine("hello") == nil)
}

@Test func unknownStatusIsOther() {
    #expect(parseStatusLine("[STATUS] capabilities requested=0x40000") == .other("capabilities requested=0x40000"))
}
