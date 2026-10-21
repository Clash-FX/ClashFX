# Fresh independent benchmark-display review — 2026-10-19

Continues the current unpublished issue 236 candidate. A fresh Luna reviewer examined automatic route changes, history versus genuine failure/timeout, and URL/node identity isolation. Parent owns integration and isolated validation. No installed App/Helper/core or OS network controls, releases, installs or app replacement.

## Confirmed review findings

- Late automatic-header events could choose cached results using a previous group's URL/expected-status namespace, even after contextual identity was rejected. Regression before fix showed 131 instead of current 42 ms after URL change, and 42 instead of current 67 ms after status change. Header lookups now use current group conditions.
- Terminal Selector context without a resolved leaf can remain after an unresolved route becomes valid and mask matching leaf history. Pending testing and a genuine current-path API outage must remain distinct from this invalidation.
- Provider P1's same-named leaf can be replaced by provider P2 with no core ID; comparing name and optional ID alone does not preserve identity. Context needs endpoint/provider/name/ID provenance.
- Nested route changes with the same final leaf can keep old ancestor/group-result evidence. Exact group-result path must match; directly measured leaf evidence remains valid across path changes to that same leaf.

Before-fix URL/status and nested-path regressions fail as expected. The additional historical-age/current-leaf-failure case passed before the changes: route updates must not refresh the 31-minute-old success timestamp, and actual later failure/timeout/unavailable states supersede it with old success retained only as reference.

Final implementation and verification are complete below; host baseline comparison is appended during bounded synchronization.

## Implemented provenance rules

Selector results now capture endpoint/provider/name/core-ID by value, with an optional exact path for automatic-group/ancestor probes. A direct leaf probe deliberately has no ancestor-path dependency. An unresolved terminal result stops matching when the route resolves; pending testing remains pending. A real retest readback failure is bound to the frozen original route if known, so it remains visible on that same route rather than falling back to old success. Frozen state contains identity values rather than weakly owned proxy/provider references.

Automatic group titles require the captured path and full final-leaf identity, and all lookups use current URL/status conditions. Automatic child rows similarly bind completed candidate results to the actual nested child path and full resolved identity. Cancellation preserves that binding. Group identity includes provider identity for direct leaf members; nested row identity is captured separately. Thus a provider swap without an ID cannot pass as the old node merely because its name is unchanged.

Regression coverage adds actual unresolved-to-resolved menu flow, genuine post-retest API readback outage, nested group path changes with unchanged final leaf, nested child changes to a different final leaf, provider P1-to-P2 replacement with absent core IDs, direct-leaf reuse across a harmless ancestor-path change, and historical age plus real later failure/timeout/unavailable priority. URL/status and unresolved/nested path cases fail against the pre-fix source.

The final full-provenance real-core/AppKit fixture passes all four cases: actual core-selected route updates retain correctly scoped measurements, URL-specific delay displays remain isolated, real failure diagnostics retain their cause, and manual priority/automatic restoration remains controlled by core now. No TUN or installed Helper is used in this fixture.

An initial expanded full suite reached 489 cases with only the previously recorded reused-descriptor validation case failing; benchmark-specific checks pass. A separate worker is diagnosing this repeated validation-test failure before the final all-suite result is accepted.

## Final results

The fresh reviewer independently found the unresolved-route, provider-identity and nested-path gaps, implemented the bounded Selector identity/path changes, and rechecked the completed child/header bindings read-only. Final scoped review found no remaining concrete issue. Parent reproduced the gaps, integrated the fixes and accepted the test results.

- **489 unhosted XCTest tests passed, zero failures**, including 12 new model/menu regressions relative to the previous 477-case candidate.
- **Four real-core/AppKit integration cases passed** with the final provenance rules. All sockets use private loopback fixtures, TUN is disabled, and the installed application/Helper is never used.
- **Isolated App/Helper Debug build passed**. The temporary checkout preserves its prior formatting/lint bypass and uses a command-line macOS 14 deployment override for the installed toolchain/dependencies. Shipping minimum deployment settings are unchanged; this does not establish release-package compatibility.

The initial App build encountered duplicate CocoaLumberjack interfaces because an earlier temporary copy had dereferenced CocoaPods public-header symlinks. Recopying dependencies with their original symlink topology fixed the isolated build; no dependency or project source change was needed.

### Repeated validation-test failure resolved

A separate Luna worker diagnosed the previously recorded reused-descriptor failure. Foundation's readability-handler cancellation can still own the old FD after closeFile returns. The old test used dup2 to forcibly replace that still-owned FD; deferred cleanup then closed the replacement. This was a fixture ownership race, not a demonstrated production validator defect. Diagnostic controls showed ordinary close plus natural allocation did not close an unrelated replacement.

The test now obtains the old descriptor number only through natural OS allocation, retains every temporary descriptor it owns, bounds the search to 64 pipe allocations/one second, and keeps the original objects alive through assertions. It still verifies eight concurrent repeated-stop/late-callback operations cannot drain or close the replacement pipe; no assertion was weakened and no production RuntimeConfigValidationRunner code changed.

The corrected descriptor regression passed **100 consecutive runs**, and the standalone validation/restore suite passed **13 tests**. The final 489-case suite includes the corrected fixture. Worker evidence is in /var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/newreviewR (final-reviewed-tests.log, validation-suite.log, fd-ownership-diagnostic.swift). Earlier failures are retained in this review's logs.

Final logs in this review directory: final-complete-tests.log, final-real-core-menu.log, final-app-helper-build.log. Original-source backups, bounded hash manifest and host state comparisons are retained beside them. This is source-level correction and isolated verification, not full GUI/authorization acceptance or a Lab release.

Final host audit: installed App/Helper/core PID/start time and binary SHA256, system proxy and system DNS all match the pre-review baseline exactly. Only bounded source/test/documentation files were synchronized after hash checks; unrelated workspace edits were preserved. No install, publish, application replacement or installed runtime/network controls.
