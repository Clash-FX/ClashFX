package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	bbolt "github.com/metacubex/bbolt"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
)

type cacheDBLifecycle struct {
	mu      sync.Mutex
	stateMu sync.Mutex
	cache   *cachefile.CacheFile
	path    string
	timeout time.Duration
	closing atomic.Bool
	state   atomic.Uint64 // low bit is suspended; upper bits identify lifecycle requests.
}

func newCacheDBLifecycle(cache *cachefile.CacheFile, path string, timeout time.Duration) *cacheDBLifecycle {
	return &cacheDBLifecycle{
		cache:   cache,
		path:    path,
		timeout: timeout,
	}
}

func (l *cacheDBLifecycle) withOpen(start func() error) error {
	return l.withOpenRequested(l.state.Load(), start)
}

// Capture admission before waiting for mu so an explicit suspend can cancel an
// already queued request. Keeping that token explicit also makes race tests deterministic.
func (l *cacheDBLifecycle) withOpenRequested(requestedState uint64, start func() error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	state := l.state.Load()
	// Only an explicit lifecycle request invalidates a queued open. An older
	// startup's failure can set the suspended bit while the newer open waits;
	// its cleanup must not cancel that newer request as well.
	if state>>1 != requestedState>>1 {
		return errCoreLifecycleCancelled
	}

	if err := l.reopenLocked(); err != nil {
		return err
	}
	if err := start(); err != nil {
		// The startup callback tears down partial listeners before returning.
		// Fence mutations and release the database while still owning mu; do
		// not overwrite a newer suspend request published during startup.
		l.stateMu.Lock()
		if l.state.Load() == state {
			l.state.Store(state | 1)
		}
		l.stateMu.Unlock()
		if closeErr := l.closeLocked(); closeErr != nil {
			return fmt.Errorf("%w; cleanup: %v", err, closeErr)
		}
		return err
	}
	if !l.activateIfUnchanged(state) {
		return errCoreLifecycleCancelled
	}
	return nil
}

// withActive holds the cache lifecycle lock for active-core mutations. This
// makes their apply order explicit relative to suspend's stop-and-close path.
func (l *cacheDBLifecycle) withActive(mutate func() error) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.isSuspended() {
		return errCoreSuspended
	}
	return mutate()
}

func (l *cacheDBLifecycle) isSuspended() bool {
	return l.state.Load()&1 != 0
}

// advanceEpochIfActive pairs a TUN request's epoch bump with the suspend gate,
// so a request made after suspension cannot invalidate unrelated work.
func (l *cacheDBLifecycle) advanceEpochIfActive(epoch *atomic.Uint64) (uint64, error) {
	l.stateMu.Lock()
	defer l.stateMu.Unlock()
	if l.isSuspended() {
		return 0, errCoreSuspended
	}
	return epoch.Add(1), nil
}

func (l *cacheDBLifecycle) requestSuspend(invalidate func()) uint64 {
	l.stateMu.Lock()
	defer l.stateMu.Unlock()

	state := l.state.Load()
	nextGeneration := (state >> 1) + 1
	requested := (nextGeneration << 1) | 1
	l.state.Store(requested)
	if invalidate != nil {
		invalidate()
	}
	return requested
}

func (l *cacheDBLifecycle) activateIfUnchanged(state uint64) bool {
	l.stateMu.Lock()
	defer l.stateMu.Unlock()
	if l.state.Load() != state {
		return false
	}
	return l.state.CompareAndSwap(state, state&^uint64(1))
}

func (l *cacheDBLifecycle) reopen() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.reopenLocked()
}

func (l *cacheDBLifecycle) reopenLocked() error {
	if l.cache == nil {
		return fmt.Errorf("open cache database %q: cache wrapper is unavailable", l.path)
	}
	if err := l.cache.Reopen(l.path, 0o666, &bbolt.Options{Timeout: l.timeout}); err != nil {
		return fmt.Errorf("open cache database %q: %w", l.path, err)
	}
	return nil
}

func (l *cacheDBLifecycle) close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.closeLocked()
}

func (l *cacheDBLifecycle) suspend(stopCore func()) error {
	requested := l.requestSuspend(nil)
	return l.suspendRequested(requested, stopCore)
}

func (l *cacheDBLifecycle) suspendWithEpoch(stopCore func(), epoch *atomic.Uint64) error {
	requested := l.requestSuspend(func() { epoch.Add(1) })
	return l.suspendRequested(requested, stopCore)
}

func (l *cacheDBLifecycle) suspendRequested(requested uint64, stopCore func()) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.state.Load() != requested {
		return errCoreLifecycleCancelled
	}
	stopCore()
	return l.closeLocked()
}

func (l *cacheDBLifecycle) closeLocked() error {
	l.closing.Store(true)
	defer l.closing.Store(false)

	if l.cache == nil {
		return nil
	}
	if err := l.cache.Close(); err != nil {
		return fmt.Errorf("close cache database %q: %w", l.path, err)
	}
	return nil
}

var (
	processCacheDBLifecycleOnce sync.Once
	processCacheDBLifecycle     *cacheDBLifecycle
)

func currentCacheDBLifecycle() *cacheDBLifecycle {
	processCacheDBLifecycleOnce.Do(func() {
		processCacheDBLifecycle = newCacheDBLifecycle(cachefile.Cache(), constant.Path.Cache(), time.Second)
	})
	return processCacheDBLifecycle
}
