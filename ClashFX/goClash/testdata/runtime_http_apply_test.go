package route

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

type runtimeHTTPConfigSnapshot struct {
	port       int
	socksPort  int
	redirPort  int
	tproxyPort int
	mixedPort  int
	mode       tunnel.TunnelMode
}

func snapshotRuntimeHTTPConfig() runtimeHTTPConfigSnapshot {
	general := executor.GetGeneralSafe()
	return runtimeHTTPConfigSnapshot{
		port:       general.Port,
		socksPort:  general.SocksPort,
		redirPort:  general.RedirPort,
		tproxyPort: general.TProxyPort,
		mixedPort:  general.MixedPort,
		mode:       general.Mode,
	}
}

func newRuntimeConfigServer(t *testing.T) *httptest.Server {
	t.Helper()

	previousEmbedMode := embedMode
	embedMode = false
	executor.SetRuntimeMutationGateFactory(nil)
	server := httptest.NewServer(configRouter())
	t.Cleanup(func() {
		server.Close()
		executor.SetRuntimeMutationGateFactory(nil)
		embedMode = previousEmbedMode
	})
	return server
}

func availableRuntimeHTTPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

func TestRuntimeHTTPPutCapturesLifecycleGateBeforeBody(t *testing.T) {
	testRuntimeHTTPMutationCapturesLifecycleGateBeforeBody(t, http.MethodPut)
}
func TestRuntimeHTTPPatchCapturesLifecycleGateBeforeBody(t *testing.T) {
	testRuntimeHTTPMutationCapturesLifecycleGateBeforeBody(t, http.MethodPatch)
}
func testRuntimeHTTPMutationCapturesLifecycleGateBeforeBody(t *testing.T, method string) {
	server := newRuntimeConfigServer(t)
	before := snapshotRuntimeHTTPConfig()
	mixedPort := availableRuntimeHTTPPort(t)

	var generation atomic.Uint64
	factoryEntered := make(chan struct{}, 1)
	executor.SetRuntimeMutationGateFactory(func() func(func() error) error {
		capturedGeneration := generation.Load()
		select {
		case factoryEntered <- struct{}{}:
		default:
		}
		return func(body func() error) error {
			if generation.Load() != capturedGeneration {
				return fmt.Errorf("runtime generation changed before mutation")
			}
			return body()
		}
	})

	pipeReader, pipeWriter := io.Pipe()
	request, err := http.NewRequest(method, server.URL+"/?force=true", pipeReader)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	type requestResult struct {
		status int
		err    error
	}
	resultChannel := make(chan requestResult, 1)
	client := server.Client()
	client.Timeout = 5 * time.Second
	go func() {
		response, requestErr := client.Do(request)
		result := requestResult{err: requestErr}
		if response != nil {
			result.status = response.StatusCode
			_ = response.Body.Close()
		}
		resultChannel <- result
	}()

	select {
	case <-factoryEntered:
	case <-time.After(5 * time.Second):
		_ = pipeWriter.Close()
		t.Fatal("request did not capture its lifecycle gate")
	}

	// No body bytes have been written yet; invalidate the captured generation
	// before DecodeJSON can finish and allow the handler to enter its gate.
	generation.Add(1)
	payload, err := json.Marshal(struct {
		Payload string `json:"payload"`
	}{Payload: fmt.Sprintf("mixed-port: %d\nmode: direct\n", mixedPort)})
	if err != nil {
		t.Fatal(err)
	}
	if method == http.MethodPatch {
		payload, err = json.Marshal(map[string]any{"mode": "direct", "mixed-port": mixedPort})
		if err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pipeWriter.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err := pipeWriter.Close(); err != nil {
		t.Fatal(err)
	}

	var result requestResult
	select {
	case result = <-resultChannel:
	case <-time.After(5 * time.Second):
		t.Fatal("PUT request did not finish")
	}
	if result.err != nil {
		t.Fatal(result.err)
	}
	if result.status != http.StatusBadRequest {
		t.Fatalf("expected stale lifecycle request to return 400, got %d", result.status)
	}

	after := snapshotRuntimeHTTPConfig()
	if after != before {
		// Keep a regression from leaving a listener behind in this test process.
		executor.WithRuntimeConfigLock(func() {
			if after.mixedPort != before.mixedPort {
				listener.ReCreateMixed(before.mixedPort, tunnel.Tunnel)
			}
			if after.mode != before.mode {
				tunnel.SetMode(before.mode)
			}
		})
		t.Fatalf("stale PUT changed runtime config: before=%+v after=%+v", before, after)
	}
}

func TestRuntimeHTTPPutUsesDefaultLifecycleGate(t *testing.T) {
	server := newRuntimeConfigServer(t)
	request, err := http.NewRequest(
		http.MethodPut,
		server.URL+"/",
		strings.NewReader(`{"payload":"mode: rule\n"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("expected normal PUT to return 204, got %d: %s", response.StatusCode, body)
	}
}

func TestConcurrentApplyConfigAndValidateHasNoFalseReadinessFailure(t *testing.T) {
	first, err := executor.ParseWithBytes([]byte("mode: rule\nallow-lan: false\nbind-address: 127.0.0.1\ndns: {enable: false}\ntun: {enable: false}\n"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := executor.ParseWithBytes([]byte("mode: direct\nallow-lan: true\nbind-address: 127.0.0.1\ndns: {enable: false}\ntun: {enable: false}\n"))
	if err != nil {
		t.Fatal(err)
	}

	configs := []*config.Config{first, second}
	var wait sync.WaitGroup
	applyErrors := make(chan error, len(configs))
	for _, cfg := range configs {
		wait.Add(1)
		go func(cfg *config.Config) {
			defer wait.Done()
			applyErrors <- executor.ApplyConfigAndValidate(cfg, true)
		}(cfg)
	}
	wait.Wait()
	close(applyErrors)
	for err := range applyErrors {
		if err != nil {
			t.Fatalf("concurrent checked apply failed: %v", err)
		}
	}
}

func TestRuntimeHTTPPatchRejectsUDPOnlyListenerFailure(t *testing.T) {
	server := newRuntimeConfigServer(t)
	oldPort := availableRuntimeHTTPPort(t)
	original := fmt.Sprintf("mixed-port: %d\ndns: {enable: false}\ntun: {enable: false}\n", oldPort)
	cfg, err := executor.ParseWithBytes([]byte(original))
	if err != nil {
		t.Fatal(err)
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
		_ = executor.ApplyConfigAndValidate(empty, true)
	})
	blocker, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	occupied := blocker.LocalAddr().(*net.UDPAddr).Port
	request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(fmt.Sprintf(`{"mixed-port":%d}`, occupied)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("UDP-only PATCH bind failure returned %d", response.StatusCode)
	}
	if executor.GetGeneralSafe().MixedPort != oldPort {
		t.Fatal("failed PATCH did not restore the previous live listener")
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatalf("restore original after PATCH failure: %v", err)
	}
	connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", oldPort))
	if err != nil {
		t.Fatal(err)
	}
	_ = connection.Close()
}

func TestRuntimeHTTPPatchRejectedListenerDoesNotPublishBatchSettings(t *testing.T) {
	server := newRuntimeConfigServer(t)
	oldPort := availableRuntimeHTTPPort(t)
	original := fmt.Sprintf("mixed-port: %d\nallow-lan: false\nbind-address: 127.0.0.1\nmode: rule\ndns: {enable: false}\ntun: {enable: false}\n", oldPort)
	cfg, err := executor.ParseWithBytes([]byte(original))
	if err != nil {
		t.Fatal(err)
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatal(err)
	}
	beforePrefixes := runtimeHTTPAccessPrefixSnapshot{
		skip:       []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
		allowed:    []netip.Prefix{netip.MustParsePrefix("192.168.0.0/16")},
		disallowed: []netip.Prefix{netip.MustParsePrefix("172.16.0.0/12")},
	}
	previousPrefixes := snapshotRuntimeHTTPAccessPrefixes()
	inbound.SetAccessPrefixes(beforePrefixes.skip, beforePrefixes.allowed, beforePrefixes.disallowed)
	t.Cleanup(func() {
		inbound.SetAccessPrefixes(previousPrefixes.skip, previousPrefixes.allowed, previousPrefixes.disallowed)
	})
	t.Cleanup(func() {
		empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
		_ = executor.ApplyConfigAndValidate(empty, true)
	})
	before := executor.GetGeneralSafe()
	beforeAccess := snapshotRuntimeHTTPAccessPrefixes()

	blocker, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	occupied := blocker.LocalAddr().(*net.UDPAddr).Port
	request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(fmt.Sprintf(
		`{"allow-lan":true,"bind-address":"127.0.0.1","mixed-port":%d,"skip-auth-prefixes":["203.0.113.0/24"],"lan-allowed-ips":["198.51.100.0/24"],"lan-disallowed-ips":["192.0.2.0/24"],"sniffing":true,"tcp-concurrent":true,"interface-name":"clashfx-regression-test","mode":"direct","tun":{"enable":false,"mtu":1421,"device":"metadata-only-test"}}`,
		occupied,
	)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("UDP-only PATCH bind failure returned %d", response.StatusCode)
	}

	after := executor.GetGeneralSafe()
	if !reflect.DeepEqual(before.Tun, after.Tun) {
		t.Fatalf("failed PATCH published disabled TUN metadata: before=%+v after=%+v", before.Tun, after.Tun)
	}
	if after.AllowLan != before.AllowLan || after.BindAddress != before.BindAddress ||
		after.Mode != before.Mode || after.Sniffing != before.Sniffing ||
		after.TCPConcurrent != before.TCPConcurrent || after.Interface != before.Interface {
		t.Fatalf("failed PATCH retained batch settings: before=%+v after=%+v", before, after)
	}
	if after.MixedPort != oldPort {
		t.Fatalf("failed PATCH did not restore mixed port: got %d, want %d", after.MixedPort, oldPort)
	}
	if got := snapshotRuntimeHTTPAccessPrefixes(); !reflect.DeepEqual(got, beforeAccess) {
		t.Fatalf("failed PATCH published access prefixes: before=%+v after=%+v", beforeAccess, got)
	}
	connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", oldPort))
	if err != nil {
		t.Fatalf("previous mixed listener was not restored: %v", err)
	}
	_ = connection.Close()
}

func TestRuntimeHTTPPatchCommitsDisabledTunMetadataAfterListenerChecks(t *testing.T) {
	server := newRuntimeConfigServer(t)
	cfg, err := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
	if err != nil {
		t.Fatal(err)
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = executor.ApplyConfigAndValidate(cfg, true) })
	request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(`{"tun":{"enable":false,"mtu":1421,"device":"metadata-only-test"}}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("valid disabled TUN metadata PATCH returned %d", response.StatusCode)
	}
	actual := executor.GetGeneralSafe().Tun
	if actual.Enable || actual.MTU != 1421 || actual.Device != "metadata-only-test" {
		t.Fatalf("disabled TUN metadata did not commit: %+v", actual)
	}
}

type runtimeHTTPAccessPrefixSnapshot struct {
	skip       []netip.Prefix
	allowed    []netip.Prefix
	disallowed []netip.Prefix
}

func snapshotRuntimeHTTPAccessPrefixes() runtimeHTTPAccessPrefixSnapshot {
	return runtimeHTTPAccessPrefixSnapshot{
		skip:       append([]netip.Prefix(nil), inbound.SkipAuthPrefixes()...),
		allowed:    append([]netip.Prefix(nil), inbound.AllowedIPs()...),
		disallowed: append([]netip.Prefix(nil), inbound.DisAllowedIPs()...),
	}
}

func TestRuntimeHTTPPatchAdditionalGlobalFailureRollsBackAllRequestedListeners(t *testing.T) {
	for _, failingService := range []string{"ss-config", "vmess-config", "tuic-server"} {
		t.Run(failingService, func(t *testing.T) {
			server := newRuntimeConfigServer(t)
			oldMixedPort := availableRuntimeDualProtocolPort(t)
			oldSSPort := availableRuntimeDualProtocolPortExcept(t, oldMixedPort)
			oldVMessPort := availableRuntimeHTTPPortExcept(t, oldMixedPort, oldSSPort)
			oldTuicPort := availableRuntimeUDPPortExcept(t, oldMixedPort, oldSSPort, oldVMessPort)
			oldCertificate, oldPrivateKey, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
			if err != nil {
				t.Fatal(err)
			}
			oldSSURL := fmt.Sprintf("ss://aes-128-gcm:original%%40ss@127.0.0.1:%d", oldSSPort)
			oldVMessURL := fmt.Sprintf("vmess://original:11111111-1111-4111-8111-111111111111@127.0.0.1:%d", oldVMessPort)
			oldTuic := map[string]any{
				"enable": true, "listen": fmt.Sprintf("127.0.0.1:%d", oldTuicPort), "token": []string{"original"},
				"certificate": oldCertificate, "private-key": oldPrivateKey,
			}
			original, err := yaml.Marshal(map[string]any{
				"mixed-port": oldMixedPort, "allow-lan": false, "bind-address": "127.0.0.1",
				"ss-config": oldSSURL, "vmess-config": oldVMessURL, "tuic-server": oldTuic,
				"dns": map[string]any{"enable": false}, "tun": map[string]any{"enable": false},
			})
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := executor.ParseWithBytes(original)
			if err != nil {
				t.Fatal(err)
			}
			if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
				t.Fatalf("apply original global listeners: %v", err)
			}
			ports := listener.GetPorts()
			if ports.ShadowSocksConfig == oldSSURL || ports.VmessConfig == oldVMessURL {
				t.Fatal("listener port snapshot unexpectedly preserved the original URL")
			}
			oldTuicConfig := listener.GetLastTuicConfig()
			t.Cleanup(func() {
				empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
				_ = executor.ApplyConfigAndValidate(empty, true)
			})

			var blocker net.Listener
			if failingService == "ss-config" || failingService == "vmess-config" {
				blocker, err = net.Listen("tcp", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				defer blocker.Close()
			}
			blockedPort := 0
			if blocker != nil {
				blockedPort = blocker.Addr().(*net.TCPAddr).Port
			}
			newMixedPort := availableRuntimeDualProtocolPortExcept(t, oldMixedPort, oldSSPort, oldVMessPort, oldTuicPort, blockedPort)
			newSSPort := availableRuntimeDualProtocolPortExcept(t, oldMixedPort, oldSSPort, oldVMessPort, oldTuicPort, blockedPort, newMixedPort)
			newVMessPort := availableRuntimeHTTPPortExcept(t, oldMixedPort, oldSSPort, oldVMessPort, oldTuicPort, blockedPort, newMixedPort, newSSPort)
			newTuicPort := availableRuntimeUDPPortExcept(t, oldMixedPort, oldSSPort, oldVMessPort, oldTuicPort, blockedPort, newMixedPort, newSSPort, newVMessPort)
			newCertificate, newPrivateKey, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
			if err != nil {
				t.Fatal(err)
			}
			newTuic := map[string]any{
				"enable": true, "listen": fmt.Sprintf("127.0.0.1:%d", newTuicPort), "token": []string{"requested"},
				"certificate": newCertificate, "private-key": newPrivateKey,
			}
			newSSURL := fmt.Sprintf("ss://aes-128-gcm:requested%%40ss@127.0.0.1:%d", newSSPort)
			newVMessURL := fmt.Sprintf("vmess://requested:22222222-2222-4222-8222-222222222222@127.0.0.1:%d", newVMessPort)
			switch failingService {
			case "ss-config":
				newSSPort = blockedPort
				newSSURL = fmt.Sprintf("ss://aes-128-gcm:requested%%40ss@127.0.0.1:%d", newSSPort)
			case "vmess-config":
				newVMessPort = blockedPort
				newVMessURL = fmt.Sprintf("vmess://requested:22222222-2222-4222-8222-222222222222@127.0.0.1:%d", newVMessPort)
			case "tuic-server":
				newSSPort = oldMixedPort
				newSSURL = fmt.Sprintf("ss://aes-128-gcm:requested%%40ss@127.0.0.1:%d", newSSPort)
				newTuic["certificate"] = "invalid-pem"
				newTuic["private-key"] = "invalid-pem"
			}

			requestBody, err := json.Marshal(map[string]any{
				"allow-lan": true, "bind-address": "127.0.0.1", "mixed-port": newMixedPort,
				"ss-config": newSSURL, "vmess-config": newVMessURL, "tuic-server": newTuic,
			})
			if err != nil {
				t.Fatal(err)
			}
			request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(string(requestBody)))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Content-Type", "application/json")
			response, err := server.Client().Do(request)
			if err != nil {
				t.Fatal(err)
			}
			_ = response.Body.Close()
			if response.StatusCode != http.StatusBadRequest {
				t.Fatalf("invalid %s PATCH returned %d", failingService, response.StatusCode)
			}

			general := executor.GetGeneralSafe()
			if general.MixedPort != oldMixedPort || general.AllowLan || general.BindAddress != "127.0.0.1" {
				t.Fatalf("failed %s PATCH retained basic listener changes: %+v", failingService, general.Inbound)
			}
			for _, port := range []int{oldMixedPort, oldSSPort, oldVMessPort} {
				connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
				if err != nil {
					t.Fatalf("failed %s PATCH did not restore listener on port %d: %v", failingService, port, err)
				}
				_ = connection.Close()
			}
			if actual := listener.GetTuicConf(); !actual.Enable || actual.Listen != fmt.Sprintf("127.0.0.1:%d", oldTuicPort) {
				t.Fatalf("failed %s PATCH did not restore TUIC: %+v", failingService, actual)
			}
			if got := listener.GetLastShadowSocksConfig(); got != oldSSURL {
				t.Fatalf("failed %s PATCH changed original SS URL: got %q, want %q", failingService, got, oldSSURL)
			}
			if got := listener.GetLastVmessConfig(); got != oldVMessURL {
				t.Fatalf("failed %s PATCH changed original VMess URL: got %q, want %q", failingService, got, oldVMessURL)
			}
			if got := listener.GetLastTuicConfig(); got.String() != oldTuicConfig.String() {
				t.Fatalf("failed %s PATCH changed original TUIC config: got %s, want %s", failingService, got.String(), oldTuicConfig.String())
			}
			assertRuntimeHTTPPortClosed(t, newMixedPort)
			if failingService != "ss-config" && !(failingService == "tuic-server" && newSSPort == oldMixedPort) {
				assertRuntimeHTTPPortClosed(t, newSSPort)
			}
			if failingService != "vmess-config" {
				assertRuntimeHTTPPortClosed(t, newVMessPort)
			}
			assertRuntimeHTTPUDPPortAvailable(t, newTuicPort)
		})
	}
}

func assertRuntimeHTTPPortClosed(t *testing.T, port int) {
	t.Helper()
	connection, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
	if err == nil {
		_ = connection.Close()
		t.Fatalf("unexpected listener remained on TCP port %d", port)
	}
}

func assertRuntimeHTTPUDPPortAvailable(t *testing.T, port int) {
	t.Helper()
	packet, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("unexpected listener remained on UDP port %d: %v", port, err)
	}
	_ = packet.Close()
}

