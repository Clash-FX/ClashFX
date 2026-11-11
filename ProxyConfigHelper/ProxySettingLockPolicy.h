#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

// Policy for acquiring the system network preferences lock.
//
// SCPreferencesLock(ref, false) is non-blocking: when another writer (including
// another ClashFX helper operation such as DNS restore racing a system-proxy
// restore at quit) holds the lock it fails at once with kSCStatusPrefsBusy
// ("Preferences update currently in progress"). That state is transient, so
// callers retry for a bounded time instead of abandoning cleanup. Any other
// failure (authorization, invalid preferences, ...) is not retried.

static const NSTimeInterval ClashFXPreferencesLockRetryBudget = 3.0;
static const NSTimeInterval ClashFXPreferencesLockRetryInterval = 0.08;

static inline BOOL ClashFXShouldRetryPreferencesLock(int scStatus) {
    return scStatus == kSCStatusPrefsBusy;
}

// Runs `attempt` until it succeeds, fails with a non-retryable status, or the
// budget is exhausted. `attempt` returns YES on success; on failure it stores the
// failing status in *status. `sleep` is injectable so tests do not wait.
// Returns YES on success. `attempts` (optional) receives the number of tries.
static inline BOOL ClashFXAttemptPreferencesLock(NSTimeInterval budget,
                                                 NSTimeInterval interval,
                                                 BOOL (^attempt)(int *status),
                                                 void (^sleep)(NSTimeInterval),
                                                 NSTimeInterval (^now)(void),
                                                 int *finalStatus,
                                                 NSInteger *attempts) {
    NSTimeInterval deadline = now() + MAX(budget, 0);
    NSInteger tries = 0;
    int status = kSCStatusOK;
    BOOL ok = NO;
    while (YES) {
        tries += 1;
        status = kSCStatusOK;
        ok = attempt(&status);
        if (ok || !ClashFXShouldRetryPreferencesLock(status)) {
            break;
        }
        if (now() + interval >= deadline) {
            break;
        }
        sleep(interval);
    }
    if (finalStatus) {
        *finalStatus = ok ? kSCStatusOK : status;
    }
    if (attempts) {
        *attempts = tries;
    }
    return ok;
}
