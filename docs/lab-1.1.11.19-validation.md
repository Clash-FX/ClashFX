# Lab 1.1.11.19 validation

This release fixes Enhanced Mode-to-Local and cold Local startup handoffs. It checks the actual bootstrap, recovery checkpoint and finalized profile proxy ports before binding them. A shared 45-second deadline bounds the port wait, with lifecycle and baseline identity checks guarding submission. Ordinary verified Local reloads retain their previous path.

## Evidence before release

- A macOS 27.2.1 Apple Silicon experiment reproduced a root-owned TCP TIME_WAIT handoff: the ordinary-user bind initially returned EADDRINUSE, then the production waiter succeeded after 30.83 seconds. The same-user control bound immediately. Direct socket state and successful fixture exit were observed; the Terminal netstat observer was unavailable, so independent post-exit TCP-table claims are not made.
- The exact production source passed full local application acceptance on 2026-11-13 (Asia/Singapore): verified Local startup, TUN enable, TUN disable with complete profile readback, HTTPS through the Local proxy, and TUN re-enable with a new external core. Readback retained 25 policy groups and 7,254 rules, allowing only known telemetry and the existing Local startup bypass-prefix difference. Baseline application, Enhanced Mode, physical DNS, default route, system proxy and HTTPS recovery all passed.
- The original cold-start source and a deliberately removed port deadline both failed the new regression at early profile submission. Revised cold-start, close/retry, stale-session, timeout, rollback and readiness-fence harnesses passed. Ten socket-waiter tests passed using temporary loopback endpoints. These tests did not operate the installed application.
- A universal Release candidate passed the SDK deployment check, app/helper/core minimum-version checks, bundled Mach-O inspection, deep/strict signatures, core features, Dashboard and ZIP integrity. The isolated Xcode 27 compiler used the genuine macOS 26.5 SDK with an explicit 10.14 target, including SwiftPM. Intel minima are 10.14 and Apple Silicon minima are 11.0. The unchanged core was built with Go 1.22.
- The final published tag build must independently pass CI and packaged artifact checks. The local acceptance candidate retained inherited internal version metadata; it is not the distributable versioned release asset.

## Release identity and limits

Tag: `1.1.11.19`. Sparkle build: `1001011019`. Channel: `lab`. Publication uses the repository tag workflow and a reviewed appcast update.

The signing pipeline is ad hoc with a Sparkle-signed update payload; Developer ID notarization is not claimed. Execution on macOS 10.14 or Intel hardware and long-duration stress testing remain unverified. The locally installed 1.1.11.18 is not updated or restarted as part of publication.
