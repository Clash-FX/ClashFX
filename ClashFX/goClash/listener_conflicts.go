package main

import (
	"fmt"
	"net"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/common/utils"
	embedSS "github.com/metacubex/mihomo/listener/shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_vmess"
	"gopkg.in/yaml.v3"
)

type listenerProtocol uint8

const (
	listenerTCP listenerProtocol = iota + 1
	listenerUDP
)

type listenerHostKind uint8

const (
	listenerHostExact listenerHostKind = iota + 1
	listenerHostIPv4Wildcard
	listenerHostIPv6Wildcard
	listenerHostDualWildcard
)

type listenerHost struct {
	kind listenerHostKind
	ip   netip.Addr
}

type listenerPortRange struct {
	first int
	last  int
}

type listenerEndpoint struct {
	protocol          listenerProtocol
	host              listenerHost
	ports             listenerPortRange
	name              string
	globalTCPFallback bool
}

type listenerFamily uint8

const (
	listenerFamilyGeneric listenerFamily = iota
	listenerFamilyIPv4
	listenerFamilyIPv6
)

func listenerHostForAddress(host string, family listenerFamily) (listenerHost, bool) {
	host = strings.TrimSpace(strings.Trim(host, "[]"))
	if host == "localhost" {
		return listenerHost{kind: listenerHostExact, ip: netip.MustParseAddr("127.0.0.1")}, true
	}
	if host == "" {
		switch family {
		case listenerFamilyIPv4:
			return listenerHost{kind: listenerHostIPv4Wildcard}, true
		case listenerFamilyIPv6:
			return listenerHost{kind: listenerHostIPv6Wildcard}, true
		default:
			return listenerHost{kind: listenerHostDualWildcard}, true
		}
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return listenerHost{}, false
	}
	ip = ip.Unmap()
	if family == listenerFamilyIPv4 && !ip.Is4() || family == listenerFamilyIPv6 && !ip.Is6() {
		return listenerHost{}, false
	}
	if ip.IsUnspecified() {
		switch family {
		case listenerFamilyIPv4:
			return listenerHost{kind: listenerHostIPv4Wildcard}, true
		case listenerFamilyIPv6:
			return listenerHost{kind: listenerHostIPv6Wildcard}, true
		default:
			if ip.Is4() {
				// Preserve the explicitly requested IPv4 binding domain. Darwin
				// permits a separate IPv6 listener on this port and routes each
				// family to its own service, even if Go opens a dual-stack fd.
				return listenerHost{kind: listenerHostIPv4Wildcard}, true
			}
			return listenerHost{kind: listenerHostDualWildcard}, true
		}
	}
	return listenerHost{kind: listenerHostExact, ip: ip}, true
}

func listenerHostsOverlap(a, b listenerHost) bool {
	if a.kind == listenerHostDualWildcard || b.kind == listenerHostDualWildcard {
		return true
	}
	if a.kind == listenerHostExact && b.kind == listenerHostExact {
		return a.ip == b.ip
	}
	if a.kind == listenerHostIPv4Wildcard {
		return b.kind == listenerHostIPv4Wildcard || b.kind == listenerHostExact && b.ip.Is4()
	}
	if b.kind == listenerHostIPv4Wildcard {
		return a.kind == listenerHostExact && a.ip.Is4()
	}
	if a.kind == listenerHostIPv6Wildcard {
		return b.kind == listenerHostIPv6Wildcard || b.kind == listenerHostExact && b.ip.Is6()
	}
	if b.kind == listenerHostIPv6Wildcard {
		return a.kind == listenerHostExact && a.ip.Is6()
	}
	return false
}

func listenerEndpointsOverlap(a, b listenerEndpoint) bool {
	return a.protocol == b.protocol && listenerHostsOverlap(a.host, b.host) &&
		a.ports.first <= b.ports.last && b.ports.first <= a.ports.last
}

