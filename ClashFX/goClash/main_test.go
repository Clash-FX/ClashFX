package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	A "github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	OG "github.com/metacubex/mihomo/adapter/outboundgroup"
	P "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	CP "github.com/metacubex/mihomo/constant/provider"
	mihomoDNS "github.com/metacubex/mihomo/dns"
	E "github.com/metacubex/sing/common/exceptions"
	miekgDNS "github.com/miekg/dns"
	"gopkg.in/yaml.v3"
)

type delayedURLTestAdapter struct {
	*outbound.Base
	mu    sync.RWMutex
	delay time.Duration
}

// controlledURLTestProxy is a deterministic C.Proxy fixture: the group sees
// only the configured liveness and delay, never scheduler or socket timing.
type controlledURLTestProxy struct {
	*outbound.Base
	mu    sync.RWMutex
	delay uint16
	alive bool
}

func newControlledURLTestProxy(name string, delay uint16) *controlledURLTestProxy {
	return &controlledURLTestProxy{
		Base:  outbound.NewBase(outbound.BaseOption{Name: name, Type: C.Direct}),
		delay: delay,
		alive: true,
	}
}

func (p *controlledURLTestProxy) setState(delay uint16, alive bool) {
	p.mu.Lock()
	p.delay = delay
	p.alive = alive
	p.mu.Unlock()
}

func (p *controlledURLTestProxy) Adapter() C.ProxyAdapter {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.Base
}

func (p *controlledURLTestProxy) AliveForTestUrl(string) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.alive
}

func (p *controlledURLTestProxy) LastDelayForTestUrl(string) uint16 {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.delay
}

func (p *controlledURLTestProxy) DelayHistory() []C.DelayHistory { return nil }

func (p *controlledURLTestProxy) ExtraDelayHistories() map[string]C.ProxyState { return nil }

func (p *controlledURLTestProxy) URLTest(context.Context, string, utils.IntRanges[uint16]) (uint16, error) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.delay, nil
}

func newDelayedURLTestAdapter(name string, delay time.Duration) *delayedURLTestAdapter {
	return &delayedURLTestAdapter{
		Base:  outbound.NewBase(outbound.BaseOption{Name: name, Type: C.Direct}),
		delay: delay,
	}
}

func (a *delayedURLTestAdapter) setDelay(delay time.Duration) {
	a.mu.Lock()
	a.delay = delay
	a.mu.Unlock()
}

func (a *delayedURLTestAdapter) DialContext(context.Context, *C.Metadata) (C.Conn, error) {
	a.mu.RLock()
	delay := a.delay
	a.mu.RUnlock()
	time.Sleep(delay)

	client, server := net.Pipe()
	go func() {
		defer server.Close()
		request, err := http.ReadRequest(bufio.NewReader(server))
		if err != nil {
			return
		}
		_ = request.Body.Close()
		_, _ = fmt.Fprint(server, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
	}()
	return outbound.NewConn(client, a), nil
}

func TestClosedTunErrorsAreTreatedAsClosed(t *testing.T) {
	tests := []struct {
		name string
		err  error
	}{
		{name: "socket operation on non-socket", err: syscall.ENOTSOCK},
		{name: "bad file descriptor", err: syscall.EBADF},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if !E.IsClosed(test.err) {
				t.Fatalf("%v must stop the Darwin TUN read loop", test.err)
			}
		})
	}
}

func TestURLTestRecomputesSelectionAfterAllCandidatesFinish(t *testing.T) {
	const testURL = "http://clashfx.test/generate_204"
	firstAdapter := newDelayedURLTestAdapter("first", 10*time.Millisecond)
	secondAdapter := newDelayedURLTestAdapter("second", 80*time.Millisecond)
	firstProxy := A.NewProxy(firstAdapter)
	secondProxy := A.NewProxy(secondAdapter)
	proxies := []C.Proxy{firstProxy, secondProxy}
	healthCheck := P.NewHealthCheck(proxies, testURL, 1000, 0, true, nil)
	proxyProvider, err := P.NewCompatibleProvider("test", proxies, healthCheck)
	if err != nil {
		t.Fatal(err)
	}
	defer proxyProvider.Close()

	group := OG.NewURLTest(
		&OG.GroupCommonOption{Name: "auto", URL: testURL},
		[]CP.ProxyProvider{proxyProvider},
	)
	if _, err := group.URLTest(context.Background(), testURL, nil); err != nil {
		t.Fatal(err)
	}
	if got := group.Now(); got != "first" {
		t.Fatalf("initial selection = %q, want first", got)
	}

	firstAdapter.setDelay(250 * time.Millisecond)
	secondAdapter.setDelay(20 * time.Millisecond)
	done := make(chan error, 1)
	go func() {
		_, err := group.URLTest(context.Background(), testURL, nil)
		done <- err
	}()

	// Allow the faster second result to settle while the first request remains
	// in flight. Polling LastDelayForTestUrl here races Mihomo's queue write and
	// makes this regression test itself unsafe under go test -race.
	time.Sleep(100 * time.Millisecond)
	if got := group.Now(); got != "first" {
		t.Fatalf("selection during partial results = %q, want cached first", got)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if got := group.Now(); got != "second" {
		t.Fatalf("selection after complete results = %q, want second", got)
	}
}

func TestURLTestHonorsExactToleranceBoundary(t *testing.T) {
	const (
		testURL   = "http://clashfx.test/generate_204"
		tolerance = 10
	)
	current := newControlledURLTestProxy("current", 10)
	candidate := newControlledURLTestProxy("candidate", 30)
	proxyMap := map[string]C.Proxy{
		"current":   current,
		"candidate": candidate,
	}

	parsed, err := OG.ParseProxyGroup(map[string]any{
		"name":      "auto",
		"type":      "url-test",
		"url":       testURL,
		"tolerance": tolerance,
		// Keep the selected node after the first position: Mihomo's URLTest
		// comparator marks the retained node while scanning remaining proxies.
		"proxies": []string{"candidate", "current"},
	}, proxyMap, map[string]CP.ProxyProvider{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	group, ok := parsed.(*OG.URLTest)
	if !ok {
		t.Fatalf("parsed group = %T, want *outboundgroup.URLTest", parsed)
	}

	if _, err := group.URLTest(context.Background(), testURL, nil); err != nil {
		t.Fatal(err)
	}
	if got := group.Now(); got != "current" {
		t.Fatalf("initial selection = %q, want current", got)
	}

	current.setState(100, true)
	candidate.setState(90, true)
	if _, err := group.URLTest(context.Background(), testURL, nil); err != nil {
		t.Fatal(err)
	}
	if got := group.Now(); got != "current" {
		t.Fatalf("equal tolerance selection = %q, want current", got)
	}

	candidate.setState(89, true)
	if _, err := group.URLTest(context.Background(), testURL, nil); err != nil {
		t.Fatal(err)
	}
	if got := group.Now(); got != "candidate" {
		t.Fatalf("tolerance plus one selection = %q, want candidate", got)
	}
}

func TestSplitTunRouteExcludeEntriesAcceptsLocalhost(t *testing.T) {
	prefixes, domains, invalid := splitTunRouteExcludeEntries("127.0.0.1, localhost, *.local, +.example.com")

	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid entries: %v", invalid)
	}
	if got, want := len(prefixes), 1; got != want {
		t.Fatalf("prefix count = %d, want %d", got, want)
	}
	if got, want := domains, []string{"localhost", "*.local", "+.example.com"}; len(got) != len(want) {
		t.Fatalf("domains = %v, want %v", got, want)
	} else {
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("domains = %v, want %v", got, want)
			}
		}
	}
}

