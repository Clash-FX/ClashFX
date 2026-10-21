# Lab 1.1.11.13 publication verification — 2026-10-15

- Source PR [#265](https://github.com/Clash-FX/ClashFX/pull/265), reviewed head `d0e1a92a0e042e1bdf00415cc01ed6acd02d6e0e`, merge `a62127fc13b3bbc5313d0679e95aa201b906c313`. The merge tree exactly matches the reviewed head. Only the proxy-menu preference, presentation, tests, five localizations and release notes were published; unrelated local changes and planning artifacts were excluded.
- [Source CI 38599360581](https://github.com/Clash-FX/ClashFX/actions/runs/38599360581) passed 401 isolated XCTest cases with zero failures, Helper metadata/signature regression, universal Release compatibility gates, Go tests and race checks, real listener readiness, hosted standalone TUN lifecycle and cleanup. Local 401-case regression and app compilation also passed.
- Annotated tag `1.1.11.13` resolves to the source merge. [Release CI 38602166454](https://github.com/Clash-FX/ClashFX/actions/runs/38602166454) passed build, compatibility/dashboard bundle checks, Helper metadata/signature regression, DMG verification, Sparkle signing, prerelease upload, appcast PR creation and both website dispatches.
- [GitHub Lab release](https://github.com/Clash-FX/ClashFX/releases/tag/1.1.11.13) is non-draft and prerelease=true, with bilingual notes. Website Auto Update Version runs [38605079680](https://github.com/mixc6763-prog/ClashFX-web/actions/runs/38605079680) and [38605081512](https://github.com/mixc6763-prog/ClashX.Web/actions/runs/38605081512) both succeeded.
- Appcast PR [#266](https://github.com/Clash-FX/ClashFX/pull/266) changes only `docs/appcast.xml`, adding one item and preserving all 121 prior items. Parent review verified the item against the downloaded package before merging as `187ea95d19883514a63b07d92ac98ec1f5d8e81a`.
- [Pages deployment 38605330290](https://github.com/Clash-FX/ClashFX/actions/runs/38605330290) succeeded. The canonical [live appcast](https://clash-fx.github.io/ClashFX/appcast.xml) was fetched and independently verified after deployment.

Merges used the repository's existing administrator path after parent review and applicable checks. Protection rules were unchanged, and no review from another identity was fabricated. The generated XML-only appcast uses the existing skip-ci convention.

## Published package and feed

DMG: 94,411,967 bytes; SHA-256 `ae0c03ce26a85ab844746853bb392516705d038e160781787211966ad54e50a7`, matching GitHub's asset digest. The downloaded DMG passed hdiutil integrity verification; its app passed strict deep code-signature verification. The packaged public Sparkle key independently verified the DMG's Ed25519 signature against both proposed and live feeds. The package was mounted read-only, never launched, and detached afterward.

Packaged version `1.1.11.13`, build `1001011013`, BETA true. App/Helper x86_64 minimum 10.14 and arm64 11.0; core x86_64 minimum 10.13 and arm64 11.0. The live feed contains exactly one matching new Lab item, minimum OS 10.14, and matching URL, byte length and signature.

## Manual review and limits

Actual AppKit menu-row snapshots showed the selected group by default and the final node with the preference enabled; both fit at 420 pt width. An isolated probe compiled the exact production setting-installation methods, and English/Simplified Chinese rows were visually reviewed at 390 pt content width. Labels and explanatory text were readable and unclipped. Menu tests cover live preference changes, nested route changes, automatic/manual-priority presentation, unresolved routes and benchmark identity.

Full settings-window/VoiceOver interaction, relaunch persistence and macOS 10.14 runtime were not manually exercised. Local Xcode 27 validation used a command-line macOS 12 deployment override; source compatibility targets were unchanged. Helper, installer and core sources match the previously accepted 1.1.11.12 candidate, so that acceptance remains applicable; source CI additionally exercised the existing gates.

## Host and worktree preservation

Original tracked-file hashes match the publication baseline. Running process IDs and system proxy/DNS/default-route hashes match before/after snapshots. No installed app or helper was replaced and no local network mode was toggled. This document is a new uncommitted publication record.

Publication operations and the release trigger used `mixc6763-prog`. After live-feed verification, gh was switched back to `charlessnow` and the authenticated user was checked.

Local evidence: `/tmp/clashfx-lab-1.1.11.13-evidence`.
