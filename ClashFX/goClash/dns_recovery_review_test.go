package main

import (
	"net"
	"reflect"
	"strings"
	"testing"
)

func TestPreferredDNSPlanRejectsSourceSelfCyclesLikeColdStartup(t *testing.T) {
	for _, listen := range []string{"127.0.0.1:7874", "0.0.0.0:7874", ":7874", "localhost:7874"} {
		for _, key := range []string{"nameserver", "default-nameserver", "fallback", "direct-nameserver", "nameserver-policy", "proxy-server-nameserver-policy"} {
			for _, preferred := range []bool{false, true} {
				t.Run(listen+"/"+key+"/preferred="+map[bool]string{false: "false", true: "true"}[preferred], func(t *testing.T) {
					var resolver interface{} = []interface{}{"udp://127.0.0.1:7874"}
					if strings.HasSuffix(key, "policy") {
						resolver = map[string]interface{}{"*.example": "tcp://localhost:7874"}
					}
					dns := map[string]interface{}{"listen": listen, key: resolver}
					beforeListen := dns["listen"]
					raw := map[string]interface{}{"dns": dns}
					var plan *enhancedConfigPortPlan
					if preferred {
						plan = &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}
					}
					_, _, err := selectEnhancedConfigPorts(raw, dns, plan, func(int) bool { return true }, func(int) bool { return true }, func() (int, error) { t.Fatal("source cycle must reject before random fallback"); return 0, nil })
					if err == nil || !strings.Contains(err.Error(), "dns_self_cycle") {
						t.Fatalf("accepted invalid source cycle: dns=%v err=%v", dns, err)
					}
					if dns["listen"] != beforeListen || !reflect.DeepEqual(dns[key], resolver) {
						t.Fatalf("DNS changed after rejection: %v", dns)
					}
				})
			}
		}
	}
}

func TestPreferredDNSPlanPreservesOccupiedSourceResolver(t *testing.T) {
	for _, preferred := range []bool{false, true} {
		dns := map[string]interface{}{"listen": "0.0.0.0:7874", "nameserver": []interface{}{"udp://127.0.0.1:7874"}}
		var plan *enhancedConfigPortPlan
		if preferred {
			plan = &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}
		}
		_, port, err := selectEnhancedConfigPorts(map[string]interface{}{"dns": dns}, dns, plan, func(int) bool { return true }, func(p int) bool { return p != 7874 }, func() (int, error) { return 50777, nil })
		if err != nil || port == 7874 {
			t.Fatalf("independent occupied local resolver rejected: port=%v err=%v", port, err)
		}
		if !reflect.DeepEqual(dns["nameserver"], []interface{}{"udp://127.0.0.1:7874"}) {
			t.Fatalf("independent resolver rewritten: %v", dns)
		}
	}
}

func TestPreferredDNSPlanKeepsDeclaredProxyBootstrap(t *testing.T) {
	dns := map[string]interface{}{"listen": ":7874", "nameserver": []interface{}{"https://dns.example/dns-query"}, "proxy-server-nameserver": []interface{}{"udp://127.0.0.1:7874"}}
	_, port, err := selectEnhancedConfigPorts(map[string]interface{}{"dns": dns}, dns, &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}, func(int) bool { return true }, func(int) bool { return true }, func() (int, error) { t.Fatal("confirmed preference should be usable"); return 0, nil })
	if err != nil || port != 49634 {
		t.Fatalf("valid proxy bootstrap rejected: %v %v", port, err)
	}
	if !reflect.DeepEqual(dns["proxy-server-nameserver"], []interface{}{"udp://127.0.0.1:49634"}) {
		t.Fatalf("bootstrap not retargeted: %v", dns)
	}
}

