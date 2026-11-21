import Foundation

/// AirPlay `statusFlags` bit set while a sender has an active session on the receiver.
public let receiverSessionActiveFlag = 0x800

public func receiverIsBusy(statusFlags: Int) -> Bool {
    statusFlags & receiverSessionActiveFlag != 0
}

public struct ReceiverInfo: Equatable, Sendable {
    public var statusFlags: Int
    public var model: String?
}

/// `statusFlags` and `model` from a complete RTSP response to `GET /info`; nil if incomplete or unparsable.
public func parseReceiverInfo(_ response: Data) -> ReceiverInfo? {
    guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let header = String(decoding: response[..<split.lowerBound], as: UTF8.self)
    guard let lengthLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
          let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) else { return nil }
    let body = response[split.upperBound...]
    guard body.count >= length,
          let plist = try? PropertyListSerialization.propertyList(from: Data(body.prefix(length)), format: nil) as? [String: Any]
    else { return nil }
    guard let flags = (plist["statusFlags"] as? NSNumber)?.intValue else { return nil }
    return ReceiverInfo(statusFlags: flags, model: plist["model"] as? String)
}

/// `statusFlags` from a complete RTSP response to `GET /info`; nil if incomplete or unparsable.
public func parseReceiverStatusFlags(_ response: Data) -> Int? {
    parseReceiverInfo(response)?.statusFlags
}

/// Asks the receiver for `/info` and returns its `statusFlags`, or nil on any failure.
/// Blocks for up to `timeout` seconds; call off the main thread.
public func fetchReceiverStatusFlags(_ target: AirPlayTarget, timeout: TimeInterval = 3) -> Int? {
    fetchReceiverInfo(target, timeout: timeout)?.statusFlags
}

/// Asks the receiver for `/info`; nil on any failure. Blocks; call off the main thread.
public func fetchReceiverInfo(_ target: AirPlayTarget, timeout: TimeInterval = 3) -> ReceiverInfo? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(target.ip, String(target.port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    guard connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 else { return nil }
    let request = "GET /info RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: AirPlay/550.10\r\n\r\n"
    guard request.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        data.append(buf, count: n)
        if let info = parseReceiverInfo(data) { return info }
    }
    return nil
}

/// Decides when a soundbar taken by another sender is free again: two idle polls in a row.
public struct TakeoverWatch {
    private var idleStreak = 0

    public init() {}

    /// Returns true when it is time to reconnect.
    public mutating func observe(busy: Bool) -> Bool {
        idleStreak = busy ? 0 : idleStreak + 1
        return idleStreak >= 2
    }
}
