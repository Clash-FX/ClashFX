package main

import (
	"bytes"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	bbolt "github.com/metacubex/bbolt"
	"github.com/metacubex/mihomo/component/profile"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
)

func TestMain(m *testing.M) {
	testHome, err := os.MkdirTemp("", "clashfx-go-test-home-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "create isolated Mihomo test home: %v\n", err)
		os.Exit(1)
	}
	constant.SetHomeDir(testHome)
	constant.SetConfig(filepath.Join(testHome, "config.yaml"))

	exitCode := m.Run()
	if err := os.RemoveAll(testHome); err != nil {
		fmt.Fprintf(os.Stderr, "remove isolated Mihomo test home: %v\n", err)
		if exitCode == 0 {
			exitCode = 1
		}
	}
	os.Exit(exitCode)
}

func openTestCacheDB(t *testing.T, path string) *bbolt.DB {
	t.Helper()
	db, err := bbolt.Open(path, 0o600, &bbolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open temporary cache DB: %v", err)
	}
	return db
}

func TestCacheDBLifecycleCloseReopenPreservesCacheFileData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	cache := &cachefile.CacheFile{DB: openTestCacheDB(t, path)}
	lifecycle := newCacheDBLifecycle(cache, path, 100*time.Millisecond)
	t.Cleanup(func() {
		if err := lifecycle.close(); err != nil {
			t.Errorf("close temporary cache DB: %v", err)
		}
	})

	for round := 0; round < 4; round++ {
		value := []byte(fmt.Sprintf("persisted-round-%d", round))
		cache.SetStorage("lifecycle", value)

		if err := lifecycle.close(); err != nil {
			t.Fatalf("close round %d: %v", round, err)
		}
		if cache.DB == nil {
			t.Fatalf("close round %d cleared CacheFile.DB", round)
		}

		if err := lifecycle.reopen(); err != nil {
			t.Fatalf("reopen round %d: %v", round, err)
		}
		if got := cache.GetStorage("lifecycle"); !bytes.Equal(got, value) {
			t.Fatalf("round %d read %q, want %q", round, got, value)
		}
	}
}

func TestCacheDBLifecycleLockTimeoutCanRetry(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	owner := openTestCacheDB(t, path)
	cache := &cachefile.CacheFile{}
	lifecycle := newCacheDBLifecycle(cache, path, 60*time.Millisecond)
	t.Cleanup(func() {
		if err := lifecycle.close(); err != nil {
			t.Errorf("cleanup cache DB: %v", err)
		}
		if err := owner.Close(); err != nil {
			t.Errorf("cleanup competing DB: %v", err)
		}
	})

	err := lifecycle.reopen()
	if !errors.Is(err, bbolt.ErrTimeout) {
		t.Fatalf("reopen with competing DB lock returned %v, want timeout", err)
	}
	if cache.DB != nil {
		t.Fatal("failed reopen installed a cache DB")
	}

	if err := owner.Close(); err != nil {
		t.Fatalf("release competing DB lock: %v", err)
	}
	if err := lifecycle.reopen(); err != nil {
		t.Fatalf("retry reopen after lock release: %v", err)
	}
	cache.SetStorage("retry", []byte("opened"))
	if got := cache.GetStorage("retry"); string(got) != "opened" {
		t.Fatalf("cache wrapper returned %q after retry", got)
	}
	if err := lifecycle.close(); err != nil {
		t.Fatalf("close reopened DB: %v", err)
	}
}

