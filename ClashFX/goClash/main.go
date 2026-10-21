package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework Foundation
#import <Foundation/Foundation.h>
#import "UIHelper.h"
*/
import "C"

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	mihomoDNS "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/oschwald/geoip2-golang"
	"github.com/phayes/freeport"
	"gopkg.in/yaml.v3"
)

var (
	secretOverride     string = ""
	enableIPV6         bool   = false
	tunEnabled         bool   = false
	tunRouteExcludeRaw string = ""
	// tunMTUValue: 0 means use defaultTunMTU. Deviates from mihomo's upstream
	// default of 9000 because macOS utun slot size is 4096 (XNU UTUN_IF_MAX_SLOT_SIZE)
	// and sing-tun/gvisor have known bugs at high MTU (sing-tun #1168, gvisor #9922,
	// gvisor PR #12634). See ClashFX docs for full rationale.
	tunMTUValue uint32 = 0
	// tunInterfaceName: empty preserves auto-detect. Non-empty pins the WAN interface
	// and forces auto-detect OFF (mihomo issue #1011: macOS sleep/wake -> lo0 loopback).
	tunInterfaceName  string = ""
	tunMu             sync.Mutex
	savedUIPath       string
	callbacksPaused   int32        // atomic: 0=active, 1=paused
	userTunStackRaw   atomic.Value // string; race-free across config reload vs enhanced-mode toggle
	configUpdateEpoch atomic.Uint64
)

const defaultTunMTU uint32 = 1500
const enhancedControllerPort = 19090

var enhancedCoreProcessDirectRules = []string{
	"PROCESS-NAME,ClashFX Networking,DIRECT",
	"PROCESS-NAME,mihomo,DIRECT",
	"PROCESS-NAME,mihomo-bin,DIRECT",
	"PROCESS-NAME,mihomo_core,DIRECT",
}

func isAddrValid(addr string) bool {
	if addr != "" {
		comps := strings.Split(addr, ":")
		v := comps[len(comps)-1]
		if port, err := strconv.Atoi(v); err == nil {
			if port > 0 && port <= 65535 {
				return checkPortAvailable(port)
			}
		}
	}
	return false
}

func checkPortAvailable(port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	addr := ":"
	l, err := net.Listen("tcp", addr+strconv.Itoa(port))
	if err != nil {
		log.Warnln("check port fail 0.0.0.0:%d", port)
		return false
	}
	_ = l.Close()

	addr = "127.0.0.1:"
	l, err = net.Listen("tcp", addr+strconv.Itoa(port))
	if err != nil {
		log.Warnln("check port fail 127.0.0.1:%d", port)
		return false
	}
	_ = l.Close()
	log.Infoln("check port %d success", port)
	return true
}

// Mixed proxy startup needs both transports; API controllers remain TCP-only.
func checkMixedPortAvailable(port int) bool {
	return checkMixedPortAvailableAt(port, true, "*")
}

// Probe exactly the same binding as Mihomo's global mixed listener. A
// loopback-only core must not be rejected by an unrelated IPv6/LAN listener.
func checkMixedPortAvailableAt(port int, allowLan bool, bindAddress string) bool {
	if port < 1 || port > 65535 {
		return false
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if allowLan {
		if bindAddress == "*" {
			address = ":" + strconv.Itoa(port)
		} else {
			address = fmt.Sprintf("%s:%d", bindAddress, port)
		}
	}
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	defer tcp.Close()
	udp, err := net.ListenPacket("udp", address)
	if err != nil {
		return false
	}
	defer udp.Close()
	return true
}

func checkLoopbackTCPPortAvailable(port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Warnln("check loopback TCP port fail %s: %v", address, err)
		return false
	}
	_ = listener.Close()
	return true
}

const preferredEnhancedDNSPort = 7874

func alignEnhancedDNSListen(dns map[string]interface{}, reservedPorts ...int) error {
	return alignEnhancedDNSListenWithReserved(dns, reservedPorts, checkDNSPortAvailable, freeport.GetFreePort)
}

func checkDNSPortAvailable(port int) bool {
	if port < 1 || port > 65535 {
		return false
	}
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	tcp, err := net.Listen("tcp", address)
	if err != nil {
		log.Warnln("dns_listener_probe address=127.0.0.1 port=%d transport=tcp result=unavailable error=%v", port, err)
		return false
	}
	_ = tcp.Close()
	udp, err := net.ListenPacket("udp", address)
	if err != nil {
		log.Warnln("dns_listener_probe address=127.0.0.1 port=%d transport=udp result=unavailable error=%v", port, err)
		return false
	}
	_ = udp.Close()
	log.Infoln("dns_listener_probe address=127.0.0.1 port=%d result=available transports=tcp,udp", port)
	return true
}

func alignEnhancedDNSListenWith(dns map[string]interface{}, available func(int) bool, freePort func() (int, error)) error {
	return alignEnhancedDNSListenWithReserved(dns, nil, available, freePort)
}

func alignEnhancedDNSListenWithReserved(dns map[string]interface{}, reservedPorts []int, available func(int) bool, freePort func() (int, error), topology ...map[string]interface{}) error {
	bootstrapReferences := declaredProxyDNSBootstrapReferences(dns)
	chosen, err := chooseEnhancedDNSPortWithBootstrap(dns, reservedPorts, bootstrapReferences, available, freePort, topology...)
	if err != nil {
		log.Errorln("%v", err)
		return err
	}
	return retargetEnhancedDNSListen(dns, chosen, reservedPorts...)
}

func chooseEnhancedDNSPort(dns map[string]interface{}, reservedPorts []int, available func(int) bool, freePort func() (int, error)) (int, error) {
	return chooseEnhancedDNSPortWithBootstrap(dns, reservedPorts, declaredProxyDNSBootstrapReferences(dns), available, freePort)
}

// Keep source-cycle validation identical for cold startup and persisted-port
// preferences. Moving the listener must not turn a known self-cycle into a
// dangling resolver. An occupied source may be an independent local resolver;
// preserve that supported case rather than rewriting or rejecting it.
func validateEnhancedDNSSourceCycle(dns map[string]interface{}, reserved []int, bootstrapReferences []dnsBootstrapReference, available func(int) bool, topology ...map[string]interface{}) error {
	listen, ok := dns["listen"].(string)
	if !ok {
		return nil
	}
	host, port, valid := enhancedDNSListenAddress(listen)
	// Generated listeners bind IPv4 loopback. IPv6 and non-loopback source
	// resolvers remain independent endpoints after projection; probing their
	// numeric port on IPv4 cannot establish ownership or a self-cycle.
	if !valid || !dnsBootstrapHostsMatch(host, "127.0.0.1") {
		return nil
	}
	if dnsHasGeneralSelfReference(dns, host, port, bootstrapReferences) {
		conflict := containsInt(reserved, port)
		if len(topology) > 0 {
			// Allocation reserves both DNS transports, but a source resolver
			// only conflicts with an actual endpoint of its own transport.
			conflict = enhancedDNSSourceResolverConflicts(dns, topology[0], bootstrapReferences)
		}
		if conflict || available(port) {
			return fmt.Errorf("[dns_self_cycle] address=%s port=%d", host, port)
		}
	}
	return nil
}

