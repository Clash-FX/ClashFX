package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func recoveryDNSFixture() (map[string]interface{}, map[string]interface{}) {
	dns := map[string]interface{}{
		"enable":                  true,
		"listen":                  "0.0.0.0:7874",
		"nameserver":              []interface{}{"127.0.0.1:5353", "https://dns.example/dns-query"},
		"default-nameserver":      []interface{}{"udp://127.0.0.1:5353"},
		"fallback":                []interface{}{"tls://1.1.1.1:853"},
		"proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874", "udp://127.0.0.1:5353"},
		"nameserver-policy": map[string]interface{}{
			"*.lan": "127.0.0.1:5353",
		},
	}
	return map[string]interface{}{"dns": dns}, dns
}

func assertRecoveryDNSFixtureAtPort(t *testing.T, dns map[string]interface{}, port int) {
	t.Helper()
	wantListen := "127.0.0.1:" + strconv.Itoa(port)
	if got := dns["listen"]; got != wantListen {
		t.Fatalf("dns.listen = %v, want %s", got, wantListen)
	}
	wantProxyResolvers := []interface{}{
		"udp://127.0.0.1:" + strconv.Itoa(port),
		"udp://127.0.0.1:5353",
	}
	if got := dns["proxy-server-nameserver"]; !reflect.DeepEqual(got, wantProxyResolvers) {
		t.Fatalf("proxy-server-nameserver = %v, want %v", got, wantProxyResolvers)
	}
	wantNameservers := []interface{}{"127.0.0.1:5353", "https://dns.example/dns-query"}
	if got := dns["nameserver"]; !reflect.DeepEqual(got, wantNameservers) {
		t.Fatalf("nameserver changed = %v, want %v", got, wantNameservers)
	}
	if got, want := dns["default-nameserver"], []interface{}{"udp://127.0.0.1:5353"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("default-nameserver changed = %v, want %v", got, want)
	}
	if got, want := dns["fallback"], []interface{}{"tls://1.1.1.1:853"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("fallback changed = %v, want %v", got, want)
	}
	if got, want := dns["nameserver-policy"], map[string]interface{}{"*.lan": "127.0.0.1:5353"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("nameserver-policy changed = %v, want %v", got, want)
	}
}

func TestEnhancedDNSRecoveryRetargetsBootstrapAcrossStartupRestartAndReloads(t *testing.T) {
	const (
		startupPort  = 49634
		restartPort  = 50127
		normalReload = 51288
		customReload = 52349
	)

	startupRaw, startupDNS := recoveryDNSFixture()
	apiPort, dnsPort, err := selectEnhancedConfigPorts(startupRaw, startupDNS, nil,
		func(int) bool { return true },
		func(port int) bool { return port == startupPort },
		func() (int, error) { return startupPort, nil })
	if err != nil {
		t.Fatalf("cold-start port selection: %v", err)
	}
	if apiPort != enhancedControllerPort || dnsPort != startupPort {
		t.Fatalf("cold-start ports = (%d, %d), want (%d, %d)", apiPort, dnsPort, enhancedControllerPort, startupPort)
	}
	assertRecoveryDNSFixtureAtPort(t, startupDNS, startupPort)

	// A restart starts from the same profile source but receives a different
	// confirmed endpoint pair from the parent process.
	restartRaw, restartDNS := recoveryDNSFixture()
	plan := &enhancedConfigPortPlan{APIPort: 19091, DNSPort: restartPort}
	apiPort, dnsPort, err = selectEnhancedConfigPorts(restartRaw, restartDNS, plan,
		func(port int) bool { return port == plan.APIPort },
		func(port int) bool { return port == plan.DNSPort },
		func() (int, error) { return 0, os.ErrInvalid })
	if err != nil {
		t.Fatalf("restart port selection: %v", err)
	}
	if apiPort != plan.APIPort || dnsPort != restartPort {
		t.Fatalf("restart ports = (%d, %d), want (%d, %d)", apiPort, dnsPort, plan.APIPort, restartPort)
	}
	assertRecoveryDNSFixtureAtPort(t, restartDNS, restartPort)

	if err := retargetEnhancedDNSListen(restartDNS, normalReload); err != nil {
		t.Fatalf("normal reload retarget: %v", err)
	}
	assertRecoveryDNSFixtureAtPort(t, restartDNS, normalReload)

	// The custom-config file path must apply the same provenance rule while
	// preserving explicit local resolvers and unrelated DNS settings.
	customRaw, _ := recoveryDNSFixture()
	customYAML, err := yaml.Marshal(customRaw)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(t.TempDir(), "custom-enhanced.yaml")
	if err := os.WriteFile(configPath, customYAML, 0600); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(configPath, customReload); err != nil {
		t.Fatalf("custom reload retarget: %v", err)
	}
	customBytes, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	var customResult map[string]interface{}
	if err := yaml.Unmarshal(customBytes, &customResult); err != nil {
		t.Fatal(err)
	}
	customDNS, ok := customResult["dns"].(map[string]interface{})
	if !ok {
		t.Fatalf("custom config dns section = %T, want map", customResult["dns"])
	}
	assertRecoveryDNSFixtureAtPort(t, customDNS, customReload)
}

func TestEnhancedDNSRecoveryRejectsIndependentTargetCycleWithoutMutation(t *testing.T) {
	const targetPort = 53456
	_, dns := recoveryDNSFixture()
	dns["nameserver"] = []interface{}{"127.0.0.1:53456", "https://dns.example/dns-query"}

	err := retargetEnhancedDNSListen(dns, targetPort)
	if err == nil || !strings.HasPrefix(err.Error(), "[dns_self_cycle]") {
		t.Fatalf("retarget error = %v, want a rejected independent resolver cycle", err)
	}
	if got := dns["listen"]; got != "0.0.0.0:7874" {
		t.Fatalf("listener mutated after cycle rejection: %v", got)
	}
	wantBootstrap := []interface{}{"udp://127.0.0.1:7874", "udp://127.0.0.1:5353"}
	if got := dns["proxy-server-nameserver"]; !reflect.DeepEqual(got, wantBootstrap) {
		t.Fatalf("bootstrap references mutated after cycle rejection: %v", got)
	}
}
