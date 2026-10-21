package main

import (
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestCustomIPv6DNSReloadKeepsSamePortBootstrapReachable(t *testing.T) {
	const port = 53127
	contents := []byte("dns:\n  enable: true\n  listen: '[::1]:53127'\n  nameserver: [1.1.1.1]\n  proxy-server-nameserver: ['udp://[::1]:53127']\n")
	updated := customIPv6RetargetFile(t, contents, port)
	dns := updated["dns"].(map[string]interface{})
	if got, want := dns["listen"], "[::1]:53127"; got != want {
		t.Fatalf("DNS listener = %v, want %s", got, want)
	}
	if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://[::1]:53127"; got != want {
		t.Fatalf("bootstrap resolver = %v, want %s", got, want)
	}
}

func TestCustomIPv6DNSReloadRetargetsOwnedReferencesAndPreservesUnrelatedResolvers(t *testing.T) {
	contents := []byte(`dns:
  enable: true
  listen: '[::1]:53127'
  nameserver: [1.1.1.1]
  proxy-server-nameserver:
    - 'UDP://[0:0:0:0:0:0:0:1]:53127'
    - 'udp://127.0.0.1:53127'
    - 'udp://[2001:db8::53]:53127'
    - 'udp://dns.example:53127'
    - 'https://[::1]:53127/dns-query'
    - 'tls://[::1]:53127'
`)
	updated := customIPv6RetargetFile(t, contents, 54001)
	dns := updated["dns"].(map[string]interface{})
	if got, want := dns["listen"], "[::1]:54001"; got != want {
		t.Fatalf("DNS listener = %v, want %s", got, want)
	}
	want := []interface{}{
		"UDP://[0:0:0:0:0:0:0:1]:54001",
		"udp://127.0.0.1:53127",
		"udp://[2001:db8::53]:53127",
		"udp://dns.example:53127",
		"https://[::1]:53127/dns-query",
		"tls://[::1]:53127",
	}
	if got := dns["proxy-server-nameserver"].([]interface{}); !reflect.DeepEqual(got, want) {
		t.Fatalf("proxy resolvers = %v, want %v", got, want)
	}
}

func TestCustomIPv6WildcardRetargetsInternalLoopbackBootstrap(t *testing.T) {
	contents := []byte("dns:\n  enable: true\n  listen: '[::]:53127'\n  proxy-server-nameserver: ['udp://[::1]:53127']\n")
	updated := customIPv6RetargetFile(t, contents, 54001)
	dns := updated["dns"].(map[string]interface{})
	if got, want := dns["listen"], "[::]:54001"; got != want {
		t.Fatalf("DNS listener = %v, want %s", got, want)
	}
	if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://[::1]:54001"; got != want {
		t.Fatalf("wildcard bootstrap = %v, want %s", got, want)
	}
}

func TestCustomIPv6DNSRetargetPreservesZone(t *testing.T) {
	contents := []byte("dns:\n  enable: true\n  listen: '[fe80::1%en0]:53127'\n  proxy-server-nameserver: ['udp://[fe80::1%en0]:53127']\n")
	updated := customIPv6RetargetFile(t, contents, 54001)
	dns := updated["dns"].(map[string]interface{})
	if got, want := dns["listen"], "[fe80::1%en0]:54001"; got != want {
		t.Fatalf("DNS listener = %v, want %s", got, want)
	}
	if got, want := dns["proxy-server-nameserver"].([]interface{})[0], "udp://[fe80::1%en0]:54001"; got != want {
		t.Fatalf("zone bootstrap = %v, want %s", got, want)
	}
}

func TestCustomIPv6ListenParserDoesNotTreatIPv4MappedAddressAsIPv6(t *testing.T) {
	_, handled, err := parseCustomIPv6DNSListen(map[string]interface{}{"listen": "[::ffff:127.0.0.1]:53127"})
	if err != nil {
		t.Fatal(err)
	}
	if handled {
		t.Fatal("IPv4-mapped listener was handled as a native IPv6 listener")
	}
}

