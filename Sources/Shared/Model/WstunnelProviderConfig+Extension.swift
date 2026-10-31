// SPDX-License-Identifier: MIT
// Copyright © 2026 wireguard-apple-enhanced. All Rights Reserved.
//
// Per-tunnel wstunnel proxy settings ride the provider configuration
// alongside the UID.  IMPORTANT: providerConfiguration is reassigned
// wholesale elsewhere (see migrateConfigurationIfNeeded); always use
// these accessors, which merge keys, never clobber the dictionary.

import NetworkExtension

extension NETunnelProviderProtocol {
    private static let wstunnelConfigKey = "wstunnelConfig"
    private static let wstunnelExcludeIPsKey = "wstunnelExcludeIPs"

    /// wstunnel proxy settings for this tunnel (nil = no proxy).
    var wstunnelConfig: WstunnelConfig? {
        get {
            guard let json = providerConfiguration?[Self.wstunnelConfigKey] as? String else { return nil }
            return try? JSONDecoder().decode(WstunnelConfig.self, from: Data(json.utf8))
        }
        set {
            var pc = providerConfiguration ?? [:]
            if let newValue = newValue, let data = try? JSONEncoder().encode(newValue) {
                pc[Self.wstunnelConfigKey] = String(data: data, encoding: .utf8)
            } else {
                pc.removeValue(forKey: Self.wstunnelConfigKey)
            }
            providerConfiguration = pc
        }
    }

    /// IPs of the websocket server resolved at activation time, used by
    /// the packet-tunnel-provider as excluded routes so the wss
    /// connection never routes through the VPN itself.  Written by the
    /// app before/at activation.
    var wstunnelExcludeIPs: [String] {
        get {
            (providerConfiguration?[Self.wstunnelExcludeIPsKey] as? [String]) ?? []
        }
        set {
            var pc = providerConfiguration ?? [:]
            if newValue.isEmpty {
                pc.removeValue(forKey: Self.wstunnelExcludeIPsKey)
            } else {
                pc[Self.wstunnelExcludeIPsKey] = newValue
            }
            providerConfiguration = pc
        }
    }
}
