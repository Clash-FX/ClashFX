package main

import (
	"net"
	"runtime"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/listener/tproxy"
)

const tproxyConstructorFailureCount = 32

func TestTProxyConstructorsReleaseSocketsAfterPlatformSetupFailure(t *testing.T) {
	if runtime.GOOS == "linux" {
		t.Skip("TProxy socket setup succeeds on Linux and may require privileges")
	}

	t.Run("tcp", func(t *testing.T) {
		address := unusedTCPAddress(t)
		for attempt := 0; attempt < tproxyConstructorFailureCount; attempt++ {
			listener, err := tproxy.New(address, nil)
			if err == nil {
				if listener != nil {
					_ = listener.Close()
				}
				t.Fatalf("New(%q) unexpectedly succeeded", address)
			}
			if !strings.Contains(err.Error(), "not supported on current platform") {
				t.Fatalf("New(%q) error = %v; want unsupported-platform setup error", address, err)
			}
		}

		listener, err := net.Listen("tcp", address)
		if err != nil {
			t.Fatalf("TCP port %q remained occupied after failed New calls: %v", address, err)
		}
		_ = listener.Close()
	})

	t.Run("udp", func(t *testing.T) {
		address := unusedUDPAddress(t)
		for attempt := 0; attempt < tproxyConstructorFailureCount; attempt++ {
			listener, err := tproxy.NewUDP(address, nil)
			if err == nil {
				if listener != nil {
					_ = listener.Close()
				}
				t.Fatalf("NewUDP(%q) unexpectedly succeeded", address)
			}
			if !strings.Contains(err.Error(), "not supported on current platform") {
				t.Fatalf("NewUDP(%q) error = %v; want unsupported-platform setup error", address, err)
			}
		}

		packetConn, err := net.ListenPacket("udp", address)
		if err != nil {
			t.Fatalf("UDP port %q remained occupied after failed NewUDP calls: %v", address, err)
		}
		_ = packetConn.Close()
	})
}

func unusedTCPAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve an ephemeral TCP port: %v", err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatalf("release ephemeral TCP port: %v", err)
	}
	return address
}

func unusedUDPAddress(t *testing.T) string {
	t.Helper()
	packetConn, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve an ephemeral UDP port: %v", err)
	}
	address := packetConn.LocalAddr().String()
	if err := packetConn.Close(); err != nil {
		t.Fatalf("release ephemeral UDP port: %v", err)
	}
	return address
}
