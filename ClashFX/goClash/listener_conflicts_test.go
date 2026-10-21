package main

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestListenerConflictCounterexamplePayloadsAllowRetargetAndReadOnlyValidation(t *testing.T) {
	tests := []struct {
		name     string
		contents []byte
	}{
		{
			name: "generated API and TLS listeners bind different addresses",
			contents: listenerConflictYAML(t, map[string]interface{}{
				"external-controller":     "127.0.0.1:19090",
				"external-controller-tls": "192.168.1.20:19090",
				"dns": map[string]interface{}{
					"enable": true,
					"listen": "127.0.0.1:19091",
				},
			}),
		},
		{
			name: "custom raw UDP-only TUIC and TCP API share a port",
			contents: []byte(`external-controller: 127.0.0.1:19090
listeners:
  - name: tuic-regression
    type: tuic
    listen: 127.0.0.1
    port: 19090
dns:
  enable: true
  listen: 127.0.0.1:19091
`),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var raw map[string]interface{}
			if err := yaml.Unmarshal(test.contents, &raw); err != nil {
				t.Fatal(err)
			}
			if err := validateEnhancedListenerPortConflicts(raw, 19092); err != nil {
				t.Fatalf("valid listener relationships rejected: %v", err)
			}

			path := listenerConflictWriteTempConfig(t, test.contents)
			before, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := validateEnhancedListenerConfigFile(path); err != nil {
				t.Fatalf("custom startup rejected valid listener relationships: %v", err)
			}
			afterValidation, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(afterValidation, before) {
				t.Fatal("custom startup validator changed source bytes")
			}

			const targetPort = 19092
			if err := retargetEnhancedDNSConfigFile(path, targetPort); err != nil {
				t.Fatalf("valid config retarget rejected: %v", err)
			}
			updated, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var updatedRaw map[string]interface{}
			if err := yaml.Unmarshal(updated, &updatedRaw); err != nil {
				t.Fatal(err)
			}
			dns := updatedRaw["dns"].(map[string]interface{})
			if got, want := dns["listen"], net.JoinHostPort("127.0.0.1", strconv.Itoa(targetPort)); got != want {
				t.Fatalf("retargeted DNS listen = %v, want %s", got, want)
			}
		})
	}
}