func TestSplitTunRouteExcludeEntriesAcceptsLegacyWildcards(t *testing.T) {
	prefixes, domains, invalid := splitTunRouteExcludeEntries("192.168.*, 10.*, 172.16.*, 172.31.*")

	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid entries: %v", invalid)
	}
	if len(domains) != 0 {
		t.Fatalf("domains = %v, want none", domains)
	}
	want := []string{"192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/16", "172.31.0.0/16"}
	if len(prefixes) != len(want) {
		t.Fatalf("prefixes = %v, want %v", prefixes, want)
	}
	for i := range want {
		if prefixes[i].String() != want[i] {
			t.Fatalf("prefixes = %v, want %v", prefixes, want)
		}
	}
}

func TestSplitTunRouteExcludeEntriesRejectsInvalidText(t *testing.T) {
	_, _, invalid := splitTunRouteExcludeEntries("not valid")

	if got, want := invalid, []string{"not valid"}; len(got) != len(want) || got[0] != want[0] {
		t.Fatalf("invalid = %v, want %v", got, want)
	}
}

func TestPrependUniqueRulesAddsEnhancedCoreProcessRulesFirst(t *testing.T) {
	rawMap := map[string]interface{}{
		"rules": []interface{}{
			"DOMAIN-SUFFIX,example.com,DIRECT",
			"MATCH,Proxy",
		},
	}

	prependUniqueRules(rawMap, enhancedCoreProcessDirectRules)

	rules := rawMap["rules"].([]interface{})
	want := []string{
		"PROCESS-NAME,ClashFX Networking,DIRECT",
		"PROCESS-NAME,mihomo,DIRECT",
		"PROCESS-NAME,mihomo-bin,DIRECT",
		"PROCESS-NAME,mihomo_core,DIRECT",
		"DOMAIN-SUFFIX,example.com,DIRECT",
		"MATCH,Proxy",
	}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i := range want {
		if rules[i] != want[i] {
			t.Fatalf("rules = %v, want %v", rules, want)
		}
	}
}

func TestPrependUniqueRulesKeepsExistingEnhancedCoreProcessRule(t *testing.T) {
	rawMap := map[string]interface{}{
		"rules": []interface{}{
			"PROCESS-NAME,mihomo,DIRECT",
			"MATCH,Proxy",
		},
	}

	prependUniqueRules(rawMap, []string{"PROCESS-NAME,mihomo,DIRECT"})

	rules := rawMap["rules"].([]interface{})
	want := []string{"PROCESS-NAME,mihomo,DIRECT", "MATCH,Proxy"}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i := range want {
		if rules[i] != want[i] {
			t.Fatalf("rules = %v, want %v", rules, want)
		}
	}
}

func TestLockEnhancedLanBindingDisablesWildcardWhenAllowLanOff(t *testing.T) {
	rawMap := map[string]interface{}{
		"bind-address": "*",
	}

	lockEnhancedLanBinding(rawMap)

	if rawMap["allow-lan"] != false {
		t.Fatalf("allow-lan = %v, want false", rawMap["allow-lan"])
	}
	if rawMap["bind-address"] != "127.0.0.1" {
		t.Fatalf("bind-address = %v, want 127.0.0.1", rawMap["bind-address"])
	}
}

func TestLockEnhancedLanBindingPreservesExplicitAllowLan(t *testing.T) {
	rawMap := map[string]interface{}{
		"allow-lan":    true,
		"bind-address": "*",
	}

	lockEnhancedLanBinding(rawMap)

	if rawMap["allow-lan"] != true {
		t.Fatalf("allow-lan = %v, want true", rawMap["allow-lan"])
	}
	if rawMap["bind-address"] != "*" {
		t.Fatalf("bind-address = %v, want *", rawMap["bind-address"])
	}
}

