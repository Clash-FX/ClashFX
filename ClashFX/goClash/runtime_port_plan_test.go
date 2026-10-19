package main

import (
	"errors"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testEnhancedPortMaps() (map[string]interface{}, map[string]interface{}) {
	return map[string]interface{}{
			"allow-lan":  false,
			"mixed-port": 32123,
			"port":       8080,
			"socks-port": 1080,
		}, map[string]interface{}{
			"enable": true,
			"listen": "127.0.0.1:5353",
		}
}

func TestOwnedEnhancedPortPlanIsStableWithoutProbingOwnedPorts(t *testing.T) {
	for attempt := 0; attempt < 2; attempt++ {
		rawMap, dns := testEnhancedPortMaps()
		plan := &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 7874, Owned: true}
		probe := func(port int) bool {
			t.Fatalf("owned port %d must not be probed", port)
			return false
		}
		apiPort, dnsPort, err := selectEnhancedConfigPorts(rawMap, dns, plan, probe, probe, func() (int, error) {
			t.Fatal("owned port plan must not allocate random ports")
			return 0, nil
		})
		if err != nil {
			t.Fatalf("select owned ports: %v", err)
		}
		if apiPort != 19090 || dnsPort != 7874 {
			t.Fatalf("owned ports = (%d, %d), want (19090, 7874)", apiPort, dnsPort)
		}
		if got := rawMap["external-controller"]; got != "127.0.0.1:19090" {
			t.Fatalf("external-controller = %v", got)
		}
		if got := dns["listen"]; got != "127.0.0.1:7874" {
			t.Fatalf("dns.listen = %v", got)
		}
		if rawMap["port"] != 8080 || rawMap["socks-port"] != 1080 || rawMap["mixed-port"] != 32123 {
			t.Fatalf("proxy port fields changed: %#v", rawMap)
		}
	}
}

func TestOwnedEnhancedPortPlanRejectsNewProxyEndpointConflict(t *testing.T) {
	rawMap, dns := testEnhancedPortMaps()
	rawMap["listeners"] = []interface{}{
		map[string]interface{}{"type": "http", "listen": "127.0.0.1", "port": 20443},
	}
	plan := &enhancedConfigPortPlan{APIPort: 20443, DNSPort: 20787, Owned: true}
	probes := 0
	probe := func(int) bool { probes++; return true }
	_, _, err := selectEnhancedConfigPorts(rawMap, dns, plan, probe, probe, func() (int, error) {
		probes++
		return 30001, nil
	})
	if err == nil || !strings.Contains(err.Error(), "service=api_listener") {
		t.Fatalf("expected API endpoint conflict, got %v", err)
	}
	if probes != 0 {
		t.Fatalf("owned endpoints were probed or reallocated %d times", probes)
	}
}

func TestStartupPortPreferenceFallsBackWhenOccupiedAndPreservesProxyFields(t *testing.T) {
	rawMap, dns := testEnhancedPortMaps()
	wantProxyFields := map[string]interface{}{
		"port": rawMap["port"], "socks-port": rawMap["socks-port"], "mixed-port": rawMap["mixed-port"],
	}
	plan := &enhancedConfigPortPlan{APIPort: 25000, DNSPort: 25001}
	apiProbes := map[int]int{}
	dnsProbes := map[int]int{}
	apiPort, dnsPort, err := selectEnhancedConfigPorts(rawMap, dns, plan,
		func(port int) bool {
			apiProbes[port]++
			return port == 19090
		},
		func(port int) bool {
			dnsProbes[port]++
			return port == preferredEnhancedDNSPort
		},
		func() (int, error) { return 30002, nil })
	if err != nil {
		t.Fatalf("select startup ports: %v", err)
	}
	if apiPort != enhancedControllerPort || dnsPort != preferredEnhancedDNSPort {
		t.Fatalf("selected ports = (%d, %d), want (%d, %d)", apiPort, dnsPort, enhancedControllerPort, preferredEnhancedDNSPort)
	}
	if apiProbes[25000] != 1 || dnsProbes[25001] != 1 {
		t.Fatalf("previous ports were not checked: API=%v DNS=%v", apiProbes, dnsProbes)
	}
	for key, want := range wantProxyFields {
		if got := rawMap[key]; !reflect.DeepEqual(got, want) {
			t.Errorf("source proxy field %s changed: got %v, want %v", key, got, want)
		}
	}
}

