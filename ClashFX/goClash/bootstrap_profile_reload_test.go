package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
)

type bootstrapProfilePorts struct {
	mixed int
	api   string
}

func reserveBootstrapLoopbackPort(t *testing.T, udp bool, excluded ...int) int {
	t.Helper()
	blocked := make(map[int]bool, len(excluded))
	for _, port := range excluded {
		blocked[port] = true
	}
	for attempt := 0; attempt < 64; attempt++ {
		tcp, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("reserve loopback TCP fixture: %v", err)
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		if blocked[port] {
			_ = tcp.Close()
			continue
		}
		var packet net.PacketConn
		if udp {
			packet, err = net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				_ = tcp.Close()
				continue
			}
		}
		_ = tcp.Close()
		if packet != nil {
			_ = packet.Close()
		}
		return port
	}
	t.Fatal("could not reserve distinct loopback fixture ports")
	return 0
}

func bootstrapProfileResultString(pointer unsafe.Pointer) string {
	if pointer == nil {
		return ""
	}
	for size := 0; size < 4096; size++ {
		if *(*byte)(unsafe.Add(pointer, size)) == 0 {
			return string(unsafe.Slice((*byte)(pointer), size))
		}
	}
	return "unterminated C string"
}

func writeBootstrapProfile(t *testing.T, name, contents string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write isolated profile fixture: %v", err)
	}
	return path
}

func startBootstrapForProfileReload(t *testing.T) bootstrapProfilePorts {
	t.Helper()
	tunMu.Lock()
	previousTunEnabled := tunEnabled
	tunEnabled = false
	tunMu.Unlock()
	t.Cleanup(func() {
		tunMu.Lock()
		tunEnabled = previousTunEnabled
		tunMu.Unlock()
	})
	mixedPort := reserveBootstrapLoopbackPort(t, true)
	apiFixturePort := reserveBootstrapLoopbackPort(t, false, mixedPort)
	apiAddress := fmt.Sprintf("127.0.0.1:%d", apiFixturePort)
	bootstrap := fmt.Sprintf("mixed-port: %d\nallow-lan: false\nbind-address: 127.0.0.1\nexternal-controller: %s\ndns: {enable: false}\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", mixedPort, apiAddress)
	if err := os.WriteFile(constant.Path.Config(), []byte(bootstrap), 0o600); err != nil {
		t.Fatalf("write private bootstrap config: %v", err)
	}

	lifecycle := currentCacheDBLifecycle()
	t.Cleanup(func() {
		if err := lifecycle.suspendWithEpoch(stopBuiltinListenersForSuspend, &configUpdateEpoch); err != nil && err != errCoreLifecycleCancelled {
			t.Errorf("suspend isolated bootstrap core: %v", err)
		}
	})
	epoch := configUpdateEpoch.Add(1)
	cfg, err := startDefaultCoreWithCache(false, false, false, 0, "", epoch)
	if err != nil {
		t.Fatalf("loopback bootstrap start: %v", err)
	}
	if cfg.Controller.ExternalController != apiAddress {
		t.Fatalf("bootstrap API = %q, want %q", cfg.Controller.ExternalController, apiAddress)
	}
	host, portText, err := net.SplitHostPort(cfg.Controller.ExternalController)
	if err != nil || host != "127.0.0.1" {
		t.Fatalf("bootstrap API fallback = %q, want loopback address: %v", cfg.Controller.ExternalController, err)
	}
	parsedAPIPort, err := strconv.Atoi(portText)
	if err != nil || parsedAPIPort == 0 {
		t.Fatalf("bootstrap API = %q, err=%v", cfg.Controller.ExternalController, err)
	}
	t.Logf("bootstrap API=%s (loopback dynamic port)", cfg.Controller.ExternalController)
	apiClient := &http.Client{Timeout: time.Second}
	apiResponse, err := apiClient.Get("http://" + cfg.Controller.ExternalController + "/version")
	if err != nil {
		t.Fatalf("GET isolated API fallback %s: %v", cfg.Controller.ExternalController, err)
	}
	_ = apiResponse.Body.Close()
	if apiResponse.StatusCode != http.StatusOK {
		t.Fatalf("isolated API fallback status = %d, want %d", apiResponse.StatusCode, http.StatusOK)
	}
	return bootstrapProfilePorts{mixed: mixedPort, api: cfg.Controller.ExternalController}
}