func chooseEnhancedDNSPortWithBootstrap(dns map[string]interface{}, reservedPorts []int, bootstrapReferences []dnsBootstrapReference, available func(int) bool, freePort func() (int, error), topology ...map[string]interface{}) (int, error) {
	// The preferred port and the two fallback probes keep selection bounded.
	// 7874 is the runtime default. Only a plain proxy-server-nameserver entry
	// that matches dns.listen (including its IPv4 aliases) is a bootstrap path.
	candidates := []int{preferredEnhancedDNSPort}
	seen := make(map[int]struct{}, 3)
	reserved := make(map[int]struct{}, len(reservedPorts))
	for _, port := range reservedPorts {
		if port > 0 && port <= 65535 {
			reserved[port] = struct{}{}
		}
	}
	cyclePorts := make([]int, 0, len(candidates))
	if err := validateEnhancedDNSSourceCycle(dns, reservedPorts, bootstrapReferences, available, topology...); err != nil {
		return 0, err
	}
	tryCandidate := func(port int) bool {
		if port < 1 || port > 65535 {
			return false
		}
		if _, duplicate := seen[port]; duplicate {
			return false
		}
		seen[port] = struct{}{}
		if validateEnhancedDNSListenerPort(port, reservedPorts) != nil {
			return false
		}
		if dnsHasReferenceAtPort(dns, port, bootstrapReferences) {
			if available(port) {
				cyclePorts = append(cyclePorts, port)
			}
			return false
		}
		if available(port) {
			return true
		}
		return false
	}
	for _, port := range candidates {
		if tryCandidate(port) {
			return port, nil
		}
	}
	if port, err := freePort(); err == nil {
		if tryCandidate(port) {
			return port, nil
		}
	}
	if tryCandidate(11053) {
		return 11053, nil
	}
	if len(cyclePorts) > 0 {
		return 0, fmt.Errorf("[dns_self_cycle] address=127.0.0.1 port=%d", cyclePorts[len(cyclePorts)-1])
	}
	return 0, portConflictError{
		service: "dns_listener",
		address: "127.0.0.1",
		port:    preferredEnhancedDNSPort,
		reason:  "fallbacks_exhausted",
	}
}

type dnsResolverReference struct {
	DNSKey    string
	PolicyKey string
	Index     int
	Value     string
}

// dnsBootstrapReference is derived in memory from a plain resolver match
// to the profile's DNS listen endpoint or its IPv4 alias. No YAML field can assert this
// provenance on its own.
type dnsBootstrapReference struct {
	DNSKey          string
	PolicyKey       string
	Index           int
	Value           string
	SourceDNSListen string
}

// retargetEnhancedDNSListen is shared by startup alignment and reload. It only
// retargets proxy bootstrap resolvers whose provenance matches the current DNS
// listener, and rejects independent loopback resolvers that would collide with
// the requested listener port.
func validateEnhancedDNSListenerPort(port int, reservedPorts []int) error {
	if port < 1 || port > 65535 {
		return portConflictError{service: "dns_listener", address: "127.0.0.1", port: port, reason: "invalid_port"}
	}
	if containsInt(reservedPorts, port) {
		return portConflictError{service: "dns_listener", address: "127.0.0.1", port: port, reason: "reserved_listener"}
	}
	return nil
}

func retargetEnhancedDNSListen(dns map[string]interface{}, port int, reservedPorts ...int) error {
	if err := validateEnhancedDNSListenerPort(port, reservedPorts); err != nil {
		return err
	}
	if dns == nil {
		return fmt.Errorf("invalid DNS config: missing dns map")
	}
	listenValue, hasListen := dns["listen"]
	if hasListen && listenValue != nil {
		listen, ok := listenValue.(string)
		if !ok {
			return fmt.Errorf("invalid DNS config: invalid listen address %v", listenValue)
		}
		if strings.TrimSpace(listen) != "" {
			if _, _, ok := enhancedDNSListenAddress(listen); !ok {
				return fmt.Errorf("invalid DNS config: invalid listen address %q", listen)
			}
		}
	}
	bootstrapReferences := declaredProxyDNSBootstrapReferences(dns)
	if dnsHasReferenceAtPort(dns, port, bootstrapReferences) {
		return fmt.Errorf("[dns_self_cycle] address=127.0.0.1 port=%d", port)
	}
	sourceHostClass := "unspecified"
	sourcePort := 0
	if listen, ok := dns["listen"].(string); ok {
		if host, currentPort, valid := enhancedDNSListenAddress(listen); valid {
			sourceHostClass = "other"
			if host == "0.0.0.0" {
				sourceHostClass = "wildcard"
			} else if isLoopbackHost(host) {
				sourceHostClass = "loopback"
			}
			sourcePort = currentPort
		}
	}
	retargetedReferences := rewriteLoopbackDNSPorts(dns, port, bootstrapReferences...)
	dns["listen"] = net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	if sourceHostClass != "loopback" || sourcePort != port || retargetedReferences != 0 {
		log.Infoln("dns_listener_transition source_host_class=%s source_port=%d target_address=127.0.0.1 target_port=%d bootstrap_references_retargeted=%d",
			sourceHostClass, sourcePort, port, retargetedReferences)
	}
	return nil
}

func retargetEnhancedDNSConfigFile(configPath string, port int) error {
	if strings.TrimSpace(configPath) == "" {
		return fmt.Errorf("empty enhanced DNS config path")
	}
	if port < 1 || port > 65535 {
		return fmt.Errorf("[port_conflict] service=dns_listener address=127.0.0.1 port=%d reason=invalid_port", port)
	}
	fileInfo, err := os.Stat(configPath)
	if err != nil {
		return err
	}
	if !fileInfo.Mode().IsRegular() {
		return fmt.Errorf("enhanced DNS config is not a regular file")
	}
	contents, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	var rawMap map[string]interface{}
	if err := yaml.Unmarshal(contents, &rawMap); err != nil {
		return err
	}
	dns, ok := rawMap["dns"].(map[string]interface{})
	if !ok {
		return fmt.Errorf("invalid enhanced DNS config: missing dns map")
	}
	handledIPv6, err := retargetCustomIPv6DNSConfig(rawMap, dns, port)
	if err != nil {
		return err
	}
	if !handledIPv6 {
		if err := validateEnhancedListenerPortConflicts(rawMap, port); err != nil {
			return err
		}
		if err := retargetEnhancedDNSListen(dns, port, enhancedDNSReservedPorts(rawMap)...); err != nil {
			return err
		}
	}
	encoded, err := yaml.Marshal(rawMap)
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(configPath), ".clashfx-dns-retarget-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(fileInfo.Mode().Perm()); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.Write(encoded); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, configPath); err != nil {
		return err
	}
	return nil
}

// rewriteLoopbackDNSPorts only changes a reference when in-memory provenance
// records its profile listener, IPv4 alias and plain DNS transport. All other
// profile resolvers remain intact.
func rewriteLoopbackDNSPorts(dns map[string]interface{}, port int, bootstrapReferences ...dnsBootstrapReference) int {
	if port < 1 || port > 65535 {
		return 0
	}
	listen, ok := dns["listen"].(string)
	if !ok {
		return 0
	}
	listenHost, listenPort, ok := enhancedDNSListenAddress(listen)
	if !ok {
		return 0
	}
	retargeted := 0
	for _, reference := range bootstrapReferences {
		if reference.SourceDNSListen != listen || reference.Value == "" {
			continue
		}
		refHost, refPort, ok := dnsServerAddress(reference.Value)
		if !ok || !dnsBootstrapHostsMatch(listenHost, refHost) || refPort != listenPort || !isPlainDNSTransport(reference.Value) {
			continue
		}
		if reference.PolicyKey != "" {
			policy, ok := dns[reference.DNSKey].(map[string]interface{})
			if !ok {
				continue
			}
			value, exists := policy[reference.PolicyKey]
			if !exists {
				continue
			}
			if rewritten, changed := rewriteDNSReferenceAtIndex(value, reference.Index, reference.Value, listenPort, port); changed {
				policy[reference.PolicyKey] = rewritten
				retargeted++
			}
			continue
		}
		value, exists := dns[reference.DNSKey]
		if !exists {
			continue
		}
		if rewritten, changed := rewriteDNSReferenceAtIndex(value, reference.Index, reference.Value, listenPort, port); changed {
			dns[reference.DNSKey] = rewritten
			retargeted++
		}
	}
	return retargeted
}

func rewriteDNSReferenceAtIndex(value interface{}, index int, expected string, oldPort, newPort int) (interface{}, bool) {
	switch servers := value.(type) {
	case string:
		if index != -1 || servers != expected {
			return value, false
		}
		return retargetEnhancedBootstrapDNSServerAtPort(servers, oldPort, newPort), true
	case []string:
		if index < 0 || index >= len(servers) || servers[index] != expected {
			return value, false
		}
		rewritten := append([]string(nil), servers...)
		rewritten[index] = retargetEnhancedBootstrapDNSServerAtPort(rewritten[index], oldPort, newPort)
		return rewritten, true
	case []interface{}:
		if index < 0 || index >= len(servers) {
			return value, false
		}
		server, ok := servers[index].(string)
		if !ok || server != expected {
			return value, false
		}
		rewritten := append([]interface{}(nil), servers...)
		rewritten[index] = retargetEnhancedBootstrapDNSServerAtPort(server, oldPort, newPort)
		return rewritten, true
	default:
		return value, false
	}
}