func TestResolveTunStack(t *testing.T) {
	cases := map[string]string{
		"system":   "system",
		"System":   "system",
		" GVISOR ": "gvisor",
		"mixed":    "mixed",
		"":         "mixed",
		"bogus":    "mixed",
	}
	for in, want := range cases {
		if got := resolveTunStack(in); got != want {
			t.Errorf("resolveTunStack(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAlignEnhancedDNSListenPreservesExternalProxyServerNameserverOn7874(t *testing.T) {
	dns := map[string]interface{}{
		"listen": "127.0.0.1:49659",
		"proxy-server-nameserver": []interface{}{
			"udp://127.0.0.1:7874",
		},
		"nameserver": []interface{}{
			"https://doh.pub/dns-query",
		},
	}
	if err := alignEnhancedDNSListenWith(dns, func(port int) bool { return port == 63385 }, func() (int, error) {
		return 63385, nil
	}); err != nil {
		t.Fatal(err)
	}
	if dns["listen"] != "127.0.0.1:63385" {
		t.Fatalf("listen = %v", dns["listen"])
	}
	servers := dns["proxy-server-nameserver"].([]interface{})
	if servers[0] != "udp://127.0.0.1:7874" {
		t.Fatalf("external proxy-server-nameserver changed: %v", servers)
	}
}

func TestAlignDoesNotTreatProxyServerPortNumberAsOwnership(t *testing.T) {
	dns := map[string]interface{}{
		"listen":                  "127.0.0.1:49659",
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
	}
	if err := alignEnhancedDNSListenWith(dns, func(int) bool { return true }, func() (int, error) {
		return 63385, nil
	}); err != nil {
		t.Fatal(err)
	}
	if dns["listen"] != "127.0.0.1:63385" {
		t.Fatalf("listener = %v, want fallback because 7874 is an unowned resolver target", dns["listen"])
	}
	if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != "udp://127.0.0.1:7874" {
		t.Fatalf("external proxy resolver changed to %v", got)
	}
}

func TestAlignPreservesDoHAndDoTProxyResolversAtMatchingPort(t *testing.T) {
	dns := map[string]interface{}{
		"listen": "127.0.0.1:7874",
		"proxy-server-nameserver": []interface{}{
			"https://127.0.0.1:7874/dns-query",
			"tls://127.0.0.1:7874",
		},
	}
	if err := alignEnhancedDNSListenWith(dns, func(port int) bool { return port == 63385 }, func() (int, error) {
		return 63385, nil
	}); err != nil {
		t.Fatal(err)
	}
	want := []interface{}{"https://127.0.0.1:7874/dns-query", "tls://127.0.0.1:7874"}
	if got := dns["proxy-server-nameserver"].([]interface{}); !reflect.DeepEqual(got, want) {
		t.Fatalf("DoH/DoT resolvers changed to %v", got)
	}
}

func TestAlignEnhancedDNSListenPreservesRawReferencesWhenPreferredIsBusy(t *testing.T) {
	dns := map[string]interface{}{
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
		"nameserver-policy": map[string]interface{}{
			"example.com": "127.0.0.1:7874",
		},
	}
	if err := alignEnhancedDNSListenWith(dns, func(port int) bool { return port != 7874 }, func() (int, error) {
		return 63385, nil
	}); err != nil {
		t.Fatal(err)
	}
	if dns["listen"] != "127.0.0.1:63385" {
		t.Fatalf("listen = %v", dns["listen"])
	}
	servers := dns["proxy-server-nameserver"].([]interface{})
	if servers[0] != "udp://127.0.0.1:7874" {
		t.Fatalf("raw profile proxy-server-nameserver changed: %v", servers)
	}
	policy := dns["nameserver-policy"].(map[string]interface{})
	if policy["example.com"] != "127.0.0.1:7874" {
		t.Fatalf("nameserver-policy = %v", policy)
	}
}

func TestEnhancedDNSPortAvailabilityChecksUDPListeners(t *testing.T) {
	listener, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.LocalAddr().(*net.UDPAddr).Port
	if checkDNSPortAvailable(port) {
		t.Fatalf("DNS port %d reported available while another process owns its UDP socket", port)
	}
}

func TestResolveConfiguredMixedPortAcceptsAvailableMaximumPort(t *testing.T) {
	const maximumPort = 65535
	listener, err := net.Listen("tcp", "127.0.0.1:65535")
	if err != nil {
		t.Skipf("TCP port %d is occupied; skipping boundary check: %v", maximumPort, err)
	}
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}

	port, err := resolveConfiguredMixedPort(maximumPort, checkPortAvailable)
	if err != nil || port != maximumPort {
		t.Fatalf("available configured port: got port=%d err=%v, want %d", port, err, maximumPort)
	}
}

func TestEnhancedDNSSelectionRejectsUnavailableFallbackPort(t *testing.T) {
	dns := map[string]interface{}{"listen": "127.0.0.1:7874"}
	available := func(port int) bool { return port == 11053 }
	chosen, err := chooseEnhancedDNSPort(dns, nil, available, func() (int, error) {
		return 63385, nil
	})
	if err != nil || chosen != 11053 {
		t.Fatalf("fallback DNS port = %d, want an available fallback 11053", chosen)
	}
	chosen, err = chooseEnhancedDNSPort(dns, nil, func(int) bool { return false }, func() (int, error) {
		return 63385, nil
	})
	if chosen != 0 || err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=dns_listener address=127.0.0.1 ") {
		t.Fatalf("DNS selection = %d, %v; want an explicit port conflict when every candidate is occupied", chosen, err)
	}
}

func TestRetargetBootstrapDNSServerRequiresOwnedIPv4Endpoint(t *testing.T) {
	if got := retargetEnhancedBootstrapDNSServerAtPort("tls://223.5.5.5:853", 7874, 63385); got != "tls://223.5.5.5:853" {
		t.Fatalf("public resolver changed to %s", got)
	}
	if got := retargetEnhancedBootstrapDNSServerAtPort("https://127.0.0.1:5353/dns-query", 7874, 63385); got != "https://127.0.0.1:5353/dns-query" {
		t.Fatalf("external DoH resolver changed to %s", got)
	}
	if got := retargetEnhancedBootstrapDNSServerAtPort("udp://127.0.0.1:7874", 7874, 63385); got != "udp://127.0.0.1:63385" {
		t.Fatalf("explicitly owned loopback resolver = %s", got)
	}
	if got := retargetEnhancedBootstrapDNSServerAtPort("udp://localhost:7874", 7874, 63385); got != "udp://127.0.0.1:63385" {
		t.Fatalf("owned localhost alias = %s", got)
	}
	if got := retargetEnhancedBootstrapDNSServerAtPort("tcp://localhost:7874", 7874, 7874); got != "tcp://127.0.0.1:7874" {
		t.Fatalf("same-port localhost alias = %s", got)
	}
	for _, resolver := range []string{"udp://192.168.1.10:7874", "udp://[::1]:7874"} {
		if got := retargetEnhancedBootstrapDNSServerAtPort(resolver, 7874, 63385); got != resolver {
			t.Fatalf("non-127.0.0.1 resolver %q changed to %q", resolver, got)
		}
	}
}

func TestRewriteLoopbackDNSPortsPreservesExternalLocalResolvers(t *testing.T) {
	dns := map[string]interface{}{
		"nameserver": []interface{}{
			"127.0.0.1:5353",
			"https://127.0.0.1:5353/dns-query",
			"https://dns.adguard-dns.com/dns-query",
		},
		"fallback": []string{"127.0.0.1:5353"},
		"proxy-server-nameserver": []interface{}{
			"udp://127.0.0.1:7874",
			"udp://localhost:7874",
			"udp://[::1]:7874",
		},
		"nameserver-policy": map[string]interface{}{
			"lan.example":       "127.0.0.1:5353",
			"generated.example": "https://127.0.0.1:7874/dns-query",
		},
	}

	rewriteLoopbackDNSPorts(dns, 63385)

	servers := dns["nameserver"].([]interface{})
	wantServers := []interface{}{
		"127.0.0.1:5353",
		"https://127.0.0.1:5353/dns-query",
		"https://dns.adguard-dns.com/dns-query",
	}
	if !reflect.DeepEqual(servers, wantServers) {
		t.Fatalf("external nameservers = %v, want %v", servers, wantServers)
	}
	fallback := dns["fallback"].([]string)
	if fallback[0] != "127.0.0.1:5353" {
		t.Fatalf("external fallback resolver changed to %s", fallback[0])
	}
	proxyServers := dns["proxy-server-nameserver"].([]interface{})
	wantProxyServers := []interface{}{"udp://127.0.0.1:7874", "udp://localhost:7874", "udp://[::1]:7874"}
	if !reflect.DeepEqual(proxyServers, wantProxyServers) {
		t.Fatalf("proxy resolvers = %v, want %v", proxyServers, wantProxyServers)
	}
	policy := dns["nameserver-policy"].(map[string]interface{})
	if policy["lan.example"] != "127.0.0.1:5353" {
		t.Fatalf("external policy resolver changed to %v", policy["lan.example"])
	}
	if policy["generated.example"] != "https://127.0.0.1:7874/dns-query" {
		t.Fatalf("profile policy resolver changed to %v", policy["generated.example"])
	}
}

func TestRewriteLoopbackDNSPortsRequiresDeclaredBootstrapAndMatchingListen(t *testing.T) {
	const (
		listen = "127.0.0.1:7874"
		server = "udp://127.0.0.1:7874"
	)
	dns := map[string]interface{}{
		"listen":                  listen,
		"proxy-server-nameserver": []interface{}{server},
	}
	metadata := declaredProxyDNSBootstrapReferences(dns)
	if len(metadata) != 1 {
		t.Fatalf("bootstrap references = %v, want one exact plain self-bootstrap", metadata)
	}

	// Raw profile references are preserved even when the field and port look
	// like a historical ClashFX endpoint.
	rewriteLoopbackDNSPorts(dns, 63385)
	if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != server {
		t.Fatalf("unmarked profile resolver changed to %v", got)
	}

	rewriteLoopbackDNSPorts(dns, 63385, metadata...)
	if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://127.0.0.1:63385"; got != want {
		t.Fatalf("proven generated resolver = %v, want %v", got, want)
	}

	dns["proxy-server-nameserver"] = []interface{}{server}
	mismatched := metadata[0]
	mismatched.SourceDNSListen = "127.0.0.1:5353"
	rewriteLoopbackDNSPorts(dns, 63385, mismatched)
	if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != server {
		t.Fatalf("reference with mismatched source listener changed to %v", got)
	}
}

func TestEnhancedDNSSelectionRejectsSelfCycleWhenFallbackTargetsResolver(t *testing.T) {
	dns := map[string]interface{}{
		"listen":     "127.0.0.1:11053",
		"nameserver": []interface{}{"127.0.0.1:11053"},
	}
	chosen, err := chooseEnhancedDNSPort(dns, nil, func(port int) bool {
		return port == 11053
	}, func() (int, error) {
		return 11053, nil
	})
	if chosen != 0 || err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle] address=127.0.0.1 port=11053") {
		t.Fatalf("DNS selection = %d, %v; want a detected self-cycle", chosen, err)
	}
}

func TestGeneralResolverSelfCyclesAreRejected(t *testing.T) {
	for _, key := range []string{"nameserver", "default-nameserver", "fallback"} {
		t.Run(key, func(t *testing.T) {
			dns := map[string]interface{}{
				"listen": "127.0.0.1:7874",
				key:      []interface{}{"127.0.0.1:7874"},
			}
			if err := alignEnhancedDNSListenWith(dns, func(int) bool { return true }, func() (int, error) {
				t.Fatal("self-cycle must fail before fallback selection")
				return 0, nil
			}); err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle] address=127.0.0.1 port=7874") {
				t.Fatalf("align error = %v, want explicit DNS self-cycle", err)
			}
		})
	}
}

