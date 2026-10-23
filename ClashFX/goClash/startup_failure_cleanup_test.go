package main

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	bbolt "github.com/metacubex/bbolt"
	"github.com/metacubex/mihomo/constant"
)

func TestFailedEmbeddedStartupReleasesEndpointsAndCache(t *testing.T) {
	kind := os.Getenv("CLASHFX_STARTUP_FAILURE_CHILD")
	if kind == "" {
		for _, kind := range []string{"HTTP conflict", "API conflict"} {
			t.Run(kind, func(t *testing.T) {
				cmd := exec.Command(os.Args[0], "-test.run=^TestFailedEmbeddedStartupReleasesEndpointsAndCache$", "-test.count=1")
				cmd.Env = append(os.Environ(), "CLASHFX_STARTUP_FAILURE_CHILD="+kind)
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("isolated startup failure: %v\n%s", err, output)
				}
			})
		}
		return
	}
	blocked, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocked.Close()
	allocated := map[int]bool{}
	freePort := func() int {
		t.Helper()
		// Keep fixtures away from the runner's usual outgoing ephemeral ports.
		// Actual loopback TCP/UDP binds still decide availability; never retry
		// a core startup failure or weaken the endpoint/cache cleanup assertions.
		for port := 20000; port < 40000; port++ {
			if allocated[port] {
				continue
			}
			tcp, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				continue
			}
			udp, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				tcp.Close()
				continue
			}
			tcp.Close()
			udp.Close()
			allocated[port] = true
			return port
		}
		t.Fatal("no private startup fixture port available")
		return 0
	}
	mixed, api := freePort(), freePort()
	for api == mixed {
		api = freePort()
	}
	httpPort := blocked.Addr().(*net.TCPAddr).Port
	if kind == "API conflict" {
		httpPort = 0
		api = mixed
	}
	raw := fmt.Sprintf("port: %d\nmixed-port: %d\nexternal-controller: 127.0.0.1:%d\nallow-lan: false\ndns: {enable: false}\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", httpPort, mixed, api)
	if err := os.WriteFile(constant.Path.Config(), []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	lifecycle := currentCacheDBLifecycle()
	defer lifecycle.suspend(stopBuiltinListenersForSuspend)
	_, err = startDefaultCoreWithCache(true, false, false, 0, "", configUpdateEpoch.Add(1))
	if err == nil {
		t.Fatal("conflicting endpoint unexpectedly started")
	}
	// ReCreateServer used to launch asynchronously before listener validation.
	time.Sleep(100 * time.Millisecond)
	for _, port := range []int{mixed, api} {
		address := fmt.Sprintf("127.0.0.1:%d", port)
		listener, err := net.Listen("tcp", address)
		if err != nil {
			t.Errorf("failed startup retained TCP %s: %v", address, err)
		} else {
			listener.Close()
		}
	}
	udp, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", mixed))
	if err != nil {
		t.Errorf("failed startup retained mixed UDP: %v", err)
	} else {
		udp.Close()
	}
	if !lifecycle.isSuspended() {
		t.Error("failed startup left core mutation gate active")
	}
	if len(lastSubmittedConfig.bytes()) != 0 {
		t.Error("failed startup published confirmed config")
	}
	db, err := bbolt.Open(constant.Path.Cache(), 0600, &bbolt.Options{Timeout: 100 * time.Millisecond})
	if err != nil {
		t.Errorf("failed startup retained cache DB: %v", err)
	} else {
		db.Close()
	}
	if t.Failed() {
		return
	}
	// A failed attempt must not poison the next start or keep its cache fenced.
	raw = strings.Replace(raw, fmt.Sprintf("port: %d\n", httpPort), "port: 0\n", 1)
	if kind == "API conflict" {
		api = freePort()
		for api == mixed {
			api = freePort()
		}
		raw = strings.Replace(raw, fmt.Sprintf("external-controller: 127.0.0.1:%d", mixed), fmt.Sprintf("external-controller: 127.0.0.1:%d", api), 1)
	}
	if err := os.WriteFile(constant.Path.Config(), []byte(raw), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := startDefaultCoreWithCache(true, false, false, 0, "", configUpdateEpoch.Add(1)); err != nil {
		t.Fatalf("retry after cleanup: %v", err)
	}
	if lifecycle.isSuspended() || len(lastSubmittedConfig.bytes()) == 0 {
		t.Fatal("healthy retry was not activated/recorded")
	}
	assertCustomInboundAcceptsTCP(t, mixed)
	// Even a stop issued immediately after successful setup must synchronously
	// release the API; a queued server goroutine must never reopen it later.
	for iteration := 0; iteration < 3; iteration++ {
		if err := lifecycle.suspendWithEpoch(stopBuiltinListenersForSuspend, &configUpdateEpoch); err != nil {
			t.Fatal(err)
		}
		for _, port := range []int{mixed, api} {
			endpoint, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				t.Fatalf("stop retained endpoint %d: %v", port, err)
			}
			endpoint.Close()
		}
		if _, err := startDefaultCoreWithCache(true, false, false, 0, "", configUpdateEpoch.Add(1)); err != nil {
			t.Fatalf("rapid restart: %v", err)
		}
	}
}