func declaredProxyDNSBootstrapReferences(dns map[string]interface{}) []dnsBootstrapReference {
	listen, ok := dns["listen"].(string)
	if !ok {
		return nil
	}
	listenHost, listenPort, ok := enhancedDNSListenAddress(listen)
	if !ok {
		return nil
	}
	var references []dnsBootstrapReference
	for _, reference := range dnsResolverReferences(dns) {
		if reference.DNSKey != "proxy-server-nameserver" || !isPlainDNSTransport(reference.Value) {
			continue
		}
		serverHost, serverPort, ok := dnsServerAddress(reference.Value)
		if !ok || !dnsBootstrapHostsMatch(listenHost, serverHost) || serverPort != listenPort {
			continue
		}
		references = append(references, dnsBootstrapReference{
			DNSKey:          reference.DNSKey,
			PolicyKey:       reference.PolicyKey,
			Index:           reference.Index,
			Value:           reference.Value,
			SourceDNSListen: listen,
		})
	}
	return references
}

func enhancedDNSListenAddress(raw string) (string, int, bool) {
	listen := strings.TrimSpace(raw)
	if listen == "" || strings.Contains(listen, "://") || strings.ContainsAny(listen, "/?#@") {
		return "", 0, false
	}
	host, port, ok := dnsServerAddress(listen)
	if !ok {
		return "", 0, false
	}
	if host == "" {
		// Mihomo accepts :port as the all-IPv4-interfaces listener form.
		host = "0.0.0.0"
	}
	return host, port, true
}

func dnsBootstrapHostsMatch(listenHost, serverHost string) bool {
	listenHost = strings.ToLower(strings.Trim(listenHost, "[]"))
	serverHost = strings.ToLower(strings.Trim(serverHost, "[]"))
	if !isLoopbackHost(serverHost) {
		return false
	}
	// IPv4 wildcard listeners cover the IPv4 loopback resolver spellings, but
	// do not imply ownership of an independent IPv6 listener.
	return listenHost == "0.0.0.0" || isLoopbackHost(listenHost)
}

func isPlainDNSTransport(raw string) bool {
	server := strings.TrimSpace(raw)
	if server == "" {
		return false
	}
	if schemeEnd := strings.Index(server, "://"); schemeEnd >= 0 {
		scheme := strings.ToLower(server[:schemeEnd])
		if scheme != "udp" && scheme != "tcp" {
			return false
		}
		server = server[schemeEnd+3:]
	}
	if strings.ContainsAny(server, "/?#@") {
		return false
	}
	_, _, ok := dnsServerAddress(server)
	return ok
}

var dnsServerListKeys = []string{
	"nameserver",
	"default-nameserver",
	"fallback",
	"proxy-server-nameserver",
	"direct-nameserver",
}

var dnsServerPolicyKeys = []string{
	"nameserver-policy",
	"proxy-server-nameserver-policy",
}

func retargetEnhancedBootstrapDNSServerAtPort(raw string, ownedPort, port int) string {
	if ownedPort < 1 || ownedPort > 65535 || port < 1 || port > 65535 || !isPlainDNSTransport(raw) {
		return raw
	}
	trimmed := strings.TrimSpace(raw)
	host, currentPort, ok := dnsServerAddress(trimmed)
	if !ok || !isLoopbackHost(host) || currentPort != ownedPort {
		return raw
	}
	scheme := ""
	if i := strings.Index(trimmed, "://"); i >= 0 {
		scheme = trimmed[:i+3]
	}
	return scheme + net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
}

func dnsResolverReferences(dns map[string]interface{}) []dnsResolverReference {
	var references []dnsResolverReference
	appendValue := func(key, policyKey string, value interface{}) {
		switch servers := value.(type) {
		case string:
			references = append(references, dnsResolverReference{DNSKey: key, PolicyKey: policyKey, Index: -1, Value: servers})
		case []string:
			for i, server := range servers {
				references = append(references, dnsResolverReference{DNSKey: key, PolicyKey: policyKey, Index: i, Value: server})
			}
		case []interface{}:
			for i, raw := range servers {
				if server, ok := raw.(string); ok {
					references = append(references, dnsResolverReference{DNSKey: key, PolicyKey: policyKey, Index: i, Value: server})
				}
			}
		}
	}
	for _, key := range dnsServerListKeys {
		appendValue(key, "", dns[key])
	}
	for _, key := range dnsServerPolicyKeys {
		if policy, ok := dns[key].(map[string]interface{}); ok {
			for policyKey, value := range policy {
				appendValue(key, policyKey, value)
			}
		}
	}
	return references
}

func dnsHasReferenceAtPort(dns map[string]interface{}, port int, bootstrapReferences []dnsBootstrapReference) bool {
	for _, reference := range dnsResolverReferences(dns) {
		host, referencedPort, ok := dnsServerAddress(reference.Value)
		if !ok || !isLoopbackHost(host) || referencedPort != port || isDeclaredBootstrapReference(reference, bootstrapReferences) {
			continue
		}
		return true
	}
	return false
}

func enhancedDNSSourceResolverConflicts(dns, rawMap map[string]interface{}, bootstrapReferences []dnsBootstrapReference) bool {
	listen, _ := dns["listen"].(string)
	listenHost, listenPort, valid := enhancedDNSListenAddress(listen)
	if !valid {
		return false
	}
	planned := append(enhancedProxyListenerEndpoints(rawMap), enhancedControllerListenerEndpoints(rawMap, true)...)
	for _, ref := range dnsResolverReferences(dns) {
		if ref.DNSKey == "proxy-server-nameserver" || isDeclaredBootstrapReference(ref, bootstrapReferences) || !isPlainDNSTransport(ref.Value) {
			continue
		}
		host, port, ok := dnsServerAddress(ref.Value)
		sameHost := host == listenHost || (isLoopbackHost(host) && (listenHost == "0.0.0.0" || isLoopbackHost(listenHost)))
		if !ok || !sameHost || port != listenPort {
			continue
		}
		protocol := listenerUDP
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(ref.Value)), "tcp://") {
			protocol = listenerTCP
		}
		endpoint, ok := newListenerEndpoint(protocol, listenerFamilyGeneric, host, listenerPortRange{first: port, last: port}, "dns-source-resolver")
		if !ok {
			continue
		}
		for _, other := range planned {
			if listenerEndpointsOverlap(endpoint, other) {
				return true
			}
		}
	}
	return false
}

func dnsHasGeneralSelfReference(dns map[string]interface{}, listenHost string, listenPort int, bootstrapReferences []dnsBootstrapReference) bool {
	for _, reference := range dnsResolverReferences(dns) {
		if reference.DNSKey == "proxy-server-nameserver" || isDeclaredBootstrapReference(reference, bootstrapReferences) || !isPlainDNSTransport(reference.Value) {
			continue
		}
		host, port, ok := dnsServerAddress(reference.Value)
		// A wildcard IPv4 listener and the two loopback spellings share the
		// generated listener's address space. Do not let an alias hide a cycle.
		sameHost := host == listenHost ||
			(isLoopbackHost(host) && (listenHost == "0.0.0.0" || isLoopbackHost(listenHost)))
		if ok && sameHost && port == listenPort {
			return true
		}
	}
	return false
}

func isDeclaredBootstrapReference(reference dnsResolverReference, bootstrapReferences []dnsBootstrapReference) bool {
	for _, bootstrap := range bootstrapReferences {
		if reference.DNSKey == bootstrap.DNSKey && reference.PolicyKey == bootstrap.PolicyKey && reference.Index == bootstrap.Index && reference.Value == bootstrap.Value {
			return true
		}
	}
	return false
}

func loopbackDNSPort(raw string) (int, bool) {
	host, port, ok := dnsServerAddress(raw)
	if !ok || !isLoopbackHost(host) {
		return 0, false
	}
	return port, true
}

