"""Apply recovery-selected proxy paths before the pinned core starts routing."""
from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import hashlib


EXPECTED_SELECTOR_SOURCE_SHA256 = "c2e14f742300745a1811bd5ef5e47fd9e990252fa77af2f63a5daf7c4ba2b6ec"


def _replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(
            f"Expected one pinned startup-selection insertion point for {label}; found {count}"
        )
    return source.replace(old, new, 1)


STARTUP_SELECTION_STATE = '''
var startupRecoverySelectionsMu sync.Mutex
var startupRecoverySelectionsForNextApply map[string]string

// SetStartupRecoverySelections pins the next validated startup apply to the
// recovery snapshot. The value is consumed before that apply begins.
func SetStartupRecoverySelections(selections map[string]string) {
    copied := make(map[string]string, len(selections))
    for group, target := range selections {
        copied[group] = target
    }
    startupRecoverySelectionsMu.Lock()
    startupRecoverySelectionsForNextApply = copied
    startupRecoverySelectionsMu.Unlock()
}

func takeStartupRecoverySelections() map[string]string {
    startupRecoverySelectionsMu.Lock()
    selections := startupRecoverySelectionsForNextApply
    startupRecoverySelectionsForNextApply = nil
    startupRecoverySelectionsMu.Unlock()
    return selections
}
'''


STARTUP_SELECTION_APPLIER = r'''func applyStartupRecoverySelections(selections map[string]string) error {
	for groupName, targetName := range selections {
		proxy, exists := tunnel.Proxies()[groupName]
		if !exists {
			return fmt.Errorf("startup recovery selector %q was not found", groupName)
		}
		if proxy.Type() != C.Selector {
			return fmt.Errorf("startup recovery group %q is not a manual Selector", groupName)
		}
		selector, ok := proxy.Adapter().(*outboundgroup.Selector)
		if !ok {
			return fmt.Errorf("startup recovery group %q is not a manual Selector", groupName)
		}
		if targetName == "COMPATIBLE" {
			return fmt.Errorf("startup recovery target COMPATIBLE is not allowed for selector %q", groupName)
		}

		candidateExists := false
		for _, candidate := range selector.Proxies() {
			if candidate.Name() == targetName {
				if candidate.Type() == C.Compatible {
					return fmt.Errorf("startup recovery target %q is COMPATIBLE for selector %q", targetName, groupName)
				}
				candidateExists = true
				break
			}
		}
		if !candidateExists {
			return fmt.Errorf("startup recovery target %q is not a current candidate for selector %q", targetName, groupName)
		}
		if err := selector.SetRecoverySelection(targetName, tunnel.Proxies()["REJECT"]); err != nil {
			return fmt.Errorf("set startup recovery selector %q to %q: %w", groupName, targetName, err)
		}
		if now := selector.Now(); now != targetName {
			return fmt.Errorf("startup recovery selector %q resolved to %q after selecting %q", groupName, now, targetName)
		}
	}
	return nil
}
'''


SELECTOR_IMPORTS = '''import (
	"context"
	"encoding/json"
	"errors"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)'''

PATCHED_SELECTOR_IMPORTS = '''import (
	"context"
	"encoding/json"
	"errors"
	"sync"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)'''

SELECTOR_FIELDS = '''type Selector struct {
	*GroupBase
	disableUDP bool
	selected   string
	testUrl    string
}'''

PATCHED_SELECTOR_FIELDS = '''type Selector struct {
	*GroupBase
	disableUDP       bool
	selectionMu      sync.RWMutex
	selected         string
	selectedFallback C.Proxy
	testUrl          string
}'''

SELECTOR_METHODS = '''func (s *Selector) Now() string {
	return s.selectedProxy(false).Name()
}

func (s *Selector) Set(name string) error {
	for _, proxy := range s.GetProxies(false) {
		if proxy.Name() == name {
			s.selected = name
			return nil
		}
	}

	return errors.New("proxy not exist")
}

func (s *Selector) ForceSet(name string) {
	s.selected = name
}

// Unwrap implements C.ProxyAdapter
func (s *Selector) Unwrap(metadata *C.Metadata, touch bool) C.Proxy {
	return s.selectedProxy(touch)
}

func (s *Selector) selectedProxy(touch bool) C.Proxy {
	proxies := s.GetProxies(touch)
	for _, proxy := range proxies {
		if proxy.Name() == s.selected {
			return proxy
		}
	}

	return proxies[0]
}'''