func TestCustomIPv6DNSCanSharePortWithIPv4APIListener(t *testing.T) {
	contents := []byte("external-controller: 127.0.0.1:53127\ndns:\n  enable: true\n  listen: '[::1]:53127'\n  proxy-server-nameserver: ['udp://[::1]:53127']\n")
	updated := customIPv6RetargetFile(t, contents, 53127)
	dns := updated["dns"].(map[string]interface{})
	if got, want := dns["listen"], "[::1]:53127"; got != want {
		t.Fatalf("DNS listener = %v, want %s", got, want)
	}
}

func TestCustomIPv6DNSRejectsSameAddressAPICollisionWithoutMutation(t *testing.T) {
	contents := []byte("external-controller: '[::1]:54001'\ndns:\n  enable: true\n  listen: '[::1]:53127'\n  proxy-server-nameserver: ['udp://[::1]:53127']\n")
	customIPv6RetargetFileFailure(t, contents, 54001, "[port_conflict]")
}

func TestCustomIPv6DNSRejectsGeneralSelfCycleWithoutMutation(t *testing.T) {
	contents := []byte("dns:\n  enable: true\n  listen: '[::1]:53127'\n  nameserver: ['tcp://[::1]:54001']\n  proxy-server-nameserver: ['udp://[::1]:53127']\n")
	customIPv6RetargetFileFailure(t, contents, 54001, "[dns_self_cycle]")
}

func TestRewriteCustomIPv6DNSReferenceCopiesSupportedValues(t *testing.T) {
	const expected = "udp://[::1]:53127"
	const replacement = "udp://[::1]:54001"
	tests := []struct {
		name  string
		value interface{}
		index int
		want  interface{}
	}{
		{name: "string", value: expected, index: -1, want: replacement},
		{name: "string slice", value: []string{expected, "udp://[::2]:53127"}, index: 0, want: []string{replacement, "udp://[::2]:53127"}},
		{name: "interface slice", value: []interface{}{expected, 42}, index: 0, want: []interface{}{replacement, 42}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			original := test.value
			got, changed := rewriteCustomIPv6DNSReferenceAtIndex(test.value, test.index, expected, 54001)
			if !changed || !reflect.DeepEqual(got, test.want) {
				t.Fatalf("rewritten value = %v, changed=%t, want %v", got, changed, test.want)
			}
			if test.name != "string" && !reflect.DeepEqual(test.value, original) {
				t.Fatalf("replacement mutated original container: %v", test.value)
			}
		})
	}
}

