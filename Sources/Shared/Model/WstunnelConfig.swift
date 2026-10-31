// SPDX-License-Identifier: MIT
// Copyright © 2026 wireguard-apple-enhanced. All Rights Reserved.
//
// Per-tunnel configuration for the wstunnel WebSocket proxy.
//
// Reference client invocation (reference working manual setup):
//   wstunnel client -L 'udp://51820:192.0.2.1:51820?timeout_sec=0' \
//     --http-upgrade-path-prefix 'mytunnel' wss://wstunnel.example.com:443
//
// The in-app variant binds the local UDP listener to LOOPBACK only.

import Foundation

struct WstunnelConfig: Codable, Equatable {
    /// Proxy is active for this tunnel.
    var enabled: Bool = false
    /// WebSocket server URL, e.g. "wss://wstunnel.example.com:443".
    var serverUrl: String = ""
    /// HTTP upgrade path prefix configured on the server.
    var pathPrefix: String = ""
    /// Destination address of the WireGuard server *as reachable from
    /// the wstunnel server* (forwarded through the websocket).
    var destHost: String = ""
    var destPort: UInt16 = 51820
    /// Local UDP port wstunnel binds on loopback.  While the proxy is
    /// enabled, the tunnel's peer endpoint is rewritten to
    /// 127.0.0.1:<localPort>.
    var localPort: UInt16 = 51820

    enum ValidationError: Error, Equatable {
        case invalidServerUrl
        case invalidDestinationHost
        case invalidPort(String)
    }

    /// Hostname of the websocket server, parsed from `serverUrl`
    /// (accepts wss:// and https:// schemes).  Nil when unparseable —
    /// this is what gets resolved and excluded from VPN routes.
    var serverHost: String? {
        guard let url = URL(string: serverUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return host
    }

    /// The endpoint WireGuard must use while the proxy is enabled.
    var localEndpoint: String { "127.0.0.1:\(localPort)" }

    /// Full argv for the wstunnel client subprocess.
    func arguments() -> [String] {
        [
            "client",
            "-L", "udp://127.0.0.1:\(localPort):\(destHost):\(destPort)?timeout_sec=0",
            "--http-upgrade-path-prefix", pathPrefix,
            serverUrl
        ]
    }

    /// Throws `ValidationError` unless the config is usable.
    func validate() throws {
        guard serverHost != nil else { throw ValidationError.invalidServerUrl }
        guard !destHost.isEmpty, !destHost.contains("/"), !destHost.contains(" ") else {
            throw ValidationError.invalidDestinationHost
        }
        guard localPort > 0 else { throw ValidationError.invalidPort("localPort") }
        guard destPort > 0 else { throw ValidationError.invalidPort("destPort") }
    }
}
