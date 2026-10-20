# Lab 1.1.11.14 candidate preparation — 2026-10-20

Candidate version: `1.1.11.14`, build `1001011014`, Lab enabled. Prepared on current upstream main `187ea95d19883514a63b07d92ac98ec1f5d8e81a` in a managed worktree; the original development checkout is retained. Production source and tests match the manually tested workspace, except candidate version metadata. Local planning files, private configurations, raw logs and generated native build artifacts are excluded.

## Compatibility and runtime evidence

The temporary deployment override was restored in all eight application-project configurations, 46 Pods configurations and the Podfile. Targets are macOS 10.14; Apple Silicon binary minimum remains macOS 11. The local SDK declares minimum 12.0 and intentionally fails the release compatibility gate. It is not used to produce a purported 10.14 release package. Hosted candidate CI selects the repository's existing Xcode 26.6 toolchain and must pass SDK and packaged App/Helper/core architecture/minimum gates.

The isolated repaired source passed 492 unhosted tests, App/Helper compilation, Go/core regressions, no-TUN recovery/provider tests and the Helper home-ownership reproduction. Standalone ownership harness now includes nine cases, including trailing slash, relative and foreign homes, config/executable exclusions and a symlink alias.

The user subsequently built and launched the repaired Debug app manually and completed its Helper authorization/update. Read-only inspection confirmed the old orphaned core disappeared; the new launch reported API/TUN/interface/owned DNS readiness, UDP+TCP system DNS verification and a healthy configuration checkpoint. The user switched from one profile to another; fresh API rules and traffic reflected the new profile. Claude browser requests after switching matched the retained locked target: five claude.ai and seven anthropic.com rule hits, with seven active connections carrying upload/download data through that target. These are observations of the local Debug build, not independent GUI acceptance of the final packaged release.

Remaining manual scope includes authorization cancellation, rapid full-GUI repeated switches/failed rollback and Claude Desktop process-name routing. Subscription refresh errors and individual provider probe timeouts remain visible; they were separate from the corrected core startup failures.

## Candidate-only automation

`lab-candidate.yml` builds a universal ad-hoc-signed Release candidate, checks packaged signatures, gVisor capabilities, dashboard and minimum OS, runs the source/race/listener/TUN regressions, and uploads a ZIP plus SHA256 as workflow artifacts. The existing isolated Helper/TUN acceptance also runs against this branch on a separate disposable hosted Mac. No production release workflow is dispatched, no tag is pushed and no Release/appcast/website update is created by candidate preparation. This ad-hoc signature matches the current Lab pipeline; no Developer ID notarization is claimed.

Hosted results and downloadable candidate artifact are recorded after completion. No installed local app, Helper, core or network configuration is changed by preparation.

## Toolchain and startup probe follow-up

The first hosted packaging attempt exposed Go 1.22 CLI test binaries without LC_UUID. External linking and explicit 10.14 compiler/linker floors retain x86_64 10.14 and arm64 11.0 while emitting UUIDs; private readiness binaries are signed before launch. Real local Go 1.22 CLI, signed capability and four-log-level listener/DNS tests passed, and the hosted App/Helper/core package compatibility and strict signature gates passed.

The subsequent tagged Go gate caught a startup cleanup fixture retry colliding on an ephemeral port. Independent analysis found a definite production precheck scope mismatch: loopback-only startup used wildcard TCP/UDP probes. It now mirrors Mihomo's actual binding, holding the TCP probe while checking UDP. Regression coverage qualifies IPv4 transport availability while holding an IPv6-only neighbor, then confirms IPv4 loopback succeeds and matching IPv6/wildcard conflicts remain rejected. Startup fixture allocations avoid the runner's usual ephemeral range and retain all original endpoint/cache release and same-port retry assertions. Tagged Go/race checks run before the long App build in the candidate workflow.

## 2026-10-21: authenticator concurrency follow-up

Continuing the full Go 1.22 race run reproduced unsynchronized auth-store interface reads in accepted HTTP connections concurrent with executor user updates during reload. The pinned Mihomo auth-store overlay now protects getter and setter with an RWMutex, preserves immutable authenticator snapshots and nil transitions, and leaves the no-op nil store unchanged. It verifies the exact upstream source hash before patching. A fresh-store concurrent reader/writer regression reproduces the data race when this overlay is disabled; the fixed full and focused race results are recorded with the final candidate evidence.
