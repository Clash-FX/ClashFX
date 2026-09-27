# Issue #236: Enhanced Mode startup and benchmark feedback

Follow-up to the [1.1.11.7 report](https://github.com/Clash-FX/ClashFX/issues/236#issuecomment-5855458389).

## Changes

- Enhanced Mode readiness uses the helper's current process, launch-specific
  configuration path, binary path and actual TCP/UDP listeners. It no longer
  requires INFO-level DNS bind messages or a readable log file. Both DNS
  protocol probes must still succeed; removing the log requirement does not
  bypass listener ownership or protocol checks.
- Enhanced Mode menu validation and actions use pending lifecycle state.
  AppKit's automatic menu validation can no longer re-enable an in-progress
  toggle. Completed launches retain their identity without remaining busy.
- Launch/close completions carry their lifecycle generation. Obsolete callbacks
  cannot change current preferences, re-enable controls, present cancellation
  as an error, or restart a newer operation. Restore retries have their own
  identity and are cancelled by an ordinary launch, close, or lifecycle reset.
- Core transitions cancel in-flight benchmarks. Selector and automatic-group
  actions explain that the core is switching, and API/topology failures show
  a temporary action-level message with a detailed tooltip. Old measurements
  remain available; a missing topology is not fabricated into a failed node
  measurement. Cancelled/obsolete sessions do not display failure feedback.
- The global benchmark action no longer announces completion after a failed
  topology preflight. Menu polling runs only while a core transition needs to
  re-enable an attached menu view, not throughout ordinary menu use.
- Startup diagnostics distinguish an unattempted DNS probe from a failed
  response. Missing proxy listener diagnostics include the observed process
  and listener ports, without asserting that another application owns them.

## Verification — 2026-09-27

- 175 unhosted XCTest cases passed, including native menu interaction,
  cancellation/late-result handling, lifecycle state, DNS readiness, and
  system-proxy restoration tests using isolated dependencies.
- Native NSMenu auto-validation was exercised with the production validator:
  launch, close, restore and wake recovery keep the toggle disabled; completed
  operations re-enable it.
- A temporary, unprivileged core with TUN disabled and loopback-only listeners
  was exercised at `info`, `warning`, `error` and `silent` log levels. Its real
  socket snapshots and UDP/TCP DNS replies were evaluated by the before/after
  production readiness policies. The old policy rejected the last three
  levels; the new policy accepted all four.
- The pinned Mihomo 1.19.24 + production overlay / native menu integration
  fixture passed. Existing App/core PIDs and the system proxy snapshot were
  unchanged; fixture processes and listeners were cleaned up.
- The complete App and helper built successfully in a temporary source copy.
  Localized strings passed `plutil -lint`; `git diff --check` passed.

Local evidence: `/tmp/clashfx-236-all-tests-final.log`,
`/tmp/clashfx-236-app-build-final.log`,
`/tmp/clashfx-236-real-core-menu.log`, and `/tmp/clashfx-236/`.

## Remaining release checks

The local Xcode 27 SDK has a minimum deployment target of macOS 12 and fails
the repository's `verify-release-compatibility.py --sdk` gate for macOS 10.14.
The project and dependency deployment targets were not changed. Local XCTest
used a command-line target of 12; the App build used 14. These builds are not
macOS 10.14 release validation or release artifacts.

Before publishing a Lab, build with a compatible release toolchain and verify
real privileged TUN enable/disable, DNS restoration and system-proxy continuity.
This change was not installed into the running application and no release was
published. The reporter's exact log-level/port-conflict diagnosis still needs
their launch-specific core log/sample and relevant redacted configuration.