func TestDecodeEnhancedConfigPortPlan(t *testing.T) {
	plan, err := decodeEnhancedConfigPortPlan(`{"apiPort":19090,"dnsPort":7874,"owned":true}`)
	if err != nil || plan == nil || !plan.Owned || plan.APIPort != 19090 || plan.DNSPort != 7874 {
		t.Fatalf("decoded plan = %#v, err=%v", plan, err)
	}
	if plan, err := decodeEnhancedConfigPortPlan(""); err != nil || plan != nil {
		t.Fatalf("empty plan = %#v, err=%v; want legacy nil plan", plan, err)
	}
	if _, err := decodeEnhancedConfigPortPlan(`{"apiPort":1,"dnsPort":2,"owned":false,"confirmed":true}`); err == nil {
		t.Fatal("unknown plan key should be rejected")
	}
}

func TestSubmittedSnapshotUpdatesOnlyAfterSuccessfulApply(t *testing.T) {
	var snapshot submittedConfigSnapshot
	if got := snapshot.bytes(); len(got) != 0 {
		t.Fatalf("empty snapshot = %q", got)
	}
	if err := applyAndRecordSubmittedConfig(&snapshot, []byte("old: true\n"), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	err := applyAndRecordSubmittedConfig(&snapshot, []byte("new: true\n"), func() error {
		return errors.New("apply failed")
	})
	if err == nil || string(snapshot.bytes()) != "old: true\n" {
		t.Fatalf("failed apply changed snapshot: value=%q err=%v", snapshot.bytes(), err)
	}
	input := []byte("exact: bytes\n")
	if err := applyAndRecordSubmittedConfig(&snapshot, input, func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	input[0] = 'X'
	got := snapshot.bytes()
	if string(got) != "exact: bytes\n" {
		t.Fatalf("snapshot did not copy submitted bytes: %q", got)
	}
	got[0] = 'Y'
	if string(snapshot.bytes()) != "exact: bytes\n" {
		t.Fatal("snapshot accessor returned mutable backing bytes")
	}
}

func TestCancelledConfigUpdateDoesNotApplyOrPublishSnapshot(t *testing.T) {
	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)
	configUpdateEpoch.Store(previousEpoch + 1)
	capturedEpoch := configUpdateEpoch.Load()

	var snapshot submittedConfigSnapshot
	if err := applyAndRecordSubmittedConfig(&snapshot, []byte("previous: true\n"), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	configUpdateEpoch.Add(1)
	applyCalled := false
	err := applyConfigUpdateIfCurrent(capturedEpoch, func() error {
		return applyAndRecordSubmittedConfig(&snapshot, []byte("stale: true\n"), func() error {
			applyCalled = true
			return nil
		})
	})
	if !errors.Is(err, errConfigUpdateCancelled) {
		t.Fatalf("cancelled update error = %v", err)
	}
	if applyCalled {
		t.Fatal("cancelled config update reached Apply")
	}
	if got := string(snapshot.bytes()); got != "previous: true\n" {
		t.Fatalf("cancelled update published snapshot %q", got)
	}
}

func TestConfigUpdateRequestedDuringSuspensionIsRejected(t *testing.T) {
	lifecycle := newCacheDBLifecycle(nil, "test-cache", time.Second)
	lifecycle.requestSuspend(nil)

	var epoch atomic.Uint64
	epoch.Store(42)
	if _, err := lifecycle.advanceEpochIfActive(&epoch); !errors.Is(err, errCoreSuspended) {
		t.Fatalf("TUN request during suspension returned %v, want suspended error", err)
	}
	if got := epoch.Load(); got != 42 {
		t.Fatalf("suspended TUN request advanced epoch to %d, want 42", got)
	}

	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)
	configUpdateEpoch.Store(42)
	applyCalled := false
	err := applyConfigUpdateForLifecycle(lifecycle, 42, func() error {
		applyCalled = true
		return nil
	})
	if !errors.Is(err, errCoreSuspended) {
		t.Fatalf("config update during suspension returned %v, want suspended error", err)
	}
	if applyCalled {
		t.Fatal("config update during suspension reached Apply")
	}
}

func TestEnqueuedUpdateTokenIsRejectedAfterCoreReplacement(t *testing.T) {
	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)

	// ApiRequest captures this token when it queues the closure. The core is
	// replaced before the serial queue gets around to invoking it.
	enqueuedToken := configUpdateEpoch.Load()
	configUpdateEpoch.Add(1)

	var snapshot submittedConfigSnapshot
	if err := applyAndRecordSubmittedConfig(&snapshot, []byte("replacement-core: true\n"), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	parseClosureCalled := false
	applyCalled := false
	err := applyConfigUpdateIfCurrent(enqueuedToken, func() error {
		parseClosureCalled = true
		return applyAndRecordSubmittedConfig(&snapshot, []byte("queued-old-config: true\n"), func() error {
			applyCalled = true
			return nil
		})
	})
	if !errors.Is(err, errConfigUpdateCancelled) {
		t.Fatalf("old queued update error = %v", err)
	}
	if parseClosureCalled {
		t.Fatal("old queued update entered Parse after core replacement")
	}
	if applyCalled {
		t.Fatal("old queued update reached Apply")
	}
	if got := string(snapshot.bytes()); got != "replacement-core: true\n" {
		t.Fatalf("old queued update replaced the new core snapshot: %q", got)
	}
}

func TestLifecycleMutationWaitsForApplyAlreadyInsideCoreLock(t *testing.T) {
	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)

	applyEntered := make(chan struct{})
	releaseApply := make(chan struct{})
	lifecycleAttempted := make(chan struct{})
	lifecycleDone := make(chan struct{})
	mutations := make(chan string, 2)

	go func() {
		_ = withCoreMutation(func() error {
			close(applyEntered)
			<-releaseApply
			mutations <- "apply"
			return nil
		})
	}()
	<-applyEntered
	go func() {
		configUpdateEpoch.Add(1)
		close(lifecycleAttempted)
		_ = withCoreMutation(func() error {
			mutations <- "lifecycle"
			close(lifecycleDone)
			return nil
		})
	}()
	<-lifecycleAttempted
	select {
	case <-lifecycleDone:
		t.Fatal("lifecycle mutation passed an Apply already holding the core lock")
	case <-time.After(10 * time.Millisecond):
	}
	close(releaseApply)
	select {
	case <-lifecycleDone:
	case <-time.After(time.Second):
		t.Fatal("lifecycle mutation did not proceed after Apply released the core lock")
	}
	if first, second := <-mutations, <-mutations; first != "apply" || second != "lifecycle" {
		t.Fatalf("mutation order = %q then %q", first, second)
	}
}

