# Lab 1.1.11.9 publication verification — 2026-10-02

## Source and publication chain

- Source PR [#252](https://github.com/Clash-FX/ClashFX/pull/252), reviewed and merged as `11396cf703cb2e71a8f9fccba5ccf58924ebb457`. It is based on current main, preserves 1.1.11.8 fixes and excludes local planning artifacts.
- Source CI [37019390404](https://github.com/Clash-FX/ClashFX/actions/runs/37019390404) passed 213 isolated XCTest cases, universal Release App/Helper/core compatibility gates, full Go tests and race detection, real listener readiness across log levels, and hosted-only TUN lifecycle/DNS/route restoration. Hosted fixture processes were stopped and network state restored.
- Annotated tag `1.1.11.9` dereferences to the tested source merge. Tag object: `d48ee8bfc21b5eafebf93faf030e10ff6550cb46`.
- Release CI [37021437633](https://github.com/Clash-FX/ClashFX/actions/runs/37021437633) passed packaging, DMG verification, dashboard compatibility, Sparkle signing, prerelease creation and website dispatches.
- Appcast PR [#253](https://github.com/Clash-FX/ClashFX/pull/253) changes only `docs/appcast.xml`, adding one Lab item. Previous items match the pre-publication baseline. It was reviewed against the downloaded package and merged as `cadf5b60493fe2c06b130789efc11ad2ce08040a`.

Both merges used the repository's already-configured administrator path after parent-agent review and applicable checks. Protection rules were unchanged and no review by another identity was fabricated. The generated XML-only appcast commit uses the existing `[skip ci]` convention.

## Published package

[GitHub Release](https://github.com/Clash-FX/ClashFX/releases/tag/1.1.11.9) is non-draft and `prerelease=true`.

- DMG: 95,640,534 bytes; SHA-256 `6fb656e093e8f6ceb01e84fedefc0e06c3bcc60a3b5bc9565bae62a302f3b150` matches GitHub's reported digest.
- Debug symbols: 48,829,654 bytes; GitHub-reported digest `sha256:a8b991df0278814b0efd75908a937dd2a84d3cb3cfe3ab84df4d2fe61c2c9562`.
- Downloaded DMG passed hdiutil verification and independent CryptoKit Ed25519 verification using the app's public update key. It was mounted read-only for inspection, never launched, and detached afterward.
- Packaged Info.plist: short version `1.1.11.9`, build `1001011009`, BETA `true`, Mihomo `1.19.24`.
- Actual binary minima: App/Helper x86_64 10.14 and arm64 11.0; core x86_64 10.13 and arm64 11.0. Both required architectures were present; dashboard bundle checks passed.
- Candidate feed item: channel `lab`, minimum system `10.14`, Sparkle version `1001011009`, asset URL and length match the downloaded DMG.

## Isolation and limits

Installed App/Core/Helper PIDs and system proxy/DNS/default-route hashes match before/after snapshots. No installed app or helper was replaced, no local TUN was toggled and no issue comment was posted. `gh` uses the requested `mixc6763-prog` account.

Runtime testing on macOS 10.14 and full live GUI/Helper/TUN restoration remain outside the demonstrated coverage, as stated in the Lab release notes. Hosted standalone-core TUN restoration passed. Earlier [benchmark validation](benchmark-optimization-validation-2026-10-02.md) covers two loopback real-core/menu tests and local scheduler comparison.

Local evidence: `/tmp/clashfx-lab-1.1.11.9-evidence`.

Live feed deployment [37022989630](https://github.com/Clash-FX/ClashFX/actions/runs/37022989630) passed. The live [appcast](https://clash-fx.github.io/ClashFX/appcast.xml) contains exactly one new Lab item with matching version, channel, minimum OS, asset URL, length and independently verified signature; previous items are preserved.
