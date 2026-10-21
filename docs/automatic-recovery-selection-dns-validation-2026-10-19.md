# Automatic recovery selection and DNS validation (unreleased)

This work extends the previous unpublished candidate. Compared with hosted acceptance commit `cdf94d566b2484b44b2f5eb5f0d2c2949254792a`, 431 relevant source/test files matched, none were missing, and existing project/harness differences were retained. The candidate is distinct from installed Lab 1.1.11.13.

## Behavior

- Capture and freeze profile-scoped Selector intent before stopping the old core. Valid saved intent takes precedence over a first-member Direct fallback, including direct aliases and nested groups. Automatic groups remain core-controlled; explicitly selected DIRECT remains valid.
- If the old API is unavailable, require complete saved choices for the confirmed Selector topology. An incomplete checkpoint blocks recovery before stopping the old core.
- Both generated and custom enhanced launches include the frozen checkpoint in the final private file. The app strips the reserved field from subscription input. The core strictly applies it after cache/profile and provider loading, before `tunnel.OnRunning()`. Missing groups/targets reject startup. The guard is consumed once and does not pin normal subsequent reloads.
- Verify the replacement core's selections before publishing runtime metadata, DNS takeover and success. Retain one checkpoint across retries, reject stale generation/launch replies, and block both embedded resume and embedded startup on failure. Keep a visible mixed state and notification instead of silently selecting a default route.
- Retain the prior shared DNS retargeter and provenance checks. New regressions cover wildcard-listener cold start, changed-port recovery and normal/custom reload, unrelated local resolvers, and real cycle rejection.
- Keep detailed regular logs and a separate privacy-filtered `Library/Logs/ClashFX/Recovery/` journal: 256 KiB per file, current plus previous file, 8 KiB per record, directory/file modes 0700/0600. Benchmark floods do not enter it.

## Isolated verification

All runtime fixtures use private HOME and dynamic loopback ports, no TUN, local DNS fixtures and no user profiles. App/Helper are compiled only.

- Existing 88 Swift transaction, validation, lease and DNS regressions.
- New 17 checkpoint XCTest cases: aliases/nested Direct, explicit DIRECT, automatic groups, malformed or incomplete snapshots, missing choices, GLOBAL and unrelated memory. macOS 10.14 typecheck.
- Actual extracted AppDelegate methods with inert dependencies: capture-before-stop, duplicate exclusion, checkpoint retention/retry, failed fallback isolation, stale generation/launch and readback mismatch.
- Go local and upstream HTTP suites; targeted startup-selection/lifecycle race checks.
- Actual CLI: stale cached DIRECT recovers to Node on the first API response; missing target exits before management publication and leaves cache intact; explicit DIRECT and GLOBAL-to-automatic-group choices succeed.
- Actual HTTP/cgo config changes/rollback, 32 bridge contracts and IPv4/IPv6 UDP/TCP DNS.
- Complete isolated App/Helper build. Project deployment targets unchanged; a temporary 14.0 build override accommodates the installed SDK.

This round does not claim full GUI, authorization-dialog or real TUN acceptance. Earlier hosted acceptance is not reused as proof for these new changes.

## Independent review and final state

Fresh independent review found and resolved two additional boundaries:

- Retry must use the retained checkpoint even if uncertain ownership still reports the old core as running; clicking the Enhanced Mode item must not disable it instead.
- A queued/in-flight outbound mode change must defer recovery before consuming its cooldown. Deferral is bounded and generation/profile/owner scoped, reserves new mode changes, resumes when the queue drains and exposes a retry notice on timeout.

The actual AppDelegate-method fixture covers both findings, timeout, cancellation and normal mode requests. Unverified checkpoints also reserve node-selection/config-reload/controller-scope changes, so a failed handoff cannot discard intent. A verified ordinary reload may clear only an unprotected retry notice.

The same fresh reviewer rechecked these final paths and reported no remaining confirmed blocker in the reviewed scope. The reviewer did not rerun the parent validation suites. Final App/Helper compilation passed and 205 production source hashes match the isolated build input. The interaction harness passed 22 checks. Host-state comparison is recorded below after source synchronization. Evidence index: `/tmp/clashfx-recovery-selection-fix-path`. No publication, push, app installation/replacement or live network configuration changes.

Final host comparison: installed App/Helper/core process identities and start times, installed binary SHA-256, `scutil --proxy` and `scutil --dns` all exactly match the task baseline. Only workspace generated archive/header/core artifacts were backed up and refreshed; installed files were untouched. All owned isolated fixture processes exited.


Further independent review and fixes are recorded in [the follow-up review](automatic-recovery-independent-review-2026-10-19.md), including retry-only fences, valid fresh choices, DNS address-family compatibility and provider-update protection.
