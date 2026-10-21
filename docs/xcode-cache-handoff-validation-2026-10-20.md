# Cache lock after startup cleanup — 2026-10-20

## Evidence and cause

The supplied log reports confirmed stale-core cleanup immediately before the embedded core fails to open `cache.db` with a timeout. A read-only process listing still finds the earlier privileged ClashFX core with its original process ID and start time. Its `-d` argument ends in `/`.

The native scanner resolves its expected home directory, but its argv ownership predicate compared the raw `-d` argument directly against that resolved path. Consequently the still-running core was skipped. The fresh Helper then had no managed task and an empty scan, so it incorrectly reported successful cleanup. A root-owned core is not ruled out by an empty unprivileged `lsof` result. Its persistence and cache usage are consistent with the subsequent database lock failure; no live root file-descriptor probe or forced termination was performed.

The `com.apple.linkd.autoShortcut` and WebKit messages are separate from the recorded core-start failure.

## Repair

Normalize both absolute home paths through the same filesystem path resolution before comparison. Reject relative homes. Preserve executable/argv identity, unique `-d` and `-f` options, exact home ownership, and the generated UUID config filename check. Keep database locking intact: do not delete the cache, bypass its lock, or fall back to a separate empty cache that could lose user selections.

Regression coverage adds a trailing-slash argv and relative-home rejection to the ownership tests, and launches the real native process scanner fixture with a trailing-slash home. A standalone Foundation harness extracts the production ownership predicate and checks nine cases without XPC, listeners or system settings. The old predicate fails exactly the trailing-slash case; the repaired predicate passes all cases.

## Verification

- Full isolated unhosted suite: 492 tests pass, including the live scanner fixture.
- Production predicate harness: old code fails the reproduction; repaired code passes nine ownership/negative cases, including a symlink home alias.
- Independent review found no blocker; its suggested symlink-alias coverage was added to the standalone harness and passed.
- Isolated App/Helper Debug build succeeds. The existing Helper byte comparison and trust material checks detect a changed bundled Helper, so normal user-driven launch requests its update before cleanup.

This repair changes source and regression fixtures only. Existing Meta and old privileged ClashFX core processes are left running. No installed app or Helper is replaced, no proxy/DNS/TUN setting is written, and no release is published. The temporary macOS 14 override remains active. GUI verification requires a rebuilt app and its updated Helper; the old installed Helper retains the bug until updated through the normal user-driven authorization flow.