func TestEnhancedListenerConflictEntrypointsUseAddressAndProtocol(t *testing.T) {
	tests := []struct {
		name          string
		dnsHost       string
		dnsPort       int
		dnsListenPort int
		listeners     map[string]interface{}
		wantError     bool
	}{
		{
			name:    "DNS and legacy proxy listener share TCP and UDP",
			dnsPort: 19090,
			listeners: map[string]interface{}{
				"bind-address": "127.0.0.1",
				"mixed-port":   19090,
			},
			wantError: true,
		},
		{
			name:      "DNS and controller share loopback TCP",
			dnsPort:   19090,
			listeners: map[string]interface{}{"external-controller": "127.0.0.1:19090"},
			wantError: true,
		},
		{
			name:      "DNS and TLS controller share loopback TCP",
			dnsPort:   19090,
			listeners: map[string]interface{}{"external-controller-tls": "127.0.0.1:19090"},
			wantError: true,
		},
		{
			name:    "API and TLS API share the same TCP binding",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller":     "127.0.0.1:19090",
				"external-controller-tls": "127.0.0.1:19090",
			},
			wantError: true,
		},
		{
			name:    "API and proxy share the same TCP binding",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"bind-address":        "127.0.0.1",
				"mixed-port":          19090,
				"external-controller": "127.0.0.1:19090",
			},
			wantError: true,
		},
		{
			name:      "wildcard API binding covers loopback DNS",
			dnsPort:   19090,
			listeners: map[string]interface{}{"external-controller": "0.0.0.0:19090"},
			wantError: true,
		},
		{
			name:    "different concrete IPv4 addresses may share a port",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller":     "127.0.0.1:19090",
				"external-controller-tls": "192.168.1.20:19090",
			},
		},
		{
			name:    "IPv4 and IPv6 loopback bindings are distinct",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller":     "127.0.0.1:19090",
				"external-controller-tls": "[::1]:19090",
			},
		},
		{
			name:    "IPv4-mapped IPv6 normalizes to IPv4",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller":     "127.0.0.1:19090",
				"external-controller-tls": "[::ffff:127.0.0.1]:19090",
			},
			wantError: true,
		},
		{
			name:    "localhost aliases loopback",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller":     "localhost:19090",
				"external-controller-tls": "127.0.0.1:19090",
			},
			wantError: true,
		},
		{
			name:          "actual custom DNS address can differ from loopback controller",
			dnsHost:       "192.168.1.20",
			dnsPort:       19091,
			dnsListenPort: 19090,
			listeners:     map[string]interface{}{"external-controller": "127.0.0.1:19090"},
		},
		{
			name:    "UDP-only TUIC and TCP API may share a port",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller": "127.0.0.1:19090",
				"listeners": []interface{}{map[string]interface{}{
					"type": "tuic", "listen": "127.0.0.1", "port": "19090",
				}},
			},
		},
		{
			name:    "UDP-only Hysteria2 and TCP API may share a port",
			dnsPort: 19091,
			listeners: map[string]interface{}{
				"external-controller": "127.0.0.1:19090",
				"listeners": []interface{}{map[string]interface{}{
					"type": "hysteria2", "listen": "127.0.0.1", "port": "19090",
				}},
			},
		},
		{
			name:    "UDP-only TUIC conflicts with DNS UDP on the same address",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tuic", "listen": "127.0.0.1", "port": "19090",
			}}},
			wantError: true,
		},
		{
			name:    "UDP-only Hysteria2 conflicts with DNS UDP on the same address",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "hysteria2", "listen": "127.0.0.1", "port": "19090",
			}}},
			wantError: true,
		},
		{
			name:    "SOCKS udp false still has a TCP listener",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "socks", "listen": "127.0.0.1", "port": "19090", "udp": false,
			}}},
			wantError: true,
		},
		{
			name:    "mixed udp false still has a TCP listener",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "mixed", "listen": "127.0.0.1", "port": "19090", "udp": false,
			}}},
			wantError: true,
		},
		{
			name:    "TCP tunnel listener conflicts with DNS TCP",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tunnel", "listen": "127.0.0.1", "port": "19090",
				"network": []interface{}{"tcp"}, "target": "192.0.2.1:80",
			}}},
			wantError: true,
		},
		{
			name:    "UDP tunnel listener conflicts with DNS UDP",
			dnsPort: 19090,
			listeners: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tunnel", "listen": "127.0.0.1", "port": "19090",
				"network": []interface{}{"udp"}, "target": "192.0.2.1:53",
			}}},
			wantError: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dnsHost := test.dnsHost
			if dnsHost == "" {
				dnsHost = "127.0.0.1"
			}
			dnsListenPort := test.dnsListenPort
			if dnsListenPort == 0 {
				dnsListenPort = test.dnsPort
			}
			raw := listenerConflictRoot(dnsHost, dnsListenPort, test.listeners)
			err := validateEnhancedListenerPortConflicts(raw, test.dnsPort)
			if test.wantError && err == nil {
				t.Fatal("conflicting listeners were accepted by map validator")
			}
			if !test.wantError && err != nil {
				t.Fatalf("valid listener relationships rejected by map validator: %v", err)
			}

			contents := listenerConflictYAML(t, raw)
			path := listenerConflictWriteTempConfig(t, contents)
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			fileErr := validateEnhancedListenerConfigFile(path)
			if test.wantError && fileErr == nil {
				t.Fatal("conflicting listeners were accepted by custom startup validator")
			}
			if !test.wantError && fileErr != nil {
				t.Fatalf("valid listener relationships rejected by custom startup validator: %v", fileErr)
			}
			unchanged, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(unchanged, original) {
				t.Fatal("custom startup validator changed source bytes")
			}

			retargetErr := retargetEnhancedDNSConfigFile(path, test.dnsPort)
			if test.wantError && retargetErr == nil {
				t.Fatal("conflicting listeners were accepted by file retarget")
			}
			if !test.wantError && retargetErr != nil {
				t.Fatalf("valid listener relationships rejected by file retarget: %v", retargetErr)
			}
			if test.wantError {
				afterReject, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(afterReject, original) {
					t.Fatal("rejected retarget changed source bytes")
				}
			}
		})
	}
}

