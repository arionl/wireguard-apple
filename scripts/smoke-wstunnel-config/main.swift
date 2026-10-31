// SPDX-License-Identifier: MIT
// Copyright © 2026 wireguard-apple-enhanced. All Rights Reserved.
//
// Standalone verification harness for WstunnelConfig (no Xcode test
// target exists upstream).  Compile + run on a Mac:
//
//   swiftc Sources/Shared/Model/WstunnelConfig.swift \
//         scripts/smoke-wstunnel-config.swift -o /tmp/wstunnel-smoke \
//   && /tmp/wstunnel-smoke && echo SMOKE-PASS
//
// WstunnelConfig.swift deliberately imports only Foundation so this
// works without NetworkExtension entitlements.

import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok - \(label)")
    } else {
        failures += 1
        print("FAIL - \(label)")
    }
}

// -- Reference config matches the reference manual command -------------------------
let cfg = WstunnelConfig(
    enabled: true,
    serverUrl: "wss://wstunnel.example.com:443",
    pathPrefix: "mytunnel",
    destHost: "192.0.2.1",
    destPort: 51820,
    localPort: 51820
)

expect(cfg.arguments() == [
    "client",
    "-L", "udp://127.0.0.1:51820:192.0.2.1:51820?timeout_sec=0",
    "--http-upgrade-path-prefix", "mytunnel",
    "wss://wstunnel.example.com:443"
], "arguments match the reference command (loopback bind)")

expect(cfg.serverHost == "wstunnel.example.com", "serverHost parses")
expect(cfg.localEndpoint == "127.0.0.1:51820", "localEndpoint")

// -- JSON roundtrip through the providerConfiguration string -----------------
let json = String(data: try! JSONEncoder().encode(cfg), encoding: .utf8)!
let decoded = try! JSONDecoder().decode(WstunnelConfig.self, from: Data(json.utf8))
expect(decoded == cfg, "JSON roundtrip")
expect(json.contains("\"pathPrefix\":\"mytunnel\""), "JSON carries pathPrefix")

// -- Validation ---------------------------------------------------------------
do { try cfg.validate(); print("ok - validate passes") }
catch { failures += 1; print("FAIL - validate should pass") }

var bad = cfg
bad.serverUrl = "not a url"
expect((try? bad.validate()) == nil && bad.serverHost == nil, "invalid server URL rejected")

bad = cfg
bad.destHost = ""
expect((try? bad.validate()) == nil, "empty destination rejected")

bad = cfg
bad.localPort = 0
expect((try? bad.validate()) == nil, "zero local port rejected")

bad = cfg
bad.serverUrl = "ftp://wstunnel.example.com"
expect(bad.serverHost == nil && (try? bad.validate()) == nil, "non-wss scheme rejected")

// -- Defaults -----------------------------------------------------------------
let d = WstunnelConfig()
expect(d.enabled == false && d.localPort == 51820 && d.destPort == 51820, "defaults")

if failures > 0 {
    print("SMOKE-FAIL: \(failures) failure(s)")
    exit(1)
}
print("SMOKE-PASS")