func TestGeneralResolverSelfCycleOnReservedProxyPortIsRejected(t *testing.T) {
	dns := map[string]interface{}{
		"listen": "127.0.0.1:7890",
		"nameserver": []interface{}{
			"127.0.0.1:7890",
			"https://dns.example/dns-query",
		},
	}
	err := alignEnhancedDNSListenWithReserved(dns, []int{7890}, func(port int) bool {
		return port == preferredEnhancedDNSPort
	}, func() (int, error) {
		t.Fatal("reserved self-cycle must fail before fallback selection")
		return 0, nil
	})
	if err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle] address=127.0.0.1 port=7890") {
		t.Fatalf("align error = %v, want explicit self-cycle on the reserved proxy port", err)
	}
	if dns["listen"] != "127.0.0.1:7890" {
		t.Fatalf("DNS listener changed after rejection: %v", dns["listen"])
	}
	wantServers := []interface{}{"127.0.0.1:7890", "https://dns.example/dns-query"}
	if got := dns["nameserver"].([]interface{}); !reflect.DeepEqual(got, wantServers) {
		t.Fatalf("resolver list changed after rejection: %v", got)
	}
}

func TestReservedListenerAliasesCannotHideGeneralResolverCycle(t *testing.T) {
	for _, addresses := range [][2]string{
		{"0.0.0.0:7890", "127.0.0.1:7890"},
		{"0.0.0.0:7890", "localhost:7890"},
		{"127.0.0.1:7890", "localhost:7890"},
	} {
		t.Run(addresses[0]+"_"+addresses[1], func(t *testing.T) {
			dns := map[string]interface{}{
				"listen": addresses[0], "nameserver": []interface{}{addresses[1]},
			}
			err := alignEnhancedDNSListenWithReserved(dns, []int{7890}, func(int) bool {
				t.Fatal("reserved listener aliases must be rejected before probing ports")
				return false
			}, func() (int, error) {
				t.Fatal("reserved listener aliases must be rejected before allocating ports")
				return 0, nil
			})
			if err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle]") {
				t.Fatalf("error = %v, want reserved DNS cycle rejection", err)
			}
			if dns["listen"] != addresses[0] {
				t.Fatal("rejection must preserve the original listener")
			}
		})
	}
}

func TestGeneralResolverSelfEndpointIsPreservedWhenExternalSocketOwnsIt(t *testing.T) {
	external, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer external.Close()
	port := external.LocalAddr().(*net.UDPAddr).Port
	fallbackPort := freeLoopbackDNSPort(t, preferredEnhancedDNSPort, port)
	dns := map[string]interface{}{
		"listen":     net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		"nameserver": []interface{}{net.JoinHostPort("127.0.0.1", strconv.Itoa(port))},
	}
	if err := alignEnhancedDNSListenWith(dns, func(candidate int) bool {
		if candidate == port {
			return checkDNSPortAvailable(candidate)
		}
		return candidate == fallbackPort
	}, func() (int, error) {
		return fallbackPort, nil
	}); err != nil {
		t.Fatal(err)
	}
	servers := dns["nameserver"].([]interface{})
	if servers[0] != net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) {
		t.Fatalf("external local resolver changed to %v", servers[0])
	}
	wantListen := net.JoinHostPort("127.0.0.1", strconv.Itoa(fallbackPort))
	if dns["listen"] != wantListen {
		t.Fatalf("DNS listener = %v, want fallback port", dns["listen"])
	}
}

func TestDeclaredProxyBootstrapRetargetsAwayFromReservedOriginalListener(t *testing.T) {
	dns := map[string]interface{}{
		"listen":                  "127.0.0.1:7890",
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7890"},
	}
	if err := alignEnhancedDNSListenWithReserved(dns, []int{7890}, func(port int) bool {
		return port == preferredEnhancedDNSPort
	}, func() (int, error) {
		t.Fatal("preferred DNS port should be available")
		return 0, nil
	}); err != nil {
		t.Fatal(err)
	}
	if dns["listen"] != "127.0.0.1:7874" {
		t.Fatalf("DNS listener = %v, want preferred fallback 127.0.0.1:7874", dns["listen"])
	}
	servers := dns["proxy-server-nameserver"].([]interface{})
	if servers[0] != "udp://127.0.0.1:7874" {
		t.Fatalf("declared bootstrap = %v, want retargeted resolver", servers[0])
	}
}

func TestDeclaredLegacyBootstrapFollowsListenerFallback(t *testing.T) {
	dns := map[string]interface{}{
		"listen":                  "127.0.0.1:7874",
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
	}
	if err := alignEnhancedDNSListenWith(dns, func(port int) bool { return port == 63385 }, func() (int, error) {
		return 63385, nil
	}); err != nil {
		t.Fatal(err)
	}
	if dns["listen"] != "127.0.0.1:63385" {
		t.Fatalf("DNS listen = %v, want fallback port", dns["listen"])
	}
	servers := dns["proxy-server-nameserver"].([]interface{})
	if servers[0] != "udp://127.0.0.1:63385" {
		t.Fatalf("declared plain bootstrap did not follow listener fallback = %v", servers)
	}
	if dnsHasReferenceAtPort(dns, 63385, declaredProxyDNSBootstrapReferences(map[string]interface{}{
		"listen":                  "127.0.0.1:63385",
		"proxy-server-nameserver": servers,
	})) {
		t.Fatal("declared proxy bootstrap was classified as a true DNS cycle")
	}
}

func TestDeclaredProxyBootstrapRequiresExactPlainProfileEndpoint(t *testing.T) {
	tests := []struct {
		name string
		dns  map[string]interface{}
		want int
	}{
		{
			name: "matching plain address",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:7874",
				"proxy-server-nameserver": []interface{}{"127.0.0.1:7874"},
			},
			want: 1,
		},
		{
			name: "matching TCP address",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:7874",
				"proxy-server-nameserver": []interface{}{"tcp://127.0.0.1:7874"},
			},
			want: 1,
		},
		{
			name: "IPv4 wildcard with loopback bootstrap",
			dns: map[string]interface{}{
				"listen":                  "0.0.0.0:7874",
				"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
			},
			want: 1,
		},
		{
			name: "omitted host is IPv4 wildcard",
			dns: map[string]interface{}{
				"listen":                  ":7874",
				"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
			},
			want: 1,
		},
		{
			name: "localhost source aliases to IPv4 loopback",
			dns: map[string]interface{}{
				"listen":                  "localhost:7874",
				"proxy-server-nameserver": []interface{}{"tcp://127.0.0.1:7874"},
			},
			want: 1,
		},
		{
			name: "IPv4 loopback source aliases to localhost",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:7874",
				"proxy-server-nameserver": []interface{}{"udp://localhost:7874"},
			},
			want: 1,
		},
		{
			name: "LAN source is not a local bootstrap",
			dns: map[string]interface{}{
				"listen":                  "192.168.1.10:7874",
				"proxy-server-nameserver": []interface{}{"udp://192.168.1.10:7874"},
			},
			want: 0,
		},
		{
			name: "IPv4 wildcard does not cover IPv6 loopback",
			dns: map[string]interface{}{
				"listen":                  "0.0.0.0:7874",
				"proxy-server-nameserver": []interface{}{"udp://[::1]:7874"},
			},
			want: 0,
		},
		{
			name: "IPv6 listener remains independent",
			dns: map[string]interface{}{
				"listen":                  "[::1]:7874",
				"proxy-server-nameserver": []interface{}{"udp://[::1]:7874"},
			},
			want: 0,
		},
		{
			name: "listener absent",
			dns:  map[string]interface{}{"proxy-server-nameserver": []interface{}{"127.0.0.1:7874"}},
			want: 0,
		},
		{
			name: "listener differs",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:5353",
				"proxy-server-nameserver": []interface{}{"127.0.0.1:7874"},
			},
			want: 0,
		},
		{
			name: "DoH same port stays external",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:7874",
				"proxy-server-nameserver": []interface{}{"https://127.0.0.1:7874/dns-query"},
			},
			want: 0,
		},
		{
			name: "DoT same port stays external",
			dns: map[string]interface{}{
				"listen":                  "127.0.0.1:7874",
				"proxy-server-nameserver": []interface{}{"tls://127.0.0.1:7874"},
			},
			want: 0,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := len(declaredProxyDNSBootstrapReferences(test.dns)); got != test.want {
				t.Fatalf("bootstrap reference count = %d, want %d", got, test.want)
			}
		})
	}
}