func bootstrapProfileConfig(ports bootstrapProfilePorts, httpPort, socksPort, dnsPort int, allowLAN bool) string {
	return fmt.Sprintf("port: %d\nsocks-port: %d\nmixed-port: 0\nallow-lan: %t\nbind-address: 127.0.0.1\nipv6: true\nexternal-controller: %s\ndns:\n  enable: true\n  listen: 127.0.0.1:%d\n  ipv6: true\n  enhanced-mode: redir-host\n  default-nameserver: [127.0.0.1]\n  nameserver: [127.0.0.1]\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", httpPort, socksPort, allowLAN, ports.api, dnsPort)
}

func TestBootstrapProfileReloadMinimalMixedToHTTPAndSocksFirstApply(t *testing.T) {
	ports := startBootstrapForProfileReload(t)
	httpPort := reserveBootstrapLoopbackPort(t, false, ports.mixed)
	socksPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, httpPort)
	profile := fmt.Sprintf("port: %d\nsocks-port: %d\nmixed-port: 0\nallow-lan: false\nbind-address: 127.0.0.1\nexternal-controller: %s\ndns: {enable: false}\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", httpPort, socksPort, ports.api)
	path := writeBootstrapProfile(t, "minimal-profile.yaml", profile)
	epoch := configUpdateEpoch.Load()
	result := bootstrapProfileResultString(unsafe.Pointer(updateConfigAtEpoch(path, epoch)))
	t.Logf("minimal mixed-to-HTTP/SOCKS first apply result=%q", result)
	if result != "success" {
		t.Fatalf("minimal first profile apply returned %q", result)
	}
	assertBootstrapProfileTCP(t, httpPort)
	assertBootstrapProfileTCP(t, socksPort)
	if got := listener.GetPorts(); got.Port != httpPort || got.SocksPort != socksPort || got.MixedPort != 0 {
		t.Fatalf("listeners after minimal reload = HTTP %d SOCKS %d mixed %d, want %d/%d/0", got.Port, got.SocksPort, got.MixedPort, httpPort, socksPort)
	}
}

func assertBootstrapProfileTCP(t *testing.T, port int) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 500*time.Millisecond)
	if err != nil {
		t.Fatalf("loopback listener %d is not accepting TCP: %v", port, err)
	}
	_ = conn.Close()
}

func TestBootstrapProfileReloadFirstLoadSucceedsOnLoopback(t *testing.T) {
	ports := startBootstrapForProfileReload(t)
	httpPort := reserveBootstrapLoopbackPort(t, false, ports.mixed)
	socksPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, httpPort)
	dnsPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, httpPort, socksPort)
	profile := bootstrapProfileConfig(ports, httpPort, socksPort, dnsPort, true)
	path := writeBootstrapProfile(t, "profile.yaml", profile)
	epoch := configUpdateEpoch.Load()
	result := bootstrapProfileResultString(unsafe.Pointer(updateConfigAtEpoch(path, epoch)))
	t.Logf("first profile reload result=%q", result)
	if result != "success" {
		t.Fatalf("first profile reload failed: %s", result)
	}
	assertBootstrapProfileTCP(t, httpPort)
	assertBootstrapProfileTCP(t, socksPort)
	assertBootstrapProfileTCP(t, dnsPort)
	if got := executor.GetGeneralSafe().MixedPort; got != 0 {
		t.Fatalf("mixed-port after profile reload = %d, want 0", got)
	}
	if got := executor.GetGeneralSafe().IPv6; got {
		t.Fatal("profile ipv6=true overrode the bootstrap session's ipv6=false")
	}
	general := executor.GetGeneralSafe()
	if !general.AllowLan || general.BindAddress != "127.0.0.1" || listener.BindAddress() != "127.0.0.1" {
		t.Fatalf("allow-lan/bind-address after reload = %t/%q (runtime %q), want true/127.0.0.1", general.AllowLan, general.BindAddress, listener.BindAddress())
	}
	if got := listener.GetPorts(); got.Port != httpPort || got.SocksPort != socksPort {
		t.Fatalf("profile listeners = HTTP %d SOCKS %d, want %d and %d", got.Port, got.SocksPort, httpPort, socksPort)
	}
	if got := string(lastSubmittedConfig.bytes()); !strings.Contains(got, fmt.Sprintf("port: %d", httpPort)) {
		t.Fatalf("submitted profile snapshot did not advance: %q", got)
	}
}