func TestCacheDBLifecycleWaitsForWriterBeforeCloseAndReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	db := openTestCacheDB(t, path)
	cache := &cachefile.CacheFile{DB: db}
	lifecycle := newCacheDBLifecycle(cache, path, 60*time.Millisecond)

	writer, err := db.Begin(true)
	if err != nil {
		t.Fatalf("begin active writer: %v", err)
	}
	closeDone := make(chan error, 1)
	go func() {
		closeDone <- lifecycle.close()
	}()
	reopenDone := make(chan error, 1)
	writerFinished := false
	closeFinished := false
	reopenStarted := false
	reopenFinished := false
	t.Cleanup(func() {
		if !writerFinished {
			_ = writer.Rollback()
		}
		if !closeFinished {
			<-closeDone
		}
		if reopenStarted && !reopenFinished {
			<-reopenDone
		}
		if err := lifecycle.close(); err != nil {
			t.Errorf("cleanup lifecycle: %v", err)
		}
	})

	deadline := time.After(time.Second)
	for !lifecycle.closing.Load() {
		select {
		case <-deadline:
			t.Fatal("close never entered its exclusive lifecycle section")
		case <-time.After(time.Millisecond):
		}
	}

	reopenStarted = true
	go func() {
		reopenDone <- lifecycle.reopen()
	}()

	select {
	case err := <-reopenDone:
		reopenFinished = true
		t.Fatalf("reopen succeeded while close was waiting on the writer: %v", err)
	case <-time.After(40 * time.Millisecond):
	}

	contender, err := bbolt.Open(path, 0o600, &bbolt.Options{Timeout: 40 * time.Millisecond})
	if err == nil {
		_ = contender.Close()
		t.Fatal("a second DB acquired the lock while the active writer held it")
	}
	if !errors.Is(err, bbolt.ErrTimeout) {
		t.Fatalf("competing open returned %v, want timeout", err)
	}

	if err := writer.Rollback(); err != nil {
		t.Fatalf("finish active writer: %v", err)
	}
	writerFinished = true
	if err := <-closeDone; err != nil {
		closeFinished = true
		t.Fatalf("close after writer completed: %v", err)
	}
	closeFinished = true
	if err := <-reopenDone; err != nil {
		reopenFinished = true
		t.Fatalf("reopen after close released the lock: %v", err)
	}
	reopenFinished = true
	if err := lifecycle.close(); err != nil {
		t.Fatalf("final close: %v", err)
	}
}