PATCHED_SELECTOR_METHODS = '''func (s *Selector) Now() string {
	return s.selectedProxy(false).Name()
}

func (s *Selector) Set(name string) error {
	for _, proxy := range s.GetProxies(false) {
		if proxy.Name() == name {
			s.selectionMu.Lock()
			s.selected = name
			s.selectionMu.Unlock()
			return nil
		}
	}

	return errors.New("proxy not exist")
}

// SetRecoverySelection pins a recovery choice and rejects if its provider
// candidate disappears before the application reads the selected path.
func (s *Selector) SetRecoverySelection(name string, fallback C.Proxy) error {
	if fallback == nil || fallback.Type() != C.Reject {
		return errors.New("recovery fallback must be a reject proxy")
	}

	for _, proxy := range s.GetProxies(false) {
		if proxy.Name() == name {
			s.selectionMu.Lock()
			s.selected = name
			s.selectedFallback = fallback
			s.selectionMu.Unlock()
			return nil
		}
	}

	return errors.New("proxy not exist")
}

func (s *Selector) ForceSet(name string) {
	s.selectionMu.Lock()
	s.selected = name
	s.selectionMu.Unlock()
}

// Unwrap implements C.ProxyAdapter
func (s *Selector) Unwrap(metadata *C.Metadata, touch bool) C.Proxy {
	return s.selectedProxy(touch)
}

func (s *Selector) selectedProxy(touch bool) C.Proxy {
	s.selectionMu.RLock()
	selected := s.selected
	fallback := s.selectedFallback
	s.selectionMu.RUnlock()

	proxies := s.GetProxies(touch)
	for _, proxy := range proxies {
		if proxy.Name() == selected {
			return proxy
		}
	}
	if fallback != nil {
		return fallback
	}

	return proxies[0]
}'''


def patch_startup_selection_overlay(mihomo_root: pathlib.Path) -> None:
    """Install a one-shot, fail-closed selection hook in the pinned apply path."""
    _patch_selector_recovery_selection(mihomo_root)

    executor_path = pathlib.Path(mihomo_root) / "hub" / "executor" / "executor.go"
    source = executor_path.read_text(encoding="utf-8")

    source = _replace_once(
        source,
        "var mux sync.Mutex\n",
        "var mux sync.Mutex\n" + STARTUP_SELECTION_STATE,
        "one-shot selection state",
    )
    source = _replace_once(
        source,
        "\tapplyConfig(cfg, force)\n}\n\nfunc applyConfig(cfg *config.Config, force bool) {",
        "\tif err := applyConfig(cfg, force, nil); err != nil {\n"
        '\t\tlog.Errorln("Apply config error: %s", err.Error())\n'
        "\t}\n}\n\nfunc applyConfig(cfg *config.Config, force bool, recoverySelections map[string]string) error {",
        "preserve ordinary apply semantics",
    )
    source = _replace_once(
        source,
        "\tapplyConfig(cfg, force)\n\treturn validateRuntimeListeners(cfg, force)",
        "\tif err := applyConfig(cfg, force, takeStartupRecoverySelections()); err != nil {\n"
        "\t\treturn err\n"
        "\t}\n\treturn validateRuntimeListeners(cfg, force)",
        "propagate guarded apply error",
    )
    source = _replace_once(
        source,
        "\tloadProvider(cfg.RuleProviders)\n\truntime.GC()\n\ttunnel.OnRunning()",
        "\tloadProvider(cfg.RuleProviders)\n"
        "\tif len(recoverySelections) > 0 {\n"
        "\t\tif err := applyStartupRecoverySelections(recoverySelections); err != nil {\n"
        "\t\t\treturn err\n"
        "\t\t}\n"
        "\t}\n"
        "\truntime.GC()\n\ttunnel.OnRunning()",
        "apply before tunnel running",
    )
    source = _replace_once(
        source,
        "\tresolver.ResetConnection()\n}\n\nfunc ApplyConfigAndValidate",
        "\tresolver.ResetConnection()\n\treturn nil\n}\n\n"
        + STARTUP_SELECTION_APPLIER
        + "\nfunc ApplyConfigAndValidate",
        "return startup apply result",
    )

    formatted = subprocess.check_output(["gofmt"], input=source, text=True)
    os.chmod(executor_path, executor_path.stat().st_mode | stat.S_IWUSR)
    executor_path.write_text(formatted, encoding="utf-8")


