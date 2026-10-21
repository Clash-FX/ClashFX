# Fresh recovery/selection/DNS review (unreleased)

This review starts from the previously validated unpublished candidate. It does not install or operate the local application, helper or production core, and does not change system proxy, DNS or TUN settings.

## Confirmed fixes

1. **Retry-only failure isolation.** A failed checkpoint capture or mode-queue timeout could set `automaticRecoveryNeedsRetry` without a selection map. Selection/mode/controller/reload and embedded fallback gates now protect this state too. Retrying still uses the actual selection-restoration operation lock, so the protection does not block its own retry. A reload queued during a failed recovery is cancelled with an error rather than holding the retry behind its own fence.
2. **Stale memory compatibility.** A valid fresh non-fallback selection survives a removed saved target. An apparent first-member manual Direct fallback still requires a valid saved target. Automatic URLTest/Fallback/LoadBalance choices remain authoritative, including an automatic group's current Direct result; they do not become inferred manual fallbacks.
3. **Startup DNS cycle consistency.** Cold allocation rejected a free-port source self-cycle while persisted-port preference accepted it and left a dangling old resolver. Both startup paths now share source-cycle validation. Final planned transport/address endpoints distinguish a true conflict from an independent occupied local resolver. UDP DNS can share a numeric port with a TCP management endpoint. Plain proxy bootstrap provenance and unrelated resolvers remain unchanged.

The DNS counterexample failed on the prior candidate for nameserver/default/fallback/direct fields. New regressions cover 96 source-alias/field/port-plan combinations plus occupied resolver, distinct-transport, actual proxy conflict and proxy-bootstrap positives/negatives. New selection positives also fail against the prior policy, confirming the tests detect the reported compatibility regression.

## Readback ordering checked without a production change

A static review concern about state/DNS exposure before selection readback was investigated. The publication statements are the body of a deferred `finishLaunch` closure, executed only after successful readback. A new fixture extracts and executes the actual production readiness-success block: pending readback leaves metadata/callbacks/DNS untouched; mismatch rolls back without publishing; success performs selection read, publication, callback resume and DNS in that order. Old generation, old launch and termination cannot publish. No redundant production reorder was introduced.

## Provider update / selected-state race

A private baseline probe reproduced a `ForceSet`/`Now` data race in the pinned Selector. A provider can also remove a recovered node after the startup hook validates it; the old adapter then returns its first candidate, which may be DIRECT.

The pinned overlay now synchronizes selected-name/fallback reads and writes, including ordinary Set and ForceSet. Recovery selection installs the requested name and a validated Reject fallback atomically. If a recovered provider candidate disappears, Now/Unwrap return REJECT without changing the stored choice. Reinsertion resumes the selected node; explicit user DIRECT is still permitted. Ordinary selectors without recovery protection keep their existing default behavior. The selector source hash is pinned and checked before patching.

Four upstream overlay tests cover provider removal/reinsertion/explicit choices, invalid recovery fallback, unchanged ordinary behavior, and concurrent Set/ForceSet/Now/Dial metadata. All pass with the race detector for three repetitions. The real private CLI provider fixture observes `Node -> REJECT -> Node -> DIRECT` without proxy dials.

## Validation

Private source copies, private HOME, local static DNS fixtures and dynamic loopback endpoints are used. No App/Helper is launched; a complete isolated App/Helper build is performed with the existing SDK-only 14.0 override, keeping project deployment targets unchanged.

At this stage: 88 existing Swift tests, 20 selection tests (with 10.14 typecheck), actual AppDelegate lifecycle and 24 interaction checks, actual launch-order fixture, full local Go/upstream HTTP tests, targeted race checks repeated three times, 32 bridge contracts, real HTTP/cgo config rollback, real IPv4/IPv6 UDP/TCP DNS and CLI recovery fixtures pass. The final rebuilt overlay core and cgo archive passed the complete Go/HTTP suites, upstream Selector/provider race tests and startup/DNS/lifecycle race tests repeated three times, all 32 bridge contracts, actual CLI provider recovery, real HTTP/cgo transactions and real IPv4/IPv6 DNS. The actual IPv6 TCP/UDP occupancy positive also verifies that a separate IPv6 resolver is not rejected based on a free IPv4 port.

Final complete App/Helper build passed, and 206 production source hashes match the isolated build input. The menu-entry regression exercises the actual action guard with a queued reload, instead of only calling its retry helper. Healthy queued/idle toggles retain their original behavior. The fresh independent reviewer rechecked all final changes and found no remaining confirmed blockers in the requested scope. The reviewer independently ran the actual action-entry lifecycle, 20-case selection/10.14 typecheck and production launch-order harnesses. Go/race/bridge/complete App build results were independently run by the parent, with the bounded core worker also reproducing the prior selector race and checking its patch.

This review did not run full GUI, authorization dialogs or real TUN/system DNS switching. Installed application and network-state equivalence is recorded below.

Evidence index: `/tmp/clashfx-recovery-independent-review-path`. No commit, push, release, install or application replacement.

Final host comparison: installed App/Helper/core PID/start identities and binary SHA-256, system proxy and system DNS exactly match the baseline. No owned fixture core/app processes remain. Only workspace generated artifacts were backed up and refreshed. No installed app/helper launch/control, release, push, install or replacement was performed.
