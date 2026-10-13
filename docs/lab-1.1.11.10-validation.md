# Lab 1.1.11.10 validation

Validated production source is carried from acceptance commit `6ed5254e1c6216c7086b3e00732f14cf89282ed7` onto current main. The latest main CI and existing appcast entries are retained. Source components are byte-identical to the accepted candidate; release notes and this summary are curated for publication.

- Isolated XCTest: 353 executed, 349 passed, 4 real-core cases skipped, zero failures.
- Separate Mihomo 1.19.24 integration: all 4 cases passed; owned fixture processes and listeners cleaned up.
- Actual production-method checks with fake dependencies: 19 Proxy Lock and 11 interaction checks passed.
- Real production XPC Helper/TUN and production transaction backend on a disposable hosted Mac: 35 runner assertions and 8 transaction assertions passed. [Immutable acceptance run](https://github.com/Clash-FX/ClashFX/actions/runs/38252765807).

The hosted backend covered real TUN, route and listener ownership, UDP/TCP DNS, core restart and invalid-config failure, actual SCPreferences write conflict and transaction rollback without preference commits, per-service proxy checkpoints, exact system proxy/DNS restoration and cleanup. Temporary cloned route-cache entries may expire; persistent/default forwarding paths and removal of fixture interfaces/routes were checked.

The reusable hosted runner refuses a non-hosted environment before privileged changes. Tests did not operate the developer's running ClashFX or its helper, core, proxy, TUN, DNS or configuration.

Coverage does not include complete Cocoa GUI/AppDelegate startup, SMJobBless authorization UI, physical display/power hot-plug, helper disable-error/caller cancellation injection, full GUI transaction DNS rollback or macOS 10.14 runtime testing. Helper DNS override/restoration was tested independently. The former HY2-69 503 cannot establish its underlying cause; controlled diagnostics are now available.

Publication CI and package/feed verification are recorded separately after completion.
