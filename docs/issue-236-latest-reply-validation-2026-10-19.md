# Issue 236 latest reply: automatic-group benchmark display

Reviewed the [latest reporter reply](https://github.com/Clash-FX/ClashFX/issues/236#issuecomment-6268816440), posted 2026-10-19 at 21:50 Asia/Shanghai, and both screenshots. Uses the current unpublished candidate, not the installed Lab. gh account: mixc6763-prog. No reply was posted to GitHub.

## Findings

The screenshot shows zero unavailable probes in the summary but an unavailable selected automatic-group row. A reproducible presentation bug can produce that symptom: completed evidence for an older selected path is invalidated after a fresh core snapshot chooses another leaf. Converting that invalidation into an unavailable attempt lets the old row timestamp supersede the new leaf's valid earlier measurement. Automatic group headers have an analogous problem because they create a newly timestamped unavailable presentation during reconciliation.

The reporter supplied screenshots without the corresponding config or current diagnostic log. The code/test finding is confirmed; the precise production trigger in those screenshots remains inferred.

The label “过滤掉1条线路” is absent from application-generated strings and appears beside quota/expiry entries in the screenshots. The menu uses decoded proxy/group names without generating that phrase, so it is likely supplied by the subscription/config. Its exact provider meaning cannot be established from the screenshot. A configuration entry bearing that name can still resolve through a proxy endpoint and receive a delay measurement. The measured ms value is latency, not download speed or a count of filtered nodes. Do not hide or disable such entries based on their names.

## Fix

- Separate evidence matching from displaying an unavailable result. Discard Selector context whose URL, final leaf, or core identity no longer matches, allowing evidence for the actual current leaf to resolve normally.
- Keep completed automatic-header evidence attached to the path actually probed. Rendering continues to obtain the route from Mihomo's fresh now; the old path cannot create a synthetic new attempt against the current leaf.
- Merge the current leaf's real latest attempt into header presentation, preserving actual failure, timeout and unavailable states over older success.
- Leave genuine same-path outcomes, benchmark URL/expected-status separation, identity checks, cancellation and main-queue UI ownership intact. No core selection or subscription contents are changed.

## Validation

- Baseline: 475 unhosted XCTest cases passed before changes.
- Two regression cases against unchanged production sources fail with the exact unavailable-versus-current-delay mismatch (including live rows, reopened menus and group headers). They also test real current-leaf unavailable, timeout and failure signals.
- Final production-source XCTest bundle: 477 cases passed, zero failures.
- Real Mihomo 1.19.24 plus production overlay and AppKit menu fixture: checks actual core-selected path changes, current-node delay retained by live/reopened rows, URL isolation, actual node failures and manual-priority/automatic-route behavior. Private HOME/config, dynamic loopback endpoints, TUN disabled; all owned processes/listeners are cleaned up.
- A fresh independent Luna reviewer checked the final three production-file changes and found no concrete regressions. Review was read-only; parent owns test execution and acceptance.

Validation observations: an initial extended real-core fixture incorrectly assumed that a matching group-delay request must be issued by the Selector; core-reported expected-status semantics can legitimately choose individual leaf requests instead. The fixture now seeds a later old-path presentation from actual core measurement evidence and changes the real core path via PUT/DELETE, without depending on that endpoint choice. This is test setup, not a new production change. One parallel full-suite attempt also failed the existing reused-descriptor validation test; unchanged baseline and the final serial full suite pass. No RuntimeConfigValidationRunner or descriptor test sources were changed in this benchmark fix; the intermittent result is retained in final-tests.log rather than concealed.

## Evidence and scope

Private evidence directory: `/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-issue236-latest-_m9mkkm3`. Pointer: /tmp/clashfx-issue236-latest-path.

Key logs: baseline-tests.log, red-final-regressions.log, final-tests-after-review.log, final-reviewed-real-core.log. before-fix/ retains original production sources; backups and bounded source hashes are retained during synchronization.

No installed ClashFX/Helper/core control, system proxy/DNS/TUN configuration changes, GitHub replies, release, install or application replacement. This round is a targeted issue fix and does not clear the remaining full candidate-package GUI/authorization acceptance gap.

Final host comparison: installed App/Helper/core PID and start times, installed executable SHA256, system proxy and system DNS all match the initial baseline exactly. Final reviewed real-core fixture result.json is passed; all four real-core menu cases pass and the new path-refresh marker is present.
