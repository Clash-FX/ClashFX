# Lab 1.1.11.7 candidate validation

## Scope
Enhanced Mode lifecycle/readiness and port restoration fixes, DNS header parsing, and benchmark busy-state feedback for #236/#247.

## Completed locally
- 169 unhosted XCTest cases passed after the DNS parser fix.
- All 20 Go tests passed with the shipping dependency overlay before the Swift-only DNS parser fix.
- Complete App/Helper diagnostic build passed with the current native Go library/core. Local Xcode 27 validation used a temporary newer deployment target, not a release artifact.
- An isolated Mihomo 1.19.24 fixture returned valid UDP/TCP fake-IP answers without additional records. The old parser rejected both; the fixed parser accepts RCODE=0 and one answer. The fixture had no TUN or privileged Helper and was stopped afterward.
- On September 26, the user ran the updated Xcode build on a MacBook. Logs and read-only inspection confirmed TUN enabled with an IPv4 interface, API and owned DNS readiness, successful DNS queries and traffic.
- After a user-driven disable/re-enable cycle, logs showed the configured ordinary proxy port restored, DNS restoration completed, then Enhanced Mode became ready again. Current macOS HTTP/HTTPS/SOCKS proxy settings matched the running core.
- The disabled interval was not sampled directly with scutil; DNS restoration during that interval is supported by application logs, not an independent system snapshot.
- All main-project and Pods Debug/Release deployment settings and Podfile are restored to macOS 10.14. Native local test artifacts have been removed/restored; CI must regenerate the universal core from source.

## Required before publication
- [x] CI run [36219432971](https://github.com/Clash-FX/ClashFX/actions/runs/36219432971) passed the Xcode 26.6 SDK floor check (10.13), all 169 unhosted XCTest cases, Release build, and packaged App/Helper/core architecture and minimum-version gates. Reported minimums: App x86_64 10.14 / arm64 11.0; Helper x86_64 10.14 / arm64 11.0; core x86_64 10.13 / arm64 11.0.
- [ ] Runtime smoke test on macOS 10.14 remains required; CI checked deployment metadata but did not run the app on that OS.
- [x] Sleep/wake core health passed at 12:22. At 12:55/12:56, phone-hotspot and Wi-Fi return checks passed with unchanged core PID and proxy settings; user confirmed browsing on the hotspot. A separate installed/debug duplicate-instance Helper replacement after the earlier wake test is documented as a test-environment conflict, not a successful concurrent-instance scenario.
- [x] User confirmed browsing with TUN off and System Proxy on; logs confirmed restoration to the configured port and DNS restoration completion. This does not assert an independently captured scutil snapshot during the disabled interval.
- [ ] Verify final Lab packaging/update-channel output when release is authorized to proceed past these gates.

This is a release candidate record, not a claim that all Lab acceptance criteria have passed. CI build and compatibility gates passed, while old-system runtime and final Lab packaging/update-channel verification remain pending. Run a single ClashFX instance during validation; installed/debug builds share the privileged Helper and configuration directory.