func TestEnhancedDNSStartupSelectorReservesOnlyActualLoopbackConflicts(t *testing.T) {
	tests := []struct {
		name            string
		root            map[string]interface{}
		wantReserved    []int
		wantListenPort  int
		wantFreePortUse bool
	}{
		{
			name:            "loopback API reservation selects fallback",
			root:            map[string]interface{}{"external-controller": "127.0.0.1:7874"},
			wantReserved:    []int{7874},
			wantListenPort:  19091,
			wantFreePortUse: true,
		},
		{
			name:           "different concrete API address permits preferred number",
			root:           map[string]interface{}{"external-controller-tls": "192.168.1.20:7874"},
			wantReserved:   []int{},
			wantListenPort: 7874,
		},
		{
			name: "UDP-only inbound reserves a DNS UDP conflict",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tuic", "listen": "127.0.0.1", "port": "7874",
			}}},
			wantReserved:    []int{7874},
			wantListenPort:  19091,
			wantFreePortUse: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dns := map[string]interface{}{"enable": true, "listen": "0.0.0.0:7874"}
			test.root["dns"] = dns
			reserved := enhancedDNSReservedPorts(test.root)
			if !reflect.DeepEqual(sortedListenerPorts(reserved), sortedListenerPorts(test.wantReserved)) {
				t.Fatalf("reserved DNS ports = %v, want %v", reserved, test.wantReserved)
			}
			freePortUsed := false
			if err := alignEnhancedDNSListenWithReserved(dns, reserved, func(int) bool {
				return true
			}, func() (int, error) {
				freePortUsed = true
				return 19091, nil
			}); err != nil {
				t.Fatal(err)
			}
			if got := dns["listen"]; got != net.JoinHostPort("127.0.0.1", strconv.Itoa(test.wantListenPort)) {
				t.Fatalf("selected DNS listener = %v, want port %d", got, test.wantListenPort)
			}
			if freePortUsed != test.wantFreePortUse {
				t.Fatalf("free-port selector used = %t, want %t", freePortUsed, test.wantFreePortUse)
			}
		})
	}
}

func TestEnhancedControllerReservedPortsUseTCPBindingsAndRequestedHost(t *testing.T) {
	tests := []struct {
		name string
		host string
		root map[string]interface{}
		want []int
	}{
		{
			name: "legacy external controller is excluded",
			host: "127.0.0.1",
			root: map[string]interface{}{"external-controller": "127.0.0.1:19090"},
		},
		{
			name: "TLS controller TCP port is reserved",
			host: "127.0.0.1",
			root: map[string]interface{}{"external-controller-tls": "127.0.0.1:19090"},
			want: []int{19090},
		},
		{
			name: "mixed listener reserves TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "mixed", "listen": "127.0.0.1", "port": "19090",
			}}},
			want: []int{19090},
		},
		{
			name: "SOCKS udp false still reserves TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "socks", "listen": "127.0.0.1", "port": "19090", "udp": false,
			}}},
			want: []int{19090},
		},
		{
			name: "UDP-only TUIC does not reserve TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tuic", "listen": "127.0.0.1", "port": "19090",
			}}},
		},
		{
			name: "UDP-only Hysteria2 does not reserve TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "hysteria2", "listen": "127.0.0.1", "port": "19090",
			}}},
		},
		{
			name: "UDP tunnel does not reserve TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tunnel", "listen": "127.0.0.1", "port": "19090",
				"network": []interface{}{"udp"}, "target": "192.0.2.1:53",
			}}},
		},
		{
			name: "TCP tunnel reserves TCP port",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "tunnel", "listen": "127.0.0.1", "port": "19090",
				"network": []interface{}{"tcp"}, "target": "192.0.2.1:80",
			}}},
			want: []int{19090},
		},
		{
			name: "different listener address does not reserve requested host",
			host: "127.0.0.1",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "mixed", "listen": "192.168.1.20", "port": "19090",
			}}},
		},
		{
			name: "same listener address reserves requested host",
			host: "192.168.1.20",
			root: map[string]interface{}{"listeners": []interface{}{map[string]interface{}{
				"type": "mixed", "listen": "192.168.1.20", "port": "19090",
			}}},
			want: []int{19090},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := enhancedControllerReservedPorts(test.root, test.host)
			if !reflect.DeepEqual(sortedListenerPorts(got), sortedListenerPorts(test.want)) {
				t.Fatalf("reserved controller ports = %v, want %v", got, test.want)
			}
		})
	}
}

