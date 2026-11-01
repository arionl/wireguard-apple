// SPDX-License-Identifier: MIT
// Copyright © 2026 wireguard-apple-enhanced. All Rights Reserved.
//
// Supervised lifecycle for the embedded wstunnel client subprocess.
//
// The proxy MUST run in the container app (menu-bar app), not the
// network extension: NE processes are memory-limited and their lifetime
// is controlled by the OS.  This manager:
//   - spawns the bundled wstunnel binary for a tunnel before activation
//   - gates activation on the child being healthy (alive and reporting
//     a listening/connected log line, or alive past the settle window)
//   - restarts crashed children with capped backoff
//   - stops children when their tunnel goes down / app terminates

#if os(macOS)

import Foundation

enum WstunnelProcessError: String, Error {
    case binaryMissing = "wstunnel binary not found in app bundle"
    case notHealthy = "wstunnel did not become healthy"
    case invalidConfig = "invalid wstunnel configuration"
}

final class WstunnelProcessManager {
    static let shared = WstunnelProcessManager()

    private final class Child {
        let process: Process
        let config: WstunnelConfig
        var restarts: Int = 0
        var backoff: TimeInterval = 0.5
        var wanted: Bool = true
        init(process: Process, config: WstunnelConfig) {
            self.process = process
            self.config = config
        }
    }

    /// Tunnel name -> supervised child.  All access on `queue`.
    private var children: [String: Child] = [:]
    private let queue = DispatchQueue(label: "WstunnelProcessManager")

    /// Log lines from wstunnel that indicate the client is up.  Tuned
    /// against the wstunnel version built by scripts/build-wstunnel.sh;
    /// extend after observing real output if activation gating misfires.
    private static let readinessPatterns: [NSRegularExpression] = [
        "listen", "connected", "session"
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private init() {}

    func isRunning(tunnelName: String) -> Bool {
        queue.sync(execute: { children[tunnelName]?.wanted == true && children[tunnelName]?.process.isRunning == true })
    }

    /// Spawn the proxy for a tunnel and wait until it is healthy.
    /// Throws if the child exits or never reports readiness.  Safe to
    /// call again for the same tunnel (recycles the previous child).
    func start(config: WstunnelConfig, tunnelName: String,
               timeout: TimeInterval = 5.0) async throws {
        do { try config.validate() } catch {
            wg_log(.error, message: "WST[\(tunnelName)]: invalid config — \(error)")
            throw WstunnelProcessError.invalidConfig
        }
        // Embedded by the build phase next to the app executable.
        // (Bundle.url(forResource:) only searches Contents/Resources —
        // it can never find Contents/MacOS.)
        let binaryURL = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("wstunnel")
        guard let binaryURL, FileManager.default.fileExists(atPath: binaryURL.path) else {
            wg_log(.error, message: "WST[\(tunnelName)]: binary missing from app bundle")
            throw WstunnelProcessError.binaryMissing
        }

        stop(tunnelName: tunnelName)   // idempotent recycling

        let gate = WstunnelReadinessGate(patterns: Self.readinessPatterns)
        let p = Process()
        p.executableURL = binaryURL
        // Diagnostic verbosity: default INFO for library noise, DEBUG for
        // wstunnel/rustls internals so TLS/websocket failures are visible
        // in the app log (EnvFilter syntax).
        p.arguments = config.arguments() + ["--log-lvl", "info,wstunnel=debug,rustls=debug"]
        p.standardOutput = logPipe(tunnelName: tunnelName, severity: "info", gate: gate)
        p.standardError = logPipe(tunnelName: tunnelName, severity: "warn", gate: gate)
        p.qualityOfService = .userInitiated

        wg_log(.info, message: "WST[\(tunnelName)]: launching: \(p.arguments!.joined(separator: " "))")
        do { try p.run() } catch {
            wg_log(.error, message: "WST[\(tunnelName)]: spawn failed — \(error)")
            throw error
        }
        queue.sync { children[tunnelName] = Child(process: p, config: config) }
        p.terminationHandler = { [weak self] process in
            self?.childTerminated(tunnelName: tunnelName, process: process)
        }

        // Health gate: a readiness log line, or alive past the settle
        // window (UDP listener binds before the websocket connects).
        let healthy: Bool = await gate.waitUntilReady(
            settle: 1.5,
            timeout: timeout,
            processAlive: { [weak p] in p?.isRunning ?? false })
        if !healthy {
            wg_log(.error, message: "WST[\(tunnelName)]: not healthy within \(timeout)s — giving up")
            stop(tunnelName: tunnelName)
            throw WstunnelProcessError.notHealthy
        }
        wg_log(.info, message: "WST[\(tunnelName)]: healthy")
    }

    /// Stop the proxy for a tunnel.  No restart will be scheduled.
    func stop(tunnelName: String) {
        let child: Child? = queue.sync {
            guard let c = children[tunnelName] else { return nil }
            c.wanted = false
            children.removeValue(forKey: tunnelName)
            return c
        }
        guard let p = child?.process, p.isRunning else { return }
        p.terminationHandler = nil
        p.terminate()   // SIGTERM
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if p.isRunning {
            wg_log(.error, message: "WST[\(tunnelName)]: SIGTERM ignored — SIGKILL")
            kill(p.processIdentifier, SIGKILL)
        }
        wg_log(.info, message: "WST[\(tunnelName)]: stopped")
    }

    func stopAll() {
        for name in queue.sync(execute: { children.keys }) { stop(tunnelName: name) }
    }

    // MARK: - Crash restart

    private func childTerminated(tunnelName: String, process: Process) {
        let child = queue.sync { children[tunnelName] }
        guard let child, child.process === process else { return }

        wg_log(.error, message: "WST[\(tunnelName)]: exited unexpectedly (status \(process.terminationStatus))")
        guard child.wanted else { return }

        child.restarts += 1
        guard child.restarts <= 5 else {
            wg_log(.error, message: "WST[\(tunnelName)]: restart storm — giving up")
            queue.sync { children.removeValue(forKey: tunnelName) }
            return
        }
        let delay = child.backoff
        child.backoff = min(child.backoff * 2, 8)
        let config = child.config
        wg_log(.info, message: "WST[\(tunnelName)]: restarting in \(String(format: "%.1f", delay))s (attempt \(child.restarts))")

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.queue.sync(execute: { self.children[tunnelName] }) === child else { return }
            Task {
                // start() recycles the dead child entry and re-gates health.
                try? await self.start(config: config, tunnelName: tunnelName)
            }
        }
    }