func TestRetargetEnhancedDNSListenWithoutSourceListener(t *testing.T) {
	for _, listen := range []interface{}{nil, ""} {
		dns := map[string]interface{}{
			"nameserver":              []interface{}{"127.0.0.1:5353"},
			"proxy-server-nameserver": []interface{}{"udp://192.168.1.10:5353"},
		}
		if listen != nil {
			dns["listen"] = listen
		}
		if err := retargetEnhancedDNSListen(dns, 51188); err != nil {
			t.Fatalf("listen %v: %v", listen, err)
		}
		if got := dns["listen"]; got != "127.0.0.1:51188" {
			t.Fatalf("listen %v retargeted to %v", listen, got)
		}
		if got := dns["nameserver"].([]interface{})[0]; got != "127.0.0.1:5353" {
			t.Fatalf("external local nameserver changed to %v", got)
		}
		if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != "udp://192.168.1.10:5353" {
			t.Fatalf("unproven proxy resolver changed to %v", got)
		}
	}

	dns := map[string]interface{}{"listen": "invalid-address", "nameserver": []interface{}{"127.0.0.1:5353"}}
	if err := retargetEnhancedDNSListen(dns, 51188); err == nil {
		t.Fatal("nonempty invalid listener should be rejected")
	}
	if got := dns["listen"]; got != "invalid-address" {
		t.Fatalf("invalid listener changed to %v", got)
	}
}

func TestRetargetEnhancedDNSListenRejectsDestinationCycles(t *testing.T) {
	tests := []struct {
		name string
		dns  map[string]interface{}
	}{
		{
			name: "independent resolver collides with target",
			dns: map[string]interface{}{
				"listen":                  "0.0.0.0:7874",
				"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
				"nameserver":              []interface{}{"127.0.0.1:51188"},
			},
		},
		{
			name: "ordinary resolver retains an existing listener cycle",
			dns: map[string]interface{}{
				"listen":     "127.0.0.1:7874",
				"nameserver": []interface{}{"127.0.0.1:7874"},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			port := 51188
			if test.name == "ordinary resolver retains an existing listener cycle" {
				port = 7874
			}
			originalListen := test.dns["listen"]
			if err := retargetEnhancedDNSListen(test.dns, port); err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle]") {
				t.Fatalf("retarget error = %v, want DNS cycle rejection", err)
			}
			if got := test.dns["listen"]; got != originalListen {
				t.Fatalf("listener mutated after rejection: %v", got)
			}
		})
	}
}

func TestEnhancedDNSWildcardStartupFallbackAndReloadRetarget(t *testing.T) {
	for _, listenHost := range []string{"127.0.0.1", "0.0.0.0"} {
		t.Run(listenHost, func(t *testing.T) {
			dns := map[string]interface{}{
				"listen":                  net.JoinHostPort(listenHost, "7874"),
				"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
			}
			if err := alignEnhancedDNSListenWith(dns, func(port int) bool { return port == 49634 }, func() (int, error) {
				return 49634, nil
			}); err != nil {
				t.Fatal(err)
			}
			if got := dns["listen"]; got != "127.0.0.1:49634" {
				t.Fatalf("startup listener = %v, want 127.0.0.1:49634", got)
			}
			if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != "udp://127.0.0.1:49634" {
				t.Fatalf("startup bootstrap = %v, want udp://127.0.0.1:49634", got)
			}
			if err := retargetEnhancedDNSListen(dns, 51188); err != nil {
				t.Fatal(err)
			}
			if got := dns["listen"]; got != "127.0.0.1:51188" {
				t.Fatalf("reload listener = %v, want 127.0.0.1:51188", got)
			}
			if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != "udp://127.0.0.1:51188" {
				t.Fatalf("reload bootstrap = %v, want udp://127.0.0.1:51188", got)
			}
		})
	}
}

func TestRetargetEnhancedDNSConfigFilePreservesPermissionsAndResolvers(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "enhanced.yaml")
	contents := []byte(`dns:
  enable: true
  listen: 0.0.0.0:7874
  nameserver:
    - 127.0.0.1:5353
    - https://127.0.0.1:7874/dns-query
  default-nameserver:
    - tls://127.0.0.1:853
  proxy-server-nameserver:
    - udp://127.0.0.1:7874
    - https://127.0.0.1:7874/dns-query
    - tls://127.0.0.1:7874
`)
	if err := os.WriteFile(configPath, contents, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(configPath, 0600); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(configPath, 51188); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0600 {
		t.Fatalf("config permissions = %04o, want 0600", got)
	}
	updated, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]interface{}
	if err := yaml.Unmarshal(updated, &raw); err != nil {
		t.Fatal(err)
	}
	dns := raw["dns"].(map[string]interface{})
	if got := dns["listen"]; got != "127.0.0.1:51188" {
		t.Fatalf("rewritten listener = %v", got)
	}
	wantNameservers := []interface{}{"127.0.0.1:5353", "https://127.0.0.1:7874/dns-query"}
	if got := dns["nameserver"].([]interface{}); !reflect.DeepEqual(got, wantNameservers) {
		t.Fatalf("ordinary nameservers changed: %v", got)
	}
	wantProxy := []interface{}{"udp://127.0.0.1:51188", "https://127.0.0.1:7874/dns-query", "tls://127.0.0.1:7874"}
	if got := dns["proxy-server-nameserver"].([]interface{}); !reflect.DeepEqual(got, wantProxy) {
		t.Fatalf("proxy resolvers = %v, want %v", got, wantProxy)
	}
	if got := dns["default-nameserver"].([]interface{})[0]; got != "tls://127.0.0.1:853" {
		t.Fatalf("default resolver changed to %v", got)
	}
}

func TestEnhancedDNSSelectionAvoidsReservedPorts(t *testing.T) {
	reserved := []int{preferredEnhancedDNSPort, enhancedControllerPort, 7890, 1080, 11053}
	chosen, err := chooseEnhancedDNSPort(map[string]interface{}{}, reserved, func(int) bool { return true }, func() (int, error) {
		return 7890, nil
	})
	if chosen != 0 || err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=dns_listener ") {
		t.Fatalf("DNS selection = %d, %v; want conflict after all reserved candidates", chosen, err)
	}
}

func TestEnhancedDNSPreflightChecksTCPListeners(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	if checkDNSPortAvailable(port) {
		t.Fatalf("DNS port %d reported available while another process owns its TCP socket", port)
	}
}

