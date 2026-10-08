# Android binding for xray-rust 0.7.0

The Kotlin `XrayCore`, JNI implementation and C header are copied from tag v0.7.0,
https://github.com/aimalygin/xray-rust/tree/67969094b352f948c6b8b9e2ac75402c577cb7f7
under MPL-2.0; see ../../third_party/xray-rust/LICENSE.

Local changes add `geodataDirectory` to `XrayCore.create`, calling the existing
`xray_core_set_geodata_search_dir_exclusive` **before** configuration loading.
This avoids global working-directory changes and reflection into private handles.
The C header is unchanged from upstream.

The native core is built from the same commit without local patches. The former
`geo-budgets.patch` is gone: v0.7.0 ships the same parsing budgets that fit the
bundled US GeoIP category (300,531 CIDRs): 500,000 CIDRs per category,
750,000 IP matchers per config, 1,000,000 total matchers. The app reports this
build as `xray-rust 0.7.0`.

The C ABI is now 1.7 (was 1.4). The additions are additive: offline profile
import (`xray_profile_import_json`, wrapped internally by the upstream binding)
and WireGuard/Hysteria socket rebinding after a network change. This app does
not use them yet.

`scripts/build-rust-core.py` pins Rust 1.96.0 and builds arm64/x86_64 with the
Android NDK 28.2.13676358 and 16 KiB ELF alignment. The source cache and outputs
are ignored under `.native/`; `rust-build.json` records the source identity and
output hashes. The script rejects a source checkout with local changes.
Distribute the source revision alongside any binaries.

After a source-pin update, an existing `.native/xray-rust` checkout at the old
revision must be moved aside or explicitly updated before building. The script
rejects a mismatched checkout rather than overwriting local native changes;
with no source checkout, it fetches the exact pinned commit automatically.