func dnsServerAddress(raw string) (string, int, bool) {
	rest := strings.TrimSpace(raw)
	if i := strings.Index(rest, "://"); i >= 0 {
		rest = rest[i+3:]
	}
	if suffix := strings.IndexAny(rest, "/?#"); suffix >= 0 {
		rest = rest[:suffix]
	}
	host, portText, err := net.SplitHostPort(rest)
	if err != nil {
		return "", 0, false
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return "", 0, false
	}
	return strings.Trim(host, "[]"), port, true
}

func isLoopbackHost(host string) bool {
	switch strings.Trim(strings.ToLower(host), "[]") {
	case "127.0.0.1", "localhost":
		return true
	default:
		// IPv4-mapped IPv6 is the same bind domain as IPv4 loopback;
		// native ::1 remains an independent resolver endpoint.
		ip := net.ParseIP(strings.Trim(host, "[]"))
		return ip != nil && ip.To4() != nil && ip.Equal(net.IPv4(127, 0, 0, 1))
	}
}

func containsInt(values []int, target int) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func configuredProxyListenerPorts(rawMap map[string]interface{}) []int {
	ports := make([]int, 0, 8)
	seen := make(map[int]struct{})
	add := func(value interface{}) {
		port := portValueOrZero(value)
		if port < 1 || port > 65535 {
			return
		}
		if _, exists := seen[port]; exists {
			return
		}
		seen[port] = struct{}{}
		ports = append(ports, port)
	}
	for _, key := range []string{"port", "socks-port", "mixed-port", "redir-port", "tproxy-port"} {
		add(rawMap[key])
	}
	if listeners, ok := rawMap["listeners"].([]interface{}); ok {
		for _, rawListener := range listeners {
			if listener, ok := rawListener.(map[string]interface{}); ok {
				add(listener["port"])
			}
		}
	}
	return ports
}

func enhancedControllerTCPPort(raw interface{}) int {
	address, ok := raw.(string)
	if !ok {
		return 0
	}
	_, portText, err := net.SplitHostPort(strings.TrimSpace(address))
	if err != nil {
		return 0
	}
	port := portValueOrZero(portText)
	if port < 1 || port > 65535 {
		return 0
	}
	return port
}

func mergeUniqueStrings(base []string, additions []string) []string {
	seen := make(map[string]struct{}, len(base)+len(additions))
	result := make([]string, 0, len(base)+len(additions))
	for _, item := range base {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		result = append(result, trimmed)
	}
	for _, item := range additions {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		if _, ok := seen[trimmed]; ok {
			continue
		}
		seen[trimmed] = struct{}{}
		result = append(result, trimmed)
	}
	return result
}

func parseEntryAsPrefix(s string) (netip.Prefix, bool) {
	if prefix, err := netip.ParsePrefix(s); err == nil {
		return prefix.Masked(), true
	}
	if ip, err := netip.ParseAddr(s); err == nil {
		bits := 32
		if ip.Is6() {
			bits = 128
		}
		return netip.PrefixFrom(ip, bits), true
	}
	if prefix, ok := legacyWildcardTunRouteExcludePrefix(s); ok {
		return prefix, true
	}
	return netip.Prefix{}, false
}

func legacyWildcardTunRouteExcludePrefix(s string) (netip.Prefix, bool) {
	switch s {
	case "10.*":
		prefix, _ := netip.ParsePrefix("10.0.0.0/8")
		return prefix, true
	case "192.168.*":
		prefix, _ := netip.ParsePrefix("192.168.0.0/16")
		return prefix, true
	}

	if !strings.HasPrefix(s, "172.") || !strings.HasSuffix(s, ".*") {
		return netip.Prefix{}, false
	}
	parts := strings.Split(s, ".")
	if len(parts) != 3 {
		return netip.Prefix{}, false
	}
	secondOctet, err := strconv.Atoi(parts[1])
	if err != nil || secondOctet < 16 || secondOctet > 31 {
		return netip.Prefix{}, false
	}
	prefix, _ := netip.ParsePrefix(fmt.Sprintf("172.%d.0.0/16", secondOctet))
	return prefix, true
}

func isTunFakeIPFilterEntry(s string) bool {
	if s == "" || strings.ContainsAny(s, " \t/") {
		return false
	}
	name := strings.TrimPrefix(strings.TrimPrefix(s, "*."), "+.")
	if name == "" {
		return false
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for _, r := range label {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' {
				continue
			}
			return false
		}
	}
	return true
}

func splitTunRouteExcludeEntries(raw string) ([]netip.Prefix, []string, []string) {
	var prefixes []netip.Prefix
	var domains []string
	var invalid []string

	for _, item := range strings.Split(raw, ",") {
		entry := strings.TrimSpace(item)
		if entry == "" {
			continue
		}
		if prefix, ok := parseEntryAsPrefix(entry); ok {
			prefixes = append(prefixes, prefix)
			continue
		}
		if isTunFakeIPFilterEntry(entry) {
			domains = append(domains, entry)
			continue
		}
		invalid = append(invalid, entry)
	}

	return prefixes, domains, invalid
}

func applyTunRouteExclusions(rawCfg *config.RawConfig) error {
	prefixes, domains, invalid := splitTunRouteExcludeEntries(tunRouteExcludeRaw)
	if len(invalid) > 0 {
		return fmt.Errorf("invalid TUN route exclude entries: %s", strings.Join(invalid, ", "))
	}
	if len(prefixes) > 0 {
		rawCfg.Tun.RouteExcludeAddress = mergeUniquePrefixes(rawCfg.Tun.RouteExcludeAddress, prefixes)
	}
	if len(domains) > 0 {
		rawCfg.DNS.FakeIPFilter = mergeUniqueStrings(rawCfg.DNS.FakeIPFilter, domains)
	}
	return nil
}

func mergeUniquePrefixes(base []netip.Prefix, additions []netip.Prefix) []netip.Prefix {
	seen := make(map[string]struct{}, len(base)+len(additions))
	result := make([]netip.Prefix, 0, len(base)+len(additions))
	for _, item := range base {
		key := item.Masked().String()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, item.Masked())
	}
	for _, item := range additions {
		masked := item.Masked()
		key := masked.String()
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, masked)
	}
	return result
}

func mergeInterfaceSlice(base interface{}, additions []string) []interface{} {
	var existing []string
	switch value := base.(type) {
	case []interface{}:
		for _, item := range value {
			if str, ok := item.(string); ok {
				existing = append(existing, str)
			}
		}
	case []string:
		existing = append(existing, value...)
	}
	merged := mergeUniqueStrings(existing, additions)
	result := make([]interface{}, 0, len(merged))
	for _, item := range merged {
		result = append(result, item)
	}
	return result
}

func prependUniqueRules(rawMap map[string]interface{}, additions []string) {
	existingRules, _ := rawMap["rules"].([]interface{})
	newRules := make([]interface{}, 0, len(existingRules)+len(additions))
	for _, rule := range additions {
		if !interfaceSliceContainsString(existingRules, rule) {
			newRules = append(newRules, rule)
		}
	}
	newRules = append(newRules, existingRules...)
	rawMap["rules"] = newRules
}

func interfaceSliceContainsString(items []interface{}, target string) bool {
	for _, item := range items {
		if rule, ok := item.(string); ok && rule == target {
			return true
		}
	}
	return false
}

func lockEnhancedLanBinding(rawMap map[string]interface{}) {
	if allowLan, _ := rawMap["allow-lan"].(bool); allowLan {
		return
	}
	rawMap["allow-lan"] = false
	rawMap["bind-address"] = "127.0.0.1"
}

// resolveTunStack returns a valid mihomo TUN stack string.
// It respects an explicit user choice (case-insensitive: system/gvisor/mixed)
// and falls back to "mixed" (ClashFX default) when empty or invalid.
func resolveTunStack(userValue string) string {
	switch strings.ToLower(strings.TrimSpace(userValue)) {
	case "system":
		return "system"
	case "gvisor":
		return "gvisor"
	case "mixed":
		return "mixed"
	default:
		return "mixed"
	}
}

