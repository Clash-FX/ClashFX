#!/usr/bin/env python3
"""Verify that Mihomo DNS shutdown closes its original TCP and UDP sockets."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from typing import Iterator


ROOT = Path(__file__).resolve().parents[1]
GOCLASH_ROOT = ROOT / "ClashFX" / "goClash"
FIXTURE_NAME = "clashfx_dns_lifecycle_ownership_test.go"
PACKAGE = "github.com/metacubex/mihomo/dns"

sys.path.insert(0, str(GOCLASH_ROOT))
import core_overlay  # noqa: E402


FIXTURE = r'''package dns

import (
	"errors"
	"fmt"
	"net"
	"strconv"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

const (
	clashFXFirstPort = 20000
	clashFXLastPort  = 39999
	clashFXCycles    = 20
)

type clashFXDeadlineSetter interface {
	SetDeadline(time.Time) error
}

func TestClashFXDNSLifecycleOwnership(t *testing.T) {
	port := clashFXAvailablePort(t)
	listenAddress := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	resolvers := NewResolver(Config{})
	mapper := NewEnhancer(EnhancerConfig{EnhancedMode: C.DNSNormal})
	service := NewService(resolvers.Resolver, mapper)
	t.Cleanup(func() { ReCreateServer("", nil) })

	for cycle := 0; cycle < clashFXCycles; cycle++ {
		ReCreateServer(listenAddress, service)

		serverLifecycle.Lock()
		active := server
		var packet net.PacketConn
		var listener net.Listener
		publishedAddress := address
		if active == nil || active.udpServer == nil || active.tcpServer == nil {
			publishedAddress = ""
		} else {
			packet = active.udpServer.PacketConn
			listener = active.tcpServer.Listener
		}
		serverLifecycle.Unlock()

		if publishedAddress != listenAddress || packet == nil || listener == nil {
			t.Fatalf("cycle %d: DNS server did not publish both listeners at %s (published %s)", cycle, listenAddress, publishedAddress)
		}
		if got := packet.LocalAddr().String(); got != listenAddress {
			t.Fatalf("cycle %d: captured UDP socket at %s, want %s", cycle, got, listenAddress)
		}
		if got := listener.Addr().String(); got != listenAddress {
			t.Fatalf("cycle %d: captured TCP listener at %s, want %s", cycle, got, listenAddress)
		}

		// ReCreateServer waits for Shutdown to finish. Probe the captured handles
		// before attempting to bind the endpoint, and never close them in the test.
		ReCreateServer("", nil)
		udpErr := packet.SetReadDeadline(time.Now())
		deadlineSetter, ok := listener.(clashFXDeadlineSetter)
		if !ok {
			t.Fatalf("cycle %d: TCP listener %T has no SetDeadline method", cycle, listener)
		}
		tcpErr := deadlineSetter.SetDeadline(time.Now())
		if !errors.Is(udpErr, net.ErrClosed) {
			t.Errorf("cycle %d: original UDP socket SetReadDeadline error = %v, want net.ErrClosed", cycle, udpErr)
		}
		if !errors.Is(tcpErr, net.ErrClosed) {
			t.Errorf("cycle %d: original TCP listener SetDeadline error = %v, want net.ErrClosed", cycle, tcpErr)
		}
		if t.Failed() {
			return
		}

		// A single immediate bind pair proves both transports released the same
		// port. Keep each probe open until both binds succeed, then close only the
		// test-owned probes before the next create/stop cycle.
		tcpProbe, err := net.Listen("tcp", listenAddress)
		if err != nil {
			t.Fatalf("cycle %d: rebind TCP %s immediately after shutdown: %v", cycle, listenAddress, err)
		}
		udpProbe, err := net.ListenPacket("udp", listenAddress)
		if err != nil {
			_ = tcpProbe.Close()
			t.Fatalf("cycle %d: rebind UDP %s immediately after shutdown: %v", cycle, listenAddress, err)
		}
		if err := udpProbe.Close(); err != nil {
			_ = tcpProbe.Close()
			t.Fatalf("cycle %d: close UDP ownership probe: %v", cycle, err)
		}
		if err := tcpProbe.Close(); err != nil {
			t.Fatalf("cycle %d: close TCP ownership probe: %v", cycle, err)
		}
	}
}

func clashFXAvailablePort(t *testing.T) int {
	t.Helper()
	for port := clashFXFirstPort; port <= clashFXLastPort; port++ {
		address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
		tcp, err := net.Listen("tcp", address)
		if err != nil {
			continue
		}
		udp, err := net.ListenPacket("udp", address)
		if err != nil {
			_ = tcp.Close()
			continue
		}
		if err := udp.Close(); err != nil {
			_ = tcp.Close()
			t.Fatalf("close initial UDP port probe %s: %v", address, err)
		}
		if err := tcp.Close(); err != nil {
			t.Fatalf("close initial TCP port probe %s: %v", address, err)
		}
		return port
	}
	t.Fatal(fmt.Sprintf("could not reserve a loopback TCP/UDP port in %d-%d", clashFXFirstPort, clashFXLastPort))
	return 0
}
'''


@contextmanager
def private_go_environment(workspace: Path) -> Iterator[dict[str, str]]:
    # Dependencies and build outputs may use normal Go caches. Only the copied
    # overlay and temporary modfile are patched; HOME/profile state is private.
    cache_paths = {
        key: subprocess.check_output(["go", "env", key], text=True).strip()
        for key in ("GOPATH", "GOMODCACHE", "GOCACHE")
    }
    home = workspace / "home"
    home.mkdir()
    env = dict(os.environ, HOME=str(home), CGO_ENABLED="1", **cache_paths)
    env.setdefault("GOMAXPROCS", "2")
    keys = ("HOME", "GOPATH", "GOMODCACHE", "GOCACHE", "CGO_ENABLED")
    previous = {key: os.environ.get(key) for key in keys}
    os.environ.update({key: env[key] for key in keys})
    try:
        yield env
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def positive_count(value: str) -> int:
	count = int(value)
	if count < 1:
		raise argparse.ArgumentTypeError("count must be at least 1")
	return count


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--race", action="store_true", help="run the focused fixture with Go's race detector")
	parser.add_argument("--count", type=positive_count, default=1, help="number of fixture executions (default: 1)")
	args = parser.parse_args()

	with tempfile.TemporaryDirectory(prefix="clashfx-dns-lifecycle-ownership-") as workspace_name:
		workspace = Path(workspace_name)
		with private_go_environment(workspace) as env:
			with core_overlay.core_modfile() as modfile:
				dns_package = GOCLASH_ROOT / ".clashfx-core-workaround" / "mihomo" / "dns"
				fixture_path = dns_package / FIXTURE_NAME
				if fixture_path.exists():
					raise RuntimeError(f"refusing to overwrite existing fixture {fixture_path}")
				if not dns_package.is_dir():
					raise RuntimeError(f"pinned Mihomo DNS package copy is missing: {dns_package}")
				os.chmod(dns_package, dns_package.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
				fixture_path.write_text(FIXTURE, encoding="utf-8")
				try:
					command = [
						"go",
						"test",
						f"-modfile={modfile}",
						"-mod=mod",
						"-tags=with_gvisor",
						"-ldflags=-linkmode=external",
					]
					if args.race:
						command.append("-race")
					command.extend(
						[
							f"-count={args.count}",
							"-run=^TestClashFXDNSLifecycleOwnership$",
							"-timeout=180s",
							PACKAGE,
						]
					)
					print(
						f"Running pinned Mihomo DNS lifecycle ownership fixture "
						f"(race={args.race}, count={args.count})",
						flush=True,
					)
					return subprocess.run(command, cwd=GOCLASH_ROOT, env=env, check=False, timeout=600).returncode
				finally:
					fixture_path.unlink(missing_ok=True)


if __name__ == "__main__":
	sys.exit(main())
