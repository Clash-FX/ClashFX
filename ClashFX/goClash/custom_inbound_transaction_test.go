package main

import (
	"bytes"
	"fmt"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
)

func TestCustomInboundMoveFailureRollsBackAndKeepsSubmittedReceipt(t *testing.T) {
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	occupiedPort := blocker.Addr().(*net.TCPAddr).Port

	oldPortProbe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	oldPort := oldPortProbe.Addr().(*net.TCPAddr).Port
	if err := oldPortProbe.Close(); err != nil {
		t.Fatal(err)
	}
	if oldPort == occupiedPort {
		t.Fatal("test setup selected the occupied port for the original inbound")
	}

	const configTemplate = `port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
mixed-port: 0
dns:
  enable: false
tun:
  enable: false
listeners:
  - name: clashfx-transaction-regression
    type: mixed
    listen: 127.0.0.1
    port: %d
    udp: false
`
	oldConfig := []byte(fmt.Sprintf(configTemplate, oldPort))
	failedMove := []byte(fmt.Sprintf(configTemplate, occupiedPort))
	var receipt submittedConfigSnapshot

	apply := func(raw []byte) error {
		cfg, err := executor.ParseWithBytes(raw)
		if err != nil {
			return err
		}
		return applyAndRecordSubmittedConfig(&receipt, raw, func() error {
			executor.ApplyConfig(cfg, true)
			return listener.ValidateInboundListeners(cfg.Listeners)
		})
	}

	t.Cleanup(func() {
		emptyConfig, err := executor.ParseWithBytes([]byte("dns:\n  enable: false\ntun:\n  enable: false\n"))
		if err == nil {
			executor.ApplyConfig(emptyConfig, true)
		}
	})

	if err := apply(oldConfig); err != nil {
		t.Fatalf("apply original named inbound: %v", err)
	}
	assertCustomInboundAcceptsTCP(t, oldPort)

	if err := apply(failedMove); err == nil {
		t.Fatal("move to an occupied port was reported as successful")
	} else if !strings.Contains(err.Error(), "clashfx-transaction-regression") {
		t.Fatalf("failed move error = %v, want named-listener readiness failure", err)
	}
	if got := receipt.bytes(); !bytes.Equal(got, oldConfig) {
		t.Fatalf("failed move published a false submitted receipt: got %q, want %q", got, oldConfig)
	}

	if err := apply(oldConfig); err != nil {
		t.Fatalf("restore original named inbound after failed move: %v", err)
	}
	assertCustomInboundAcceptsTCP(t, oldPort)
	// TrustTunnel's constructor returns a nil transport for missing TLS material;
	// its upstream Close dereferences that nil transport. Rejection must survive
	// that cleanup and still allow the previous same-name inbound to restart.
	failedTLS := []byte(fmt.Sprintf(`mixed-port: 0
dns: {enable: false}
tun: {enable: false}
listeners:
  - name: clashfx-transaction-regression
    type: trusttunnel
    listen: 127.0.0.1
    port: %d
    certificate: ""
    private-key: ""
    network: [tcp]
`, oldPort))
	if err := apply(failedTLS); err == nil {
		t.Fatal("failed TrustTunnel start was accepted")
	}
	if got := receipt.bytes(); !bytes.Equal(got, oldConfig) {
		t.Fatal("failed-start cleanup changed the confirmed receipt")
	}
	if err := apply(oldConfig); err != nil {
		t.Fatalf("restore after nil-transport cleanup: %v", err)
	}
	assertCustomInboundAcceptsTCP(t, oldPort)

	if got := receipt.bytes(); !bytes.Equal(got, oldConfig) {
		t.Fatalf("rollback receipt = %q, want original config %q", got, oldConfig)
	}
}

func assertCustomInboundAcceptsTCP(t *testing.T, port int) {
	t.Helper()
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	conn, err := net.DialTimeout("tcp", address, 500*time.Millisecond)
	if err != nil {
		t.Fatalf("named inbound is not accepting TCP at %s: %v", address, err)
	}
	_ = conn.Close()
}