func mergePrefixInterfaceSlice(base interface{}, additions []netip.Prefix) []interface{} {
	var existing []netip.Prefix
	switch value := base.(type) {
	case []interface{}:
		for _, item := range value {
			if str, ok := item.(string); ok {
				if prefix, ok := parseEntryAsPrefix(str); ok {
					existing = append(existing, prefix)
				}
			}
		}
	case []string:
		for _, item := range value {
			if prefix, ok := parseEntryAsPrefix(item); ok {
				existing = append(existing, prefix)
			}
		}
	case []netip.Prefix:
		existing = append(existing, value...)
	}
	merged := mergeUniquePrefixes(existing, additions)
	result := make([]interface{}, 0, len(merged))
	for _, item := range merged {
		result = append(result, item.String())
	}
	return result
}

// HTTP mutations capture the embedded core epoch before request-body decoding.
// Parsing and mutation then use the same cache/core fence as direct updates.
func installEmbeddedRuntimeMutationGate() {
	executor.SetRuntimeMutationGateFactory(func() func(func() error) error {
		epoch := configUpdateEpoch.Load()
		lifecycle := currentCacheDBLifecycle()
		return func(body func() error) error { return applyActiveConfigUpdate(lifecycle, epoch, body) }
	})
}

//export initClashCore
func initClashCore() {
	installEmbeddedRuntimeMutationGate()
	// Reserve at least one CPU core for the UI thread to prevent Go goroutines
	// from saturating all cores during heavy operations (config switch, health checks)
	numCPU := runtime.NumCPU()
	if numCPU > 2 {
		runtime.GOMAXPROCS(numCPU - 1)
	}

	homeDir, _ := os.UserHomeDir()
	clashHome := filepath.Join(homeDir, ".config", "clashfx")
	constant.SetHomeDir(clashHome)
	configFile := filepath.Join(constant.Path.HomeDir(), constant.Path.Config())
	constant.SetConfig(configFile)
}

func readConfig(path string) ([]byte, error) {
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("Configuration file %s is empty", path)
	}
	return data, err
}

func getRawCfg() (*config.RawConfig, error) {
	buf, err := readConfig(constant.Path.Config())
	if err != nil {
		return nil, err
	}
	userTunStackRaw.Store(extractRawTunStack(buf))
	return config.UnmarshalRawConfig(buf)
}

// extractRawTunStack reads tun.stack as a raw string from config bytes,
// returning "" when absent.
func extractRawTunStack(buf []byte) string {
	var probe map[string]interface{}
	if err := yaml.Unmarshal(buf, &probe); err != nil {
		return ""
	}
	tun, ok := probe["tun"].(map[string]interface{})
	if !ok {
		return ""
	}
	stack, _ := tun["stack"].(string)
	return stack
}

// loadUserTunStackRaw returns the last raw tun.stack string captured by getRawCfg.
func loadUserTunStackRaw() string {
	s, _ := userTunStackRaw.Load().(string)
	return s
}

func parseDefaultConfigThenStart(checkPort, allowLan, ipv6 bool, proxyPort uint32, externalController string, lifecycleEpoch uint64) (*config.Config, error) {
	rawCfg, err := getRawCfg()
	if err != nil {
		return nil, err
	}

	if proxyPort > 0 {
		rawCfg.MixedPort = int(proxyPort)
		if rawCfg.Port == rawCfg.MixedPort {
			rawCfg.Port = 0
		}
		if rawCfg.SocksPort == rawCfg.MixedPort {
			rawCfg.SocksPort = 0
		}
	} else {
		if rawCfg.MixedPort == 0 {
			if rawCfg.Port > 0 {
				rawCfg.MixedPort = rawCfg.Port
				rawCfg.Port = 0
			} else if rawCfg.SocksPort > 0 {
				rawCfg.MixedPort = rawCfg.SocksPort
				rawCfg.SocksPort = 0
			} else {
				rawCfg.MixedPort = 7890
			}

			if rawCfg.SocksPort == rawCfg.MixedPort {
				rawCfg.SocksPort = 0
			}

			if rawCfg.Port == rawCfg.MixedPort {
				rawCfg.Port = 0
			}
		}
	}
	if secretOverride != "" {
		rawCfg.Secret = secretOverride
	}
	rawCfg.ExternalUI = ""
	rawCfg.ExternalUIURL = ""
	rawCfg.ExternalUIName = ""
	rawCfg.Profile.StoreSelected = true
	rawCfg.IPv6 = ipv6
	if len(externalController) > 0 {
		rawCfg.ExternalController = externalController
	}
	if checkPort {
		if !isAddrValid(rawCfg.ExternalController) {
			port, err := freeport.GetFreePort()
			if err != nil {
				return nil, err
			}
			rawCfg.ExternalController = "127.0.0.1:" + strconv.Itoa(port)
			rawCfg.Secret = ""
		}
		rawCfg.AllowLan = allowLan

		if port, err := resolveConfiguredMixedPort(rawCfg.MixedPort, func(port int) bool {
			return checkMixedPortAvailableAt(port, rawCfg.AllowLan, rawCfg.BindAddress)
		}); err != nil {
			return nil, err
		} else {
			rawCfg.MixedPort = port
		}
	}

	// Apply TUN configuration if enhanced mode is enabled
	tunMu.Lock()
	if tunEnabled {
		applyTunConfig(rawCfg)
		if err := applyTunRouteExclusions(rawCfg); err != nil {
			tunMu.Unlock()
			return nil, err
		}
	}
	tunMu.Unlock()

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		return nil, err
	}
	submittedConfig, err := yaml.Marshal(rawCfg)
	if err != nil {
		return nil, err
	}

	if err := withCoreMutation(func() error {
		if configUpdateEpoch.Load() != lifecycleEpoch {
			return errCoreLifecycleCancelled
		}
		enableIPV6 = ipv6
		// Confirm every listener before exposing a management endpoint. A failed
		// cold start must not leave an asynchronously launched REST server behind.
		if err := applyAndRecordSubmittedConfig(&lastSubmittedConfig, submittedConfig, func() error {
			if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
				return err
			}
			return route.ReCreateServerAndValidate(&route.Config{
				Addr:   cfg.Controller.ExternalController,
				Secret: cfg.Controller.Secret,
			})
		}); err != nil {
			return err
		}
		if savedUIPath != "" {
			route.SetUIPath(savedUIPath)
		}
		return nil
	}); err != nil {
		return nil, err
	}

	return cfg, nil
}

// startDefaultCoreWithCache holds the cache lifecycle lock through config and
// core startup so a concurrent suspend cannot close the DB between reopening
// it and bringing listeners back.
func startDefaultCoreWithCache(checkPort, allowLan, ipv6 bool, proxyPort uint32, externalController string, lifecycleEpoch uint64) (*config.Config, error) {
	installEmbeddedRuntimeMutationGate()
	var cfg *config.Config
	err := currentCacheDBLifecycle().withOpen(func() error {
		var err error
		cfg, err = parseDefaultConfigThenStart(checkPort, allowLan, ipv6, proxyPort, externalController, lifecycleEpoch)
		if err != nil {
			// Still under the lifecycle lock: a replacement core cannot start
			// between failed listener application and releasing its resources.
			_ = withCoreMutation(func() error {
				stopBuiltinListenersForSuspend()
				return nil
			})
		}
		return err
	})
	return cfg, err
}

