package main

import (
	"fmt"
	"runtime"
	"sync"
	"testing"

	componentauth "github.com/metacubex/mihomo/component/auth"
	listenerauth "github.com/metacubex/mihomo/listener/auth"
)

func TestAuthStoreConcurrentSnapshotsAndNilTransitions(t *testing.T) {
	store := listenerauth.NewAuthStore(nil)
	first := componentauth.NewAuthenticator([]componentauth.AuthUser{{User: "alice", Pass: "alpha"}})
	second := componentauth.NewAuthenticator([]componentauth.AuthUser{{User: "bob", Pass: "bravo"}})

	if got := store.Authenticator(); got != nil {
		t.Fatalf("new auth store snapshot = %v, want nil", got)
	}
	store.SetAuthenticator(first)
	if got := store.Authenticator(); got != first {
		t.Fatalf("first auth store snapshot = %v, want first authenticator", got)
	}
	store.SetAuthenticator(nil)
	if got := store.Authenticator(); got != nil {
		t.Fatalf("nil auth store snapshot = %v, want nil", got)
	}

	const (
		readers    = 4
		iterations = 8192
	)
	start := make(chan struct{})
	failures := make(chan string, readers+1)
	var ready sync.WaitGroup
	var workers sync.WaitGroup
	ready.Add(readers + 1)
	workers.Add(readers + 1)

	for range readers {
		go func() {
			defer workers.Done()
			ready.Done()
			<-start
			for range iterations {
				if err := validAuthStoreSnapshot(store.Authenticator(), first, second); err != nil {
					failures <- err.Error()
					return
				}
				runtime.Gosched()
			}
		}()
	}

	go func() {
		defer workers.Done()
		ready.Done()
		<-start
		values := []componentauth.Authenticator{first, nil, second, nil}
		for i := range iterations {
			store.SetAuthenticator(values[i%len(values)])
			runtime.Gosched()
		}
		store.SetAuthenticator(nil)
	}()

	ready.Wait()
	close(start)
	workers.Wait()
	close(failures)
	for failure := range failures {
		t.Error(failure)
	}
	if got := store.Authenticator(); got != nil {
		t.Fatalf("final auth store snapshot = %v, want nil", got)
	}
}

func validAuthStoreSnapshot(
	got componentauth.Authenticator,
	first componentauth.Authenticator,
	second componentauth.Authenticator,
) error {
	switch got {
	case nil:
		return nil
	case first:
		if !got.Verify("alice", "alpha") {
			return fmt.Errorf("first authenticator snapshot was incomplete")
		}
		users := got.Users()
		if len(users) != 1 || users[0] != "alice" {
			return fmt.Errorf("first authenticator users snapshot was incomplete: %v", users)
		}
		return nil
	case second:
		if !got.Verify("bob", "bravo") {
			return fmt.Errorf("second authenticator snapshot was incomplete")
		}
		users := got.Users()
		if len(users) != 1 || users[0] != "bob" {
			return fmt.Errorf("second authenticator users snapshot was incomplete: %v", users)
		}
		return nil
	default:
		return fmt.Errorf("auth store returned an unknown or partial authenticator snapshot: %T", got)
	}
}