func TestQueuedApplyCannotPublishAfterNewCoreSnapshot(t *testing.T) {
	previousEpoch := configUpdateEpoch.Load()
	defer configUpdateEpoch.Store(previousEpoch)

	var snapshot submittedConfigSnapshot
	if err := applyAndRecordSubmittedConfig(&snapshot, []byte("old-core: true\n"), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	capturedEpoch := configUpdateEpoch.Load()
	coreMutationMu.Lock()
	locked := true
	defer func() {
		if locked {
			coreMutationMu.Unlock()
		}
	}()

	queued := make(chan struct{})
	result := make(chan error, 1)
	applyCalled := false
	go func() {
		close(queued)
		result <- applyConfigUpdateIfCurrent(capturedEpoch, func() error {
			applyCalled = true
			return applyAndRecordSubmittedConfig(&snapshot, []byte("stale-update: true\n"), func() error { return nil })
		})
	}()
	<-queued
	select {
	case err := <-result:
		t.Fatalf("queued update unexpectedly passed the held core lock: %v", err)
	case <-time.After(10 * time.Millisecond):
	}

	configUpdateEpoch.Add(1)
	if err := applyAndRecordSubmittedConfig(&snapshot, []byte("new-core: true\n"), func() error { return nil }); err != nil {
		t.Fatal(err)
	}
	coreMutationMu.Unlock()
	locked = false

	if err := <-result; !errors.Is(err, errConfigUpdateCancelled) {
		t.Fatalf("queued update result = %v", err)
	}
	if applyCalled {
		t.Fatal("queued stale update reached Apply")
	}
	if got := string(snapshot.bytes()); got != "new-core: true\n" {
		t.Fatalf("new core snapshot was overwritten: %q", got)
	}
}