// applyTunConfig configures TUN and DNS settings on a RawConfig for Enhanced Mode.
// Must be called while tunMu is held.
func applyTunConfig(rawCfg *config.RawConfig) {
	rawCfg.Tun.Enable = true
	if err := (&rawCfg.Tun.Stack).UnmarshalText([]byte(resolveTunStack(loadUserTunStackRaw()))); err != nil {
		rawCfg.Tun.Stack = constant.TunMixed
	}
	rawCfg.Tun.AutoRoute = true
	rawCfg.Tun.StrictRoute = true
	rawCfg.Tun.DNSHijack = []string{"any:53", "tcp://any:53"}

	if tunMTUValue > 0 {
		rawCfg.Tun.MTU = tunMTUValue
	} else {
		rawCfg.Tun.MTU = defaultTunMTU
	}

	if tunInterfaceName != "" {
		rawCfg.Interface = tunInterfaceName
		rawCfg.Tun.AutoDetectInterface = false
	} else {
		rawCfg.Tun.AutoDetectInterface = true
	}

	// TUN mode requires DNS with fake-ip or redir-host
	if !rawCfg.DNS.Enable {
		rawCfg.DNS.Enable = true
	}
	if rawCfg.DNS.EnhancedMode == constant.DNSNormal {
		rawCfg.DNS.EnhancedMode = constant.DNSFakeIP
	}
	if rawCfg.DNS.FakeIPRange == "" {
		rawCfg.DNS.FakeIPRange = "198.18.0.1/16"
	}
	if len(rawCfg.DNS.NameServer) == 0 {
		rawCfg.DNS.NameServer = []string{
			"https://doh.pub/dns-query",
			"tls://223.5.5.5:853",
		}
	}
	if len(rawCfg.DNS.DefaultNameserver) == 0 {
		rawCfg.DNS.DefaultNameserver = []string{
			"114.114.114.114",
			"223.5.5.5",
			"119.29.29.29",
		}
	}
}

//export verifyClashConfig
func verifyClashConfig(content *C.char) *C.char {

	b := []byte(C.GoString(content))
	rawCfg, err := config.UnmarshalRawConfig(b)
	if err != nil {
		return C.CString(err.Error())
	}
	if _, err := config.ParseRawConfig(rawCfg); err != nil {
		return C.CString(err.Error())
	}

	return C.CString("success")
}

func nameserverPolicyForConvertedProxies(proxies []map[string]interface{}) map[string]interface{} {
	policy := make(map[string]interface{})
	for _, proxy := range proxies {
		server, ok := proxy["server"].(string)
		if !ok || server == "" {
			continue
		}
		if net.ParseIP(server) != nil {
			continue
		}
		policy[server] = "https://223.5.5.5/dns-query"
	}
	return policy
}

func isSubscriptionInfoProxyName(name string) bool {
	containsMarkers := []string{
		"剩余流量", "套餐到期", "过滤掉", "官网", "订阅", "用户群",
	}
	for _, marker := range containsMarkers {
		if strings.Contains(name, marker) {
			return true
		}
	}

	lowerName := strings.ToLower(strings.TrimSpace(name))
	prefixMarkers := []string{"traffic", "expire", "expired", "remaining traffic", "subscription"}
	for _, marker := range prefixMarkers {
		if strings.HasPrefix(lowerName, marker) {
			return true
		}
	}
	return false
}

//export clashConvertShareLinks
func clashConvertShareLinks(content *C.char) *C.char {
	proxies, err := convert.ConvertsV2Ray([]byte(C.GoString(content)))
	if err != nil {
		return C.CString("error:" + err.Error())
	}

	filteredProxies := make([]map[string]interface{}, 0, len(proxies))
	names := make([]string, 0, len(proxies))
	for _, proxy := range proxies {
		if name, ok := proxy["name"].(string); ok && name != "" {
			if isSubscriptionInfoProxyName(name) {
				continue
			}
			filteredProxies = append(filteredProxies, proxy)
			names = append(names, name)
		}
	}
	if len(names) == 0 {
		return C.CString("error:converted subscription did not contain proxy names")
	}
	nameserverPolicy := nameserverPolicyForConvertedProxies(filteredProxies)
	benchmarkURL := "https://cp.cloudflare.com/generate_204"
	dns := map[string]interface{}{
		"enable":        true,
		"listen":        "127.0.0.1:1053",
		"ipv6":          true,
		"enhanced-mode": "redir-host",
		"default-nameserver": []string{
			"114.114.114.114",
			"223.5.5.5",
			"119.29.29.29",
		},
		"nameserver": []string{
			"https://223.5.5.5/dns-query",
			"https://doh.pub/dns-query",
			"119.29.29.29",
			"223.5.5.5",
			"tls://223.5.5.5:853",
			"tls://223.6.6.6:853",
		},
		"fallback": []string{
			"https://223.5.5.5/dns-query",
			"https://doh.pub/dns-query",
			"tls://1.1.1.1:853",
			"tls://8.8.8.8:853",
		},
		"fallback-filter": map[string]interface{}{
			"geoip": false,
		},
	}
	if len(nameserverPolicy) > 0 {
		dns["nameserver-policy"] = nameserverPolicy
	}

	rawMap := map[string]interface{}{
		"mode":                    "rule",
		"log-level":               "info",
		"mixed-port":              7890,
		"allow-lan":               false,
		"bind-address":            "*",
		"ipv6":                    true,
		"udp":                     true,
		"unified-delay":           true,
		"cfw-latency-timeout":     8000,
		"cfw-latency-url":         benchmarkURL,
		"cfw-conn-break-strategy": true,
		"dns":                     dns,
		"proxies":                 filteredProxies,
		"proxy-groups": []map[string]interface{}{
			{
				"name":    "Proxy",
				"type":    "select",
				"proxies": append([]string{"Auto", "DIRECT"}, names...),
			},
			{
				"name":      "Auto",
				"type":      "url-test",
				"proxies":   names,
				"url":       benchmarkURL,
				"interval":  300,
				"tolerance": 200,
			},
		},
		"rules": []string{
			"DOMAIN,localhost,DIRECT",
			"DOMAIN-SUFFIX,local,DIRECT",
			"DOMAIN-SUFFIX,cn,DIRECT",
			"DOMAIN,www.baidu.com,DIRECT",
			"DOMAIN,baidu.com,DIRECT",
			"DOMAIN-KEYWORD,baidu,DIRECT",
			"DOMAIN-SUFFIX,baidu.com,DIRECT",
			"DOMAIN-SUFFIX,bdimg.com,DIRECT",
			"DOMAIN-SUFFIX,bdstatic.com,DIRECT",
			"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
			"IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
			"IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
			"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
			"IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
			"IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
			"IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
			"IP-CIDR6,::1/128,DIRECT,no-resolve",
			"IP-CIDR6,fc00::/7,DIRECT,no-resolve",
			"IP-CIDR6,fe80::/10,DIRECT,no-resolve",
			"MATCH,Proxy",
		},
	}

	data, err := yaml.Marshal(rawMap)
	if err != nil {
		return C.CString("error:" + err.Error())
	}

	header := "# clashfx-generated: share-links\n" +
		"# clashfx-template-version: 8\n" +
		"# This file was auto-generated by ClashFX from share-link subscriptions.\n" +
		"# It is a compatibility config, not a user-authored rule file.\n" +
		"# ClashFX may safely auto-upgrade this generated template.\n" +
		"# Current template: mihomo share-link converter + DNS policy + geodata-free rules.\n"
	return C.CString(header + string(data))
}

// Logging callbacks only append to the thread-safe application logger; they do
// not mutate menus. Keep constructor errors while reload pauses UI/traffic
// callbacks, otherwise the precise bind error is lost before rollback.
func shouldForwardCoreLog(paused bool, level string) bool {
	return !paused || level == "error"
}

//export clashSetupLogger
func clashSetupLogger() {
	sub := log.Subscribe()
	go func() {
		for elm := range sub {
			level := elm.Type()
			if !shouldForwardCoreLog(atomic.LoadInt32(&callbacksPaused) != 0, level) {
				continue
			}
			cs := C.CString(elm.Payload)
			cl := C.CString(level)
			C.sendLogToUI(cs, cl)
			C.free(unsafe.Pointer(cs))
			C.free(unsafe.Pointer(cl))
		}
	}()
}

//export clashSetupTraffic
func clashSetupTraffic() {
	go func() {
		tick := time.NewTicker(time.Second)
		defer tick.Stop()
		t := statistic.DefaultManager
		buf := &bytes.Buffer{}
		for range tick.C {
			if atomic.LoadInt32(&callbacksPaused) != 0 {
				continue
			}
			buf.Reset()
			up, down := t.Now()
			C.sendTrafficToUI(C.longlong(up), C.longlong(down))
		}
	}()
}

//export clashPauseCallbacks
func clashPauseCallbacks() {
	atomic.StoreInt32(&callbacksPaused, 1)
}

//export clashResumeCallbacks
func clashResumeCallbacks() {
	atomic.StoreInt32(&callbacksPaused, 0)
}

