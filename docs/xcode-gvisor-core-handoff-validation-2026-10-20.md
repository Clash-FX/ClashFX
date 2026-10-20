# Xcode core handoff validation — 2026-10-20

## Confirmed cause

The supplied launch log reports `gVisor is not included in this build, rebuild with -tags with_gvisor`, followed by the CLI started marker. TUN listeners therefore never become ready, leaving the app waiting/retrying its external-core handoff. The previous local artifact refresh omitted the build tag; the existing release builder already included it. This was an artifact preparation error, not evidence of a Meta configuration problem.

Main Thread Checker separately identifies background `NSApplication.delegate` access when the readiness probe obtains the Helper through the application singleton.

## Changes

- Rebuild the embedded archive, generated header and standalone core through the canonical tagged builder using its new native-only option.
- Add a configuration-independent `--features` query, checked by the builder and an early app build phase. An absent or stale core now stops the build with an actionable error.
- Reject enabled gVisor/mixed TUN stacks in an unsupported CLI before apply or successful validation. Allow disabled TUN and system-stack configurations. The Swift validator recognizes the diagnostic without exposing configuration contents.
- Capture the Helper on the main queue at all three listener ownership probe sites; query the captured proxy off main with the existing bounded timeout. Settle stale callbacks while retaining caller generation fences.

## Isolated verification

- Full unhosted Swift suite: 492 tests, zero failures.
- App/Helper Debug build succeeds with the new capability phase. Private build disables format/lint mutation phases; workspace phases are preserved.
- Canonical native build succeeds, including the prebuild Go suite. Targeted CLI tests also pass with `with_gvisor`.
- Real tagged/untagged CLI capability matrix: 15 checks, including validation and unsupported startup rejection, disabled TUN, explicit system stack and default stack. Supported TUN configs are only parsed, never applied.
- Four offline capability-gate unit cases and the extracted production Helper queue/ownership/timeout harness pass.
- Real embedded-core session reload passes in both IPv6 preference directions, including explicit port/address edits. Real CLI recovery passes first-response selection, missing-target rejection, saved-selection preservation, nested selections and provider removal/reinsertion.
- A fresh independent worker reviewed the capability guard, sanitized error and all Helper capture paths; no blocking findings.

No app was launched, privileged Helper installed, installed executable replaced, or system proxy/DNS/TUN setting changed by this repair. Validated native core/archive/header artifacts have been copied into the workspace with private backups of their predecessors. Installed artifacts remain untouched. Before/after observations confirm the same running Helper/core/Meta process start times, system proxy and DNS configuration. The workspace macOS 14 test override remains active until the user finishes testing; deployment-target restoration remains separate.

This does not replace real TUN and authorization-dialog acceptance. The running Meta instance and existing ClashFX Helper/core are intentionally left untouched. Subsequent GUI handoff must be performed by the user.
