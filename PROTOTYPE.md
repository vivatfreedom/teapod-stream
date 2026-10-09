# TeapodStream: Go and experimental Rust builds

The default build uses Go/teapod-core. The separate Rust build uses
**xray-rust 0.7.0** and its direct TUN file-descriptor backend.
Rust application ID: `com.teapodstream.rustprobe`. It installs alongside the original TeapodStream.
No live VPN profile or credentials are bundled.

## Rust support (1.6.6-rust.7)

- VLESS with `encryption=none` over TCP/RAW, WebSocket, HTTPUpgrade, gRPC,
  XHTTP/SplitHTTP. TLS is supported on all these carriers; REALITY on TCP/RAW,
  gRPC and XHTTP/SplitHTTP.
- `xtls-rprx-vision` and `xtls-rprx-vision-udp443` work over TCP/RAW + REALITY.
  With `encryption=none`, Vision is rejected on WS/HTTPUpgrade/gRPC/XHTTP.
- TLS + Vision is deliberately gated: the pinned native TLS transport retains
  outer TLS decoding in direct mode and the local reference test reproduces EOF
  after the inner TLS handshake. Ordinary TLS without Vision and REALITY + Vision
  passed the same payload test. No transport/crypto patch is applied here.
- TLS certificate verification remains enabled. `pinSHA256` accepts SHA-256 of
  the full DER certificate as hex (including colon-separated hex) or base64;
  the Rust config uses `pinnedPeerCertSha256`. `allowInsecure` without a pin and
  ECH are rejected.
- XHTTP `auto` / `packet-up` / `stream-up` / `stream-one`, host/path/extra,
  REALITY SNI, fingerprint, public key, short ID and spiderX.