func customIPv6RetargetFile(t *testing.T, contents []byte, port int) map[string]interface{} {
	t.Helper()
	path := filepath.Join(t.TempDir(), "custom.yaml")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(path, port); err != nil {
		t.Fatalf("retarget custom IPv6 DNS config: %v", err)
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

func customIPv6RetargetFileFailure(t *testing.T, contents []byte, port int, wantError string) {
	t.Helper()
	directory := t.TempDir()
	path := filepath.Join(directory, "custom.yaml")
	if err := os.WriteFile(path, contents, 0640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0640); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(path, port); err == nil || !strings.HasPrefix(err.Error(), wantError) {
		t.Fatalf("retarget error = %v, want prefix %s", err, wantError)
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

func TestCustomIPv6DNSRejectsEncryptedResolverOnOwnedPlainDNSPort(t *testing.T) {
	for _, server := range []string{"tls://[::1]:54321", "https://[::1]:54321/dns-query", "quic://[::1]:54321"} {
		dns := map[string]interface{}{"listen": "[::1]:53127", "nameserver": []interface{}{server}}
		_, err := retargetCustomIPv6DNSConfig(map[string]interface{}{"dns": dns}, dns, 54321)
		if err == nil || !strings.Contains(err.Error(), "dns_self_cycle") {
			t.Fatalf("owned DNS endpoint accepted as encrypted resolver: %s %v", server, err)
		}
		if dns["listen"] != "[::1]:53127" {
			t.Fatal("DNS changed after collision rejection")
		}
	}
}

func TestCustomIPv6WildcardUsesGenericSocketConflictModel(t *testing.T) {
	dns := map[string]interface{}{"listen": "[::]:53127", "nameserver": []interface{}{"1.1.1.1"}}
	raw := map[string]interface{}{"dns": dns, "mixed-port": 54321, "bind-address": "127.0.0.1"}
	_, err := retargetCustomIPv6DNSConfig(raw, dns, 54321)
	if err == nil {
		t.Fatal("generic dual-stack IPv6 DNS UDP listener must conflict with IPv4 mixed UDP")
	}
	if dns["listen"] != "[::]:53127" {
		t.Fatal("DNS changed after listener rejection")
	}
}

func TestCustomIPv6WildcardRetargetsOwnedIPv4BootstrapAliases(t *testing.T) {
	for _, host := range []string{"127.0.0.1", "localhost", "::ffff:127.0.0.1"} {
		source := "udp://" + net.JoinHostPort(host, "53127")
		dns := map[string]interface{}{"listen": "[::]:53127", "proxy-server-nameserver": []interface{}{source}}
		_, err := retargetCustomIPv6DNSConfig(map[string]interface{}{"dns": dns}, dns, 54321)
		if err != nil {
			t.Fatal(err)
		}
		want := "udp://" + net.JoinHostPort(host, "54321")
		if !reflect.DeepEqual(dns["proxy-server-nameserver"], []interface{}{want}) {
			t.Fatalf("wildcard-owned bootstrap not retargeted: %v", dns)
		}
	}
}
func TestCustomIPv6WildcardRejectsGeneralIPv4SelfCycle(t *testing.T) {
	dns := map[string]interface{}{"listen": "[::]:53127", "nameserver": []interface{}{"udp://127.0.0.1:54321"}}
	_, err := retargetCustomIPv6DNSConfig(map[string]interface{}{"dns": dns}, dns, 54321)
	if err == nil || !strings.Contains(err.Error(), "dns_self_cycle") {
		t.Fatalf("dual-stack self-cycle was accepted: %v", err)
	}
	if dns["listen"] != "[::]:53127" {
		t.Fatal("DNS changed after self-cycle rejection")
	}
}

func TestCustomMappedLoopbackReloadKeepsBootstrapOnSameBindDomain(t *testing.T) {
	contents := []byte("dns:\n  enable: true\n  listen: '[::ffff:127.0.0.1]:53127'\n  proxy-server-nameserver: ['udp://[::ffff:127.0.0.1]:53127']\n")
	updated := customIPv6RetargetFile(t, contents, 54321)
	dns := updated["dns"].(map[string]interface{})
	if dns["listen"] != "127.0.0.1:54321" || !reflect.DeepEqual(dns["proxy-server-nameserver"], []interface{}{"udp://127.0.0.1:54321"}) {
		t.Fatalf("IPv4-mapped bootstrap left behind: %v", dns)
	}
}
func TestNativeIPv6LoopbackIsNotAnIPv4BootstrapAlias(t *testing.T) {
	if isLoopbackHost("::1") || !isLoopbackHost("::ffff:127.0.0.1") {
		t.Fatal("native and mapped address ownership conflated")
	}
}

func TestCustomIPv6DNSLeavesSpecialResolverSchemesToCore(t *testing.T) {
	for _, server := range []string{"system://[::1]:54321", "dhcp://[::1]:54321", "rcode://[::1]:54321", "foo://[::1]:54321"} {
		dns := map[string]interface{}{"listen": "[::1]:53127", "nameserver": []interface{}{server}}
		_, err := retargetCustomIPv6DNSConfig(map[string]interface{}{"dns": dns}, dns, 54321)
		if err != nil {
			t.Fatalf("special/unknown resolver misclassified as endpoint: %s: %v", server, err)
		}
		if dns["listen"] != "[::1]:54321" || !reflect.DeepEqual(dns["nameserver"], []interface{}{server}) {
			t.Fatalf("resolver changed: %v", dns)
		}
	}
}
