# Xcode startup acceptance: checkpoint and geodata fixes

The user ran the current candidate from Xcode with temporary macOS 14 deployment targets. The screenshot reported “The running core no longer matches its confirmed listener checkpoint”. The pasted console output also showed enhanced-mode restoration failing to prepare its isolated validation directory. The raw pasted log contains subscription credentials and is not copied into this report or committed.

## Confirmed causes

1. **Checkpoint encoding was misreported as listener mismatch.** Baseline confirmation grouped fresh readback, listener/TUN comparison and Yams serialization in one guard. A private embedded-core probe confirmed the listener ports and TUN state matched, but Yams rejected a Foundation-backed JSON scalar with “Failed to represent 127.0.0.1”. The policy checked that values could bridge to String/Bool, then assigned the original NSString/NSNumber Any back to the root. Yams requires native representable Swift values. The fix assigns the typed native String/Bool bindings, preserving strict port and TUN checks. AppDelegate now reports readback, mismatch and encoding failures separately with value-free stage logs.
2. **Case-insensitive geodata aliases collided in staging.** GeoSite.dat and geosite.dat in the live config directory were confirmed by read-only stat to share device/inode. The resource list attempted both copies into a case-insensitive temporary directory with O_EXCL, so the second name failed. The fix skips EEXIST only when lstat proves the destination is a regular file this validation operation already copied from the same source device/inode. Unknown files, symlinks and distinct-source collisions remain errors. Source opens also use O_NONBLOCK before regular-file checks, preventing FIFO blocking.

The read-only live observation found the debug App listening on mixed port 7088 and controller 61490 after its requested 19090 was unavailable. Those observations do not justify bypassing checks or changing ports; the reproduced encoding error explains the false mismatch alert. Current connections and core were not mutated during diagnosis.

The earlier subscription-download failures occurred before the new core listener was ready: the console shows requests using old proxy port 7890 receiving connection refused. They do not establish a remote provider outage. This round does not change subscription scheduling or claim those download attempts succeeded. The autoShortcut/linkd messages are not the checkpoint failure path demonstrated by the reproducer.

## Verification

- Actual JSONSerialization readback regression asserts native Swift scalar types, exact listener comparison, preserved booleans and unchanged routing graph.
- Synthetic private GeoSite/geosite alias regression verifies successful staging with original no-follow/exclusive protections.
- **491 unhosted XCTest tests pass, zero failures.**
- **Isolated unsigned App/Helper build passes** with temporary macOS 14 build override; no running App/Helper is launched or replaced.
- New durable scripts/verify-runtime-checkpoint-yaml.py links the production Cgo bridge and Yams, runs an unprivileged core in private HOME with loopback-only dynamic endpoints and TUN/DNS disabled. Both normal startup and an owned-port blocker forcing API fallback round-trip the confirmed checkpoint through JSON readback and Yams. Both pass.
- A fresh Luna worker implemented the geodata fix and reviewed native scalar conversion and error stages. Listener-port/TUN checks remain intact; prior intentional mutable LAN/bind-setting refresh semantics were not broadened by this change.

Private evidence: 

`/var/folders/v0/tjnktt3n5f17150t8wrgy9g80000gn/T/clashfx-xcode-startup-diagnosis-o2uuk0fr`

Key logs: probe-dump.log (before fix: matching listeners then Yams encoding failure), fixed-checkpoint-yaml.log, full-tests.log, app-build.log. Root source is synchronized only after original-file hash checks, with backups retained. The original pasted attachment is not uploaded or reproduced in repository documentation.

Temporary macOS 14 project/Pods/Podfile settings stay active until the user finishes testing. Do not restore them during this repair. No installed/debug process controls, Helper replacement, proxy/DNS/TUN changes or release are performed by the agent. The running debugger process must be relaunched by the user to load the source fix; compilation alone does not hot-patch it.

Final read-only host comparison: {"processes": true, "binaries": true, "proxy": true, "dns": true}. Source-only changes synchronized; the user must relaunch the Xcode app to test them.
