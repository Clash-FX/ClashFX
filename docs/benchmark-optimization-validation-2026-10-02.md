# Manual benchmark optimization validation — 2026-10-02

Implemented quick (2500 ms) and complete (5000 ms) modes, progress and visible summaries, identity/URL/status-matched failure retry, deferred visual sorting, and three successful-delay color bands. Core selection remains authoritative. Settings provide URL presets and measurement-method runtime overrides without editing subscription source. Fresh-install defaults use Cloudflare HTTPS and unified delay; existing saved URLs and inherited measurement semantics are preserved.

## Acceptance checks

- Unhosted XCTest: 215 tests, 213 passed, two opt-in real-core tests skipped in the ordinary run; zero failures.
- Both opt-in real-core tests passed separately with pinned Mihomo 1.19.24 and production overlay. Captured raw API values exactly matched menu values, colors and refreshed automatic selection.
- Retry retains successful rows across menu close/open, quick-to-complete retries use 5000 ms, cancelled full runs drop prior retry eligibility, and clearBenchmarkRetryHistory only clears retry records while retaining measurements.
- Independent static review found whole-menu sorting could reattach benchmark functional views and duplicate options; sorting now removes/reinserts only proxy rows, keeping functional items attached. Targeted menu/sort regression and App rebuild passed.
- Real NSMenu tests confirm no row movement during updates or sort selection, ordering applies on reopen, options deduplicate and view identities survive.
- Full Go tests passed; full race suite passed with count=3. A real upstream Queue.Last/Pop lock-boundary race discovered during verification was fixed in the hash-guarded shipping overlay; concurrent regression was retained.
- Fresh c-archive built; all 26 exported ABI declarations match checked-in header. App and Helper Debug build passed with that archive from an isolated source copy.
- Five localization files and Xcode project passed plutil; git diff --check passed.

## Controlled scheduler comparison

40 distinct inline targets, 32 fast local HTTP proxies and eight variable-delay proxies. Exactly 40 requests per run, no automatic retries; all completion counts and concurrency peaks checked. The fixture connection limit matches production (100); server accept backlog is 128. Three controlled scenarios, one sample per policy: these establish scheduler behavior, not Internet latency or population-level performance.

| Scenario | Concurrency | First result (s) | Total (s) | Success | Core timeout |
|---|---:|---:|---:|---:|---:|
| healthy | 8 | 0.068 | 0.523 | 40 | 0 |
| healthy | 10 | 0.068 | 0.440 | 40 | 0 |
| healthy | 12 | 0.069 | 0.433 | 40 | 0 |
| slow-tail | 8 | 0.082 | 1.091 | 40 | 0 |
| slow-tail | 10 | 0.065 | 1.020 | 40 | 0 |
| slow-tail | 12 | 0.070 | 0.994 | 40 | 0 |
| timeout-tail | 8 | 0.076 | 2.801 | 32 | 8 |
| timeout-tail | 10 | 0.068 | 2.725 | 32 | 8 |
| timeout-tail | 12 | 0.072 | 2.731 | 32 | 8 |

Fixed 10 remains the default: it improves completion over eight here; twelve provides a small marginal gain and no gain for the timeout tail. Failure outcomes no longer lower concurrency. No default repeated probes or extra staggering were added without evidence.

## Limits and isolation

Xcode 27's local SDK floor requires a command-line macOS 12 deployment override for verification. Project macOS 10.14 settings were preserved; this is not a macOS 10.14 release/runtime certification. The installed app was not launched, replaced or restarted; no helper installation, system proxy/DNS/route modification or publication was performed. Both fixture runs confirmed installed app/core PID continuity, unchanged system proxy, stopped owned core and closed loopback listeners. Final before/after hashes also matched for system proxy, DNS and default route; installed app PID remained unchanged.

Artifacts: `/tmp/clashfx-benchmark-optimization-verification`. Final real-core fixture: `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-real-core-menu-cfvondc1`. Live Enhanced Mode and external subscription performance require separate release verification.