func TestCacheDBLifecycleBlockedApplyCannotRunAfterCacheClose(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	db := openTestCacheDB(t, path)
	cache := &cachefile.CacheFile{DB: db}
	lifecycle := newCacheDBLifecycle(cache, path, time.Second)
	t.Cleanup(func() {
		if err := lifecycle.close(); err != nil {
			t.Errorf("cleanup lifecycle: %v", err)
		}
	})

	var epoch atomic.Uint64
	epoch.Store(17)
	coreMutationMu.Lock()
	coreLockHeld := true
	defer func() {
		if coreLockHeld {
			coreMutationMu.Unlock()
		}
	}()

	stopEntered := make(chan struct{})
	suspendDone := make(chan error, 1)
	go func() {
		suspendDone <- lifecycle.suspendWithEpoch(func() {
			close(stopEntered)
			_ = withCoreMutation(func() error { return nil })
		}, &epoch)
	}()
	select {
	case <-stopEntered:
	case <-time.After(time.Second):
		t.Fatal("suspend did not enter its core-stop section")
	}

	var applyCalled atomic.Bool
	applyAttempted := make(chan struct{})
	applyDone := make(chan error, 1)
	go func() {
		close(applyAttempted)
		applyDone <- applyActiveConfigUpdate(lifecycle, epoch.Load(), func() error {
			applyCalled.Store(true)
			return nil
		})
	}()
	<-applyAttempted

	coreMutationMu.Unlock()
	coreLockHeld = false
	select {
	case err := <-suspendDone:
		if err != nil {
			t.Fatalf("suspend and close cache: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("suspend did not finish after the core lock was released")
	}
	select {
	case err := <-applyDone:
		if !errors.Is(err, errCoreSuspended) {
			t.Fatalf("blocked apply returned %v, want suspended error", err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked apply did not finish after suspension")
	}
	if applyCalled.Load() {
		t.Fatal("blocked apply ran after suspend closed the cache")
	}

	competitor, err := bbolt.Open(path, 0o600, &bbolt.Options{Timeout: time.Second})
	if err != nil {
		t.Fatalf("open cache after suspend closed it: %v", err)
	}
	if err := competitor.Close(); err != nil {
		t.Fatalf("close competing cache DB: %v", err)
	}
}

func TestCacheDBLifecycleResumeActivatesOnlyAfterSuccessfulStartup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	cache := &cachefile.CacheFile{DB: openTestCacheDB(t, path)}
	lifecycle := newCacheDBLifecycle(cache, path, time.Second)
	t.Cleanup(func() {
		if err := lifecycle.close(); err != nil {
			t.Errorf("cleanup lifecycle: %v", err)
		}
	})

	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)
	configUpdateEpoch.Store(50)
	if err := lifecycle.suspend(func() {}); err != nil {
		t.Fatalf("suspend before resume: %v", err)
	}
	oldEpoch := configUpdateEpoch.Load()

	if err := lifecycle.withOpen(func() error { return errors.New("startup failed") }); err == nil {
		t.Fatal("failed startup unexpectedly succeeded")
	}
	if !lifecycle.isSuspended() {
		t.Fatal("failed startup cleared the suspended gate")
	}
	if err := lifecycle.close(); err != nil {
		t.Fatalf("close cache after failed startup: %v", err)
	}

	newEpoch := configUpdateEpoch.Add(1)
	if err := lifecycle.withOpen(func() error {
		if !lifecycle.isSuspended() {
			return errors.New("core became active before startup completed")
		}
		return nil
	}); err != nil {
		t.Fatalf("successful resume startup: %v", err)
	}
	if lifecycle.isSuspended() {
		t.Fatal("successful resume did not clear the suspended gate")
	}

	oldApplyCalled := false
	if err := applyConfigUpdateForLifecycle(lifecycle, oldEpoch, func() error {
		oldApplyCalled = true
		return nil
	}); !errors.Is(err, errConfigUpdateCancelled) {
		t.Fatalf("pre-resume epoch returned %v, want cancelled", err)
	}
	if oldApplyCalled {
		t.Fatal("pre-resume queued update reached Apply")
	}

	newApplyCalled := false
	if err := applyConfigUpdateForLifecycle(lifecycle, newEpoch, func() error {
		newApplyCalled = true
		return nil
	}); err != nil {
		t.Fatalf("current post-resume epoch was rejected: %v", err)
	}
	if !newApplyCalled {
		t.Fatal("post-resume update did not reach Apply")
	}
}

func TestCacheDBLifecycleConcurrentCacheFileWrites(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	cache := &cachefile.CacheFile{DB: openTestCacheDB(t, path)}
	lifecycle := newCacheDBLifecycle(cache, path, 100*time.Millisecond)
	t.Cleanup(func() {
		if err := lifecycle.close(); err != nil {
			t.Errorf("cleanup concurrent cache DB: %v", err)
		}
	})
	store := cache.FakeIpStore()
	ip := netip.MustParseAddr("198.51.100.17")
	storeSelected := profile.StoreSelected.Load()
	profile.StoreSelected.Store(true)
	t.Cleanup(func() { profile.StoreSelected.Store(storeSelected) })
	start := make(chan struct{})
	var workers sync.WaitGroup
	workerErrors := make(chan error, 1)

	for worker := 0; worker < 5; worker++ {
		worker := worker
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			for iteration := 0; iteration < 60; iteration++ {
				key := fmt.Sprintf("worker-%d-%d", worker, iteration)
				cache.SetStorage(key, []byte(key))
				_ = cache.GetStorage(key)
				cache.SetSubscriptionInfo(key, key)
				_ = cache.GetSubscriptionInfo(key)
				cache.SetETagWithHash(key, cachefile.EtagWithHash{ETag: key, Time: time.Now()})
				_ = cache.GetETagWithHash(key)
				cache.SetSelected(fmt.Sprintf("group-%d", worker), key)
				_ = cache.SelectedMap()
				store.PutByHost(key, ip)
				if got, exists := store.GetByHost(key); exists && got != ip {
					select {
					case workerErrors <- fmt.Errorf("%s mapped to %s", key, got):
					default:
					}
				}
			}
		}()
	}

	lifecycleDone := make(chan error, 1)
	go func() {
		<-start
		for round := 0; round < 12; round++ {
			if err := lifecycle.close(); err != nil {
				lifecycleDone <- fmt.Errorf("close round %d: %w", round, err)
				return
			}
			if err := lifecycle.reopen(); err != nil {
				lifecycleDone <- fmt.Errorf("reopen round %d: %w", round, err)
				return
			}
		}
		lifecycleDone <- nil
	}()

	close(start)
	workers.Wait()
	if err := <-lifecycleDone; err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-workerErrors:
		t.Fatal(err)
	default:
	}

	if err := lifecycle.reopen(); err != nil {
		t.Fatalf("final reopen: %v", err)
	}
	cache.SetStorage("final", []byte("available"))
	if got := cache.GetStorage("final"); string(got) != "available" {
		t.Fatalf("final cache write returned %q", got)
	}
	if err := lifecycle.close(); err != nil {
		t.Fatalf("final close: %v", err)
	}
}

