# Packet proxy engine

Settings → Proxy runs the Packet Rust client **inside the app** as a loopback SOCKS5
listener. There is no NetworkExtension and no VPN profile.

## The proxy is a hop, not a transport

`transportMode` has three values: `direct`, `bridge_text`, `offline`. The proxy is
orthogonal to all of them — it only changes *where the bytes go*, never the chat protocol,
the message types, or the socket implementation.

| key | meaning |
| --- | --- |
| `packetProxyEnabled` | the Use Proxy switch, mirrored into the engine config |
| `packetProxyHost` / `packetProxyPort` | where the engine bound its SOCKS listener |
| `packetStatus` / `packetLastError` | last start result, for the sheet |

`PacketProxyRoute.current()` is the single resolver. Two consumers:

- `VibeHTTP.shared` — the app's HTTP session. `URLSession.shared` when the proxy is off,
  a SOCKS-configured session when it is on. Pooled and rebuilt when the port changes.
- `ChatPhoenixClient.makeURLSessionConfiguration` — the Phoenix socket and every pinned
  request built through it.

`ChatEngine` will not open the socket while the proxy is on but has not bound a port; it
starts the engine and retries. It never falls back to direct — a proxy the user switched on
must not be bypassed.

## Removed: the mesh

The old `packet_mesh` transport (bridge bundle, peer descriptors, ticket, `text_only_v1`
media blocking, 384 KB image / 2 MB voice caps, `phantom_start_mesh`) is gone. Legacy
sessions carrying `transportMode=packet_mesh` migrate to `direct` at launch.
`/packet/bootstrap` is still fetched, but only for the proxy entries the server offers.

## Start paths

`PacketProxyEngine.start(profile:)` picks the FFI entry point from the profile's stack:

| stack | FFI |
| --- | --- |
| `directSock` | `phantom_start_layered_carrier_full` |
| `packetChain` | carrier first, then native |
| `packetNative` | `phantom_start_full`, or `phantom_start` for a plain start |

Transport raw values are read by the Rust side — `reality` must stay `7`.

## Rebuilding the vendored engine

`ios/Vendor/Packet/**/*.a` is gitignored (~240 MB). A fresh clone must build it:

```sh
cd ~/Desktop/packet
./scripts/build-ios.sh            # phantom_client + packet_xray, arm64 device + sim
./scripts/copy-vibe-artifacts.sh  # copies both archives into ios/Vendor/Packet
```

`libpacket_xray.a` only exists for arm64 (device + sim); the x86_64 sim slice is built
without `--features embedded-xray`, so REALITY is unavailable there.
