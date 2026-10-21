# Selector/provider/retry/IPv6 follow-up review — 2026-10-19

Continues the unpublished candidate and previous recovery fixes. A fresh Luna reviewer independently examined Selector synchronization, provider removal/reinsertion, retry fencing, and DNS ownership. Additional fresh workers checked custom DNS retargeting and validation output handling. All work used a private source/build tree; no installed application or network controls were invoked.

## Findings and fixes

1. **Retry menu validation could disable a valid explicit retry.** After automatic recovery exhausted retries, a stopped core with a retained checkpoint was recognized by the action but not AppKit's actual menu validator. The shared availability policy and actual validator now include automatic-recovery retry availability, while retaining transition, restart, and termination blocks. The lifecycle harness executes the extracted production validator, rather than testing only its action helper.
2. **Custom IPv6 DNS reload could split listener and bootstrap ownership.** The previous file retargeter changed a native IPv6 listener to IPv4 while leaving its IPv6 bootstrap resolver behind, even when reusing the same port. A separate native IPv6 path preserves host/zone and changes only the confirmed port. It derives ownership from original plain proxy bootstrap references, preserves independent resolvers, and checks final TCP/UDP endpoints before atomic file replacement. Exact IPv6 and IPv4 binds remain independent; generic IPv6 wildcard ownership follows Mihomo's actual dual-stack socket model. Mapped IPv4 loopback uses the existing IPv4 path with matching bootstrap normalization. Rejections preserve original bytes and permissions.
3. **Special resolver schemes could be mistaken for socket endpoints.** Follow-up review questioned the default URI transport inference. Inspection of pinned Mihomo 1.19.24 showed that unknown schemes fail core validation, while special schemes such as system do not use the apparent URI socket. Only udp/quic and tcp/tls/http/https participate in endpoint-cycle checks; special and unknown schemes remain for core validation. Regression cases preserve resolver values and avoid the false self-cycle rejection.
4. **Validation stderr could race process termination.** The larger regression run exposed an intermittent missing sanitized error. Both output readers now finish bounded nonblocking drains before failure classification. Shutdown is serialized and idempotent; queued callbacks cannot read a reused descriptor. Reads never wait for EOF from inherited writers. Timeout, cancellation, output limits, and sanitization remain enforced.

IPv6 DNS transition journal events retain only the family marker, validated ports, and reference count. No resolver address or arbitrary error text is persisted in these events.

## Independent review and validation

The fresh reviewer found no further confirmed Selector concurrency, provider removal/reinsertion, retry-fencing, or automatic-group authority regressions. Protected missing selections remain fail-closed, reinsertion works, explicit DIRECT remains valid, and ordinary unprotected Selector defaults remain unchanged. This is scoped evidence, not a proof that every possible race is absent.

- Selector upstream regressions: race detector, three repetitions.
- Full bridge and CLI Go tests, upstream runtime HTTP mutation tests; focused lifecycle/startup/IPv6 race regressions.
- 108 standalone Swift policy, transaction, safety, validation, and restore tests. Nonzero-exit diagnostics repeat 12 times at the original timeout; reader tests cover an open writer, eight concurrent stoppers, and descriptor reuse.
- Actual recovery lifecycle/menu validation, 20 selection-policy cases, startup ordering, and sanitized recovery journal fixtures.
- Real-core automatic recovery/provider fixtures, bridge port contracts, runtime configuration transactions/rollback, and runtime DNS fixtures.
- Durable custom IPv6 fixture: production Cgo retargeting followed by private no-TUN core UDP/TCP queries on dynamic loopback endpoints. Same-port and changed-port native IPv6 and mapped IPv4 cases run against real sockets. Wildcard ownership cases exercise production projection only; no wildcard listener process is launched by this fixture.
- Isolated unsigned App/Helper Debug build; only private formatting/lint build phases bypassed. Build uses a temporary macOS 14 deployment override required by installed dependencies. Shipping deployment settings remain unchanged. Relevant changed Swift production sources also pass an x86_64 macOS 10.14 typecheck.

Full GUI clicking, authorization dialogs, privileged TUN and actual system DNS switching are outside this source-review run. No new Lab readiness or release claim is made.

## Evidence

Private logs and original-file backups are retained in:

`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-selector-followup-review-ywgw33b9`

Key logs: selector-race.log, go-full-build.log, final-core-build.log, swift-policy-suite/results.log, retry-menu-tests.log, journal-tests.log, bridge-contracts.log, runtime-transactions.log, provider-recovery.log, runtime-dns.log, custom-ipv6-live.log, app-helper-build.log, macos-1014-typecheck.log. Final refreshed-artifact checks and host baseline comparison are recorded alongside them.

Source synchronization is restricted to a hash-checked manifest, preserving unrelated workspace changes. Generated workspace-only core/bridge artifacts are backed up before refreshing. No commit, push, release, install, or installed app replacement is performed.

Final result: the new reviewer rechecked the special-scheme correction and its focused test passed. All final rebuilt bridge/custom DNS/transaction fixtures pass. All 208 production/build source files match the successful private build. Installed process PID/start times, installed App/Helper/core SHA-256, system proxy state, and system DNS state match the pre-review baseline exactly.
