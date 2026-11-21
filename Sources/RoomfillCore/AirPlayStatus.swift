import Foundation

public enum ClockState: String, Equatable {
    case cold, probing, ready, stalled
}

/// One `[STATUS]` line from airplay-cli.
public enum AirPlayEvent: Equatable {
    case route(flow: String, timing: String)
    case latency(warmLeadMs: Int)
    case audioBuffered(ms: Int)
    case connected
    case clockReady(state: ClockState, readyAtUnixMs: UInt64)
    case started(atUnixMs: UInt64)
    case playing(elapsedMs: Int)
    case flushed
    case eof
    case stopped
    case other(String)
}

/// Parses an airplay-cli output line; nil when it is not a `[STATUS]` line.
public func parseStatusLine(_ line: String) -> AirPlayEvent? {
    guard let marker = line.range(of: "[STATUS]") else { return nil }
    let rest = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
    let words = rest.split(separator: " ")
    guard let kind = words.first else { return .other(rest) }
    var kv: [String: String] = [:]
    for w in words.dropFirst() {
        let pair = w.split(separator: "=", maxSplits: 1)
        if pair.count == 2 { kv[String(pair[0])] = String(pair[1]) }
    }
    switch kind {
    case "route":
        if let flow = kv["flow"], let timing = kv["timing"] { return .route(flow: flow, timing: timing) }
    case "latency":
        if let v = kv["warm_lead_ms"].flatMap(Int.init) { return .latency(warmLeadMs: v) }
    case "audio":
        if let v = kv["buffered_ms"].flatMap(Int.init) { return .audioBuffered(ms: v) }
    case "connected": return .connected
    case "clock_ready":
        if let s = kv["state"].flatMap(ClockState.init(rawValue:)),
           let at = kv["ready_at_unix_ms"].flatMap(UInt64.init) { return .clockReady(state: s, readyAtUnixMs: at) }
    case "started":
        if let at = kv["at_unix_ms"].flatMap(UInt64.init) { return .started(atUnixMs: at) }
    case "playing":
        if let v = kv["elapsed_ms"].flatMap(Int.init) { return .playing(elapsedMs: v) }
    case "flushed": return .flushed
    case "eof": return .eof
    case "stopped": return .stopped
    default: break
    }
    return .other(rest)
}

/// Session state as seen from airplay-cli events: audio only counts as playing once the
/// receiver's clock is locked, because before that the receiver may render late or not at all.
public struct SessionStatus {
    public private(set) var state: SoundbarState = .connecting
    private var clockReady = false

    public init() {}

    public mutating func apply(_ event: AirPlayEvent) -> SoundbarState {
        switch event {
        case .clockReady(state: .ready, _):
            clockReady = true
            state = .ready
        case .clockReady(state: .stalled, _):
            clockReady = false
            state = .notResponding
        case .playing:
            if clockReady { state = .playing }
        default:
            break
        }
        return state
    }
}