func TestRepeatedSuspendAndColdStartReusesCustomMixedPortAndKeepsForeignConflicts(t *testing.T) {
	ports := startBootstrapForProfileReload(t)
	lifecycle := currentCacheDBLifecycle()
	address := fmt.Sprintf("127.0.0.1:%d", ports.mixed)

	for cycle := 1; cycle <= 3; cycle++ {
		clashSuspendCore()
		if !lifecycle.isSuspended() {
			t.Fatalf("cycle %d: suspend did not fence the core", cycle)
		}
		assertLoopbackMixedPortAvailable(t, address)

		cfg, err := startDefaultCoreWithCache(true, false, false, 0, "", configUpdateEpoch.Add(1))
		if err != nil {
			t.Fatalf("cycle %d: cold start after suspend: %v", cycle, err)
		}
		if cfg.General.MixedPort != ports.mixed {
			t.Fatalf("cycle %d: mixed port = %d, want configured port %d", cycle, cfg.General.MixedPort, ports.mixed)
		}
		assertRepeatedMixedPortActive(t, address)
		if lifecycle.isSuspended() {
			t.Fatalf("cycle %d: successful cold start left the core suspended", cycle)
		}
	}

	clashSuspendCore()
	assertLoopbackMixedPortAvailable(t, address)
	foreignUDP, err := net.ListenPacket("udp", address)
	if err != nil {
		t.Fatalf("reserve foreign UDP owner on %s: %v", address, err)
	}
	defer foreignUDP.Close()

	if _, err := startDefaultCoreWithCache(true, false, false, 0, "", configUpdateEpoch.Add(1)); err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=proxy_listener ") ||
		!strings.Contains(err.Error(), fmt.Sprintf("port=%d", ports.mixed)) {
		t.Fatalf("cold start with a foreign UDP owner returned %v, want configured-port conflict", err)
	}
	if !lifecycle.isSuspended() {
		t.Fatal("foreign port conflict left the failed startup active")
	}
	probe, err := net.ListenPacket("udp", address)
	if err == nil {
		_ = probe.Close()
		t.Fatal("foreign UDP owner was displaced by the failed startup")
	}
}

func assertLoopbackMixedPortAvailable(t *testing.T, address string) {
	t.Helper()
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		t.Fatalf("mixed TCP endpoint %s remained bound after suspend: %v", address, err)
	}
	_ = tcp.Close()
	udp, err := net.ListenPacket("udp", address)
	if err != nil {
		t.Fatalf("mixed UDP endpoint %s remained bound after suspend: %v", address, err)
	}
	_ = udp.Close()
}

func assertRepeatedMixedPortActive(t *testing.T, address string) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", address, time.Second)
	if err != nil {
		t.Fatalf("mixed TCP endpoint %s did not accept after restart: %v", address, err)
	}
	_ = conn.Close()
	udp, err := net.ListenPacket("udp", address)
	if err == nil {
		_ = udp.Close()
		t.Fatalf("mixed UDP endpoint %s was not held after restart", address)
	}
}