//export clash_checkSecret
func clash_checkSecret() *C.char {
	cfg, err := getRawCfg()
	if err != nil {
		return C.CString("")
	}
	if cfg.Secret != "" {
		return C.CString(cfg.Secret)
	}
	return C.CString("")
}

//export clash_setSecret
func clash_setSecret(secret *C.char) {
	secretOverride = C.GoString(secret)
}

//export run
func run(checkConfig, allowLan, ipv6 bool, portOverride uint32, externalController *C.char) *C.char {
	epoch := configUpdateEpoch.Add(1)
	cfg, err := startDefaultCoreWithCache(checkConfig, allowLan, ipv6, portOverride, C.GoString(externalController), epoch)
	if err != nil {
		return C.CString(err.Error())
	}

	portInfo := map[string]string{
		"externalController": cfg.Controller.ExternalController,
		"secret":             cfg.Controller.Secret,
	}

	jsonString, err := json.Marshal(portInfo)
	if err != nil {
		return C.CString(err.Error())
	}

	return C.CString(string(jsonString))
}

//export setUIPath
func setUIPath(path *C.char) {
	savedUIPath = C.GoString(path)
	route.SetUIPath(savedUIPath)
}

//export clashUpdateConfig
func clashUpdateConfig(path *C.char) *C.char {
	return updateConfigAtEpoch(C.GoString(path), configUpdateEpoch.Load())
}

//export clashCurrentConfigUpdateEpoch
func clashCurrentConfigUpdateEpoch() C.ulonglong {
	return C.ulonglong(configUpdateEpoch.Load())
}

//export clashUpdateConfigWithEpoch
func clashUpdateConfigWithEpoch(path *C.char, epochToken C.ulonglong) *C.char {
	return updateConfigAtEpoch(C.GoString(path), uint64(epochToken))
}

func updateConfigAtEpoch(configPath string, epoch uint64) *C.char {
	raw, err := os.ReadFile(configPath)
	if err != nil {
		return C.CString(err.Error())
	}
	if err := applyActiveConfigUpdate(currentCacheDBLifecycle(), epoch, func() error {
		cfg, err := executor.ParseWithBytes(raw)
		if err != nil {
			return err
		}
		cfg.General.IPv6 = enableIPV6
		cfg.Controller.ExternalUI = ""
		cfg.Controller.ExternalUIURL = ""
		cfg.Controller.ExternalUIName = ""
		return applyAndRecordSubmittedConfig(&lastSubmittedConfig, raw, func() error {
			if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
				return err
			}
			if savedUIPath != "" {
				route.SetUIPath(savedUIPath)
			}
			return nil
		})
	}); err != nil {
		return C.CString(err.Error())
	}
	return C.CString("success")
}

//export clashCancelPendingConfigUpdate
func clashCancelPendingConfigUpdate() {
	configUpdateEpoch.Add(1)
}

//export clashGetLastSubmittedConfig
func clashGetLastSubmittedConfig() *C.char {
	return C.CString(string(lastSubmittedConfig.bytes()))
}

//export clashGetConfigs
func clashGetConfigs() *C.char {
	general := executor.GetGeneralSafe()
	jsonString, err := json.Marshal(general)
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString(string(jsonString))
}

//export verifyGEOIPDataBase
func verifyGEOIPDataBase() bool {
	mmdb, err := geoip2.Open(constant.Path.MMDB())
	if err != nil {
		log.Warnln("mmdb fail:%s", err.Error())
		return false
	}

	_, err = mmdb.Country(net.ParseIP("114.114.114.114"))
	if err != nil {
		log.Warnln("mmdb lookup fail:%s", err.Error())
		return false
	}
	return true
}

//export clash_getCountryForIp
func clash_getCountryForIp(ip *C.char) *C.char {
	codes := mmdb.IPInstance().LookupCode(net.ParseIP(C.GoString(ip)))
	if len(codes) > 0 {
		return C.CString(strings.ToUpper(codes[0]))
	}
	return C.CString("")
}

//export clash_closeAllConnections
func clash_closeAllConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

//export clash_getProggressInfo
func clash_getProggressInfo() *C.char {
	return C.CString(GetTcpNetList() + GetUDpList())
}

// --- Enhanced Mode (TUN) Control Functions ---

//export clashPresetTunEnabled
func clashPresetTunEnabled(enabled bool) {
	_ = currentCacheDBLifecycle().withActive(func() error {
		tunMu.Lock()
		tunEnabled = enabled
		tunMu.Unlock()
		return nil
	})
}

//export clashSetTunEnabled
func clashSetTunEnabled(enabled bool) *C.char {
	tunStartFailed := false
	lifecycle := currentCacheDBLifecycle()
	err := lifecycle.withActive(func() error {
		epoch, err := lifecycle.advanceEpochIfActive(&configUpdateEpoch)
		if err != nil {
			return err
		}
		return applyConfigUpdateForLifecycle(lifecycle, epoch, func() error {
			// ParseRawConfig can update Mihomo package state, so keep it inside
			// the core fence after both the suspend and epoch checks have passed.
			rawCfg, err := getRawCfg()
			if err != nil {
				return err
			}

			if secretOverride != "" {
				rawCfg.Secret = secretOverride
			}
			rawCfg.Profile.StoreSelected = false
			rawCfg.IPv6 = enableIPV6
			rawCfg.ExternalUI = ""
			rawCfg.ExternalUIURL = ""
			rawCfg.ExternalUIName = ""

			tunMu.Lock()
			if enabled {
				applyTunConfig(rawCfg)
				if err := applyTunRouteExclusions(rawCfg); err != nil {
					tunMu.Unlock()
					return err
				}
			} else {
				rawCfg.Tun.Enable = false
			}
			tunMu.Unlock()

			cfg, err := config.ParseRawConfig(rawCfg)
			if err != nil {
				return err
			}
			executor.ApplyConfig(cfg, false)
			tunMu.Lock()
			tunEnabled = enabled
			if enabled && !listener.GetTunConf().Enable {
				tunEnabled = false
				tunStartFailed = true
			}
			tunMu.Unlock()
			return nil
		})
	})
	if err != nil {
		return C.CString(err.Error())
	}
	if tunStartFailed {
		return C.CString("TUN failed: operation not permitted (requires elevated privileges)")
	}

	return C.CString("success")
}

//export clashGetTunEnabled
func clashGetTunEnabled() bool {
	tunMu.Lock()
	defer tunMu.Unlock()
	return tunEnabled
}

//export clashSuspendCore
func clashSuspendCore() {
	lifecycle := currentCacheDBLifecycle()
	err := lifecycle.suspendWithEpoch(func() {
		_ = withCoreMutation(func() error {
			stopBuiltinListenersForSuspend()
			return nil
		})
	}, &configUpdateEpoch)
	if err != nil {
		log.Warnln("close cache database before suspending core failed: %v", err)
	}
}

// stopBuiltinListenersForSuspend is called under the core mutation lock before
// releasing cache.db; custom and URL/QUIC globals must not outlive the handoff.
func stopBuiltinListenersForSuspend() {
	executor.WithRuntimeConfigLock(func() {
		listener.ReCreateHTTP(0, tunnel.Tunnel)
		listener.ReCreateSocks(0, tunnel.Tunnel)
		listener.ReCreateMixed(0, tunnel.Tunnel)
		listener.ReCreateRedir(0, tunnel.Tunnel)
		listener.ReCreateTProxy(0, tunnel.Tunnel)
		listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
		listener.Cleanup()
		listener.ReCreateShadowSocks("", tunnel.Tunnel)
		listener.ReCreateVmess("", tunnel.Tunnel)
		tuic := listener.GetTuicConf()
		tuic.Enable = false
		listener.ReCreateTuic(tuic, tunnel.Tunnel)
		route.ReCreateServer(&route.Config{})
		closeBuiltinDNSListener()
	})
}

// closeBuiltinDNSListener releases both sockets owned by Mihomo's DNS server
// while leaving the resolver module state available for configuration work.
// startDefaultCoreWithCache rebuilds DNS through executor.ApplyConfig on resume.
func closeBuiltinDNSListener() {
	mihomoDNS.ReCreateServer("", nil)
}