- Hysteria 2 (`hy2://`, `hysteria2://`) without Salamander or port hopping; see
  [Hysteria 2 in the Rust build](#hysteria-2-in-the-rust-build-166-rust7).
- Direct TUN, TCP/UDP, Android per-app inclusion/exclusion, existing reconnect
  and TUN-sink kill-switch paths.
- DNS through the VPN or direct. App queries always go to the core's DNS
  outbound, which answers A/AAAA through the DNS module with the selected
  server (other query types get an empty NOERROR). In direct mode the module
  (`dns-module`) is routed to `direct`: the selected server is queried outside
  the tunnel through protected sockets, for app lookups and for the core's own
  (IP rules, direct destinations). Go instead forwards port 53 to 1.1.1.1 and
  resolves through `localhost`; xray-rust reads `localhost` as a server named
  localhost:53, and the StaticOnly bootstrap has no system resolver. A custom
  DNS server given by name is resolved by Android into `dns.hosts` before TUN
  starts (presets carry their IP); without it StaticOnly returns SERVFAIL.
- Ad blocking: the DNS outbound answers `geosite:category-ads-all` and
  `geosite:win-spy` (Go's list) with an empty NOERROR, as Go's
  `rcode://success` server does, which xray-rust rejects. It applies with
  FakeDNS and in direct DNS mode too; Go's direct mode skips ad blocking.
  xray-rust 0.7.0 caps a config at 250,000 domain matchers shared by routing
  and DNS-outbound rules, and ad blocking alone expands to about 187k
  (category-ads-all 186,402 + win-spy 327 in the bundled snapshot). Ad blocking
  together with a GeoSite rule on `cn`, `china-list` (about 111k each) or
  `category-ads-all` is therefore rejected before VPN startup. category-ads-all
  is also at 93% of the core's per-category cap of 200,000 entries: a
  Loyalsoldier update growing it by about 7% would stop every ad-blocking start.
- App selection is enforced only by Android's VPN UID ranges. The Rust core has
  no per-flow owner check like Go's tun2socks validator, so in both split-tunnel
  modes an app outside the VPN that binds a socket to `tun0` (SO_BINDTODEVICE,
  kernel 5.7+) is not blocked, and the tethering toggle is disabled.
- GeoIP, GeoSite, domain suffixes, individual sites and Russian-service lists.
  BYPASS sends matches directly; ONLY sends matches through VLESS. FULL disables
  destination rules. The app selection is applied by Android before these rules.
- The bundled Loyalsoldier databases are the checksum-pinned 202609082347 snapshot.
  The existing routing screen downloads updates. A complete candidate pair is
  validated through Rust before an atomic pointer selects it; failure retains
  the prior pair. Reconnect VPN to apply new rules or databases.
- Domain routing enables bounded FakeDNS automatically (4096 addresses, 300-second
  leases) to retain domain identity through TUN. Keep domain detection enabled.
  Apps then get FakeDNS answers in both DNS modes; direct mode applies to the
  core's own lookups. Applications using their own encrypted DNS or cached real IPs
  may evade GeoSite matching; turn off their secure-DNS override and restart them
  after changing routing. FakeDNS returns IPv4 and suppresses AAAA in this mode.
- Heartbeat: the SOCKS probe (custom `http://` and `https://` targets; HTTPS
  runs TLS with certificate and hostname checks inside the SOCKS tunnel) and
  PASSIVE. Liveness uses the core's live TUN counters: data counts as received
  only when TCP/UDP remote read bytes grow, not when the core writes its own
  DNS/FakeDNS answers, ICMP replies or TCP control packets. As in Go, an exited
  TUN fd read/write loop reconnects, and the TUN stall watchdog runs the failure
  action after 120 s without received data while at least 2 TUN flows are open.
  For the watchdog only, TCP payload the outbound accepted also counts as
  activity: xray-rust ACKs an app's upload locally, while Go's tun2socks
  refreshes on every TUN write (including those ACKs), so a reply-less upload
  over 2 minutes (HTTP/1.1 PUT, FTP STOR) would otherwise reconnect. UDP sends
  never block and do not count; the probe-skip freshness check stays read-only.
  PASSIVE runs only these checks, with no probe in the loop or on screen wake.
  XRAYDELAY (in-core measurement) is gated and a stored XRAYDELAY is sent as SOCKS.
- When failed heartbeats switch configurations, Rust checks candidates with a
  TCP ping and considers only profiles it supports; Go measures them through a
  temporary core instance.

The Rust build requires MTU 1500, UDP enabled and QUIC blocking disabled.
Proxy-only mode, raw Xray JSON, legacy mux and fragmentation (VLESS), noise and
other proxy protocols are rejected with an error before VPN startup. ICMP
handling is the Rust core's local synthetic behavior; it is not a remote ping
measurement.

Packet path: Android TUN → Rust userspace stack → VLESS/XHTTP/REALITY or Hysteria 2.
A no-auth SOCKS listener on `127.0.0.1` supports the app's heartbeat and IP check.
Device TUN traffic does not traverse this listener. SOCKS credentials settings
do not apply to this experimental build. Speed and totals come from the core's
live TUN payload counters (bytes written to and read from outbounds, proxy and
direct), not tun2socks IP-byte counters; the per-outbound snapshot in the
diagnostics counts closed connections only.

## Hysteria 2 in the Rust build (1.6.6-rust.7)

- `hy2://` / `hysteria2://` profiles run on the core's Hysteria 2 client:
  `protocol: hysteria`, stock QUIC TLS with ALPN `h3`, password auth (1–4096
  bytes, no control characters), default BBR. The core keeps one QUIC
  connection per server with fixed budgets of 64 concurrent TCP streams and
  32 UDP sessions for the whole device: a further connection fails at once
  until one closes. UDP is carried in 1200-byte QUIC datagrams and fragmented
  above that.
- Rejected before VPN startup with an explanation: Salamander `obfs`, port
  hopping (a port range/list or `mport`), Brutal/bandwidth and other QUIC
  overrides, and noise (it needs `sockopt.dialerProxy`). Mux and fragmentation
  do not apply to Hysteria 2 in either build and do not block it.
- `pinSHA256` (hex, colon-hex or base64 of the leaf certificate's SHA-256) is
  written as hex `pinnedPeerCertSha256` by both builders: it is also the only
  pin key of Xray-core `1aabe7ea` (teapod-core 1.1.15), which silently ignored
  the earlier Go `pinnedPeerCertificateChainSha256` key (this fix applies to
  both builds). TLS fingerprint and ALPN overrides are dropped, as QUIC TLS is
  not shaped.
- A certificate pin wins over `allowInsecure` (`insecure=1`), for Hysteria 2
  and VLESS TLS, in both builds: such a profile is built with
  `allowInsecure: false` and the pin, so only the pinned certificate is
  accepted (Xray-core `1aabe7ea` refuses `allowInsecure: true` outright). Rust
  still rejects `allowInsecure` without a pin.
- Routing, FakeDNS and DNS are the same as for VLESS; domain destinations are
  passed to the server. Android resolves every VLESS `vnext` and Hysteria
  server name into `dns.hosts` before TUN starts, under one 5-second budget;
  IP-literal servers are used as is.
- Share links: `host:port/?…` keeps its port. A port range or list
  (`20000-30000`, `443,5000-6000`) or `mport` keeps the first port in `port`
  and the specification in `hopPorts`, instead of silently becoming 443 (this
  parser fix applies to both builds). An unreadable `mport` (for example
  sing-box's `20000:30000`) is ignored when the link's own port is valid, as
  before, so such a profile still imports with that port. The Go build passes it to Xray-core as
  `finalmask.quicParams.udpHop.ports` (format checked against Xray-core
  `1aabe7ea` used by teapod-core 1.1.15 and v26.7.28).
- `scripts/test-rust-transports.py` adds two Hysteria 2 cases (pin, and
  `insecure=1` + pin) against the pinned Xray 26.7.28 `hysteria` inbound, each
  with TCP, inner-TLS and SOCKS UDP echo (64/1000/3000 bytes);
  `TEAPOD_INTEROP_HYSTERIA_ONLY=1` runs only them.

Verification for 1.6.6-rust.7:

- 152 Flutter tests passed in each build mode; analysis has only the three
  existing `onReorder` deprecation infos.
- Rust configs exported through the production builder were accepted by
  `xray-rust config check` across Hysteria 2 and VLESS profiles, routing modes,
  DNS presets, direct/proxy DNS and ad blocking; the expected Hysteria 2
  rejections (Salamander, port hopping, Go pin key, `allowInsecure` without a
  pin) were confirmed against the core. On the host, ad-blocked domains got an
  empty NOERROR and direct DNS resolved outside the tunnel.
- On the API 36 emulator: all 10 VLESS combinations and both Hysteria 2 cases
  (TCP, inner TLS and SOCKS UDP echo) against Xray-core 26.7.28; the 6
  GeoIP/GeoSite tests and the new TUN counter test.
- The release APK installed over rust.6 kept its profile. Through the installed
  APK's TUN, a different UID (shell, 2000) downloaded and SHA-256-verified
  64 MiB over xHTTP/TLS, and 8 MiB plus 64 MiB over Hysteria 2. During the
  64 MiB transfer the home screen totals grew live (29.6 → 58.6 → 64.0 MB).
  Disconnecting through the UI removed `tun0`.
- Release APKs keep the rust.4–rust.6 signing certificate, raise the version
  code (12610/14610), pass 16 KiB alignment checks and package the same
  xray-rust 0.7.0 core as rust.6.
- Not covered by these tests: heavy browsing against the 64-stream Hysteria 2
  limit, screen-off soak for the stall watchdog, and PASSIVE on a phone.

## Build selection and feature flags

`TEAPOD_CORE` is a compile-time flag, with `go` as the default. Flutter forwards
it to Gradle in `dart-defines`; Gradle selects exactly one native source set and
dependency. Native `getEngine` is checked before connecting, rejecting a stale or
mismatched frontend/native build. There is no runtime switch between engines.

```sh
# Original Go core; Rust/rustup is not needed.
JAVA_HOME=/path/to/jdk17 ./build.sh release
./build.sh test

# Experimental Rust core; installs alongside Go and upgrades earlier Rust Probe versions.
JAVA_HOME=/path/to/jdk17 ./build-rust.sh release
./build-rust.sh test
```

Artifacts are copied to `build/artifacts/go/` and `build/artifacts/rust/`.
Go builds include arm64, armv7 and x86_64; Rust builds include arm64 and x86_64.
Both are release builds with AOT/R8; they currently use the local Android debug
signing key. A published release signing setup is a separate task.

For direct Flutter commands, prepare dependencies first:

```sh
./build-rust.sh binaries
flutter build apk --release --dart-define=TEAPOD_CORE=rust \
  --target-platform android-arm64,android-x64 --split-per-abi \
  --build-name=1.6.6-rust.7 --build-number=10610

# Native Android binding tests use the same base64-encoded Flutter flag.
cd android
JAVA_HOME=/path/to/jdk17 ./gradlew :xraymobile:connectedDebugAndroidTest \
  -Pdart-defines=VEVBUE9EX0NPUkU9cnVzdA==
```

`lib/core/constants/core_features.dart` is the per-core feature matrix.
Unsupported controls remain visible inside `FeatureGate`, with interaction and
keyboard focus disabled and an explanation. Imported incompatible settings have
an explicit reset action. The config builder still rejects unsupported values;
a UI change alone cannot bypass validation. Go exposes its existing controls.
Rust's upstream update buttons are gated; its source link points at this fork.

Shared requirements: Flutter/Dart compatible with `pubspec.yaml`, Android SDK,
NDK 28.2.13676358, CMake 3.22.1, Python 3 and JDK 17 (or a compatible JDK).
Rust additionally needs rustup; its first build installs Rust 1.96.0 and the
Android targets. `JAVA_HOME` is honored without changing global Flutter settings.

`fetch-go-core.py` downloads checksum-pinned teapod-core 1.1.15. Both builds use
the same checksum-pinned geodata assets. `build-rust-core.py` builds the pinned,
unmodified Rust source and refuses a checkout with local changes. See
[Android binding notes](android/xraymobile/README.md).

The original Go service is preserved in `android/app/src/go/`; the tested Rust
service and geodata adapter are in `android/app/src/rust/`. Notifications and
service interfaces remain compatible with the shared UI. Future lifecycle fixes
must be evaluated for both implementations.

Controlled battery savings have not been measured. These builds support
comparison; phone battery-screen observations are not a controlled A/B result.

## TeapodStream 1.6.6 and core 0.7.0 (1.6.6-rust.6)

The fork now merges upstream TeapodStream 1.6.6. The core moves to stable
xray-rust v0.7.0, commit `67969094b352f948c6b8b9e2ac75402c577cb7f7`, built
without local changes: 0.7.0 ships the same GeoIP budgets that the removed
`geo-budgets.patch` added (500,000 CIDRs per category, 750,000 IP matchers,
1,000,000 matchers in total). The C ABI goes from 1.4 to 1.7 with additive
changes only. The binding is resynchronised with v0.7.0 and keeps the local
`geodataDirectory` extension. Hysteria 2, WireGuard, profile import and carrier
rebinding are in the core but are not used by the app yet. Package ID, signing
key and bundled geodata are unchanged, so the APK installs over earlier Rust
Probe versions.

Relevant core changes for VLESS through TUN:
- A client TCP FIN is forwarded after buffered upload drains, so replies
  after a half-close are kept and naturally closed flows are released.
- Download and cancellation stay responsive while an upload is blocked.
- Fewer allocations in async setup and bounded TUN upload queues.
- The 0.7.0 changelog has no TLS/Vision change. Vision over ordinary TLS
  stays gated without a new test.

Upstream 1.6.4–1.6.6 in the Rust build:
- Custom DoT/DoH/UDP DNS addresses with default ports work. xray-rust takes a
  DoT port only from its `tls://` URL, so the Rust builder writes it there.
  The upstream parser mangled IPv6 literals (`2001:db8::1`,
  `[2001:db8::1]:5353`); the fix applies to both builds.
- The heartbeat target URL is configurable. The Rust SOCKS probe accepts any
  2xx response and supports `https://` with TLS inside the SOCKS tunnel.
- `switchConfig` (formerly `urltest`) works with TCP-ping candidate checks.
  XRAYDELAY, PASSIVE, measuring candidates through the protocol, and the
  tethering switch are gated with explanations (see the support list above).
- The Rust build has no per-flow owner check, so the 1.6.4 protection against
  excluded apps binding to `tun0` does not apply. The UI and the service log say so.

Verification for this update:

- 129 Flutter tests passed in each build mode; analysis has only the three
  existing `onReorder` deprecation infos.
- Host tests of the pinned 0.7.0 source: `xray-config` 391 passed; TUN tests
  in `xray-tun` 27 passed and `xray-core-rs` 264 passed (4 Hysteria/WireGuard
  tests need a reference server and were ignored), including the new FIN and
  stalled-upload regressions.
- 1,380 Rust configs exported through the production builder (30 profile
  variants of the supported transports, security, Vision, xHTTP modes and
  certificate pins; 5 routing modes; 24 DNS variants; 9 fingerprints) were
  each checked with `xray-rust config check`, both as built and with Android's
  server-address resolution applied. All were accepted except REALITY with the
  `android` fingerprint, which has no X25519 key share. That fingerprint cannot
  complete REALITY in the Go core either.
- On the API 36 emulator, all 10 VLESS interoperability combinations passed
  again against Xray-core 26.7.28, and all 6 GeoIP/GeoSite tests passed.
- Release APKs keep the rust.5 signing certificate, raise the version code
  (12609/14609), pass 16 KiB alignment checks, and package exactly the newly
  built core (compared after symbol stripping). The Go build still produces
  all three ABIs.
- Installing over rust.5 kept an imported profile and an app-data marker.
  Through the installed release APK's TUN, a different UID (shell, 2000)
  downloaded and SHA-256-verified 8 MiB over xHTTP/TLS, then 8 MiB more with
  a client half-close, then 8 MiB over xHTTP/REALITY. The heartbeat probe went
  through the tunnel. Disconnecting through the UI removed `tun0`. The fixture
  used a local reference server and generated test credentials.

## Core update (1.6.3-rust.5)

The core is pinned to stable xray-rust v0.6.1, commit
`ed5258a3a589c2a1f9330142f37c8f3d28a640fa`. The existing GeoIP budget patch,
bundled geodata, supported protocols, package ID and signing key are retained.
Installing this APK updates rust.4 without requiring profile re-import.

Upstream changes increase the default XHTTP/H2 stream receive window from
65,535 bytes to 4 MiB (connection credit stays 16 MiB), avoiding the small-window
single-download limit on high-latency paths. A stalled TUN TCP reader no longer
blocks neighboring TCP, UDP or control events. Download prefetch is bounded to
256 KiB per flow and immediately ready reads are batched without waiting for
more data. Larger H2 receive credit permits more buffering; the TUN prefetch
limit is not a whole-process memory limit.

No additional setting is needed to use these fixes. Vision over ordinary TLS
remains gated; the upstream TLS/Vision implementation was not changed by this
release. The public Android bindings and C ABI are unchanged. Keep rust.4 and
rust.5 energy observations separate because the native data path has changed.

Verification for this update:

- 90 Flutter tests passed in each build mode; analysis has only the three
  existing `onReorder` deprecation infos.
- 19 upstream regression tests passed against the patched v0.6.1 source:
  H2 window validation, receive-window limits/replenishment, all H2 modes,
  stalled-reader isolation, bounded prefetch, DNS/FIN ordering and cancellation.
- Six Android GeoIP/GeoSite tests passed, including simultaneous loading of
  the bundled US/RU and Cloudflare/YouTube categories.
- All 10 Android VLESS interoperability combinations passed again, transferring
  both plain payloads and inner TLS against the local Xray-core 26.7.28 server.
- Both release APKs retain the rust.4 signing certificate, increase the Android
  version code and pass 16 KiB ZIP alignment checks. Their packaged Rust libraries
  match the newly built v0.6.1 libraries after symbol stripping.
- On an isolated API 36 emulator, installation over rust.4 retained an app-data
  marker. A separate application UID downloaded and SHA-256-verified 8 MiB through
  the installed release APK's Android TUN with xHTTP/TLS, then another 8 MiB with
  xHTTP/REALITY. Both sessions disconnected cleanly. The fixture used a local
  reference server and generated test credentials.

## Verification of additional VLESS transports (1.6.3-rust.4)

90 Flutter tests passed in each build mode. The local Android interoperability
campaign passed all 10 enabled combinations against Xray-core v26.7.28,
including both REALITY/Vision flows. Each combination transferred 128 KiB in
plain echo and another 128 KiB inside TLS, with byte-for-byte verification.
TLS/Vision was separately tested and failed after the inner handshake; its flag
remains disabled. The native core itself was not modified for this expansion.


The Dart tests check carrier/security/flow combinations, TCP/RAW and WebSocket
aliases, preservation of Vision flow/path/SNI, TLS certificate pin conversion,
unsupported combinations and the per-engine QUIC policy. Rust does not inherit
Go's automatic host-side QUIC toggle for Vision; the native core enforces the
selected Vision UDP policy.

The optional local interoperability campaign uses Xray-core v26.7.28, ephemeral
keys/certificates and echo endpoints bound to host loopback. Flutter exports
configs through the production parser and builder. Android native clients send
both plain payloads and an inner TLS session (4 × 32 KiB per stream) through each
supported combination. It requires a running Android emulator; no live VPN
profile is needed:

```sh
JAVA_HOME=/path/to/jdk17 ANDROID_SERIAL=emulator-5554 \
  python3 scripts/test-rust-transports.py
```

The default download is the checksum-pinned Linux x86_64 Xray reference binary;
other platforms can set `XRAY_REFERENCE` to a compatible local binary. The
harness uses emulator host alias `10.0.2.2`; physical-device battery and WAN
performance measurements are outside this test.

## Verification of separate builds (1.6.3-rust.3)

- 71 Flutter tests passed in each mode (`TEAPOD_CORE=go` and `rust`).
  Coverage includes unchanged Go feature availability, visible-but-disabled Rust
  controls, explicit reset of an imported unsupported value, per-core config and
  SOCKS credentials, and refusal to connect with a mismatched native engine.
- Release APKs were built for all three Go ABIs and both Rust ABIs. Archive
  inspection confirms exactly the selected core: `libgojni.so` in Go and
  `libxray_ffi.so` / `libxray_mobile_jni.so` in Rust.
- Both installed builds connected through their Flutter UI with the same separately
  imported VLESS/XHTTP/REALITY profile. A different application UID received HTTP
  204 through each VPN, followed by a successful explicit disconnect.
- The Go service source is byte-for-byte identical to the upstream baseline.
- The installed Rust network screen retains SOCKS authentication and proxy-only
  controls with disabled interaction and explanatory text.
- Static analysis has no new findings; three existing `onReorder` deprecation
  infos remain.

## Verification of routing (1.6.3-rust.2)

- 63 Flutter tests passed, including both routing modes and failed-download/failed-validation retention.
- 6 Android native tests passed: GeoSite match/non-match, GeoIP literal/domain matching,
  missing/corrupt databases, and simultaneous loading of bundled US/RU plus Cloudflare/YouTube sets.
- On the API 36 emulator, a separate application fetched an external-IP endpoint:
  baseline used the VPN IP; GeoSite BYPASS, GeoIP US BYPASS, and a combined GeoSite/GeoIP
  fallback used the physical connection's IP; GeoSite ONLY used the VPN IP for a match
  and the physical IP for a different domain.
- The same application used the physical IP when excluded by Android's app allowlist,
  and the VPN IP when selected. The test disconnected between cases.
- Updating databases through the app downloaded and validated a new pair, activated
  its generation, and retained the bundled pair. Combined GeoIP/GeoSite routing
  passed again after reconnecting against the downloaded generation.
- Native libraries packaged in both APKs match the patched build after Android's symbol stripping.

## Validation on a phone

The initial 1.6.3-rust.1 validation on 2026-09-09 passed 57 Flutter tests. An Android API 36 x86_64
emulator connected using a separately imported VLESS/XHTTP/REALITY profile.
A second application (a different UID) received valid DNS answers over UDP
through the TUN DNS endpoint and HTTP 204 through the tunnel. The same probes
passed after disconnecting and reconnecting. The native diagnostic snapshot
reported `tunBackend: fd` and no packet drops in the sampled run.
`flutter analyze` reports only three pre-existing `onReorder` deprecation infos.
Physical-device battery, Wi-Fi/cellular transitions and extended sleep tests
remain to be measured; the emulator result is a functional smoke test.

Import a VLESS share link in the app, approve the Android VPN request, and test
web browsing, DNS/UDP, screen-off resume, reconnect and disconnect. In the
diagnostic snapshot, `engine` must be `xray-rust 0.7.0` and `tunBackend` must be
`fd`; incoming and outgoing packet counters should increase with app traffic.

Compare energy against the original app on the same phone, server, network and
workload. Desktop/emulator tests cannot establish a battery-life improvement.

## Dependencies

- [xray-rust source](https://github.com/aimalygin/xray-rust), MPL-2.0.
- [Pinned source v0.7.0](https://github.com/aimalygin/xray-rust/tree/67969094b352f948c6b8b9e2ac75402c577cb7f7), unmodified;
  [third-party notices](third_party/xray-rust/THIRD_PARTY_NOTICES.md), including the vendored GotaTun WireGuard engine.
- [Bundled geodata snapshot](https://github.com/Loyalsoldier/v2ray-rules-dat/releases/tag/202609082347).
- Upstream TeapodStream retains its existing license.