func listenerAddressEndpoints(protocol listenerProtocol, family listenerFamily, address, name string) []listenerEndpoint {
	host, port, ok := splitListenerAddress(address)
	if !ok || port == 0 {
		return nil
	}
	endpoint, ok := newListenerEndpoint(protocol, family, host, listenerPortRange{first: port, last: port}, name)
	if !ok {
		return nil
	}
	return []listenerEndpoint{endpoint}
}

func splitListenerAddress(address string) (string, int, bool) {
	host, portText, err := net.SplitHostPort(strings.TrimSpace(address))
	if err != nil {
		return "", 0, false
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 0 || port > 65535 {
		return "", 0, false
	}
	return host, port, true
}

func newListenerEndpoint(protocol listenerProtocol, family listenerFamily, host string, ports listenerPortRange, name string) (listenerEndpoint, bool) {
	if ports.last < 1 || ports.first > 65535 || ports.last > 65535 || ports.first > ports.last {
		return listenerEndpoint{}, false
	}
	if ports.first < 1 {
		ports.first = 1
	}
	parsedHost, ok := listenerHostForAddress(host, family)
	if !ok {
		return listenerEndpoint{}, false
	}
	if protocol == listenerUDP && family == listenerFamilyGeneric && parsedHost.kind == listenerHostIPv4Wildcard {
		// Unlike TCP's more-specific binding coexistence on Darwin, the
		// generic UDP wildcard occupies both families. DNS uses an ordinary
		// UDP socket, so an IPv6 listener on this port must still be rejected.
		parsedHost.kind = listenerHostDualWildcard
	}
	return listenerEndpoint{protocol: protocol, host: parsedHost, ports: ports, name: name}, true
}

func listenerPortRanges(raw interface{}) []listenerPortRange {
	if raw == nil {
		return nil
	}
	spec := fmt.Sprint(raw)
	if !listenerPortSpecWithinUint16(spec) {
		return nil
	}
	ranges, err := utils.NewUnsignedRanges[uint16](spec)
	if err != nil || len(ranges) == 0 {
		return nil
	}
	result := make([]listenerPortRange, 0, len(ranges))
	for _, portRange := range ranges {
		first, last := int(portRange.Start()), int(portRange.End())
		if last < 1 || first > 65535 {
			continue
		}
		if first < 1 {
			first = 1 // port 0 asks the OS for an ephemeral port; it is not reserved.
		}
		result = append(result, listenerPortRange{first: first, last: last})
	}
	return result
}

func listenerPortSpecWithinUint16(spec string) bool {
	spec = strings.TrimSpace(spec)
	if spec == "" || spec == "*" {
		return true
	}
	for _, item := range strings.Split(strings.ReplaceAll(spec, ",", "/"), "/") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		bounds := strings.Split(item, "-")
		if len(bounds) > 2 {
			return false
		}
		for _, bound := range bounds {
			value, err := strconv.ParseUint(strings.Trim(bound, "[ ]"), 10, 64)
			if err != nil || value > 65535 {
				return false
			}
		}
	}
	return true
}

func endpointsForPortValue(protocols []listenerProtocol, host string, rawPort interface{}, name string) []listenerEndpoint {
	var result []listenerEndpoint
	for _, ports := range listenerPortRanges(rawPort) {
		for _, protocol := range protocols {
			if endpoint, ok := newListenerEndpoint(protocol, listenerFamilyGeneric, host, ports, name); ok {
				result = append(result, endpoint)
			}
		}
	}
	return result
}

func rawMapSlice(raw interface{}) []map[string]interface{} {
	var result []map[string]interface{}
	switch items := raw.(type) {
	case []interface{}:
		for _, item := range items {
			if mapping, ok := item.(map[string]interface{}); ok {
				result = append(result, mapping)
			}
		}
	case []map[string]interface{}:
		result = append(result, items...)
	}
	return result
}