//export clashReopenCacheDB
func clashReopenCacheDB() {
	if err := currentCacheDBLifecycle().reopen(); err != nil {
		log.Warnln("reopen cache database failed: %v", err)
	}
}

// clashResumeCore returns exactly "success" after startup. Failures return
// "error:<reason>"; callers must treat every other value as a failed resume.
// Cache-open errors are returned before parsing config or publishing listeners.
//
//export clashResumeCore
func clashResumeCore() *C.char {
	epoch := configUpdateEpoch.Add(1)
	cfg, err := startDefaultCoreWithCache(false, false, enableIPV6, 0, "", epoch)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	_ = cfg
	return C.CString("success")
}

//export clashWriteEnhancedConfig
func clashWriteEnhancedConfig(configPath *C.char, outputPath *C.char, tunRouteExcludeList *C.char, tunMTUParam C.uint, tunInterfaceNameParam *C.char, bypassCnApps C.int) *C.char {
	return writeEnhancedConfig(C.GoString(configPath), C.GoString(outputPath), C.GoString(tunRouteExcludeList),
		uint32(tunMTUParam), C.GoString(tunInterfaceNameParam), bypassCnApps != 0, nil)
}

//export clashWriteEnhancedConfigWithPorts
func clashWriteEnhancedConfigWithPorts(configPath *C.char, outputPath *C.char, tunRouteExcludeList *C.char, tunMTUParam C.uint, tunInterfaceNameParam *C.char, bypassCnApps C.int, portPlanJSON *C.char) *C.char {
	plan, err := decodeEnhancedConfigPortPlan(C.GoString(portPlanJSON))
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	return writeEnhancedConfig(C.GoString(configPath), C.GoString(outputPath), C.GoString(tunRouteExcludeList),
		uint32(tunMTUParam), C.GoString(tunInterfaceNameParam), bypassCnApps != 0, plan)
}

func writeEnhancedConfig(configPath, outputPath, excludeRaw string, mtuParam uint32, ifaceName string, bypassCnApps bool, portPlan *enhancedConfigPortPlan) *C.char {
	ifaceName = strings.TrimSpace(ifaceName)

	effectiveMTU := mtuParam
	if effectiveMTU == 0 {
		effectiveMTU = defaultTunMTU
	}
	srcPath := configPath
	if srcPath == "" {
		srcPath = constant.Path.Config()
	}
	buf, err := readConfig(srcPath)
	if err != nil {
		return C.CString("error:" + err.Error())
	}

	var rawMap map[string]interface{}
	if err := yaml.Unmarshal(buf, &rawMap); err != nil {
		return C.CString("error:" + err.Error())
	}

	userTunStack := ""
	if existingTun, ok := rawMap["tun"].(map[string]interface{}); ok {
		if s, ok := existingTun["stack"].(string); ok {
			userTunStack = s
		}
	}
	rawMap["tun"] = map[string]interface{}{
		"enable":                true,
		"stack":                 resolveTunStack(userTunStack),
		"auto-route":            true,
		"auto-detect-interface": ifaceName == "",
		"strict-route":          true,
		"dns-hijack":            []string{"any:53", "tcp://any:53"},
		"mtu":                   effectiveMTU,
	}
	if ifaceName != "" {
		rawMap["interface-name"] = ifaceName
	}

	prefixes, domains, invalid := splitTunRouteExcludeEntries(excludeRaw)
	if len(invalid) > 0 {
		return C.CString("error:invalid TUN route exclude entries: " + strings.Join(invalid, ", "))
	}

	dns, _ := rawMap["dns"].(map[string]interface{})
	if dns == nil {
		dns = map[string]interface{}{}
	}
	dns["enable"] = true
	if len(domains) > 0 {
		dns["fake-ip-filter"] = mergeInterfaceSlice(dns["fake-ip-filter"], domains)
	}
	if mode, _ := dns["enhanced-mode"].(string); mode == "" || mode == "normal" {
		dns["enhanced-mode"] = "fake-ip"
	}
	if fir, _ := dns["fake-ip-range"].(string); fir == "" {
		dns["fake-ip-range"] = "198.18.0.1/16"
	}
	if dns["nameserver"] == nil {
		dns["nameserver"] = []string{"https://doh.pub/dns-query", "tls://223.5.5.5:853"}
	}
	if dns["default-nameserver"] == nil {
		dns["default-nameserver"] = []string{"114.114.114.114", "223.5.5.5", "119.29.29.29"}
	}
	// The legacy entry point retains its original default-port normalization.
	// A planned write leaves every source proxy field as the user specified it.
	if portPlan == nil {
		ensureDefaultProxyPort(rawMap)
	}
	lockEnhancedLanBinding(rawMap)
	_, _, err = selectEnhancedConfigPorts(rawMap, dns, portPlan, nil, nil, nil)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	rawMap["dns"] = dns
	if len(prefixes) > 0 {
		tunMap, _ := rawMap["tun"].(map[string]interface{})
		tunMap["route-exclude-address"] = mergePrefixInterfaceSlice(tunMap["route-exclude-address"], prefixes)
		rawMap["tun"] = tunMap
	}

	// Pin a stable controller port so the Yacd dashboard origin
	// (127.0.0.1:PORT) stays constant across launches; otherwise its
	// per-origin localStorage (theme, columns) resets every time.
	ec := rawMap["external-controller"].(string)

	if secretOverride != "" {
		rawMap["secret"] = secretOverride
	}
	rawMap["ipv6"] = enableIPV6
	if savedUIPath != "" {
		rawMap["external-ui"] = savedUIPath
	}

	profile, _ := rawMap["profile"].(map[string]interface{})
	if profile == nil {
		profile = map[string]interface{}{}
	}
	profile["store-selected"] = true
	rawMap["profile"] = profile

	if bypassCnApps {
		providers, _ := rawMap["rule-providers"].(map[string]interface{})
		if providers == nil {
			providers = map[string]interface{}{}
		}
		providers["clashfx-cn-apps-direct"] = map[string]interface{}{
			"type":     "http",
			"behavior": "classical",
			"url":      "https://raw.githubusercontent.com/Clash-FX/cn-apps-direct/main/apps-direct.list",
			"path":     "./ruleset/clashfx-cn-apps-direct.list",
			"interval": 86400,
		}
		rawMap["rule-providers"] = providers

		existingRules, _ := rawMap["rules"].([]interface{})
		newRules := make([]interface{}, 0, len(existingRules)+1)
		newRules = append(newRules, "RULE-SET,clashfx-cn-apps-direct,DIRECT")
		newRules = append(newRules, existingRules...)
		rawMap["rules"] = newRules
	}
	prependUniqueRules(rawMap, enhancedCoreProcessDirectRules)

	data, err := yaml.Marshal(rawMap)
	if err != nil {
		return C.CString("error:" + err.Error())
	}

	path := outputPath
	if path == "" {
		return C.CString("error:empty enhanced config output path")
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".enhanced-config-*")
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return C.CString("error:" + err.Error())
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return C.CString("error:" + err.Error())
	}
	if err := tmp.Close(); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.Chmod(tmpPath, 0600); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return C.CString("error:" + err.Error())
	}

	secret, _ := rawMap["secret"].(string)
	dnsListen, _ := dns["listen"].(string)
	portInfo := map[string]string{
		"externalController": ec,
		"secret":             secret,
		"dnsListen":          dnsListen,
	}
	jsonString, err := json.Marshal(portInfo)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString(string(jsonString))
}

//export clashRetargetEnhancedDNSConfig
func clashRetargetEnhancedDNSConfig(configPath *C.char, dnsPort C.int) *C.char {
	if err := retargetEnhancedDNSConfigFile(C.GoString(configPath), int(dnsPort)); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("")
}

//export clashValidateEnhancedListenerConfig
func clashValidateEnhancedListenerConfig(configPath *C.char) *C.char {
	if err := validateEnhancedListenerConfigFile(C.GoString(configPath)); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("")
}

//export clashValidateRuntimeConfig
func clashValidateRuntimeConfig(configPath *C.char) *C.char {
	if err := validateRuntimeListenerConfigFile(C.GoString(configPath)); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("")
}

func main() {
}