def _patch_selector_recovery_selection(mihomo_root: pathlib.Path) -> None:
    selector_path = pathlib.Path(mihomo_root) / "adapter" / "outboundgroup" / "selector.go"
    source = selector_path.read_text(encoding="utf-8")
    digest = hashlib.sha256(source.encode("utf-8")).hexdigest()
    if digest != EXPECTED_SELECTOR_SOURCE_SHA256:
        raise RuntimeError(
            "Review the ClashFX selector recovery overlay before updating Mihomo: "
            f"expected selector SHA-256 {EXPECTED_SELECTOR_SOURCE_SHA256}, found {digest}"
        )

    source = _replace_once(source, SELECTOR_IMPORTS, PATCHED_SELECTOR_IMPORTS, "selector sync import")
    source = _replace_once(source, SELECTOR_FIELDS, PATCHED_SELECTOR_FIELDS, "selector selection state")
    source = _replace_once(source, SELECTOR_METHODS, PATCHED_SELECTOR_METHODS, "selector selection methods")
    formatted = subprocess.check_output(["gofmt"], input=source, text=True)
    os.chmod(selector_path, selector_path.stat().st_mode | stat.S_IWUSR)
    selector_path.write_text(formatted, encoding="utf-8")
    _install_selector_recovery_tests(mihomo_root)


