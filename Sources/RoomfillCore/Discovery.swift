import Foundation
import Network

public enum DiscoveryError: Error, Equatable {
    case notFound(String)
    case timeout
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let finish: (T) -> Void
    init(_ finish: @escaping (T) -> Void) { self.finish = finish }
    func fire(_ value: T) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { finish(value) }
    }
}

/// Instance names of `_airplay._tcp` services seen within `timeout` seconds.
public func browseAirPlayReceivers(timeout: TimeInterval) async -> [String] {
    await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        let queue = DispatchQueue(label: "Roomfill.browse")
        let names = Box(Set<String>())
        let once = OneShot<[String]> { cont.resume(returning: $0.sorted()) }
        browser.browseResultsChangedHandler = { results, _ in
            for r in results { if case let .service(name, _, _, _) = r.endpoint { names.value.insert(name) } }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            browser.cancel()
            once.fire(Array(names.value))
        }
    }
}

/// Resolves the named `_airplay._tcp` service to an IPv4 address and port.
public func resolveAirPlayReceiver(named name: String, timeout: TimeInterval) async throws -> AirPlayTarget {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AirPlayTarget, Error>) in
        let queue = DispatchQueue(label: "Roomfill.resolve")
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        let connection = Box<NWConnection?>(nil)
        let once = OneShot<Result<AirPlayTarget, Error>> { result in
            browser.cancel()
            connection.value?.cancel()
            cont.resume(with: result)
        }
        browser.browseResultsChangedHandler = { results, _ in
            guard connection.value == nil,
                  let match = results.first(where: {
                      if case let .service(n, _, _, _) = $0.endpoint { return n == name } else { return false }
                  }) else { return }
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let c = NWConnection(to: match.endpoint, using: params)
            connection.value = c
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = c.currentPath?.remoteEndpoint {
                        var ip = "\(host)"
                        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                        once.fire(.success(AirPlayTarget(ip: ip, port: Int(port.rawValue), name: name)))
                    }
                case .failed(let e):
                    once.fire(.failure(e))
                default:
                    break
                }
            }
            c.start(queue: queue)
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            once.fire(.failure(connection.value == nil ? DiscoveryError.notFound(name) : DiscoveryError.timeout))
        }
    }
}
