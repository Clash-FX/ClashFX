# Lab 1.1.11.8 — published and verified

Verified on 2026-09-27 using GitHub account `mixc6763-prog`.

## Release path

The existing Lab procedure was followed: scoped changes and bilingual release
notes, PR CI, reviewed merge to main, an annotated four-segment tag at that
merge, the unchanged tag-triggered Actions packaging workflow, and review of
the generated appcast PR. No temporary validation workflow was merged.

- Source PR: [#250](https://github.com/Clash-FX/ClashFX/pull/250).
- Tested head: `f1cbd3bc228a3b2c7f95e9624f368b7f4c06fccf`.
- [PR CI 36322344140](https://github.com/Clash-FX/ClashFX/actions/runs/36322344140)
  passed all 175 XCTest cases, the Release build, and compatibility gates.
- Source merge: `b122c66884ebedc85bd3b1645def27014f133c0e`. Its complete tree
  matches the tested PR tree.
- Annotated tag `1.1.11.8` dereferences to that merge. Tag object:
  `014d4b39bbe1ff7a35e78d9c3a6c94f8568aea3f`.
- [Release CI 36323265512](https://github.com/Clash-FX/ClashFX/actions/runs/36323265512)
  passed, including packaged DMG compatibility checks, Sparkle signing,
  prerelease creation and website dispatches.
- Appcast PR [#251](https://github.com/Clash-FX/ClashFX/pull/251) changed only
  `docs/appcast.xml`, adding the new Lab item without changing older items.
  It was reviewed against the downloaded asset before merge
  `da1d010b1d0124312c7436808502d611ad50e6ef`.
- [Pages deployment 36324015257](https://github.com/Clash-FX/ClashFX/actions/runs/36324015257)
  completed successfully; the live feed was fetched and independently checked.

The release and appcast merges used the existing guarded administrator path
after the parent agent's review. Repository review rules were not modified and
no review by another GitHub identity was fabricated. Source CI was complete
before merging; the generated appcast commit uses the existing `[skip ci]`
convention, with no failed or pending checks.

## Published artifacts and update channel

[GitHub Release](https://github.com/Clash-FX/ClashFX/releases/tag/1.1.11.8)
is non-draft and `prerelease=true`.

- `ClashFX.dmg`: 95,449,587 bytes; SHA-256
  `22cf5b33f23e11b5c8266a332896b22ea2dd2654fbc9e054f72054d44c8cadad`.
- `ClashFX.app.dSYM.zip`: 48,463,607 bytes; GitHub-reported SHA-256
  `91e724eb8a9921601710b35d5c2b97a14d2413b10e3352f62bcc4a789f155ec1`.
- The downloaded DMG passed `hdiutil verify` without being mounted or launched.
- Its Ed25519 signature was independently verified with CryptoKit and the
  app's `SUPublicEDKey`, against both the candidate and live appcast signatures.
- Live appcast: short version `1.1.11.8`, Sparkle version `1001011008`, channel
  `lab`, minimum macOS `10.14`, and enclosure URL/length matching the DMG.
- CI checked the DMG's actual App/Helper minimums: x86_64 10.14, arm64 11.0;
  core minimums: x86_64 10.13, arm64 11.0.

## Local isolation and scope

The user's running App/core/Helper PIDs, system proxy/DNS hashes, and IPv4/IPv6
default-route fields matched the pre-validation baseline after publication.
No installed app or helper was replaced, no local TUN was toggled, and no issue
comment was posted. `gh` remains on the explicitly requested `mixc6763-prog`
account.

The earlier [isolated validation](issue-236-isolated-validation.md) covers real
core TUN start/stop and route restoration on a disposable hosted Mac. Full
GUI/Helper system DNS/proxy restoration and macOS 10.14 runtime testing remain
outside the demonstrated coverage; the Lab notes state that boundary.

Local raw evidence: `/tmp/clashfx-lab-1.1.11.8-evidence/`.
