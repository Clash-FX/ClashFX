package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/metacubex/mihomo/log"
	"github.com/phayes/freeport"
)

// enhancedConfigPortPlan is supplied by the parent process. An owned plan is
// authoritative only when that process has independently established that it
// is reloading the same running core.
type enhancedConfigPortPlan struct {
	APIPort int  `json:"apiPort"`
	DNSPort int  `json:"dnsPort"`
	Owned   bool `json:"owned"`
}

func decodeEnhancedConfigPortPlan(raw string) (*enhancedConfigPortPlan, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	var plan enhancedConfigPortPlan
	if err := decoder.Decode(&plan); err != nil {
		return nil, fmt.Errorf("invalid enhanced config port plan: %w", err)
	}
	if err := decoder.Decode(new(interface{})); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("invalid enhanced config port plan: trailing JSON value")
		}
		return nil, fmt.Errorf("invalid enhanced config port plan: %w", err)
	}
	return &plan, nil
}

// selectEnhancedConfigPorts chooses API and DNS endpoints without changing
// proxy fields. A nil plan preserves the historic random-allocation policy.
func selectEnhancedConfigPorts(rawMap, dns map[string]interface{}, plan *enhancedConfigPortPlan,
	apiAvailable, dnsAvailable func(int) bool, freePort func() (int, error)) (int, int, error) {
	if apiAvailable == nil {
		apiAvailable = checkLoopbackTCPPortAvailable
	}
	if dnsAvailable == nil {
		dnsAvailable = checkDNSPortAvailable
	}
	if freePort == nil {
		freePort = freeport.GetFreePort
	}

	if plan == nil {
		return selectLegacyEnhancedConfigPorts(rawMap, dns, apiAvailable, dnsAvailable, freePort)
	}
	if plan.Owned {
		return selectOwnedEnhancedConfigPorts(rawMap, dns, plan)
	}
	return selectPreferredEnhancedConfigPorts(rawMap, dns, plan, apiAvailable, dnsAvailable, freePort)
}

func selectLegacyEnhancedConfigPorts(rawMap, dns map[string]interface{}, apiAvailable, dnsAvailable func(int) bool, freePort func() (int, error)) (int, int, error) {
	controllerReservedPorts := enhancedControllerReservedPorts(rawMap, "127.0.0.1")
	apiPort := enhancedControllerPort
	if containsInt(controllerReservedPorts, apiPort) || !apiAvailable(apiPort) {
		port, err := freePort()
		if err != nil || containsInt(controllerReservedPorts, port) || !apiAvailable(port) {
			conflict := portConflictError{service: "api_listener", address: "127.0.0.1", port: enhancedControllerPort, reason: "fallback_unavailable"}
			log.Errorln("%v", conflict)
			return 0, 0, conflict
		}
		apiPort = port
	}
	if err := setEnhancedControllerPort(rawMap, apiPort); err != nil {
		return 0, 0, err
	}
	reservedDNSPorts := enhancedDNSReservedPorts(rawMap)
	if err := alignEnhancedDNSListenWithReserved(dns, reservedDNSPorts, dnsAvailable, freePort, rawMap); err != nil {
		return 0, 0, err
	}
	rawMap["dns"] = dns
	_, dnsPort, ok := dnsServerAddress(fmt.Sprint(dns["listen"]))
	if !ok {
		return 0, 0, fmt.Errorf("invalid selected DNS listener %v", dns["listen"])
	}
	if err := validateEnhancedListenerPortConflictsWithDNS(rawMap, dnsPort); err != nil {
		return 0, 0, err
	}
	return apiPort, dnsPort, nil
}

func selectOwnedEnhancedConfigPorts(rawMap, dns map[string]interface{}, plan *enhancedConfigPortPlan) (int, int, error) {
	if !validRuntimePort(plan.APIPort) {
		return 0, 0, portConflictError{service: "api_listener", address: "127.0.0.1", port: plan.APIPort, reason: "invalid_owned_port"}
	}
	if !validRuntimePort(plan.DNSPort) {
		return 0, 0, portConflictError{service: "dns_listener", address: "127.0.0.1", port: plan.DNSPort, reason: "invalid_owned_port"}
	}
	if err := setEnhancedControllerPort(rawMap, plan.APIPort); err != nil {
		return 0, 0, err
	}
	reservedDNSPorts := enhancedDNSReservedPorts(rawMap)
	if err := retargetEnhancedDNSListen(dns, plan.DNSPort, reservedDNSPorts...); err != nil {
		return 0, 0, err
	}
	rawMap["dns"] = dns
	if err := validateEnhancedListenerPortConflictsWithDNS(rawMap, plan.DNSPort); err != nil {
		return 0, 0, err
	}
	return plan.APIPort, plan.DNSPort, nil
}

