package main

import (
	"github.com/metacubex/mihomo/adapter/inbound"
	"net"
	"net/netip"
	"sync"
	"testing"
)

func TestInboundAccessPolicyCopiesSnapshotsAndSupportsConcurrentReload(t *testing.T) {
	oldSkip, oldAllow, oldDeny := inbound.SkipAuthPrefixes(), inbound.AllowedIPs(), inbound.DisAllowedIPs()
	t.Cleanup(func() { inbound.SetAccessPrefixes(oldSkip, oldAllow, oldDeny) })
	loop := netip.MustParsePrefix("127.0.0.0/8")
	other := netip.MustParsePrefix("10.0.0.0/8")
	source := []netip.Prefix{loop}
	inbound.SetAccessPrefixes(source, source, nil)
	source[0] = other
	address := &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 12345}
	if !inbound.SkipAuthRemoteAddr(address) || !inbound.IsRemoteAddrDisAllowed(address) {
		t.Fatal("caller mutated published policy")
	}
	copied := inbound.AllowedIPs()
	copied[0] = other
	if !inbound.IsRemoteAddrDisAllowed(address) {
		t.Fatal("getter leaked mutable policy backing storage")
	}
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		for i := 0; i < 1000; i++ {
			inbound.SetAccessPrefixes([]netip.Prefix{loop}, []netip.Prefix{loop}, nil)
		}
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 1000; i++ {
			_ = inbound.SkipAuthRemoteAddr(address)
			_ = inbound.IsRemoteAddrDisAllowed(address)
			_ = inbound.AllowedIPs()
		}
	}()
	workers.Wait()
}