func availableRuntimeDualProtocolPort(t *testing.T) int {
	return availableRuntimeDualProtocolPortExcept(t)
}

func availableRuntimeDualProtocolPortExcept(t *testing.T, excluded ...int) int {
	t.Helper()
	for attempt := 0; attempt < 20; attempt++ {
		tcp, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		if runtimeHTTPPortExcluded(port, excluded) {
			_ = tcp.Close()
			continue
		}
		udp, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
		_ = tcp.Close()
		if err == nil {
			_ = udp.Close()
			return port
		}
	}
	t.Fatal("could not reserve a TCP and UDP test port")
	return 0
}

func availableRuntimeUDPPort(t *testing.T) int {
	return availableRuntimeUDPPortExcept(t)
}

func availableRuntimeUDPPortExcept(t *testing.T, excluded ...int) int {
	t.Helper()
	for attempt := 0; attempt < 20; attempt++ {
		udp, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := udp.LocalAddr().(*net.UDPAddr).Port
		if err := udp.Close(); err != nil {
			t.Fatal(err)
		}
		if !runtimeHTTPPortExcluded(port, excluded) {
			return port
		}
	}
	t.Fatal("could not reserve an available UDP test port")
	return 0
}

func availableRuntimeHTTPPortExcept(t *testing.T, excluded ...int) int {
	t.Helper()
	for attempt := 0; attempt < 20; attempt++ {
		port := availableRuntimeHTTPPort(t)
		if !runtimeHTTPPortExcluded(port, excluded) {
			return port
		}
	}
	t.Fatal("could not reserve an available TCP test port")
	return 0
}