def _install_selector_recovery_tests(mihomo_root: pathlib.Path) -> None:
    test_path = pathlib.Path(mihomo_root) / "adapter" / "outboundgroup" / "selector_recovery_overlay_test.go"
    if test_path.exists():
        raise RuntimeError(f"Unexpected selector recovery overlay test already exists: {test_path}")

    os.chmod(test_path.parent, test_path.parent.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    test_path.write_text(SELECTOR_RECOVERY_TESTS, encoding="utf-8")


SELECTOR_RECOVERY_TESTS = r'''package outboundgroup

import (
	"context"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type selectorRecoveryTestProvider struct {
	P.ProxyProvider
	mu      sync.RWMutex
	proxies []C.Proxy
	version uint32
}

func newSelectorRecoveryTestProvider(proxies ...C.Proxy) *selectorRecoveryTestProvider {
	return &selectorRecoveryTestProvider{proxies: append([]C.Proxy(nil), proxies...), version: 1}
}

func (p *selectorRecoveryTestProvider) Proxies() []C.Proxy {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return append([]C.Proxy(nil), p.proxies...)
}

func (p *selectorRecoveryTestProvider) Version() uint32 {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.version
}

func (p *selectorRecoveryTestProvider) Touch() {}

func (p *selectorRecoveryTestProvider) replace(proxies ...C.Proxy) {
	p.mu.Lock()
	p.proxies = append([]C.Proxy(nil), proxies...)
	p.version++
	p.mu.Unlock()
}

func selectorRecoveryTestProxy(name string) C.Proxy {
	return adapter.NewProxy(outbound.NewRejectWithOption(outbound.RejectOption{Name: name}))
}

func newSelectorRecoveryTestSelector(provider P.ProxyProvider) *Selector {
	return NewSelector(&GroupCommonOption{Name: "RECOVERY"}, []P.ProxyProvider{provider})
}

func TestSelectorRecoverySelectionFailsClosedForRemovedProviderCandidate(t *testing.T) {
	direct := selectorRecoveryTestProxy("DIRECT")
	node := selectorRecoveryTestProxy("Node")
	other := selectorRecoveryTestProxy("Other")
	reject := selectorRecoveryTestProxy("REJECT")
	provider := newSelectorRecoveryTestProvider(direct, node)
	selector := newSelectorRecoveryTestSelector(provider)

	if err := selector.SetRecoverySelection("Node", reject); err != nil {
		t.Fatalf("guard Node: %v", err)
	}
	if got := selector.Now(); got != "Node" {
		t.Fatalf("initial selected path=%q, want Node", got)
	}

	provider.replace(direct, other)
	if got := selector.Now(); got != "REJECT" {
		t.Fatalf("removed selected path=%q, want REJECT", got)
	}
	if got := selector.Unwrap(nil, false).Name(); got != "REJECT" {
		t.Fatalf("removed selected proxy=%q, want REJECT", got)
	}

	provider.replace(direct, node, other)
	if got := selector.Now(); got != "Node" {
		t.Fatalf("reinserted selected path=%q, want Node", got)
	}
	if err := selector.Set("DIRECT"); err != nil {
		t.Fatalf("explicit DIRECT: %v", err)
	}
	if got := selector.Now(); got != "DIRECT" {
		t.Fatalf("explicit selection=%q, want DIRECT", got)
	}
	if err := selector.Set("Other"); err != nil {
		t.Fatalf("explicit Other: %v", err)
	}
	provider.replace(direct)
	if got := selector.Now(); got != "REJECT" {
		t.Fatalf("removed ordinary Set selection=%q, want retained REJECT guard", got)
	}

	provider.replace(direct, node)
	if err := selector.Set("Node"); err != nil {
		t.Fatalf("reselect Node after reinsertion: %v", err)
	}
	provider.replace(direct)
	if got := selector.Now(); got != "REJECT" {
		t.Fatalf("reselected provider candidate fallback=%q, want REJECT", got)
	}
}

func TestSelectorRecoverySelectionRequiresRejectFallback(t *testing.T) {
	direct := adapter.NewProxy(outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"}))
	node := selectorRecoveryTestProxy("Node")
	provider := newSelectorRecoveryTestProvider(direct, node)
	selector := newSelectorRecoveryTestSelector(provider)

	if err := selector.SetRecoverySelection("Node", direct); err == nil {
		t.Fatal("recovery selection accepted a non-Reject fallback")
	}
	if err := selector.SetRecoverySelection("Missing", selectorRecoveryTestProxy("REJECT")); err == nil {
		t.Fatal("recovery selection accepted a missing candidate")
	}
}

func TestSelectorUnprotectedMissingSelectionKeepsDefaultFallback(t *testing.T) {
	direct := selectorRecoveryTestProxy("DIRECT")
	node := selectorRecoveryTestProxy("Node")
	provider := newSelectorRecoveryTestProvider(direct, node)
	selector := newSelectorRecoveryTestSelector(provider)

	selector.ForceSet("Missing")
	if got := selector.Now(); got != "DIRECT" {
		t.Fatalf("unprotected missing selection=%q, want default DIRECT", got)
	}
}

func TestSelectorConcurrentSetForceSetNowAndDialMetadata(t *testing.T) {
	first := selectorRecoveryTestProxy("First")
	second := selectorRecoveryTestProxy("Second")
	provider := newSelectorRecoveryTestProvider(first, second)
	selector := newSelectorRecoveryTestSelector(provider)
	if err := selector.Set("First"); err != nil {
		t.Fatal(err)
	}

	var workers sync.WaitGroup
	workers.Add(4)
	go func() {
		defer workers.Done()
		for index := 0; index < 4000; index++ {
			name := "First"
			if index%2 != 0 {
				name = "Second"
			}
			if err := selector.Set(name); err != nil {
				t.Errorf("Set(%q): %v", name, err)
			}
		}
	}()
	go func() {
		defer workers.Done()
		for index := 0; index < 4000; index++ {
			name := "First"
			if index%2 != 0 {
				name = "Second"
			}
			selector.ForceSet(name)
		}
	}()
	go func() {
		defer workers.Done()
		for index := 0; index < 4000; index++ {
			if got := selector.Now(); got != "First" && got != "Second" {
				t.Errorf("Now()=%q, want a current candidate", got)
				return
			}
		}
	}()
	go func() {
		defer workers.Done()
		for index := 0; index < 4000; index++ {
			conn, err := selector.DialContext(context.Background(), &C.Metadata{})
			if err != nil {
				t.Errorf("DialContext with private Reject candidate: %v", err)
				return
			}
			if err := conn.Close(); err != nil {
				t.Errorf("close private Reject connection: %v", err)
				return
			}
		}
	}()
	workers.Wait()
}
'''
