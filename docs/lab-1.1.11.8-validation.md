# Lab 1.1.11.8 validation record

## Evidence

- The 11 production, test, and localization files in this candidate match the corresponding files in validation snapshot `6ea2d98ce13da298ca5083c0a6922684ad30c08f` exactly.
- GitHub Actions run [36320969930](https://github.com/Clash-FX/ClashFX/actions/runs/36320969930) passed 175 XCTest cases, built universal App/Helper binaries, and passed the App/Helper/core minimum-system-version gates.
- Shipping-overlay Go tests passed in the candidate worktree.
- In the disposable hosted runner, an independent core created a working TUN interface, returned UDP/TCP fake-IP DNS responses, routed the test lookup through its TUN, and restored the prior interfaces and routes after shutdown.
- The local isolated readiness check passed without changing the installed App, core, Helper, system proxy/DNS, or default routes.
- The candidate is based on `origin/main` at `365cf54171c5cb51d8964b710a2cad9cad06b42a`. Its `.github/workflows/main.yml` matches that release workflow. The validation snapshot's workflow is intentionally different and is excluded from this candidate.

## Limits

The validation does not establish full GUI and privileged-Helper enable/disable behavior or system DNS/proxy restoration, and it does not establish runtime compatibility on macOS 10.14 hardware. Release-time packaging and signature checks, notarization, and the live appcast were not evaluated by the isolated workflow; it did not generate a Lab DMG.

After the scoped PR passes CI and is merged, the release path is an annotated four-segment tag at the merge commit. The tag workflow creates the Lab prerelease and a generated appcast PR; review and merge that appcast PR, then verify the live Lab feed. No tag or release is part of this candidate PR.
