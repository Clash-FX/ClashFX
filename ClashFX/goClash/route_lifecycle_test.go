package main

import (
	"net"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/route"
)

func TestRuntimeManagementEndpointLifecycle(t *testing.T) {
	certificate, key, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
	if err != nil {
		t.Fatal(err)
	}
	freeAddress := func() string {
		t.Helper()
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		address := l.Addr().String()
		l.Close()
		return address
	}
	httpAddress, tlsAddress := freeAddress(), freeAddress()
	for tlsAddress == httpAddress {
		tlsAddress = freeAddress()
	}
	unixAddress := filepath.Join(constant.Path.HomeDir(), "runtime-api.sock")
	cfg := &route.Config{Addr: httpAddress, TLSAddr: tlsAddress, UnixAddr: unixAddress, Certificate: certificate, PrivateKey: key}
	t.Cleanup(func() { route.ReCreateServer(&route.Config{}) })
	for iteration := 0; iteration < 5; iteration++ {
		route.ReCreateServer(cfg)
		assertOccupied(t, "tcp", httpAddress)
		assertOccupied(t, "tcp", tlsAddress)
		connection, err := net.Dial("unix", unixAddress)
		if err != nil {
			t.Fatalf("healthy Unix API rejected: %v", err)
		}
		connection.Close()
		route.ReCreateServer(&route.Config{})
		assertBindable(t, "tcp", httpAddress)
		assertBindable(t, "tcp", tlsAddress)
		// Closing the endpoint must not depend on its serving goroutine starting.
		endpoint, err := net.Listen("unix", unixAddress)
		if err != nil {
			t.Fatalf("Unix API retained after stop: %v", err)
		}
		endpoint.Close()
	}
	cfg.Addr = ""
	cfg.UnixAddr = ""
	cfg.ClientAuthType = "require-and-verify"
	cfg.ClientAuthCert = "invalid-client-ca"
	route.ReCreateServer(cfg)
	assertBindable(t, "tcp", tlsAddress) // validation fails after the TCP bind
	cfg.ClientAuthCert = ""
	cfg.ClientAuthType = ""
	route.ReCreateServer(cfg)
	assertOccupied(t, "tcp", tlsAddress)
}
