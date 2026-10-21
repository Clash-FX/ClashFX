package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/profile"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	"github.com/metacubex/mihomo/tunnel"
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

func TestStartupRecoverySelectionCLIPath(t *testing.T) {
	for _, scenario := range []string{
		"cached_node", "missing_target", "missing_group", "non_selector_key",
		"compatible_target", "direct_nested", "provider_candidate",
	} {
		t.Run(scenario, func(t *testing.T) {
			runStartupSelectionHelper(t, scenario)
		})
	}
}

func TestStartupRecoverySelectionRejectsMalformedConfigValue(t *testing.T) {
	home := t.TempDir()
	port := unusedTCPPort(t)
	configPath := filepath.Join(home, "config.yaml")
	config := fmt.Sprintf("external-controller: 127.0.0.1:%d\ntun:\n  enable: false\nx-clashfx-recovery-selections: [TAGSS, Node]\n", port)
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := run([]string{"-d", home, "-f", configPath}, &stdout, &stderr); code != 1 {
		t.Fatalf("malformed recovery selection exit=%d stdout=%q stderr=%q, want 1", code, stdout.String(), stderr.String())
	}
	if conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond); err == nil {
		_ = conn.Close()
		t.Fatalf("malformed recovery selections published the management endpoint on port %d", port)
	}
}

