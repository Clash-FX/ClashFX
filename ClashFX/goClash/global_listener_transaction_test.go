package main

import (
	"bytes"
	"fmt"
	"net"
	"testing"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"gopkg.in/yaml.v3"
)

func TestGlobalUDPBindFailureDoesNotPublishClosedTCPAndCanRollback(t *testing.T) {
	for _, key := range []string{"mixed-port", "socks-port"} {
		t.Run(key, func(t *testing.T) {
			blocked, err := net.ListenPacket("udp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer blocked.Close()
			occupied := blocked.LocalAddr().(*net.UDPAddr).Port
			available, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", occupied))
			if err != nil {
				t.Fatal(err)
			}
			_ = available.Close()
			oldTCP, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			oldPort := oldTCP.Addr().(*net.TCPAddr).Port
			_ = oldTCP.Close()
			oldUDP, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", oldPort))
			if err != nil {
				t.Fatal(err)
			}
			_ = oldUDP.Close()
			makeConfig := func(port int) []byte {
				return []byte(fmt.Sprintf("%s: %d\nallow-lan: false\ndns: {enable: false}\ntun: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n", key, port))
			}
			var snapshot submittedConfigSnapshot
			apply := func(raw []byte) error {
				cfg, err := executor.ParseWithBytes(raw)
				if err != nil {
					return err
				}
				return applyAndRecordSubmittedConfig(&snapshot, raw, func() error {
					executor.ApplyConfig(cfg, true)
					return executor.ValidateRuntimeListeners(cfg, true)
				})
			}
			t.Cleanup(func() { _ = apply([]byte("dns: {enable: false}\ntun: {enable: false}\n")) })
			original := makeConfig(oldPort)
			if err := apply(original); err != nil {
				t.Fatal(err)
			}
			if err := apply(makeConfig(occupied)); err == nil {
				t.Fatal("UDP-only conflict was reported as ready")
			}
			if !bytes.Equal(snapshot.bytes(), original) {
				t.Fatal("UDP-only conflict changed submitted receipt")
			}
			general := executor.GetGeneral()
			if key == "mixed-port" && general.MixedPort != 0 || key == "socks-port" && general.SocksPort != 0 {
				t.Fatal("closed TCP listener retained a reported live port")
			}
			if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", occupied)); err == nil {
				_ = conn.Close()
				t.Fatal("partial TCP listener survived failed UDP bind")
			}
			if err := apply(original); err != nil {
				t.Fatalf("rollback: %v", err)
			}
			assertCustomInboundAcceptsTCP(t, oldPort)
			if !bytes.Equal(snapshot.bytes(), original) {
				t.Fatal("rollback receipt differs")
			}
		})
	}
}

func TestURLGlobalsValidateAndReleaseDuringEmbeddedHandoff(t *testing.T) {
	for _, key := range []string{"ss-config", "vmess-config"} {
		t.Run(key, func(t *testing.T) {
			blocker, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer blocker.Close()
			occupied := blocker.Addr().(*net.TCPAddr).Port
			freeTCP, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			oldPort := freeTCP.Addr().(*net.TCPAddr).Port
			_ = freeTCP.Close()
			customTCP, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			customPort := customTCP.Addr().(*net.TCPAddr).Port
			_ = customTCP.Close()
			raw := func(port int) []byte {
				uri := fmt.Sprintf("ss://aes-128-gcm:fixture-pass@127.0.0.1:%d", port)
				if key == "vmess-config" {
					uri = fmt.Sprintf("vmess://fixture:11111111-1111-4111-8111-111111111111@127.0.0.1:%d", port)
				}
				return []byte(fmt.Sprintf("%s: %q\ndns: {enable: false}\ntun: {enable: false}\nlisteners:\n  - {name: handoff-custom, type: http, listen: 127.0.0.1, port: %d}\n", key, uri, customPort))
			}
			apply := func(data []byte) error {
				cfg, err := executor.ParseWithBytes(data)
				if err != nil {
					return err
				}
				executor.ApplyConfig(cfg, true)
				return executor.ValidateRuntimeListeners(cfg, true)
			}
			t.Cleanup(stopBuiltinListenersForSuspend)
			if err := apply(raw(oldPort)); err != nil {
				t.Fatalf("valid URL global: %v", err)
			}
			assertCustomInboundAcceptsTCP(t, oldPort)
			assertCustomInboundAcceptsTCP(t, customPort)
			if err := apply(raw(occupied)); err == nil {
				t.Fatal("failed URL global bind was confirmed")
			}
			if err := apply(raw(oldPort)); err != nil {
				t.Fatalf("URL global rollback: %v", err)
			}
			stopBuiltinListenersForSuspend()
			for _, port := range []int{oldPort, customPort} {
				socket, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
				if err != nil {
					t.Fatalf("handoff kept port %d: %v", port, err)
				}
				_ = socket.Close()
			}
			if key == "ss-config" {
				socket, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", oldPort))
				if err != nil {
					t.Fatalf("handoff kept SS UDP: %v", err)
				}
				_ = socket.Close()
			}
			if err := apply(raw(oldPort)); err != nil {
				t.Fatalf("resume previous listeners: %v", err)
			}
			assertCustomInboundAcceptsTCP(t, oldPort)
			assertCustomInboundAcceptsTCP(t, customPort)
		})
	}
}