func TestCloseBuiltinDNSListenerReleasesLoopbackTCPAndUDP(t *testing.T) {
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := probe.Addr().(*net.TCPAddr).Port
	if err := probe.Close(); err != nil {
		t.Fatal(err)
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if !checkDNSPortAvailable(port) {
		t.Skipf("loopback DNS fixture port %d became occupied before setup", port)
	}

	resolvers := mihomoDNS.NewResolver(mihomoDNS.Config{})
	mapper := mihomoDNS.NewEnhancer(mihomoDNS.EnhancerConfig{EnhancedMode: C.DNSNormal})
	mihomoDNS.ReCreateServer(address, mihomoDNS.NewService(resolvers.Resolver, mapper))
	t.Cleanup(closeBuiltinDNSListener)

	waitForMihomoDNSReady(t, address)

	closeBuiltinDNSListener()
	deadline := time.Now().Add(2 * time.Second)
	for !checkDNSPortAvailable(port) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if !checkDNSPortAvailable(port) {
		t.Fatalf("Mihomo DNS server still owns TCP or UDP port %d after suspension", port)
	}
}

func TestMihomoProxyBootstrapUsesGeneralLocalResolverAfterFallback(t *testing.T) {
	upstreamPacket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	upstreamHits := make(chan struct{}, 1)
	upstream := &miekgDNS.Server{
		PacketConn: upstreamPacket,
		Handler: miekgDNS.HandlerFunc(func(w miekgDNS.ResponseWriter, request *miekgDNS.Msg) {
			select {
			case upstreamHits <- struct{}{}:
			default:
			}
			response := new(miekgDNS.Msg)
			response.SetReply(request)
			for _, question := range request.Question {
				if question.Qtype != miekgDNS.TypeA {
					continue
				}
				record, err := miekgDNS.NewRR(question.Name + " 30 IN A 203.0.113.17")
				if err == nil {
					response.Answer = append(response.Answer, record)
				}
			}
			_ = w.WriteMsg(response)
		}),
	}
	go func() { _ = upstream.ActivateAndServe() }()
	t.Cleanup(func() { _ = upstream.Shutdown() })

	for _, listenHost := range []string{"127.0.0.1", "0.0.0.0"} {
		t.Run(listenHost, func(t *testing.T) {
			startupFallbackPort := freeLoopbackDNSPort(t, preferredEnhancedDNSPort)
			oldPort := freeLoopbackDNSPort(t, preferredEnhancedDNSPort, startupFallbackPort)
			oldAddress := net.JoinHostPort(listenHost, strconv.Itoa(oldPort))
			dnsProfile := map[string]interface{}{
				"listen":                  oldAddress,
				"nameserver":              []interface{}{"udp://" + upstreamPacket.LocalAddr().String()},
				"proxy-server-nameserver": []interface{}{"udp://" + net.JoinHostPort("127.0.0.1", strconv.Itoa(oldPort))},
			}
			if err := alignEnhancedDNSListenWith(dnsProfile, func(candidate int) bool {
				return candidate == startupFallbackPort
			}, func() (int, error) {
				return startupFallbackPort, nil
			}); err != nil {
				t.Fatal(err)
			}
			wantStartupListen := net.JoinHostPort("127.0.0.1", strconv.Itoa(startupFallbackPort))
			if dnsProfile["listen"] != wantStartupListen {
				t.Fatalf("aligned DNS listener = %v, want %s", dnsProfile["listen"], wantStartupListen)
			}
			if got := dnsProfile["proxy-server-nameserver"].([]interface{})[0]; got != "udp://"+wantStartupListen {
				t.Fatalf("declared proxy bootstrap = %v, want udp://%s", got, wantStartupListen)
			}

			retargetPort := freeLoopbackDNSPort(t, preferredEnhancedDNSPort, startupFallbackPort, oldPort)
			verifyBootstrap := func() {
				t.Helper()
				proxyServer := dnsProfile["proxy-server-nameserver"].([]interface{})[0].(string)
				mainServer := dnsProfile["nameserver"].([]interface{})[0].(string)
				mainServers, err := mihomoDNS.ParseNameServer([]string{mainServer})
				if err != nil {
					t.Fatalf("parse local fixture nameserver: %v", err)
				}
				proxyServers, err := mihomoDNS.ParseNameServer([]string{proxyServer})
				if err != nil {
					t.Fatalf("parse proxy nameserver: %v", err)
				}
				resolvers := mihomoDNS.NewResolver(mihomoDNS.Config{Main: mainServers, ProxyServer: proxyServers})
				if resolvers.ProxyResolver == nil {
					t.Fatal("Mihomo did not create the proxy resolver")
				}
				mapper := mihomoDNS.NewEnhancer(mihomoDNS.EnhancerConfig{EnhancedMode: C.DNSNormal})
				listen := dnsProfile["listen"].(string)
				mihomoDNS.ReCreateServer(listen, mihomoDNS.NewService(resolvers.Resolver, mapper))
				waitForMihomoDNSReady(t, listen)

				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				answers, err := resolvers.ProxyResolver.LookupIPv4(ctx, "bootstrap.fixture.test")
				if err != nil {
					t.Fatalf("proxy DNS bootstrap through the local general resolver failed: %v", err)
				}
				if len(answers) != 1 || answers[0].String() != "203.0.113.17" {
					t.Fatalf("bootstrap answers = %v, want [203.0.113.17]", answers)
				}
				select {
				case <-upstreamHits:
				default:
					t.Fatal("proxy bootstrap did not reach the local fixture resolver")
				}
				closeBuiltinDNSListener()
			}
			defer closeBuiltinDNSListener()

			verifyBootstrap()
			if err := retargetEnhancedDNSListen(dnsProfile, retargetPort); err != nil {
				t.Fatal(err)
			}
			if got := dnsProfile["proxy-server-nameserver"].([]interface{})[0]; got != "udp://"+dnsProfile["listen"].(string) {
				t.Fatalf("fixed-port bootstrap = %v, want udp://%s", got, dnsProfile["listen"])
			}
			verifyBootstrap()
		})
	}

}

func freeLoopbackDNSPort(t *testing.T, excluded ...int) int {
	t.Helper()
	for attempt := 0; attempt < 8; attempt++ {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := listener.Addr().(*net.TCPAddr).Port
		if containsInt(excluded, port) {
			_ = listener.Close()
			continue
		}
		packet, err := net.ListenPacket("udp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)))
		if err != nil {
			_ = listener.Close()
			continue
		}
		_ = packet.Close()
		_ = listener.Close()
		return port
	}
	t.Fatal("could not allocate a free loopback DNS fixture port")
	return 0
}

func waitForMihomoDNSReady(t *testing.T, address string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	query := new(miekgDNS.Msg)
	query.SetQuestion(miekgDNS.Fqdn("readiness.fixture.test"), miekgDNS.TypeA)
	client := &miekgDNS.Client{Net: "udp", Timeout: 100 * time.Millisecond}
	for time.Now().Before(deadline) {
		tcp, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if err == nil {
			_ = tcp.Close()
			if response, _, queryErr := client.Exchange(query, address); queryErr == nil && response != nil {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("Mihomo DNS server did not answer TCP and UDP on %s", address)
}

func TestConfiguredProxyListenerPortsAreReserved(t *testing.T) {
	got := configuredProxyListenerPorts(map[string]interface{}{
		"port":        8080,
		"socks-port":  "1080",
		"mixed-port":  7890,
		"redir-port":  int64(7892),
		"tproxy-port": 7893,
		"listeners": []interface{}{
			map[string]interface{}{"type": "mixed", "port": 7894},
		},
	})
	want := []int{8080, 1080, 7890, 7892, 7893, 7894}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("reserved proxy ports = %v, want %v", got, want)
	}
}

// Regression: suspension immediately after recreation must also close listeners
// whose serving goroutines have only just been scheduled.
func TestImmediateDNSRecreationSuspensionReleasesBothListeners(t *testing.T) {
	resolvers := mihomoDNS.NewResolver(mihomoDNS.Config{})
	mapper := mihomoDNS.NewEnhancer(mihomoDNS.EnhancerConfig{EnhancedMode: C.DNSNormal})
	service := mihomoDNS.NewService(resolvers.Resolver, mapper)
	t.Cleanup(closeBuiltinDNSListener)
	// Use one qualified non-ephemeral port for every cycle. A fresh :0 port
	// can be claimed by the runner's unrelated outgoing UDP activity after
	// shutdown, which does not identify whether this server retained its socket.
	port := 0
	for candidate := 20000; candidate < 40000; candidate++ {
		if checkDNSPortAvailable(candidate) {
			port = candidate
			break
		}
	}
	if port == 0 {
		t.Fatal("no DNS lifecycle fixture port available")
	}
	for i := 0; i < 20; i++ {
		mihomoDNS.ReCreateServer(net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), service)
		closeBuiltinDNSListener()
		if !checkDNSPortAvailable(port) {
			t.Fatalf("immediate suspension left DNS port %d occupied", port)
		}
	}
}

func TestRetargetEnhancedDNSConfigFileFailureLeavesOriginalIntact(t *testing.T) {
	for _, port := range []int{0, 65536, 5353} {
		t.Run(strconv.Itoa(port), func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "enhanced.yaml")
			original := []byte("dns:\n  listen: 0.0.0.0:7874\n  nameserver: [udp://127.0.0.1:5353]\n  proxy-server-nameserver: [udp://127.0.0.1:7874]\n")
			if err := os.WriteFile(path, original, 0600); err != nil {
				t.Fatal(err)
			}
			if err := retargetEnhancedDNSConfigFile(path, port); err == nil {
				t.Fatal("unsafe retarget accepted")
			}
			after, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(original) {
				t.Fatal("rejected retarget changed original config")
			}
			entries, err := os.ReadDir(directory)
			if err != nil {
				t.Fatal(err)
			}
			if len(entries) != 1 {
				t.Fatalf("temporary config leaked: %v", entries)
			}
		})
	}
}

func TestP2EnhancedDNSReservedPortsCollectsProxyAndControllerTCPPorts(t *testing.T) {
	raw := map[string]interface{}{
		"bind-address": "127.0.0.1",
		"port":         "49634",
		"socks-port":   1080,
		"mixed-port":   int64(7890),
		"redir-port":   float64(7892),
		"tproxy-port":  "7893",
		"listeners": []interface{}{
			map[string]interface{}{"name": "first", "type": "mixed", "listen": "127.0.0.1", "port": 7894},
			map[string]interface{}{"name": "second", "type": "mixed", "listen": "127.0.0.1", "port": "7893"}, // duplicate proxy port
			map[string]interface{}{"name": "invalid", "type": "mixed", "listen": "127.0.0.1", "port": "invalid"},
		},
		"external-controller":     "127.0.0.1:49634",
		"external-controller-tls": "127.0.0.1:9443",
	}
	want := []int{49634, 1080, 7890, 7892, 7893, 7894, 9443}
	if got := enhancedDNSReservedPorts(raw); !reflect.DeepEqual(sortedListenerPorts(got), sortedListenerPorts(want)) {
		t.Fatalf("reserved listener ports = %v, want %v", got, want)
	}
}

func TestP2EnhancedDNSReservedPortsIgnoreInvalidDisabledAndNonTCPPorts(t *testing.T) {
	raw := map[string]interface{}{
		"port":        0,
		"socks-port":  "disabled",
		"mixed-port":  65536,
		"redir-port":  -1,
		"tproxy-port": nil,
		"listeners": []interface{}{
			map[string]interface{}{"type": "mixed", "port": 70000},
			map[string]interface{}{"type": "mixed", "port": "bad"},
		},
		"external-controller":     "unix:///tmp/clash-controller.sock",
		"external-controller-tls": "pipe://./pipe/clash-controller",
	}
	if got := enhancedDNSReservedPorts(raw); len(got) != 0 {
		t.Fatalf("invalid, disabled, or non-TCP ports were reserved: %v", got)
	}
}

func TestP2RetargetRejectsAPIControllerPortsAsDNSTargets(t *testing.T) {
	for _, key := range []string{"external-controller", "external-controller-tls"} {
		t.Run(key, func(t *testing.T) {
			raw := map[string]interface{}{
				key: "127.0.0.1:49634",
				"dns": map[string]interface{}{
					"enable":                  true,
					"listen":                  "0.0.0.0:7874",
					"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
				},
			}
			contents, err := yaml.Marshal(raw)
			if err != nil {
				t.Fatal(err)
			}
			p2AssertRetargetFileFailure(t, contents, 49634,
				"[port_conflict] service=dns_listener ", "reason=reserved_listener")
		})
	}
}

func TestP2StartupAvoidsAvailableReservedPreferredPortAndFixedRetargetRejects(t *testing.T) {
	const (
		preferredPort = 7874
		fallbackPort  = 51888
	)
	dns := map[string]interface{}{
		"enable":                  true,
		"listen":                  "0.0.0.0:7874",
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
	}
	raw := map[string]interface{}{
		"port": preferredPort,
		"dns":  dns,
	}
	if err := alignEnhancedDNSListenWithReserved(dns, enhancedDNSReservedPorts(raw), func(int) bool {
		// Every candidate is available at the socket layer; startup must still
		// skip 7874 because it belongs to a configured proxy listener.
		return true
	}, func() (int, error) {
		return fallbackPort, nil
	}); err != nil {
		t.Fatal(err)
	}
	wantListen := net.JoinHostPort("127.0.0.1", strconv.Itoa(fallbackPort))
	if got := dns["listen"]; got != wantListen {
		t.Fatalf("startup listener = %v, want reserved preferred port to fall back to %s", got, wantListen)
	}
	if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://"+wantListen; got != want {
		t.Fatalf("startup bootstrap = %v, want %s", got, want)
	}
	before, err := yaml.Marshal(dns)
	if err != nil {
		t.Fatal(err)
	}
	err = retargetEnhancedDNSListen(dns, preferredPort, enhancedDNSReservedPorts(raw)...)
	if err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=dns_listener ") || !strings.Contains(err.Error(), "reason=reserved_listener") {
		t.Fatalf("fixed-port retarget error = %v, want reserved-listener conflict", err)
	}
	after, err := yaml.Marshal(dns)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("fixed-port rejection mutated DNS map:\nbefore:\n%s\nafter:\n%s", before, after)
	}
}

