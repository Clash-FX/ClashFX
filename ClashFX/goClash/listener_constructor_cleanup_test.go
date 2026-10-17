package main

import (
	"errors"
	"net"
	"strings"
	"syscall"
	"testing"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/ca"
	LC "github.com/metacubex/mihomo/listener/config"
	singShadowsocks "github.com/metacubex/mihomo/listener/sing_shadowsocks"
	singVmess "github.com/metacubex/mihomo/listener/sing_vmess"
	"github.com/metacubex/mihomo/listener/tuic"
)

type constructorClose func() error

func TestMihomoMultiAddressConstructorCleanup(t *testing.T) {
	certificate, privateKey, _, err := ca.NewRandomTLSKeyPair(ca.KeyPairTypeP256)
	if err != nil {
		t.Fatal(err)
	}

	newShadowsocks := func(listen string) (constructorClose, error) {
		listener, err := singShadowsocks.New(LC.ShadowsocksServer{
			Listen: listen,
			Cipher: "none",
			Udp:    true,
		}, nil, constructorAdditions()...)
		if err != nil {
			return nil, err
		}
		return listener.Close, nil
	}
	newVmess := func(listen string) (constructorClose, error) {
		listener, err := singVmess.New(LC.VmessServer{
			Listen: listen,
			Users: []LC.VmessUser{{
				Username: "constructor-cleanup-test",
				UUID:     "00000000-0000-4000-8000-000000000001",
			}},
		}, nil, constructorAdditions()...)
		if err != nil {
			return nil, err
		}
		return listener.Close, nil
	}
	newTuic := func(listen string) (constructorClose, error) {
		listener, err := tuic.New(LC.TuicServer{
			Listen:      listen,
			Token:       []string{"constructor-cleanup-test"},
			Certificate: certificate,
			PrivateKey:  privateKey,
		}, nil, constructorAdditions()...)
		if err != nil {
			return nil, err
		}
		return listener.Close, nil
	}

	t.Run("Shadowsocks TCP and UDP", func(t *testing.T) {
		firstTCP := reserveSocket(t, "tcp", "127.0.0.1:0")
		firstAddress := socketAddress(firstTCP)
		firstUDP := reserveSocket(t, "udp", firstAddress)
		secondTCP := reserveSocket(t, "tcp", "127.0.0.1:0")
		secondAddress := socketAddress(secondTCP)

		// Keep the second TCP port occupied. The constructor can bind its UDP
		// socket there before its TCP bind fails, covering every acquired socket.
		closeSocket(t, firstTCP)
		closeSocket(t, firstUDP)

		closeListener, err := newShadowsocks(firstAddress + "," + secondAddress)
		if err == nil {
			if closeListener != nil {
				_ = closeListener()
			}
			t.Fatal("expected the second TCP bind to fail")
		}
		if !strings.Contains(err.Error(), secondAddress) {
			t.Fatalf("constructor failed before the occupied second address: %v", err)
		}

		assertBindable(t, "tcp", firstAddress)
		assertBindable(t, "udp", firstAddress)
		assertBindable(t, "udp", secondAddress)

		// Retrying the original first range must succeed and keep both sockets
		// bound until the returned listener is closed.
		retryClose, err := newShadowsocks(firstAddress)
		if err != nil {
			t.Fatalf("retry on the released first port failed: %v", err)
		}
		assertOccupied(t, "tcp", firstAddress)
		assertOccupied(t, "udp", firstAddress)
		if err := retryClose(); err != nil {
			t.Fatalf("close successful Shadowsocks listener: %v", err)
		}
		assertBindable(t, "tcp", firstAddress)
		assertBindable(t, "udp", firstAddress)
	})

	t.Run("VMess TCP", func(t *testing.T) {
		firstBlocker := reserveSocket(t, "tcp", "127.0.0.1:0")
		firstAddress := socketAddress(firstBlocker)
		secondBlocker := reserveSocket(t, "tcp", "127.0.0.1:0")
		secondAddress := socketAddress(secondBlocker)
		closeSocket(t, firstBlocker)

		closeListener, err := newVmess(firstAddress + "," + secondAddress)
		if err == nil {
			if closeListener != nil {
				_ = closeListener()
			}
			t.Fatal("expected the second TCP bind to fail")
		}
		if !strings.Contains(err.Error(), secondAddress) {
			t.Fatalf("constructor failed before the occupied second address: %v", err)
		}

		assertBindable(t, "tcp", firstAddress)
		retryClose, err := newVmess(firstAddress)
		if err != nil {
			t.Fatalf("retry on the released first port failed: %v", err)
		}
		assertOccupied(t, "tcp", firstAddress)
		if err := retryClose(); err != nil {
			t.Fatalf("close successful VMess listener: %v", err)
		}
		assertBindable(t, "tcp", firstAddress)
	})

	t.Run("TUIC UDP", func(t *testing.T) {
		firstBlocker := reserveSocket(t, "udp", "127.0.0.1:0")
		firstAddress := socketAddress(firstBlocker)
		secondBlocker := reserveSocket(t, "udp", "127.0.0.1:0")
		secondAddress := socketAddress(secondBlocker)
		closeSocket(t, firstBlocker)

		closeListener, err := newTuic(firstAddress + "," + secondAddress)
		if err == nil {
			if closeListener != nil {
				_ = closeListener()
			}
			t.Fatal("expected the second UDP bind to fail")
		}
		if !strings.Contains(err.Error(), secondAddress) {
			t.Fatalf("constructor failed before the occupied second address: %v", err)
		}

		assertBindable(t, "udp", firstAddress)
		retryClose, err := newTuic(firstAddress)
		if err != nil {
			t.Fatalf("retry on the released first port failed: %v", err)
		}
		assertOccupied(t, "udp", firstAddress)
		if err := retryClose(); err != nil {
			t.Fatalf("close successful TUIC listener: %v", err)
		}
		assertBindable(t, "udp", firstAddress)
	})
}

func constructorAdditions() []inbound.Addition {
	return []inbound.Addition{
		inbound.WithInName("constructor-cleanup-test"),
		inbound.WithSpecialRules(""),
	}
}

func reserveSocket(t *testing.T, network, address string) netCloser {
	t.Helper()
	var socket netCloser
	var err error
	if network == "tcp" {
		socket, err = net.Listen(network, address)
	} else {
		socket, err = net.ListenPacket(network, address)
	}
	if err != nil {
		t.Fatalf("reserve %s %s: %v", network, address, err)
	}
	t.Cleanup(func() { _ = socket.Close() })
	return socket
}

type netCloser interface {
	Close() error
}

func socketAddress(socket netCloser) string {
	switch socket := socket.(type) {
	case net.Listener:
		return socket.Addr().String()
	case net.PacketConn:
		return socket.LocalAddr().String()
	default:
		panic("unsupported test socket type")
	}
}

func closeSocket(t *testing.T, socket netCloser) {
	t.Helper()
	if err := socket.Close(); err != nil {
		t.Fatalf("close reserved test socket: %v", err)
	}
}

func assertBindable(t *testing.T, network, address string) {
	t.Helper()
	socket := reserveSocket(t, network, address)
	closeSocket(t, socket)
}

func assertOccupied(t *testing.T, network, address string) {
	t.Helper()
	var socket netCloser
	var err error
	if network == "tcp" {
		socket, err = net.Listen(network, address)
	} else {
		socket, err = net.ListenPacket(network, address)
	}
	if err == nil {
		_ = socket.Close()
		t.Fatalf("expected %s %s to remain bound", network, address)
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Fatalf("expected address-in-use for %s %s, got %v", network, address, err)
	}
}
