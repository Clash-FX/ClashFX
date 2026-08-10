package main

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"net/http"
	"sync"
	"syscall"
	"testing"
	"time"

	A "github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	OG "github.com/metacubex/mihomo/adapter/outboundgroup"
	P "github.com/metacubex/mihomo/adapter/provider"
	C "github.com/metacubex/mihomo/constant"
	CP "github.com/metacubex/mihomo/constant/provider"
	E "github.com/metacubex/sing/common/exceptions"
)

type delayedURLTestAdapter struct {
	*outbound.Base
	mu    sync.RWMutex
	delay time.Duration
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

func TestClosedTunSocketIsTreatedAsClosed(t *testing.T) {
	if !E.IsClosed(syscall.ENOTSOCK) {
		t.Fatal("ENOTSOCK must stop the Darwin TUN read loop")
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

	deadline := time.Now().Add(150 * time.Millisecond)
	for secondProxy.LastDelayForTestUrl(testURL) >= 50 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
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