func TestListenerPortRangesAndZeroPortUseMihomoListenerSemantics(t *testing.T) {
	raw := listenerConflictRoot("127.0.0.1", 19090, map[string]interface{}{
		"listeners": []interface{}{
			map[string]interface{}{
				"name": "range", "type": "mixed", "listen": "127.0.0.1", "port": "19088,19090-19091,19094-19095", "udp": false,
			},
			map[string]interface{}{"name": "ephemeral", "type": "mixed", "listen": "127.0.0.1", "port": "0"},
		},
	})

	for _, port := range []int{19088, 19090, 19091, 19094, 19095} {
		if !containsInt(enhancedDNSReservedPorts(raw), port) {
			t.Errorf("DNS reserved ports omit listener port %d from comma/range value", port)
		}
		if !containsInt(enhancedControllerReservedPorts(raw, "127.0.0.1"), port) {
			t.Errorf("controller reserved ports omit listener port %d from comma/range value", port)
		}
	}
	if containsInt(enhancedDNSReservedPorts(raw), 0) {
		t.Fatal("ephemeral port 0 was reserved for DNS")
	}
	if containsInt(enhancedControllerReservedPorts(raw, "127.0.0.1"), 0) {
		t.Fatal("ephemeral port 0 was reserved for controller")
	}
	if err := validateEnhancedListenerPortConflicts(raw, 19090); err == nil {
		t.Fatal("DNS collision inside comma/range listener value was accepted")
	}
}

func listenerConflictRoot(dnsHost string, dnsPort int, other map[string]interface{}) map[string]interface{} {
	root := make(map[string]interface{}, len(other)+1)
	for key, value := range other {
		root[key] = value
	}
	root["dns"] = map[string]interface{}{
		"enable": true,
		"listen": net.JoinHostPort(dnsHost, strconv.Itoa(dnsPort)),
	}
	return root
}

func listenerConflictYAML(t *testing.T, raw map[string]interface{}) []byte {
	t.Helper()
	contents, err := yaml.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	return contents
}