    // MARK: - Output logging

    private func logPipe(tunnelName: String, severity: String, gate: WstunnelReadinessGate) -> Pipe {
        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        let src = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: DispatchQueue.global())
        src.setEventHandler {
            let data = handle.availableData
            guard !data.isEmpty else { src.cancel(); return }
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                wg_log(.info, message: "WST[\(tunnelName)][\(severity)]: \(line)")
                gate.observe(line: String(line))
            }
        }
        src.resume()
        return pipe
    }
}

// MARK: - Readiness gate

/// Ready when a wstunnel log line matches a readiness pattern, or when
/// the process has simply stayed alive past the settle window.
private final class WstunnelReadinessGate: @unchecked Sendable {
    private let patterns: [NSRegularExpression]
    private let lock = NSLock()
    private var sawReadyLine = false

    init(patterns: [NSRegularExpression]) { self.patterns = patterns }

    func observe(line: String) {
        guard !sawReadyLine else { return }
        for re in patterns
        where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            lock.lock(); sawReadyLine = true; lock.unlock()
            return
        }
    }

    func waitUntilReady(settle: TimeInterval, timeout: TimeInterval,
                        processAlive: () -> Bool) async -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if sawReadyLine { return true }
            if !processAlive() { return false }
            if Date().timeIntervalSince(t0) > settle, processAlive() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return sawReadyLine && processAlive()
    }
}

// MARK: - Host resolution

/// getaddrinfo wrapper: all A/AAAA records for a host.  Synchronous —
/// call off the main thread.
enum HostResolver {
    static func ips(forHost host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM // one entry per address, not per socket type
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var ips = Set<String>()
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let p = ai {
            if let addr = p.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                // inet_ntop needs a pointer to the embedded in_addr /
                // in6_addr — NOT the sockaddr itself (its first bytes are
                // len/family/port and produce garbage addresses).
                switch p.pointee.ai_family {
                case AF_INET:
                    let sa = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self)
                    withUnsafePointer(to: sa.pointee.sin_addr) {
                        _ = inet_ntop(AF_INET, $0, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    }
                case AF_INET6:
                    let sa = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self)
                    withUnsafePointer(to: sa.pointee.sin6_addr) {
                        _ = inet_ntop(AF_INET6, $0, &buffer, socklen_t(INET6_ADDRSTRLEN))
                    }
                default:
                    break
                }
                if buffer[0] != 0 {
                    ips.insert(String(cString: buffer))
                }
            }
            ai = p.pointee.ai_next
        }
        return ips.sorted()
    }
}

#endif
