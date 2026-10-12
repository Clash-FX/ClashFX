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
	cache   *cachefile.CacheFile
	path    string
	timeout time.Duration
	closing atomic.Bool
}

func newCacheDBLifecycle(cache *cachefile.CacheFile, path string, timeout time.Duration) *cacheDBLifecycle {
	return &cacheDBLifecycle{
		cache:   cache,
		path:    path,
		timeout: timeout,
	}
}

func (l *cacheDBLifecycle) withOpen(start func() error) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if err := l.reopenLocked(); err != nil {
		return err
	}
	return start()
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
	l.mu.Lock()
	defer l.mu.Unlock()
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
