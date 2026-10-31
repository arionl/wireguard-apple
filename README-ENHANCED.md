# wireguard-apple-enhanced

An enhanced fork of [WireGuard/wireguard-apple](https://github.com/WireGuard/wireguard-apple)
(the official WireGuard clients for Apple platforms) that adds **WebSocket
tunneling of WireGuard UDP traffic via [wstunnel](https://github.com/erebe/wstunnel)**.

## Why

Some networks (hotel wifi, corporate middleboxes, CGNAT front doors) degrade
or block raw UDP. Tunneling the WireGuard session through a WebSocket (wss/443)
makes it indistinguishable from normal HTTPS browsing.

Reference client command this fork automates:

```
wstunnel client -L 'udp://127.0.0.1:51820:192.0.2.1:51820?timeout_sec=0' \
  --http-upgrade-path-prefix 'mytunnel' wss://wstunnel.example.com:443
```

## What the fork adds (macOS only)

- Per-tunnel **WebSocket Proxy** settings in the tunnel editor
  (server URL, HTTP upgrade path prefix, destination host:port, local port).
- The **wstunnel client is built from source** as part of the app build
  (`scripts/build-wstunnel.sh`, cargo + lipo → universal binary; successful
  builds are cached) and embedded in the app bundle.
- A supervised subprocess (`WstunnelProcessManager`) in the container app:
  started before tunnel activation, restarted on crash (capped backoff),
  stopped with the tunnel. **Activation fails if the websocket tunnel is
  not healthy** — no dead tunnels.
- The peer endpoint is auto-rewritten to `127.0.0.1:<localPort>` when the
  proxy is enabled.
- The proxy server's resolved IPs are applied as **excluded routes**
  (`NEIPv4Settings.excludedRoutes`) so the wss connection itself never
  routes through the VPN.

## Building

Prereqs on the build machine (Mac, Apple Silicon or Intel):
- Xcode (built & verified on Xcode 27.1 / macOS 27)
- Go 1.21+ on PATH (hermetic WireGuardKitGo build)
- Rust via rustup (`curl -sSL https://sh.rustup.rs | sh -s -- -y --profile minimal`)
  — the app build cross-compiles wstunnel v11.1.0 for both arches from
  source (first build ~4 min; cached in `~/.cache/wireguard-enhanced/`,
  later builds ~2s)

```sh
cp Sources/WireGuardApp/Config/Developer.xcconfig.template Sources/WireGuardApp/Config/Developer.xcconfig
#   DEVELOPMENT_TEAM = <your team>, APP_ID_MACOS = <your bundle id>
xcodebuild -project WireGuard.xcodeproj -scheme WireGuardmacOS \
  -configuration Debug -destination "generic/platform=macOS" build
# compile-only without signing: add CODE_SIGNING_ALLOWED=NO
```

For a *runnable* app, open the project in Xcode once with your Apple ID
signed in and let automatic signing register the App IDs/profiles (the
bundle needs Network Extension capability for three ids: app,
.network-extension, .login-item-helper).

## Fork-specific fixes over upstream

- `WireGuardKitC.h`: `#include <sys/types.h>` for the macOS 27 SDK's
  stricter modular headers.

## Status (2026-10-31)

Tasks 1–7 of the implementation plan complete; app builds with the
embedded wstunnel binary. Remaining: E2E validation against
wstunnel.example.com on a GUI Mac (import real tunnel config, verify
handshake through the proxy, excluded routes, crash-restart recovery).

## Limitations

- The container app must be running (menu bar app; enable *Launch at Login*)
  for proxied tunnels — the network extension cannot host the subprocess.
- Server DNS changes mid-session are not re-excluded until re-activation.
- iOS targets are unchanged.
