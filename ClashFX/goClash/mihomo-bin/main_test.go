package main

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/constant"
)

func TestValidateOnlyParsesTUNConfigWithoutStartingListeners(t *testing.T) {
	home := t.TempDir()
	port := unusedTCPPort(t)
	configPath := filepath.Join(home, "config.yaml")
	config := fmt.Sprintf("mixed-port: %d\nallow-lan: false\ntun:\n  enable: true\n  stack: system\n  auto-route: true\nrules:\n  - MATCH,DIRECT\n", port)
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	if code := run([]string{"-t", "-d", home}, &stdout, &stderr); code != 0 {
		t.Fatalf("-t exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stdout.String(), "configuration is valid") {
		t.Fatalf("validation success not reported: %q", stdout.String())
	}
	if !strings.Contains(constant.Path.Config(), configPath) {
		t.Fatalf("config path %q does not resolve inside isolated home %q", constant.Path.Config(), home)
	}
	if listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port)); err != nil {
		t.Fatalf("-t opened mixed proxy listener on %d: %v", port, err)
	} else {
		_ = listener.Close()
	}
	if listener, err := net.ListenPacket("udp", fmt.Sprintf("127.0.0.1:%d", port)); err != nil {
		t.Fatalf("-t opened mixed proxy UDP listener on %d: %v", port, err)
	} else {
		_ = listener.Close()
	}
}

func TestValidateOnlyInvalidConfigExitsNonzero(t *testing.T) {
	home := t.TempDir()
	configPath := filepath.Join(home, "bad.yaml")
	if err := os.WriteFile(configPath, []byte("mixed-port: [invalid\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := run([]string{"-t", "-d", home, "-f", configPath}, &stdout, &stderr)
	if code == 0 || !strings.Contains(stderr.String(), "Parse config error") {
		t.Fatalf("invalid config: exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func TestStartupRejectsNamedListenerBindFailureWithoutWaitingForSignal(t *testing.T) {
	home := t.TempDir()
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	occupiedPort := blocker.Addr().(*net.TCPAddr).Port
	configPath := filepath.Join(home, "config.yaml")
	config := fmt.Sprintf(`port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
mixed-port: 0
external-controller: ""
dns:
  enable: false
tun:
  enable: false
listeners:
  - name: clashfx-startup-regression
    type: mixed
    listen: 127.0.0.1
    port: %d
    udp: false
`, occupiedPort)
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	var stdout, stderr bytes.Buffer
	result := make(chan int, 1)
	go func() {
		result <- run([]string{"-d", home, "-f", configPath}, &stdout, &stderr)
	}()
	select {
	case code := <-result:
		if code != 1 {
			t.Fatalf("startup exit=%d stdout=%q stderr=%q, want bind failure exit 1", code, stdout.String(), stderr.String())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("startup did not reject the failed named listener before waiting for a signal")
	}
}

func unusedTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

func TestValidateOnlyDoesNotRequireRelativeProviderInitialization(t *testing.T) {
	for _, present := range []bool{false, true} {
		t.Run(fmt.Sprint(present), func(t *testing.T) {
			home := t.TempDir()
			config := `mixed-port: 0
mode: rule
proxy-providers:
  local:
    type: file
    path: ./providers/proxies.yaml
    health-check:
      enable: false
rule-providers:
  localrules:
    type: file
    behavior: classical
    path: ./providers/rules.yaml
    format: yaml
proxy-groups:
  - name: PROXY
    type: select
    use: [local]
rules:
  - RULE-SET,localrules,PROXY
  - MATCH,PROXY
`
			path := filepath.Join(home, "config.yaml")
			if err := os.WriteFile(path, []byte(config), 0600); err != nil {
				t.Fatal(err)
			}
			if present {
				if err := os.Mkdir(filepath.Join(home, "providers"), 0700); err != nil {
					t.Fatal(err)
				}
				for name, data := range map[string]string{"proxies.yaml": "proxies: []\n", "rules.yaml": "payload: [DOMAIN,example.test]\n"} {
					if err := os.WriteFile(filepath.Join(home, "providers", name), []byte(data), 0600); err != nil {
						t.Fatal(err)
					}
				}
			}
			var stdout, stderr bytes.Buffer
			if code := run([]string{"-t", "-d", home, "-f", path}, &stdout, &stderr); code != 0 {
				t.Fatalf("parse-only validation incorrectly initialized relative providers: exit=%d stderr=%q", code, stderr.String())
			}
		})
	}
}