func runtimeHTTPPortExcluded(port int, excluded []int) bool {
	for _, candidate := range excluded {
		if candidate != 0 && candidate == port {
			return true
		}
	}
	return false
}

func TestRuntimeHTTPModePatchPreservesURLGlobals(t *testing.T) {
	for _, key := range []string{"ss-config", "vmess-config"} {
		t.Run(key, func(t *testing.T) {
			server := newRuntimeConfigServer(t)
			port := availableRuntimeHTTPPort(t)
			uri := fmt.Sprintf("ss://aes-128-gcm:fixture@127.0.0.1:%d", port)
			if key == "vmess-config" {
				uri = fmt.Sprintf("vmess://fixture:11111111-1111-4111-8111-111111111111@127.0.0.1:%d", port)
			}
			raw := fmt.Sprintf("%s: %q\ndns: {enable: false}\ntun: {enable: false}\n", key, uri)
			cfg, err := executor.ParseWithBytes([]byte(raw))
			if err != nil {
				t.Fatal(err)
			}
			if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
				_ = executor.ApplyConfigAndValidate(empty, true)
			})
			request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(`{"mode":"direct"}`))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Content-Type", "application/json")
			response, err := server.Client().Do(request)
			if err != nil {
				t.Fatal(err)
			}
			_ = response.Body.Close()
			if response.StatusCode != http.StatusNoContent {
				t.Fatalf("unrelated mode PATCH rejected healthy URL listener: %d", response.StatusCode)
			}
			connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				t.Fatalf("mode PATCH disabled URL listener: %v", err)
			}
			_ = connection.Close()
		})
	}
}