func TestEnabledGlobalTuicCannotConfirmFailedConstruction(t *testing.T) {
	cfg, err := executor.ParseWithBytes([]byte("dns: {enable: false}\ntun: {enable: false}\ntuic-server: {enable: true, listen: '127.0.0.1:0', certificate: 'invalid-pem', private-key: 'invalid-pem'}\n"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(stopBuiltinListenersForSuspend)
	executor.ApplyConfig(cfg, true)
	if err := executor.ValidateRuntimeListeners(cfg, true); err == nil {
		t.Fatal("TUIC constructor failure reported ready")
	}
}

func TestMixedStartupChecksUDPWithoutRejectingTCPOnlyController(t *testing.T) {
	blocked, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocked.Close()
	port := blocked.LocalAddr().(*net.UDPAddr).Port
	if !checkLoopbackTCPPortAvailable(port) {
		t.Fatal("UDP-only holder was treated as TCP-controller conflict")
	}
	if _, err := resolveConfiguredMixedPort(port, checkMixedPortAvailable); err == nil {
		t.Fatal("startup accepted UDP-only conflict for mixed listener")
	}
}

func TestHealthyGlobalTuicDefaultsPassReadinessAndHandoff(t *testing.T) {
	certificate, key, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
	if err != nil {
		t.Fatal(err)
	}
	probe, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := probe.LocalAddr().(*net.UDPAddr).Port
	_ = probe.Close()
	raw, err := yaml.Marshal(map[string]interface{}{"dns": map[string]interface{}{"enable": false}, "tun": map[string]interface{}{"enable": false}, "tuic-server": map[string]interface{}{"enable": true, "listen": fmt.Sprintf("127.0.0.1:%d", port), "token": []string{"fixture"}, "certificate": certificate, "private-key": key}})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := executor.ParseWithBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(stopBuiltinListenersForSuspend)
	for round := 0; round < 2; round++ {
		executor.ApplyConfig(cfg, true)
		if err := executor.ValidateRuntimeListeners(cfg, true); err != nil {
			t.Fatalf("healthy TUIC defaults rejected round %d: %v", round, err)
		}
		actual := listener.GetTuicConf()
		if !actual.Enable || actual.CWND != 32 || actual.MaxIdleTime != 15000 || actual.AuthenticationTimeout != 1000 {
			t.Fatal("constructor defaults not reflected")
		}
	}
	stopBuiltinListenersForSuspend()
	released, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatalf("TUIC UDP survived handoff: %v", err)
	}
	_ = released.Close()
}

func TestMixedStartupProbeRespectsActualBindScope(t *testing.T) {
	var blocked net.PacketConn
	var port int
	for attempt := 0; attempt < 32; attempt++ {
		candidate, err := net.ListenPacket("udp6", "[::1]:0")
		if err != nil {
			t.Skipf("IPv6 loopback unavailable: %v", err)
		}
		port = candidate.LocalAddr().(*net.UDPAddr).Port
		address := fmt.Sprintf("127.0.0.1:%d", port)
		tcp, tcpErr := net.Listen("tcp", address)
		udp, udpErr := net.ListenPacket("udp", address)
		if tcp != nil {
			tcp.Close()
		}
		if udp != nil {
			udp.Close()
		}
		ipv6TCP, ipv6Err := net.Listen("tcp", fmt.Sprintf("[::1]:%d", port))
		if ipv6TCP != nil {
			ipv6TCP.Close()
		}
		wildcardTCP, wildcardErr := net.Listen("tcp", fmt.Sprintf(":%d", port))
		if wildcardTCP != nil {
			wildcardTCP.Close()
		}
		if tcpErr == nil && udpErr == nil && ipv6Err == nil && wildcardErr == nil {
			blocked = candidate
			break
		}
		candidate.Close()
	}
	if blocked == nil {
		t.Fatal("could not reserve an IPv6 neighbor with free IPv4 transports")
	}
	defer blocked.Close()
	if !checkMixedPortAvailableAt(port, false, "*") {
		t.Fatal("IPv6-only neighbor blocked an IPv4 loopback-only mixed listener")
	}
	if checkMixedPortAvailableAt(port, true, "[::1]") {
		t.Fatal("same-address IPv6 UDP conflict was accepted")
	}
	if checkMixedPortAvailableAt(port, true, "*") {
		t.Fatal("wildcard UDP conflict was accepted")
	}
}