func TestP2ListenerConflictValidationCoversEveryProxyPortField(t *testing.T) {
	tests := []struct {
		name string
		raw  map[string]interface{}
	}{
		{name: "port", raw: map[string]interface{}{"port": "49634"}},
		{name: "socks-port", raw: map[string]interface{}{"socks-port": 49634}},
		{name: "mixed-port", raw: map[string]interface{}{"mixed-port": int64(49634)}},
		{name: "redir-port", raw: map[string]interface{}{"redir-port": 49634}},
		{name: "tproxy-port", raw: map[string]interface{}{"tproxy-port": "49634"}},
		{name: "listeners.port", raw: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{"type": "mixed", "listen": "127.0.0.1", "port": 49634}}}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := validateEnhancedListenerPortConflicts(test.raw, 49634)
			if err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=dns_listener ") || !strings.Contains(err.Error(), "port=49634 reason=reserved_listener") {
				t.Fatalf("%s conflict error = %v, want DNS reserved-listener conflict", test.name, err)
			}
		})
	}
}

func TestP2GeneratedAndCustomReloadRejectProxyPortWithoutChangingFile(t *testing.T) {
	t.Run("generated startup fallback then fixed active DNS port", func(t *testing.T) {
		const (
			proxyPort        = 49634
			generatedDNSPort = 51888
		)
		dns := map[string]interface{}{
			"enable":                  true,
			"listen":                  "0.0.0.0:7874",
			"nameserver":              []interface{}{"tls://223.5.5.5:853"},
			"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
		}
		raw := map[string]interface{}{
			"port":                    proxyPort,
			"external-controller":     "127.0.0.1:9090",
			"external-controller-tls": "127.0.0.1:9443",
			"dns":                     dns,
		}
		if err := alignEnhancedDNSListenWithReserved(dns, enhancedDNSReservedPorts(raw), func(port int) bool {
			return port == generatedDNSPort
		}, func() (int, error) {
			return generatedDNSPort, nil
		}); err != nil {
			t.Fatal(err)
		}
		if got, want := dns["listen"], "127.0.0.1:51888"; got != want {
			t.Fatalf("generated startup listener = %v, want %v", got, want)
		}
		if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://127.0.0.1:51888"; got != want {
			t.Fatalf("generated bootstrap = %v, want %v", got, want)
		}
		contents, err := yaml.Marshal(raw)
		if err != nil {
			t.Fatal(err)
		}
		p2AssertRetargetFileFailure(t, contents, proxyPort,
			"[port_conflict] service=dns_listener ", "reason=reserved_listener")
	})

	t.Run("custom source profile with TUN and wildcard DNS listen", func(t *testing.T) {
		contents := []byte(`port: 49634
external-controller: 127.0.0.1:9090
external-controller-tls: 127.0.0.1:9443
tun:
  enable: true
  stack: system
dns:
  enable: true
  listen: 0.0.0.0:7874
  nameserver:
    - tls://223.5.5.5:853
  proxy-server-nameserver:
    - udp://127.0.0.1:7874
`)
		p2AssertRetargetFileFailure(t, contents, 49634,
			"[port_conflict] service=dns_listener ", "reason=reserved_listener")
	})
}