func TestStaleSuspendCannotStopSuccessfulResume(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cache.db")
	lifecycle := newCacheDBLifecycle(&cachefile.CacheFile{DB: openTestCacheDB(t, path)}, path, time.Second)
	t.Cleanup(func() { _ = lifecycle.close() })
	requested := lifecycle.requestSuspend(nil)
	if err := lifecycle.withOpen(func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	stopped := false
	if err := lifecycle.suspendRequested(requested, func() { stopped = true }); !errors.Is(err, errCoreLifecycleCancelled) {
		t.Fatalf("stale suspend error=%v", err)
	}
	if stopped || lifecycle.isSuspended() {
		t.Fatal("stale suspend stopped or marked the replacement core")
	}
	if err := lifecycle.withActive(func() error { return nil }); err != nil {
		t.Fatalf("resumed core unavailable: %v", err)
	}
	if err := lifecycle.cache.DB.Update(func(tx *bbolt.Tx) error { _, err := tx.CreateBucketIfNotExists([]byte("still-open")); return err }); err != nil {
		t.Fatalf("stale suspend closed cache: %v", err)
	}
}

// A superseded start may fail while the latest start is already waiting for
// its cleanup. Only an explicit suspend should invalidate the waiting start.
func TestFailedStartupDoesNotCancelNewerQueuedOpen(t *testing.T) {
	for _, suspend := range []bool{false, true} {
		t.Run(fmt.Sprintf("explicit_suspend_%t", suspend), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "cache.db")
			lifecycle := newCacheDBLifecycle(&cachefile.CacheFile{DB: openTestCacheDB(t, path)}, path, time.Second)
			t.Cleanup(func() { _ = lifecycle.close() })
			entered, release := make(chan struct{}), make(chan struct{})
			oldDone, newDone := make(chan error, 1), make(chan error, 1)
			go func() {
				oldDone <- lifecycle.withOpen(func() error { close(entered); <-release; return errCoreLifecycleCancelled })
			}()
			<-entered
			// Capture the token withOpen records at entry, before failure cleanup
			// or an explicit suspend can run; no scheduler timing is required.
			requestedState := lifecycle.state.Load()
			ran := false
			go func() {
				newDone <- lifecycle.withOpenRequested(requestedState, func() error { ran = true; return nil })
			}()
			if suspend {
				lifecycle.requestSuspend(nil)
			}
			close(release)
			if err := <-oldDone; !errors.Is(err, errCoreLifecycleCancelled) {
				t.Fatalf("old startup: %v", err)
			}
			err := <-newDone
			if suspend {
				if !errors.Is(err, errCoreLifecycleCancelled) || ran || !lifecycle.isSuspended() {
					t.Fatalf("explicit suspend did not fence queued open: err=%v ran=%t", err, ran)
				}
			} else {
				if err != nil || !ran || lifecycle.isSuspended() {
					t.Fatalf("older failure canceled newer startup: err=%v ran=%t", err, ran)
				}
				if err := lifecycle.cache.DB.Update(func(tx *bbolt.Tx) error { _, err := tx.CreateBucketIfNotExists([]byte("newer-open")); return err }); err != nil {
					t.Fatalf("newer startup cache unavailable: %v", err)
				}
			}
		})
	}
}