func listenerBool(mapping map[string]interface{}, key string, fallback bool) bool {
	value, exists := mapping[key]
	if !exists {
		return fallback
	}
	switch value := value.(type) {
	case bool:
		return value
	case string:
		parsed, err := strconv.ParseBool(value)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func listenerStringList(raw interface{}) []string {
	var result []string
	switch values := raw.(type) {
	case []string:
		result = append(result, values...)
	case []interface{}:
		for _, value := range values {
			if text, ok := value.(string); ok {
				result = append(result, text)
			}
		}
	}
	return result
}

func enhancedProxyListenerEndpoints(rawMap map[string]interface{}) []listenerEndpoint {
	var endpoints []listenerEndpoint
	allowLan, _ := rawMap["allow-lan"].(bool)
	globalHost := "127.0.0.1"
	if allowLan {
		bindAddress, _ := rawMap["bind-address"].(string)
		if bindAddress == "" {
			bindAddress = "*" // mihomo's default bind-address
		}
		if bindAddress == "*" {
			globalHost = "" // genAddr turns '*' into ':port' for generic Go Listen.
		} else {
			globalHost = bindAddress
		}
	}
	globalPorts := []struct {
		key       string
		protocols []listenerProtocol
	}{
		{key: "port", protocols: []listenerProtocol{listenerTCP}},
		{key: "socks-port", protocols: []listenerProtocol{listenerTCP, listenerUDP}},
		{key: "mixed-port", protocols: []listenerProtocol{listenerTCP, listenerUDP}},
		{key: "redir-port", protocols: []listenerProtocol{listenerTCP}},
		{key: "tproxy-port", protocols: []listenerProtocol{listenerTCP, listenerUDP}},
	}
	for _, item := range globalPorts {
		projected := endpointsForPortValue(item.protocols, globalHost, rawMap[item.key], item.key)
		// Named listeners bind before global TCP listeners. For ':port', Go
		// can keep its IPv4 service when a named IPv6 listener owns that port.
		// Explicit IPv6 wildcard bindings do not have that fallback.
		if globalHost == "" {
			for index := range projected {
				if projected[index].protocol == listenerTCP {
					projected[index].globalTCPFallback = true
				}
			}
		}
		endpoints = append(endpoints, projected...)
	}

	if raw, ok := rawMap["ss-config"].(string); ok && raw != "" {
		if address, _, _, err := embedSS.ParseSSURL(raw); err == nil {
			for _, target := range strings.Split(address, ",") {
				endpoints = append(endpoints, listenerAddressEndpoints(listenerTCP, listenerFamilyGeneric, target, "ss-config")...)
				endpoints = append(endpoints, listenerAddressEndpoints(listenerUDP, listenerFamilyGeneric, target, "ss-config")...)
			}
		}
	}
	if raw, ok := rawMap["vmess-config"].(string); ok && raw != "" {
		if address, _, _, err := sing_vmess.ParseVmessURL(raw); err == nil {
			for _, target := range strings.Split(address, ",") {
				endpoints = append(endpoints, listenerAddressEndpoints(listenerTCP, listenerFamilyGeneric, target, "vmess-config")...)
			}
		}
	}

	if tuicServer, ok := rawMap["tuic-server"].(map[string]interface{}); ok && listenerBool(tuicServer, "enable", false) {
		if address, ok := tuicServer["listen"].(string); ok {
			endpoints = append(endpoints, listenerAddressEndpoints(listenerUDP, listenerFamilyGeneric, address, "tuic-server")...)
		}
	}

	// Mihomo indexes custom listeners by name; the last entry wins, including
	// the empty name. Shadowed entries never bind and must not cause conflicts.
	inbounds := rawMapSlice(rawMap["listeners"])
	lastByName := make(map[string]int, len(inbounds))
	names := make([]string, len(inbounds))
	decoder := structure.NewDecoder(structure.Option{TagName: "inbound", WeaklyTypedInput: true, KeyReplacer: structure.DefaultKeyReplacer})
	for index, inbound := range inbounds {
		var decoded struct {
			Name string `inbound:"name"`
		}
		if err := decoder.Decode(inbound, &decoded); err != nil {
			// An invalid name is rejected by semantic validation; do not let it
			// hide a different listener during the structural check.
			names[index] = fmt.Sprintf("\x00invalid-listener-%d", index)
		} else {
			names[index] = decoded.Name
		}
		lastByName[names[index]] = index
	}
	for index, inbound := range inbounds {
		if lastByName[names[index]] != index {
			continue
		}
		typeName, _ := inbound["type"].(string)
		host, _ := inbound["listen"].(string)
		if host == "" {
			host = "0.0.0.0" // inbound.Base.NewBase default
		}
		var protocols []listenerProtocol
		switch typeName {
		case "socks", "mixed", "tproxy":
			protocols = []listenerProtocol{listenerTCP}
			if listenerBool(inbound, "udp", true) {
				protocols = append(protocols, listenerUDP)
			}
		case "http", "redir", "vmess", "vless", "trojan", "anytls", "sudoku":
			protocols = []listenerProtocol{listenerTCP}
		case "shadowsocks":
			if kcpTun, ok := inbound["kcp-tun"].(map[string]interface{}); ok && listenerBool(kcpTun, "enable", false) {
				protocols = []listenerProtocol{listenerUDP}
			} else {
				protocols = []listenerProtocol{listenerTCP}
				if listenerBool(inbound, "udp", true) {
					protocols = append(protocols, listenerUDP)
				}
			}
		case "tuic", "hysteria2":
			protocols = []listenerProtocol{listenerUDP}
		case "mieru":
			switch inbound["transport"] {
			case "TCP":
				protocols = []listenerProtocol{listenerTCP}
			case "UDP":
				protocols = []listenerProtocol{listenerUDP}
			}
		case "tunnel":
			for _, network := range listenerStringList(inbound["network"]) {
				switch network {
				case "tcp":
					protocols = append(protocols, listenerTCP)
				case "udp":
					protocols = append(protocols, listenerUDP)
				}
			}
		case "trusttunnel":
			networks := listenerStringList(inbound["network"])
			if len(networks) == 0 {
				networks = []string{"tcp"}
			}
			for _, network := range networks {
				network = strings.ToLower(network)
				switch {
				case strings.HasPrefix(network, "tcp"):
					protocols = appendListenerProtocol(protocols, listenerTCP)
				case strings.HasPrefix(network, "udp"):
					protocols = appendListenerProtocol(protocols, listenerUDP)
				}
			}
			// The parser accepts "tun", but this creates no port listener.
		}
		endpoints = append(endpoints, endpointsForPortValue(protocols, host, inbound["port"], "listeners."+typeName)...)
	}
	return endpoints
}

func appendListenerProtocol(protocols []listenerProtocol, protocol listenerProtocol) []listenerProtocol {
	for _, existing := range protocols {
		if existing == protocol {
			return protocols
		}
	}
	return append(protocols, protocol)
}

func enhancedControllerListenerEndpoints(rawMap map[string]interface{}, includeController bool) []listenerEndpoint {
	var endpoints []listenerEndpoint
	keys := []string{"external-controller-tls"}
	if includeController {
		keys = append([]string{"external-controller"}, keys...)
	}
	for _, key := range keys {
		address, _ := rawMap[key].(string)
		endpoints = append(endpoints, listenerAddressEndpoints(listenerTCP, listenerFamilyGeneric, address, key)...)
	}
	return endpoints
}

func enhancedDNSReservedPorts(rawMap map[string]interface{}) []int {
	targetHost, _ := listenerHostForAddress("127.0.0.1", listenerFamilyGeneric)
	targets := []listenerEndpoint{
		{protocol: listenerTCP, host: targetHost, ports: listenerPortRange{first: 1, last: 65535}},
		{protocol: listenerUDP, host: targetHost, ports: listenerPortRange{first: 1, last: 65535}},
	}
	return listenerReservedPorts(targets, append(enhancedProxyListenerEndpoints(rawMap), enhancedControllerListenerEndpoints(rawMap, true)...))
}

// enhancedControllerReservedPorts returns proxy and TLS listener ports which
// overlap a candidate TCP controller on host. external-controller is omitted
// because generated startup replaces it with the selected address.
func enhancedControllerReservedPorts(rawMap map[string]interface{}, host string) []int {
	controllerHost, ok := listenerHostForAddress(host, listenerFamilyGeneric)
	if !ok {
		return nil
	}
	target := listenerEndpoint{protocol: listenerTCP, host: controllerHost, ports: listenerPortRange{first: 1, last: 65535}}
	return listenerReservedPorts([]listenerEndpoint{target}, append(enhancedProxyListenerEndpoints(rawMap), enhancedControllerListenerEndpoints(rawMap, false)...))
}

func listenerReservedPorts(targets, candidates []listenerEndpoint) []int {
	seen := make(map[int]struct{})
	var ports []int
	for _, target := range targets {
		for _, candidate := range candidates {
			if target.protocol != candidate.protocol || !listenerHostsOverlap(target.host, candidate.host) {
				continue
			}
			first := target.ports.first
			if candidate.ports.first > first {
				first = candidate.ports.first
			}
			last := target.ports.last
			if candidate.ports.last < last {
				last = candidate.ports.last
			}
			for port := first; port <= last; port++ {
				if _, exists := seen[port]; exists {
					continue
				}
				seen[port] = struct{}{}
				ports = append(ports, port)
			}
		}
	}
	sort.Ints(ports)
	return ports
}

func validateEnhancedListenerPortConflicts(rawMap map[string]interface{}, dnsPort int) error {
	if dnsPort < 1 || dnsPort > 65535 {
		return portConflictError{service: "dns_listener", address: "127.0.0.1", port: dnsPort, reason: "invalid_port"}
	}
	dnsHost, _ := listenerHostForAddress("127.0.0.1", listenerFamilyGeneric)
	dnsPorts := listenerPortRange{first: dnsPort, last: dnsPort}
	dnsEndpoints := []listenerEndpoint{
		{protocol: listenerTCP, host: dnsHost, ports: dnsPorts, name: "dns_listener"},
		{protocol: listenerUDP, host: dnsHost, ports: dnsPorts, name: "dns_listener"},
	}
	return validateEnhancedListenerEndpoints(rawMap, dnsEndpoints)
}

// Named inbounds and DNS bind before basic global TCP listeners. Generic TCP
// can coexist with their earlier concrete IPv6 binds; management
// controllers are not covered because their startup order differs by entry.
func earlierIPv6AllowsGlobalTCPFallback(earlier, global listenerEndpoint) bool {
	return global.globalTCPFallback && earlier.protocol == listenerTCP &&
		earlier.host.kind == listenerHostExact && earlier.host.ip.Is6()
}

func validateEnhancedListenerEndpoints(rawMap map[string]interface{}, dnsEndpoints []listenerEndpoint) error {
	proxies := enhancedProxyListenerEndpoints(rawMap)
	controllers := enhancedControllerListenerEndpoints(rawMap, true)
	for i := range proxies {
		for j := i + 1; j < len(proxies); j++ {
			if listenerEndpointsOverlap(proxies[i], proxies[j]) {
				if strings.HasPrefix(proxies[i].name, "listeners.") && earlierIPv6AllowsGlobalTCPFallback(proxies[i], proxies[j]) ||
					strings.HasPrefix(proxies[j].name, "listeners.") && earlierIPv6AllowsGlobalTCPFallback(proxies[j], proxies[i]) {
					continue
				}
				return portConflictError{service: "proxy_listener", address: listenerHostString(proxies[i].host), port: maxInt(proxies[i].ports.first, proxies[j].ports.first), reason: "reserved_listener"}
			}
		}
	}
	for _, dns := range dnsEndpoints {
		for _, candidate := range append(append([]listenerEndpoint(nil), proxies...), controllers...) {
			if listenerEndpointsOverlap(dns, candidate) {
				if earlierIPv6AllowsGlobalTCPFallback(dns, candidate) {
					continue
				}
				return portConflictError{service: "dns_listener", address: listenerHostString(dns.host), port: maxInt(dns.ports.first, candidate.ports.first), reason: "reserved_listener"}
			}
		}
	}
	for _, controller := range controllers {
		for _, candidate := range proxies {
			if listenerEndpointsOverlap(controller, candidate) {
				return portConflictError{service: "api_listener", address: listenerHostString(controller.host), port: maxInt(controller.ports.first, candidate.ports.first), reason: "reserved_listener"}
			}
		}
	}
	for i := range controllers {
		for j := i + 1; j < len(controllers); j++ {
			if listenerEndpointsOverlap(controllers[i], controllers[j]) {
				return portConflictError{service: "api_listener", address: listenerHostString(controllers[i].host), port: maxInt(controllers[i].ports.first, controllers[j].ports.first), reason: "reserved_listener"}
			}
		}
	}
	return nil
}

func validateEnhancedListenerConfigFile(configPath string) error {
	if strings.TrimSpace(configPath) == "" {
		return fmt.Errorf("empty enhanced listener config path")
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
		return fmt.Errorf("invalid enhanced listener config: missing dns map")
	}
	address, ok := dns["listen"].(string)
	if !ok || strings.TrimSpace(address) == "" {
		return fmt.Errorf("invalid enhanced listener config: missing dns.listen")
	}
	host, port, ok := splitListenerAddress(address)
	if !ok {
		return fmt.Errorf("invalid enhanced listener config: invalid dns.listen %q", address)
	}
	var dnsEndpoints []listenerEndpoint
	if port > 0 {
		// Mihomo's preResolve maps localhost to IPv4 loopback and rejects
		// other hostnames; keep unknown names out of collision guesses.
		if _, knownHost := listenerHostForAddress(host, listenerFamilyGeneric); knownHost {
			dnsEndpoints = append(dnsEndpoints,
				listenerAddressEndpoints(listenerTCP, listenerFamilyGeneric, address, "dns_listener")...)
			dnsEndpoints = append(dnsEndpoints,
				listenerAddressEndpoints(listenerUDP, listenerFamilyGeneric, address, "dns_listener")...)
		}
	}
	return validateEnhancedListenerEndpoints(rawMap, dnsEndpoints)
}

func listenerHostString(host listenerHost) string {
	switch host.kind {
	case listenerHostExact:
		return host.ip.String()
	case listenerHostIPv4Wildcard:
		return "0.0.0.0"
	case listenerHostIPv6Wildcard:
		return "::"
	default:
		return "*"
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// Generic runtime configurations need not expose a DNS socket at all. TUN
// startup uses the stricter enhanced validator; reload uses the actual final map.
func validateRuntimeListenerConfigFile(configPath string) error {
	contents, err := os.ReadFile(configPath)
	if err != nil {
		return err
	}
	var root map[string]interface{}
	if err := yaml.Unmarshal(contents, &root); err != nil {
		return err
	}
	if root == nil {
		return fmt.Errorf("invalid runtime config: missing mapping")
	}
	var dnsEndpoints []listenerEndpoint
	if dns, ok := root["dns"].(map[string]interface{}); ok && listenerBool(dns, "enable", false) {
		if address, ok := dns["listen"].(string); ok && strings.TrimSpace(address) != "" {
			dnsEndpoints = append(dnsEndpoints, listenerAddressEndpoints(listenerTCP, listenerFamilyGeneric, address, "dns_listener")...)
			dnsEndpoints = append(dnsEndpoints, listenerAddressEndpoints(listenerUDP, listenerFamilyGeneric, address, "dns_listener")...)
		}
	}
	return validateEnhancedListenerEndpoints(root, dnsEndpoints)
}