func listenerConflictWriteTempConfig(t *testing.T, contents []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "enhanced.yaml")
	if err := os.WriteFile(path, contents, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func sortedListenerPorts(ports []int) []int {
	sorted := append([]int(nil), ports...)
	sort.Ints(sorted)
	return sorted
}

func TestListenerExplicitIPv4WildcardAllowsSeparateIPv6Service(t *testing.T) {
	raw := map[string]interface{}{
		"allow-lan": true, "bind-address": "0.0.0.0", "port": 7890,
		"external-controller":     "127.0.0.1:9090",
		"external-controller-tls": "[::1]:7890",
		"dns":                     map[string]interface{}{"enable": true, "listen": "127.0.0.1:19091"},
	}
	if err := validateEnhancedListenerPortConflicts(raw, 19091); err != nil {
		t.Fatalf("IPv4 wildcard and IPv6 service rejected: %v", err)
	}
	// Remove the TLS API itself to check the proxy-only reservation projection.
	delete(raw, "external-controller-tls")
	if containsInt(enhancedControllerReservedPorts(raw, "::1"), 7890) {
		t.Fatal("IPv4 wildcard incorrectly reserves IPv6 controller port")
	}
	raw["external-controller-tls"] = "[::1]:7890"
	contents := listenerConflictYAML(t, raw)
	path := listenerConflictWriteTempConfig(t, contents)
	if err := validateEnhancedListenerConfigFile(path); err != nil {
		t.Fatal(err)
	}
	if err := retargetEnhancedDNSConfigFile(path, 19092); err != nil {
		t.Fatal(err)
	}
	raw["bind-address"] = "*"
	if err := validateEnhancedListenerPortConflicts(raw, 19091); err == nil {
		t.Fatal("generic wildcard must retain its IPv6 coverage")
	}
	raw["bind-address"] = "0.0.0.0"
	raw["external-controller-tls"] = "127.0.0.1:7890"
	if err := validateEnhancedListenerPortConflicts(raw, 19091); err == nil {
		t.Fatal("IPv4 wildcard must still cover IPv4 loopback")
	}
}

func TestListenerIPv4WildcardUDPStillConflictsWithIPv6DNS(t *testing.T) {
	raw := listenerConflictRoot("::1", 7890, map[string]interface{}{
		"allow-lan": true, "bind-address": "0.0.0.0", "mixed-port": 7890,
		"external-controller": "127.0.0.1:9090",
	})
	path := listenerConflictWriteTempConfig(t, listenerConflictYAML(t, raw))
	if err := validateEnhancedListenerConfigFile(path); err == nil {
		t.Fatal("generic UDP wildcard must retain IPv6 DNS conflict protection")
	}
	delete(raw, "mixed-port")
	raw["port"] = 7890 // TCP-only IPv4 wildcard can coexist with IPv6 DNS.
	path = listenerConflictWriteTempConfig(t, listenerConflictYAML(t, raw))
	if err := validateEnhancedListenerConfigFile(path); err != nil {
		t.Fatalf("TCP-only IPv4 service rejected: %v", err)
	}
}

func TestProxyListenerPairsShareTheSameConflictGate(t *testing.T) {
	tests := []struct {
		name     string
		raw      map[string]interface{}
		conflict bool
	}{
		{"http and mixed overlap", map[string]interface{}{"port": 32123, "mixed-port": 32123}, true},
		{"custom range overlaps mixed", map[string]interface{}{"mixed-port": 32123, "listeners": []interface{}{map[string]interface{}{"type": "http", "listen": "127.0.0.1", "port": "32120-32125"}}}, true},
		{"two custom TCP listeners overlap", map[string]interface{}{"listeners": []interface{}{map[string]interface{}{"name": "first", "type": "http", "listen": "127.0.0.1", "port": 32123}, map[string]interface{}{"name": "second", "type": "http", "listen": "127.0.0.1", "port": 32123}}}, true},
		{"same port different transports", map[string]interface{}{"port": 32123, "listeners": []interface{}{map[string]interface{}{"type": "tuic", "listen": "127.0.0.1", "port": 32123}}}, false},
		{"same TCP port different addresses", map[string]interface{}{"listeners": []interface{}{map[string]interface{}{"name": "first", "type": "http", "listen": "127.0.0.1", "port": 32123}, map[string]interface{}{"name": "second", "type": "http", "listen": "127.0.0.2", "port": 32123}}}, false},
	}
	// Raw duplicate names are overwritten before the core creates listeners.
	for _, name := range []string{"", "same-name"} {
		tests = append(tests, struct {
			name     string
			raw      map[string]interface{}
			conflict bool
		}{
			"shadowed custom listener " + name,
			map[string]interface{}{"mixed-port": 32123, "listeners": []interface{}{
				map[string]interface{}{"name": name, "type": "http", "listen": "127.0.0.1", "port": 32123},
				map[string]interface{}{"name": name, "type": "http", "listen": "127.0.0.1", "port": 32124},
			}}, false,
		})
	}

	tests = append(tests, struct {
		name     string
		raw      map[string]interface{}
		conflict bool
	}{
		"numeric and empty names are distinct", map[string]interface{}{"mixed-port": 32123, "listeners": []interface{}{
			map[string]interface{}{"name": 123, "type": "http", "listen": "127.0.0.1", "port": 32123},
			map[string]interface{}{"type": "http", "listen": "127.0.0.1", "port": 32124},
		}}, true,
	})
	tests = append(tests, struct {
		name     string
		raw      map[string]interface{}
		conflict bool
	}{
		"numeric name shadowed by equivalent string", map[string]interface{}{"mixed-port": 32123, "listeners": []interface{}{
			map[string]interface{}{"name": 123, "type": "http", "listen": "127.0.0.1", "port": 32123},
			map[string]interface{}{"name": "123", "type": "http", "listen": "127.0.0.1", "port": 32124},
		}}, false,
	})

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			test.raw["external-controller"] = "127.0.0.1:32130"
			test.raw["dns"] = map[string]interface{}{"enable": true, "listen": "127.0.0.1:32131"}
			path := listenerConflictWriteTempConfig(t, listenerConflictYAML(t, test.raw))
			for name, validate := range map[string]func(string) error{"startup": validateEnhancedListenerConfigFile, "reload": validateRuntimeListenerConfigFile} {
				if err := validate(path); (err != nil) != test.conflict {
					t.Errorf("%s conflict=%v got %v", name, test.conflict, err)
				}
			}
		})
	}
}