func TestP2RetargetRejectsAPIProxyAndAPITLSConflictsWithDifferentDNSPort(t *testing.T) {
	tests := []struct {
		name     string
		contents []byte
	}{
		{
			name: "final API port collides with proxy listener",
			contents: []byte(`mixed-port: 49634
external-controller: 127.0.0.1:49634
dns:
  enable: true
  listen: 0.0.0.0:7874
`),
		},
		{
			name: "API and TLS API share a port",
			contents: []byte(`mixed-port: 7890
external-controller: 127.0.0.1:9090
external-controller-tls: 127.0.0.1:9090
dns:
  enable: true
  listen: 0.0.0.0:7874
`),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var raw map[string]interface{}
			if err := yaml.Unmarshal(test.contents, &raw); err != nil {
				t.Fatal(err)
			}
			err := validateEnhancedListenerPortConflicts(raw, 51188)
			if err == nil || !strings.HasPrefix(err.Error(), "[port_conflict] service=api_listener ") || !strings.Contains(err.Error(), "reason=reserved_listener") {
				t.Fatalf("conflict validation error = %v, want API listener reserved-port conflict", err)
			}
			p2AssertRetargetFileFailure(t, test.contents, 51188,
				"[port_conflict] service=api_listener ", "reason=reserved_listener")
		})
	}
}

func TestP2GeneratedAndCustomRetargetPreserveBootstrapAndFinalConfig(t *testing.T) {
	t.Run("generated runtime map", func(t *testing.T) {
		const (
			generatedDNSPort = 51888
			activeDNSPort    = 51999
		)
		dns := map[string]interface{}{
			"enable":                  true,
			"listen":                  "0.0.0.0:7874",
			"nameserver":              []interface{}{"tls://223.5.5.5:853"},
			"default-nameserver":      []interface{}{"114.114.114.114"},
			"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"},
		}
		tun := map[string]interface{}{"enable": true, "stack": "system", "mtu": 1400}
		raw := map[string]interface{}{
			"mixed-port":              7890,
			"external-controller":     "127.0.0.1:9090",
			"external-controller-tls": "127.0.0.1:9443",
			"tun":                     tun,
			"dns":                     dns,
		}
		if err := alignEnhancedDNSListenWithReserved(dns, enhancedDNSReservedPorts(raw), func(port int) bool {
			return port == generatedDNSPort
		}, func() (int, error) {
			return generatedDNSPort, nil
		}); err != nil {
			t.Fatal(err)
		}
		raw["dns"] = dns
		contents, err := yaml.Marshal(raw)
		if err != nil {
			t.Fatal(err)
		}
		updated := p2RetargetFile(t, contents, activeDNSPort)
		p2AssertRetargetedRuntimeConfig(t, updated, activeDNSPort, "127.0.0.1:9090", "127.0.0.1:9443", tun)
	})

	t.Run("custom source profile", func(t *testing.T) {
		contents := []byte(`mixed-port: 7890
external-controller: 127.0.0.1:9090
external-controller-tls: 127.0.0.1:9443
interface-name: utun8
tun:
  enable: true
  stack: system
  mtu: 1400
dns:
  enable: true
  listen: 0.0.0.0:7874
  nameserver:
    - tls://223.5.5.5:853
  default-nameserver:
    - 114.114.114.114
  proxy-server-nameserver:
    - udp://127.0.0.1:7874
`)
		updated := p2RetargetFile(t, contents, 52001)
		tun := map[string]interface{}{"enable": true, "stack": "system", "mtu": 1400}
		p2AssertRetargetedRuntimeConfig(t, updated, 52001, "127.0.0.1:9090", "127.0.0.1:9443", tun)
		if got := updated["interface-name"]; got != "utun8" {
			t.Fatalf("interface name = %v, want utun8", got)
		}
	})
}

func p2AssertRetargetFileFailure(t *testing.T, contents []byte, port int, wantPrefix, wantDetail string) {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, "enhanced.yaml")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0640); err != nil {
		t.Fatal(err)
	}
	err := retargetEnhancedDNSConfigFile(path, port)
	if err == nil || !strings.HasPrefix(err.Error(), wantPrefix) || !strings.Contains(err.Error(), wantDetail) {
		t.Fatalf("retarget error = %v, want prefix %q and detail %q", err, wantPrefix, wantDetail)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, contents) {
		t.Fatal("rejected retarget changed original config bytes")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0640 {
		t.Fatalf("rejected retarget changed config permissions to %04o", got)
	}
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != filepath.Base(path) {
		t.Fatalf("rejected retarget left unexpected files: %v", entries)
	}
}

func p2RetargetFile(t *testing.T, contents []byte, port int) map[string]interface{} {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, "enhanced.yaml")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0600); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(path, port); err != nil {
		t.Fatal(err)
	}
	updated, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]interface{}
	if err := yaml.Unmarshal(updated, &raw); err != nil {
		t.Fatal(err)
	}
	return raw
}

func p2AssertRetargetedRuntimeConfig(t *testing.T, raw map[string]interface{}, port int, apiAddress, tlsAddress string, wantTun map[string]interface{}) {
	t.Helper()
	dns, ok := raw["dns"].(map[string]interface{})
	if !ok {
		t.Fatalf("DNS config has type %T", raw["dns"])
	}
	wantListen := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if got := dns["listen"]; got != wantListen {
		t.Fatalf("retargeted DNS listener = %v, want %s", got, wantListen)
	}
	wantBootstrap := "udp://" + wantListen
	if got := dns["proxy-server-nameserver"].([]interface{})[0]; got != wantBootstrap {
		t.Fatalf("retargeted bootstrap = %v, want %s", got, wantBootstrap)
	}
	if got := dns["nameserver"].([]interface{})[0]; got != "tls://223.5.5.5:853" {
		t.Fatalf("ordinary resolver changed to %v", got)
	}
	if got := dns["default-nameserver"].([]interface{})[0]; got != "114.114.114.114" {
		t.Fatalf("default resolver changed to %v", got)
	}
	if got := raw["external-controller"]; got != apiAddress {
		t.Fatalf("final API address = %v, want %s", got, apiAddress)
	}
	if got := raw["external-controller-tls"]; got != tlsAddress {
		t.Fatalf("final TLS API address = %v, want %s", got, tlsAddress)
	}
	tun, ok := raw["tun"].(map[string]interface{})
	if !ok || !reflect.DeepEqual(tun, wantTun) {
		t.Fatalf("TUN config = %v, want %v", raw["tun"], wantTun)
	}
}