func runStartupSelectionHelper(t *testing.T, scenario string) {
	t.Helper()
	home := t.TempDir()
	readyPath := filepath.Join(home, "ready")
	command := exec.Command(os.Args[0], "-test.run=^TestStartupSelectionHelper$")
	command.Env = privateHomeEnvironment(home, map[string]string{
		"CLASHFX_STARTUP_SELECTION_SCENARIO": scenario,
		"CLASHFX_STARTUP_SELECTION_READY":    readyPath,
	})
	var output lockedBuffer
	command.Stdout = &output
	command.Stderr = &output
	if isStartupSelectionFailureScenario(scenario) {
		if err := command.Run(); err != nil {
			t.Fatalf("startup helper failed: %v; output: %s", err, output.String())
		}
		return
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}

	finished := make(chan error, 1)
	go func() { finished <- command.Wait() }()
	deadline := time.After(8 * time.Second)
	for {
		if _, err := os.Stat(readyPath); err == nil {
			if err := command.Process.Signal(os.Interrupt); err != nil {
				t.Fatalf("stop startup helper: %v; output: %s", err, output.String())
			}
			select {
			case err := <-finished:
				if err != nil {
					t.Fatalf("startup helper failed: %v; output: %s", err, output.String())
				}
				return
			case <-time.After(3 * time.Second):
				_ = command.Process.Kill()
				t.Fatalf("startup helper did not stop after SIGINT; output: %s", output.String())
			}
		}
		select {
		case err := <-finished:
			if err != nil {
				t.Fatalf("startup helper failed before readiness: %v; output: %s", err, output.String())
			}
			t.Fatalf("startup helper exited without reporting readiness; output: %s", output.String())
		case <-deadline:
			_ = command.Process.Kill()
			<-finished
			t.Fatalf("startup helper timed out; output: %s", output.String())
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
}

func TestStartupSelectionHelper(t *testing.T) {
	scenario := os.Getenv("CLASHFX_STARTUP_SELECTION_SCENARIO")
	if scenario == "" {
		return
	}
	home := os.Getenv("HOME")
	if err := os.MkdirAll(home, 0700); err != nil {
		t.Fatal(err)
	}
	constant.SetHomeDir(home)
	controllerPort := unusedTCPPort(t)
	configPath := filepath.Join(home, "config.yaml")
	config := startupSelectionTestConfig(controllerPort, scenario)
	if scenario == "provider_candidate" {
		providerDir := filepath.Join(home, "providers")
		if err := os.MkdirAll(providerDir, 0700); err != nil {
			t.Fatal(err)
		}
		provider := "proxies:\n  - name: Node\n    type: socks5\n    server: 127.0.0.1\n    port: 1081\n"
		if err := os.WriteFile(filepath.Join(providerDir, "proxies.yaml"), []byte(provider), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	if scenario == "cached_node" || isStartupSelectionFailureScenario(scenario) {
		profile.StoreSelected.Store(true)
		cachefile.Cache().SetSelected("TAGSS", "DIRECT")
	}
	selections := map[string]string{}
	switch scenario {
	case "cached_node", "provider_candidate":
		selections["TAGSS"] = "Node"
	case "missing_target":
		selections["TAGSS"] = "Unavailable"
	case "missing_group":
		selections["MISSING"] = "DIRECT"
	case "non_selector_key":
		selections["DIRECT"] = "DIRECT"
	case "compatible_target":
		selections["TAGSS"] = "COMPATIBLE"
	case "direct_nested":
		selections["TAGSS"] = "DIRECT"
		selections["OUTER"] = "TAGSS"
	default:
		t.Fatalf("unknown startup selection scenario %q", scenario)
	}
	config = strings.Replace(config, "rules:\n", "x-clashfx-recovery-selections:\n"+formatSelectionMapping(selections)+"rules:\n", 1)
	if err := os.WriteFile(configPath, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}

	if isStartupSelectionFailureScenario(scenario) {
		var stdout, stderr bytes.Buffer
		if code := run([]string{"-d", home, "-f", configPath}, &stdout, &stderr); code != 1 {
			t.Fatalf("missing target startup exit=%d stdout=%q stderr=%q, want 1", code, stdout.String(), stderr.String())
		}
		if tunnel.Status() != tunnel.Inner {
			t.Fatalf("failed guarded startup tunnel status=%s, want inner", tunnel.Status())
		}
		if cached := cachefile.Cache().SelectedMap()["TAGSS"]; cached != "DIRECT" {
			t.Fatalf("failed guarded startup changed cached TAGSS selection to %q", cached)
		}
		if conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", controllerPort), 100*time.Millisecond); err == nil {
			_ = conn.Close()
			t.Fatalf("failed guarded startup published the management endpoint on port %d", controllerPort)
		}
		return
	}

	var stdout, stderr lockedBuffer
	done := make(chan int, 1)
	go func() { done <- run([]string{"-d", home, "-f", configPath}, &stdout, &stderr) }()
	endpoint := fmt.Sprintf("http://127.0.0.1:%d/proxies", controllerPort)
	deadline := time.Now().Add(6 * time.Second)
	var selected map[string]string
	for time.Now().Before(deadline) {
		select {
		case code := <-done:
			t.Fatalf("startup exited before management readiness with %d; stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		default:
		}
		response, err := http.Get(endpoint)
		if err == nil {
			var body struct {
				Proxies map[string]struct {
					Now string `json:"now"`
				} `json:"proxies"`
			}
			decodeErr := json.NewDecoder(response.Body).Decode(&body)
			_ = response.Body.Close()
			if decodeErr == nil && response.StatusCode == http.StatusOK {
				selected = map[string]string{}
				for name, proxy := range body.Proxies {
					selected[name] = proxy.Now
				}
				break
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	want := map[string]string{"TAGSS": "Node"}
	if scenario == "direct_nested" {
		want = map[string]string{"TAGSS": "DIRECT", "OUTER": "TAGSS"}
	}
	for group, target := range want {
		if selected[group] != target {
			t.Fatalf("startup selection %s=%q, want %q; all selections=%v", group, selected[group], target, selected)
		}
	}
	if scenario == "cached_node" {
		if cached := cachefile.Cache().SelectedMap()["TAGSS"]; cached != "DIRECT" {
			t.Fatalf("successful recovery startup changed the saved TAGSS cache to %q", cached)
		}
	}
	time.Sleep(100 * time.Millisecond)
	readyPath := os.Getenv("CLASHFX_STARTUP_SELECTION_READY")
	if err := os.WriteFile(readyPath, []byte("ready"), 0600); err != nil {
		t.Fatal(err)
	}
	if code := <-done; code != 0 {
		t.Fatalf("startup exit after SIGINT=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
}

func startupSelectionTestConfig(controllerPort int, scenario string) string {
	proxyBody := `proxies:
  - name: Node
    type: socks5
    server: 127.0.0.1
    port: 1081
`
	providerConfig := ""
	groups := `proxy-groups:
  - name: TAGSS
    type: select
    proxies: [DIRECT, Node, COMPATIBLE]
  - name: OUTER
    type: select
    proxies: [TAGSS, DIRECT, COMPATIBLE]
`
	if scenario == "provider_candidate" {
		proxyBody = ""
		providerConfig = `proxy-providers:
  local:
    type: file
    path: ./providers/proxies.yaml
    health-check:
      enable: false
`
		groups = `proxy-groups:
  - name: TAGSS
    type: select
    use: [local]
`
	}
	return fmt.Sprintf(`port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
mixed-port: 0
allow-lan: false
mode: rule
external-controller: 127.0.0.1:%d
secret: ""
tun:
  enable: false
profile:
  store-selected: true
%s%s%s
rules:
  - MATCH,TAGSS
`, controllerPort, proxyBody, providerConfig, groups)
}

func formatSelectionMapping(selections map[string]string) string {
	var builder strings.Builder
	for group, target := range selections {
		fmt.Fprintf(&builder, "  %q: %q\n", group, target)
	}
	return builder.String()
}

func isStartupSelectionFailureScenario(scenario string) bool {
	switch scenario {
	case "missing_target", "missing_group", "non_selector_key", "compatible_target":
		return true
	default:
		return false
	}
}

func privateHomeEnvironment(home string, values map[string]string) []string {
	environment := make([]string, 0, len(os.Environ())+len(values)+1)
	for _, entry := range os.Environ() {
		key, _, _ := strings.Cut(entry, "=")
		if key == "HOME" {
			continue
		}
		if _, replaced := values[key]; !replaced {
			environment = append(environment, entry)
		}
	}
	environment = append(environment, "HOME="+home)
	for key, value := range values {
		environment = append(environment, key+"="+value)
	}
	return environment
}

type lockedBuffer struct {
	mutex sync.Mutex
	bytes.Buffer
}

func (buffer *lockedBuffer) Write(value []byte) (int, error) {
	buffer.mutex.Lock()
	defer buffer.mutex.Unlock()
	return buffer.Buffer.Write(value)
}

func (buffer *lockedBuffer) String() string {
	buffer.mutex.Lock()
	defer buffer.mutex.Unlock()
	return buffer.Buffer.String()
}

var _ io.Writer = (*lockedBuffer)(nil)

func TestTUNBuildCapabilityMatrix(t *testing.T) {
	for _, supported := range []bool{false, true} {
		for _, enabled := range []bool{false, true} {
			for _, stack := range []constant.TUNStack{constant.TunGvisor, constant.TunMixed, constant.TunSystem} {
				err := validateTUNBuildCapability(enabled, stack, supported)
				wantError := enabled && !supported && stack != constant.TunSystem
				if (err != nil) != wantError {
					t.Fatalf("enabled=%v stack=%v supported=%v err=%v", enabled, stack, supported, err)
				}
			}
		}
	}
}

func TestFeaturesQueryDoesNotRequireConfigOrPublishListeners(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := run([]string{"--features", "-f", filepath.Join(t.TempDir(), "missing.yaml")}, &stdout, &stderr)
	var payload struct{ Features []string }
	if code != 0 || json.Unmarshal(stdout.Bytes(), &payload) != nil {
		t.Fatalf("features query failed: %d %s %s", code, &stdout, &stderr)
	}
	found := false
	for _, tag := range payload.Features {
		if tag == "with_gvisor" {
			found = true
		}
	}
	if found != features.WithGVisor {
		t.Fatalf("features do not match compiled capability: %s", &stdout)
	}
}

func TestMissingGVisorRejectsBeforeStartupOrValidationSuccess(t *testing.T) {
	for _, stack := range []string{"gvisor", "mixed"} {
		home := t.TempDir()
		cfg := "mixed-port: 0\nexternal-controller: ''\ndns: {enable: false}\ntun: {enable: true, stack: " + stack + "}\nrules: [\"MATCH,DIRECT\"]\n"
		if err := os.WriteFile(filepath.Join(home, "config.yaml"), []byte(cfg), 0600); err != nil {
			t.Fatal(err)
		}
		var stdout, stderr bytes.Buffer
		code := run([]string{"-t", "-d", home, "-f", filepath.Join(home, "config.yaml")}, &stdout, &stderr)
		if features.WithGVisor {
			if code != 0 {
				t.Fatalf("supported stack rejected: %s", &stderr)
			}
		} else {
			if code != 1 || !strings.Contains(stderr.String(), "unsupported_tun_stack_build") || strings.Contains(stdout.String(), "configuration is valid") {
				t.Fatalf("unsupported stack accepted: %d %s %s", code, &stdout, &stderr)
			}
			stdout.Reset()
			stderr.Reset()
			if code := run([]string{"-d", home, "-f", filepath.Join(home, "config.yaml")}, &stdout, &stderr); code != 1 || strings.Contains(stdout.String(), "mihomo-bin started") {
				t.Fatalf("unsupported core started: %d %s %s", code, &stdout, &stderr)
			}
		}
	}
}