func TestRuntimeHTTPModePatchPreservesUnrequestedTuic(t *testing.T) {
	server := newRuntimeConfigServer(t)
	port := availableRuntimeUDPPort(t)
	certificate, privateKey, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
	if err != nil {
		t.Fatal(err)
	}
	original, err := yaml.Marshal(map[string]any{
		"dns": map[string]any{"enable": false},
		"tun": map[string]any{"enable": false},
		"tuic-server": map[string]any{
			"enable": true, "listen": fmt.Sprintf("127.0.0.1:%d", port), "token": []string{"original"},
			"certificate": certificate, "private-key": privateKey,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := executor.ParseWithBytes(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatalf("apply original TUIC: %v", err)
	}
	originalTuic := listener.GetLastTuicConfig()
	t.Cleanup(func() {
		empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
		_ = executor.ApplyConfigAndValidate(empty, true)
	})

	request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(`{"mode":"direct"}`))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("unrelated mode PATCH rejected healthy TUIC listener: %d", response.StatusCode)
	}
	if actual := listener.GetLastTuicConfig(); actual.String() != originalTuic.String() {
		t.Fatalf("mode PATCH changed unrequested TUIC config: got %s, want %s", actual.String(), originalTuic.String())
	}
	if actual := listener.GetTuicConf(); !actual.Enable || actual.Listen != fmt.Sprintf("127.0.0.1:%d", port) {
		t.Fatalf("mode PATCH changed unrequested TUIC listener: %+v", actual)
	}
	probe, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
	if err == nil {
		_ = probe.Close()
		t.Fatal("mode PATCH released the unrequested TUIC UDP port")
	}
}

func TestRuntimeHTTPRejectedBindChangeRestoresListenerAndMode(t *testing.T) {
	server := newRuntimeConfigServer(t)
	port := availableRuntimeHTTPPort(t)
	cfg, err := executor.ParseWithBytes([]byte(fmt.Sprintf("mixed-port: %d\nallow-lan: false\ndns: {enable: false}\ntun: {enable: false}\n", port)))
	if err != nil {
		t.Fatal(err)
	}
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		empty, _ := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\n"))
		_ = executor.ApplyConfigAndValidate(empty, true)
	})
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	request, err := http.NewRequest(http.MethodPatch, server.URL+"/", strings.NewReader(fmt.Sprintf(`{"allow-lan":true,"bind-address":"127.0.0.1","mixed-port":%d,"mode":"direct"}`, blocker.Addr().(*net.TCPAddr).Port)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := server.Client().Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("LAN expansion conflict returned %d", response.StatusCode)
	}
	actual := executor.GetGeneralSafe()
	if actual.AllowLan || actual.MixedPort != port || actual.Mode != cfg.General.Mode {
		t.Fatal("failed LAN expansion committed partial listener/mode state")
	}
	connection, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("loopback listener not restored: %v", err)
	}
	_ = connection.Close()
}