func selectPreferredEnhancedConfigPorts(rawMap, dns map[string]interface{}, plan *enhancedConfigPortPlan,
	apiAvailable, dnsAvailable func(int) bool, freePort func() (int, error)) (int, int, error) {
	controllerReservedPorts := enhancedControllerReservedPorts(rawMap, "127.0.0.1")
	apiPort, err := chooseAvailableRuntimePort([]int{plan.APIPort, enhancedControllerPort}, controllerReservedPorts, apiAvailable, freePort)
	if err != nil {
		return 0, 0, portConflictError{service: "api_listener", address: "127.0.0.1", port: plan.APIPort, reason: "fallback_unavailable"}
	}
	if err := setEnhancedControllerPort(rawMap, apiPort); err != nil {
		return 0, 0, err
	}
	reservedDNSPorts := enhancedDNSReservedPorts(rawMap)
	dnsPort, err := chooseAvailableEnhancedDNSPort(dns, plan.DNSPort, reservedDNSPorts, dnsAvailable, freePort, rawMap)
	if err != nil {
		return 0, 0, err
	}
	if err := retargetEnhancedDNSListen(dns, dnsPort, reservedDNSPorts...); err != nil {
		return 0, 0, err
	}
	rawMap["dns"] = dns
	if err := validateEnhancedListenerPortConflictsWithDNS(rawMap, dnsPort); err != nil {
		return 0, 0, err
	}
	return apiPort, dnsPort, nil
}

func chooseAvailableRuntimePort(preferred []int, reserved []int, available func(int) bool, freePort func() (int, error)) (int, error) {
	seen := make(map[int]struct{}, len(preferred)+1)
	try := func(port int) bool {
		if !validRuntimePort(port) || containsInt(reserved, port) {
			return false
		}
		if _, ok := seen[port]; ok {
			return false
		}
		seen[port] = struct{}{}
		return available(port)
	}
	for _, port := range preferred {
		if try(port) {
			return port, nil
		}
	}
	port, err := freePort()
	if err == nil && try(port) {
		return port, nil
	}
	return 0, fmt.Errorf("no available runtime port")
}

func chooseAvailableEnhancedDNSPort(dns map[string]interface{}, preferred int, reserved []int,
	available func(int) bool, freePort func() (int, error), topology ...map[string]interface{}) (int, error) {
	references := declaredProxyDNSBootstrapReferences(dns)
	if err := validateEnhancedDNSSourceCycle(dns, reserved, references, available, topology...); err != nil {
		return 0, err
	}
	seen := make(map[int]struct{}, 4)
	try := func(port int) bool {
		if !validRuntimePort(port) || containsInt(reserved, port) {
			return false
		}
		if _, ok := seen[port]; ok {
			return false
		}
		seen[port] = struct{}{}
		if dnsHasReferenceAtPort(dns, port, references) || !available(port) {
			return false
		}
		return true
	}
	for _, port := range []int{preferred, preferredEnhancedDNSPort} {
		if try(port) {
			return port, nil
		}
	}
	if port, err := freePort(); err == nil && try(port) {
		return port, nil
	}
	if try(11053) {
		return 11053, nil
	}
	return 0, portConflictError{service: "dns_listener", address: "127.0.0.1", port: preferred, reason: "fallbacks_exhausted"}
}

func setEnhancedControllerPort(rawMap map[string]interface{}, port int) error {
	if !validRuntimePort(port) {
		return portConflictError{service: "api_listener", address: "127.0.0.1", port: port, reason: "invalid_port"}
	}
	rawMap["external-controller"] = fmt.Sprintf("127.0.0.1:%d", port)
	return nil
}

func validateEnhancedListenerPortConflictsWithDNS(rawMap map[string]interface{}, dnsPort int) error {
	return validateEnhancedListenerPortConflicts(rawMap, dnsPort)
}

func validRuntimePort(port int) bool { return port >= 1 && port <= 65535 }

type submittedConfigSnapshot struct {
	value atomic.Value // stores []byte; nil means no successful apply has been recorded.
}

var lastSubmittedConfig submittedConfigSnapshot

var errConfigUpdateCancelled = errors.New("cancelled: configuration update superseded by core lifecycle change")
var errCoreLifecycleCancelled = errors.New("cancelled: core lifecycle mutation superseded by a newer lifecycle change")
var errCoreSuspended = errors.New("cancelled: core is suspended")

var coreMutationMu sync.Mutex

func withCoreMutation(mutate func() error) error {
	coreMutationMu.Lock()
	defer coreMutationMu.Unlock()
	return mutate()
}

func applyConfigUpdateIfCurrent(epoch uint64, apply func() error) error {
	return applyActiveConfigUpdate(currentCacheDBLifecycle(), epoch, apply)
}

func applyActiveConfigUpdate(lifecycle *cacheDBLifecycle, epoch uint64, apply func() error) error {
	return lifecycle.withActive(func() error {
		return applyConfigUpdateForLifecycle(lifecycle, epoch, apply)
	})
}

func applyConfigUpdateForLifecycle(lifecycle *cacheDBLifecycle, epoch uint64, apply func() error) error {
	return withCoreMutation(func() error {
		if configUpdateEpoch.Load() != epoch {
			return errConfigUpdateCancelled
		}
		if lifecycle.isSuspended() {
			return errCoreSuspended
		}
		return apply()
	})
}

func applyAndRecordSubmittedConfig(snapshot *submittedConfigSnapshot, raw []byte, apply func() error) error {
	if err := apply(); err != nil {
		return err
	}
	snapshot.value.Store(append([]byte(nil), raw...))
	return nil
}

func (snapshot *submittedConfigSnapshot) bytes() []byte {
	value := snapshot.value.Load()
	if value == nil {
		return nil
	}
	raw, ok := value.([]byte)
	if !ok {
		return nil
	}
	return append([]byte(nil), raw...)
}