func TestStartupSourceCycleCheckPreservesDistinctTransportResolver(t *testing.T) {
	for _, preferred := range []bool{false, true} {
		dns := map[string]interface{}{"listen": "0.0.0.0:19090", "nameserver": []interface{}{"udp://127.0.0.1:19090"}}
		raw := map[string]interface{}{"dns": dns}
		var plan *enhancedConfigPortPlan
		if preferred {
			plan = &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}
		}
		api, port, err := selectEnhancedConfigPorts(raw, dns, plan, func(int) bool { return true }, func(p int) bool { return p != 19090 }, func() (int, error) { return 50777, nil })
		if err != nil || api != 19090 || port == 19090 {
			t.Fatalf("TCP controller must coexist with independent UDP resolver: api=%d dns=%d err=%v", api, port, err)
		}
		if !reflect.DeepEqual(dns["nameserver"], []interface{}{"udp://127.0.0.1:19090"}) {
			t.Fatalf("UDP resolver rewritten: %v", dns)
		}
	}
}

func TestStartupSourceCycleCheckRejectsActualProxyTransportConflict(t *testing.T) {
	for _, preferred := range []bool{false, true} {
		dns := map[string]interface{}{"listen": "0.0.0.0:7890", "nameserver": []interface{}{"udp://127.0.0.1:7890"}}
		raw := map[string]interface{}{"dns": dns, "mixed-port": 7890}
		var plan *enhancedConfigPortPlan
		if preferred {
			plan = &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}
		}
		_, _, err := selectEnhancedConfigPorts(raw, dns, plan, func(int) bool { return true }, func(p int) bool { return p != 7890 }, func() (int, error) { return 50777, nil })
		if err == nil || !strings.Contains(err.Error(), "dns_self_cycle") {
			t.Fatalf("proxy endpoint is not an independent DNS resolver: %v", err)
		}
	}
}

func TestStartupSourceCyclePreservesIndependentIPv6Resolver(t *testing.T) {
	tcp, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skipf("IPv6 loopback unavailable: %v", err)
	}
	defer tcp.Close()
	address := tcp.Addr().String()
	udp, err := net.ListenPacket("udp6", address)
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	port := tcp.Addr().(*net.TCPAddr).Port
	dns := map[string]interface{}{"listen": address, "nameserver": []interface{}{"udp://" + address}}
	_, selected, err := selectEnhancedConfigPorts(map[string]interface{}{"dns": dns}, dns, &enhancedConfigPortPlan{APIPort: 19090, DNSPort: port}, func(int) bool { return true }, func(p int) bool {
		if p != port {
			t.Fatalf("unexpected alternate DNS probe %d", p)
		}
		return checkDNSPortAvailable(p)
	}, func() (int, error) { t.Fatal("independent IPv6 resolver must not force fallback"); return 0, nil })
	if err != nil || selected != port {
		t.Fatalf("IPv6 resolver must coexist with generated IPv4 DNS: %v %v", selected, err)
	}
	if !reflect.DeepEqual(dns["nameserver"], []interface{}{"udp://" + address}) {
		t.Fatalf("IPv6 resolver changed: %v", dns)
	}
}

func TestStartupSourceCyclePreservesNonIPv4ListenerReferences(t *testing.T) {
	for _, listen := range []string{"[::1]:7874", "[::]:7874", "192.0.2.10:7874"} {
		for _, preferred := range []bool{false, true} {
			resolver := "udp://" + listen
			dns := map[string]interface{}{"listen": listen, "nameserver": []interface{}{resolver}}
			var plan *enhancedConfigPortPlan
			if preferred {
				plan = &enhancedConfigPortPlan{APIPort: 19090, DNSPort: 49634}
			}
			_, _, err := selectEnhancedConfigPorts(map[string]interface{}{"dns": dns}, dns, plan, func(int) bool { return true }, func(int) bool { return true }, func() (int, error) { return 50777, nil })
			if err != nil {
				t.Fatalf("source outside generated IPv4 ownership was rejected: %s %v", listen, err)
			}
			if !reflect.DeepEqual(dns["nameserver"], []interface{}{resolver}) {
				t.Fatalf("independent resolver was rewritten: %v", dns)
			}
		}
	}
}