func TestBootstrapProfileReloadOccupiedListenerReturnsErrorAndRollbackSucceeds(t *testing.T) {
	ports := startBootstrapForProfileReload(t)
	blockedHTTP, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve loopback profile HTTP conflict: %v", err)
	}
	defer blockedHTTP.Close()
	occupied := blockedHTTP.Addr().(*net.TCPAddr).Port
	socksPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, occupied)
	dnsPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, occupied, socksPort)
	profile := bootstrapProfileConfig(ports, occupied, socksPort, dnsPort, true)
	profilePath := writeBootstrapProfile(t, "occupied-profile.yaml", profile)
	previousSnapshot := lastSubmittedConfig.bytes()
	epoch := configUpdateEpoch.Load()
	result := bootstrapProfileResultString(unsafe.Pointer(updateConfigAtEpoch(profilePath, epoch)))
	t.Logf("occupied profile reload result=%q", result)
	wantError := fmt.Sprintf("global HTTP listener on port %d is not ready", occupied)
	if result != wantError {
		t.Fatalf("occupied profile listener returned %q, want %q", result, wantError)
	}
	if got := string(lastSubmittedConfig.bytes()); got != string(previousSnapshot) {
		t.Fatalf("failed apply changed submitted snapshot: got %q want %q", got, previousSnapshot)
	}
	rollbackPath := writeBootstrapProfile(t, "bootstrap-rollback.yaml", fmt.Sprintf("mixed-port: %d\nallow-lan: false\nbind-address: 127.0.0.1\nexternal-controller: %s\ndns: {enable: false}\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", ports.mixed, ports.api))
	rollback := bootstrapProfileResultString(unsafe.Pointer(updateConfigAtEpoch(rollbackPath, epoch)))
	t.Logf("bootstrap rollback result=%q", rollback)
	if rollback != "success" {
		t.Fatalf("bootstrap listener rollback failed: %s", rollback)
	}
	assertBootstrapProfileTCP(t, ports.mixed)
	if got := listener.GetPorts(); got.MixedPort != ports.mixed {
		t.Fatalf("rollback mixed-port = %d, want %d", got.MixedPort, ports.mixed)
	}
	for _, port := range []int{socksPort, dnsPort} {
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Errorf("rollback retained profile TCP listener %d: %v", port, err)
		} else {
			_ = listener.Close()
		}
		packet, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Errorf("rollback retained profile UDP listener %d: %v", port, err)
		} else {
			_ = packet.Close()
		}
	}
}

func TestBootstrapProfileReloadRejectsInvalidatedLifecycleEpoch(t *testing.T) {
	ports := startBootstrapForProfileReload(t)
	httpPort := reserveBootstrapLoopbackPort(t, false, ports.mixed)
	socksPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, httpPort)
	dnsPort := reserveBootstrapLoopbackPort(t, true, ports.mixed, httpPort, socksPort)
	path := writeBootstrapProfile(t, "stale-profile.yaml", bootstrapProfileConfig(ports, httpPort, socksPort, dnsPort, true))
	staleEpoch := configUpdateEpoch.Load()
	if err := currentCacheDBLifecycle().suspendWithEpoch(stopBuiltinListenersForSuspend, &configUpdateEpoch); err != nil {
		t.Fatalf("invalidate bootstrap lifecycle: %v", err)
	}
	result := bootstrapProfileResultString(unsafe.Pointer(updateConfigAtEpoch(path, staleEpoch)))
	t.Logf("stale profile reload result=%q", result)
	if result == "success" || !strings.Contains(result, "cancelled") {
		t.Fatalf("stale lifecycle epoch returned %q, want cancellation", result)
	}
}