func TestURLBasedGlobalListenersUseSharedEndpointChecks(t *testing.T) {
	for _, test := range []struct {
		name, key, value string
		conflict         bool
	}{
		{"SS collides with API", "ss-config", "ss://aes-128-gcm:test@127.0.0.1:32130", true},
		{"SS multiple address includes DNS", "ss-config", "ss://aes-128-gcm:test@127.0.0.1:32132,127.0.0.1:32131", true},
		{"VMess collides with DNS TCP", "vmess-config", "vmess://fixture:11111111-1111-4111-8111-111111111111@127.0.0.1:32131", true},
		{"VMess free", "vmess-config", "vmess://fixture:11111111-1111-4111-8111-111111111111@127.0.0.1:32132", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw := map[string]interface{}{"external-controller": "127.0.0.1:32130", "dns": map[string]interface{}{"enable": true, "listen": "127.0.0.1:32131"}, test.key: test.value}
			path := listenerConflictWriteTempConfig(t, listenerConflictYAML(t, raw))
			for name, validate := range map[string]func(string) error{"startup": validateEnhancedListenerConfigFile, "reload": validateRuntimeListenerConfigFile} {
				if err := validate(path); (err != nil) != test.conflict {
					t.Errorf("%s got %v, conflictwant %v", name, err, test.conflict)
				}
			}
		})
	}
}

func TestGenericGlobalTCPCanCoexistWithEarlierNamedIPv6Bind(t *testing.T) {
	named, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skipf("IPv6 loopback unavailable: %v", err)
	}
	defer named.Close()
	port := named.Addr().(*net.TCPAddr).Port
	// This raw socket has no protocol handler and never forwards traffic.
	generic, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		t.Fatalf("pinned Go generic TCP fallback unavailable: %v", err)
	}
	defer generic.Close()
	raw := map[string]interface{}{"port": port, "allow-lan": true, "bind-address": "*", "listeners": []interface{}{map[string]interface{}{"name": "ipv6-first", "type": "http", "listen": "::1", "port": port}}, "external-controller": "127.0.0.1:32130", "dns": map[string]interface{}{"enable": true, "listen": "127.0.0.1:32131"}}
	path := listenerConflictWriteTempConfig(t, listenerConflictYAML(t, raw))
	if err := validateEnhancedListenerConfigFile(path); err != nil {
		t.Fatalf("startup rejected supported IPv4 fallback: %v", err)
	}
	if err := validateRuntimeListenerConfigFile(path); err != nil {
		t.Fatalf("reload rejected supported IPv4 fallback: %v", err)
	}
}
