# Issue #236: isolated validation without interrupting the running app

## Reusable local check

Run `python3 scripts/verify-isolated-core-readiness.py` as a normal macOS user.
It builds the repository's pinned Mihomo with its production overlay and
compiles the production Swift readiness policy into a temporary test runner.
All fixture listeners bind to loopback, TUN is disabled, and the fixture uses
its own configuration/home. It does not launch the installed app or invoke
the privileged helper.

On 2026-09-27, both the implementation worker and the reviewing parent ran it
successfully:

- `info`, `warning`, `error`, and `silent`: actual controller/proxy/DNS
  listeners and UDP/TCP DNS responses were accepted by the production policy.
- Missing proxy port, missing DNS transport, and a foreign configuration
  identity were rejected.
- Existing App, core, and Helper process identities and system proxy/DNS
  snapshots were unchanged. The parent additionally compared IPv4/IPv6 default
  route fields with the initial baseline; they were unchanged.
- All fixture processes stopped and temporary directories were removed.

Local evidence is in `/tmp/clashfx-236-validation/local-readiness.json`,
`before.json`, and `after-local.json`.

## Disposable CI check

The dedicated validation snapshot is commit
`6ea2d98ce13da298ca5083c0a6922684ad30c08f` on
`codex/issue-236-isolated-validation`.
It contains the current fixes and the two new validation scripts. This is a
**validation-only branch**: its `main.yml` intentionally replaces the release
workflow with a dispatch-only, read-only validation workflow. Do not merge that
workflow replacement into the release branch.

[CI run 36320969930](https://github.com/Clash-FX/ClashFX/actions/runs/36320969930)
uses Xcode 26.6, preserves the repository deployment targets, runs the isolated
regressions, builds universal App/Helper binaries, and checks the actual App,
Helper, and core architecture/minimum-OS load commands.

`scripts/verify-ci-tun-lifecycle.py` refuses execution unless the environment
identifies a GitHub-hosted macOS runner and the process is root. In that
disposable runner only, it launches an independent core with TUN and automatic
routing enabled. It checks a newly created UP/IPv4 utun, owned listeners,
UDP/TCP fake-IP DNS responses, and a route lookup through the new utun. After
stopping only that core, it checks interface and route restoration. It never
changes system proxy/DNS settings or installs the ClashFX Helper.

The workflow has no release, tag, appcast update, or notification steps. The
default branch, existing application installation, and global GitHub account
selection are unchanged.

## CI results

Run 36320969930 completed successfully; the parent downloaded and checked the
original artifact logs rather than relying only on the overall green status.

- 175 XCTest cases passed with zero failures.
- Universal build and deployment gates passed: App/Helper minimums are 10.14
  for x86_64 and 11.0 for arm64; core minimums are 10.13 and 11.0 respectively.
- All four log-level readiness cases and all three rejection cases passed in
  CI as well as locally.
- Real core TUN created `utun4`, UP with IPv4 `198.18.0.1`. The route lookup for
  `203.0.113.1` selected that new interface. This check did not send packets to
  the reserved destination.
- The child PID owned its controller, mixed-proxy and TCP/UDP DNS listeners;
  UDP and TCP queries both returned fake-IP responses.
- SIGTERM stopped the fixture core with exit code 0, without forced killing.
  `utun4` and its routes disappeared; the original four utun interfaces, default
  route, and test-destination route returned to their baseline state.
- A final check on the user's Mac again confirmed unchanged App/core/Helper
  PIDs, system proxy/DNS hashes, and IPv4/IPv6 default-route fields. The global
  GitHub account selection was also unchanged.

Downloaded evidence: `/tmp/clashfx-236-validation/ci-logs/` and
`/tmp/clashfx-236-validation/after-final.json`.

## Scope limits

Binary deployment gates are not proof of execution on macOS 10.14 hardware.
Standalone core TUN tests are not full GUI/privileged-Helper enable/disable or
system DNS/proxy restoration acceptance. The existing isolated tests exercise
the production system-proxy manager with fake helper dependencies; they do not
write the host's network configuration.
