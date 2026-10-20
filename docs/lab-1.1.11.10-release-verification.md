# Lab 1.1.11.10 publication verification — 2026-10-13

- Source PR [#259](https://github.com/Clash-FX/ClashFX/pull/259), merge `7ed509f335f040862b456f334b9a13565f394b12`. Production source matches the accepted Helper/TUN candidate byte-for-byte; current main CI and existing feed are retained.
- [Source CI 38391560079](https://github.com/Clash-FX/ClashFX/actions/runs/38391560079): success; 349 isolated XCTest cases with zero failures, universal Release architecture/minimum-version gates, Go race checks, real listener readiness, hosted TUN lifecycle and cleanup all passed.
- Annotated tag `1.1.11.10` resolves to that merge. [Release CI 38393588821](https://github.com/Clash-FX/ClashFX/actions/runs/38393588821) passed build, DMG verification, dashboard bundle checks, Sparkle signing, prerelease creation and both website dispatches. Both website Auto Update Version dispatch runs completed successfully.
- [GitHub Lab release](https://github.com/Clash-FX/ClashFX/releases/tag/1.1.11.10) is non-draft, prerelease=true. Bilingual release notes include fixes, validation results and coverage limits.
- Appcast PR [#260](https://github.com/Clash-FX/ClashFX/pull/260) changes only `docs/appcast.xml`, with one new item and all 118 previous items preserved; reviewed against the downloaded package and merged as `b5a62422f18abf4faf4ecc203b9d64610cfc4218`.
- [Pages deployment 38395726395](https://github.com/Clash-FX/ClashFX/actions/runs/38395726395) succeeded. The canonical [live appcast](https://clash-fx.github.io/ClashFX/appcast.xml) was fetched and independently verified.

Merges used the existing administrator path after parent review and applicable CI checks. Protection rules were unchanged; no approval from another identity was fabricated. The XML-only appcast uses the existing skip-ci convention.

## Actual published package and feed

DMG: 94,188,227 bytes; SHA-256 `b103fce9f5dea0a82968424136352aef8fcef65dc82f5fcd251d30f0095200d8`, matching GitHub's asset digest. Downloaded DMG passed hdiutil integrity verification and independent CryptoKit Ed25519 verification with the packaged public Sparkle key. It was mounted read-only for inspection, never launched, and detached afterward.

Packaged short version `1.1.11.10`, build `1001011010`, BETA true, Mihomo `1.19.24`. App/Helper x86_64 minimum 10.14 and arm64 11.0; core x86_64 minimum 10.13 and arm64 11.0. Both architectures and dashboard bundle gates passed. The live feed has exactly one matching new item, Lab channel, minimum OS 10.14, matching DMG URL, byte length and signature.

## Feature validation and limits

Prior isolated feature acceptance passed 349 XCTest cases, 4 separate real-core integration cases and 30 production-method probes. [Real Helper/TUN acceptance 38252765807](https://github.com/Clash-FX/ClashFX/actions/runs/38252765807) passed 43 backend assertions including startup/restart, invalid-config and proxy-write rollback, system proxy/DNS restoration and cleanup. Full GUI/AppDelegate startup, SMJobBless authorization, physical display/power hot-plug, helper disable-error/cancellation, GUI transaction-level DNS rollback and macOS 10.14 runtime testing remain outside demonstrated coverage. The earlier HY2-69 503 does not identify its underlying cause.

## Developer host preservation

All original worktree files and the tracked binary diff match the publication baseline. Only the isolated temporary clone was committed/merged/tagged. Running App PID 70829, Helper PID 70845 and core PID 71936 remained unchanged, as did system proxy, DNS and default-route hashes. No installed app/helper/config was replaced and no local TUN or proxy was toggled. This document is a new uncommitted record; existing changes are retained.

Publication operations used `mixc6763-prog`; gh was switched back to `charlessnow` and the authenticated user checked afterward.

Local evidence: `/tmp/clashfx-lab-1.1.11.10-evidence` (CI logs, downloaded DMG, metadata, feed snapshots, independent signature verification and host baselines).
