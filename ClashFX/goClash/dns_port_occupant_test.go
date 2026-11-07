package main

import (
	"net"
	"strconv"
	"testing"

	"github.com/phayes/freeport"
)

// hermeticDNSProbe uses the production probe but never touches the fixed
// fallback ports (7874, 11053), which belong to a running ClashFX on a
// developer machine.
func hermeticDNSProbe(port int) bool {
	if port == preferredEnhancedDNSPort || port == 11053 {
		return false
	}
	return checkDNSPortAvailable(port)
}

type dnsOccupant struct {
	name string
	hold func(t *testing.T, port int) func()
}

func holdTCP(host string) func(t *testing.T, port int) func() {
	return func(t *testing.T, port int) func() {
		l, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			t.Fatalf("occupy tcp %s:%d: %v", host, port, err)
		}
		return func() { _ = l.Close() }
	}
}

func holdUDP(host string) func(t *testing.T, port int) func() {
	return func(t *testing.T, port int) func() {
		c, err := net.ListenPacket("udp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err != nil {
			t.Fatalf("occupy udp %s:%d: %v", host, port, err)
		}
		return func() { _ = c.Close() }
	}
}

// plainBindWorks reports whether the listener sequence used by the DNS server
// (UDP, then TCP, on the loopback address) can bind the port right now.
func plainBindWorks(port int) bool {
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	udp, err := net.ListenPacket("udp", address)
	if err != nil {
		return false
	}
	defer udp.Close()
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	_ = tcp.Close()
	return true
}

func TestDNSPortSelectionSkipsPortsHeldByOtherProcesses(t *testing.T) {
	occupants := []dnsOccupant{
		{"tcp-only loopback", holdTCP("127.0.0.1")},
		{"udp-only loopback", holdUDP("127.0.0.1")},
		{"tcp wildcard", holdTCP("0.0.0.0")},
		{"udp wildcard", holdUDP("0.0.0.0")},
	}
	for _, occupant := range occupants {
		t.Run(occupant.name, func(t *testing.T) {
			preferred, err := freeport.GetFreePort()
			if err != nil {
				t.Fatal(err)
			}
			release := occupant.hold(t, preferred)
			defer release()
			blocked := !plainBindWorks(preferred)

			dns := map[string]interface{}{"listen": "127.0.0.1:" + strconv.Itoa(preferred)}
			chosen, err := chooseAvailableEnhancedDNSPort(dns, preferred, nil, hermeticDNSProbe, freeport.GetFreePort)
			if err != nil {
				t.Fatalf("selection failed: %v", err)
			}
			if blocked && chosen == preferred {
				t.Fatalf("selected %d although another process holds it (%s)", chosen, occupant.name)
			}
			if !plainBindWorks(chosen) {
				t.Fatalf("selected port %d cannot be bound by the DNS server sequence", chosen)
			}
			t.Logf("occupant=%s preferred=%d blocked=%v chosen=%d", occupant.name, preferred, blocked, chosen)
		})
	}
}

// A port that is free at selection but taken before the core binds must be
// avoided by the next regeneration: the retry path re-probes and moves on.
func TestDNSPortRegenerationMovesOffAPortTakenAfterSelection(t *testing.T) {
	first, err := freeport.GetFreePort()
	if err != nil {
		t.Fatal(err)
	}
	dns := map[string]interface{}{"listen": "127.0.0.1:" + strconv.Itoa(first)}
	chosen, err := chooseAvailableEnhancedDNSPort(dns, first, nil, hermeticDNSProbe, freeport.GetFreePort)
	if err != nil || chosen != first {
		t.Fatalf("first selection chosen=%d err=%v, want %d", chosen, err, first)
	}

	release := holdTCP("127.0.0.1")(t, first)
	defer release()
	dns = map[string]interface{}{"listen": "127.0.0.1:" + strconv.Itoa(first)}
	next, err := chooseAvailableEnhancedDNSPort(dns, first, nil, hermeticDNSProbe, freeport.GetFreePort)
	if err != nil {
		t.Fatalf("regeneration failed: %v", err)
	}
	if next == first {
		t.Fatalf("regeneration reselected %d while it is held", next)
	}
}

// With every fallback unavailable the selector must report a classified
// conflict instead of silently returning an unusable port.
func TestDNSPortSelectionReportsClassifiedConflictWhenExhausted(t *testing.T) {
	preferred, err := freeport.GetFreePort()
	if err != nil {
		t.Fatal(err)
	}
	dns := map[string]interface{}{"listen": "127.0.0.1:" + strconv.Itoa(preferred)}
	_, err = chooseAvailableEnhancedDNSPort(dns, preferred, nil,
		func(int) bool { return false },
		func() (int, error) { return preferred, nil })
	conflict, ok := err.(portConflictError)
	if !ok {
		t.Fatalf("error %T %v, want portConflictError", err, err)
	}
	if conflict.reason != "fallbacks_exhausted" || conflict.service != "dns_listener" {
		t.Fatalf("unexpected conflict %+v", conflict)
	}
}
