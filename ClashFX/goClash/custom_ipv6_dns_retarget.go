package main

import (
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"

	"github.com/metacubex/mihomo/log"
)

type customIPv6DNSListen struct {
	host    string
	address netip.Addr
	port    int
}

// retargetCustomIPv6DNSConfig handles only custom DNS listeners whose bind
// address parses as native IPv6. Generated listeners and all IPv4 custom
// configs continue through retargetEnhancedDNSListen.
func retargetCustomIPv6DNSConfig(rawMap, dns map[string]interface{}, port int) (bool, error) {
	listen, handled, err := parseCustomIPv6DNSListen(dns)
	if !handled {
		return false, nil
	}
	if err != nil {
		return true, err
	}
	if port < 1 || port > 65535 {
		return true, fmt.Errorf("[port_conflict] service=dns_listener address=%s port=%d reason=invalid_port", listen.address, port)
	}

	finalListen := net.JoinHostPort(listen.host, strconv.Itoa(port))
	dnsEndpoints, err := customIPv6DNSListenerEndpoints(finalListen)
	if err != nil {
		return true, err
	}
	if err := validateEnhancedListenerEndpoints(rawMap, dnsEndpoints); err != nil {
		return true, err
	}

	bootstrapReferences := customIPv6DNSBootstrapReferences(dns, listen.address, listen.port)
	for _, reference := range dnsResolverReferences(dns) {
		if customIPv6DNSReferenceIsBootstrap(reference, bootstrapReferences) {
			continue
		}
		endpoint, ok := customIPv6DNSResolverEndpoint(reference.Value)
		if !ok {
			continue
		}
		for _, dnsEndpoint := range dnsEndpoints {
			if listenerEndpointsOverlap(dnsEndpoint, endpoint) {
				return true, fmt.Errorf("[dns_self_cycle] address=%s port=%d", listenerHostString(dnsEndpoint.host), port)
			}
		}
	}

	retargeted := 0
	for _, reference := range bootstrapReferences {
		value, exists := dns[reference.DNSKey]
		if !exists {
			continue
		}
		if rewritten, changed := rewriteCustomIPv6DNSReferenceAtIndex(value, reference.Index, reference.Value, port); changed {
			dns[reference.DNSKey] = rewritten
			retargeted++
		}
	}
	dns["listen"] = finalListen
	log.Infoln("dns_listener_transition family=ipv6 source_port=%d target_port=%d bootstrap_references_retargeted=%d",
		listen.port, port, retargeted)
	return true, nil
}

func parseCustomIPv6DNSListen(dns map[string]interface{}) (customIPv6DNSListen, bool, error) {
	value, ok := dns["listen"].(string)
	if !ok {
		return customIPv6DNSListen{}, false, nil
	}
	host, portText, err := net.SplitHostPort(strings.TrimSpace(value))
	if err != nil {
		return customIPv6DNSListen{}, false, nil
	}
	address, err := netip.ParseAddr(host)
	if err != nil || !address.Is6() || address.Is4In6() {
		return customIPv6DNSListen{}, false, nil
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return customIPv6DNSListen{}, true, fmt.Errorf("invalid custom IPv6 DNS listen port")
	}
	return customIPv6DNSListen{host: host, address: address, port: port}, true, nil
}

func customIPv6DNSListenerEndpoints(address string) ([]listenerEndpoint, error) {
	host, port, ok := splitListenerAddress(address)
	if !ok || port < 1 {
		return nil, fmt.Errorf("invalid custom IPv6 DNS listener address")
	}
	ports := listenerPortRange{first: port, last: port}
	endpoints := make([]listenerEndpoint, 0, 2)
	for _, protocol := range []listenerProtocol{listenerTCP, listenerUDP} {
		endpoint, valid := newListenerEndpoint(protocol, listenerFamilyGeneric, host, ports, "dns_listener")
		if !valid {
			return nil, fmt.Errorf("invalid custom IPv6 DNS listener address")
		}
		endpoints = append(endpoints, endpoint)
	}
	return endpoints, nil
}

func customIPv6DNSBootstrapReferences(dns map[string]interface{}, sourceAddress netip.Addr, sourcePort int) []dnsResolverReference {
	var references []dnsResolverReference
	for _, reference := range dnsResolverReferences(dns) {
		if reference.DNSKey != "proxy-server-nameserver" || reference.PolicyKey != "" || !isPlainDNSTransport(reference.Value) {
			continue
		}
		host, port, ok := dnsServerAddress(reference.Value)
		if !ok || port != sourcePort {
			continue
		}
		address, err := netip.ParseAddr(host)
		if strings.EqualFold(host, "localhost") {
			address, err = netip.ParseAddr("127.0.0.1")
		}
		if err != nil || !customIPv6DNSAddressesMatch(sourceAddress, address) {
			continue
		}
		references = append(references, reference)
	}
	return references
}

func customIPv6DNSAddressesMatch(source, reference netip.Addr) bool {
	if source == reference {
		return true
	}
	// DNS uses generic tcp/udp sockets. The IPv6 wildcard covers both
	// loopback families; an exact ::1 listener does not own IPv4 aliases.
	return source.IsUnspecified() && source.Zone() == "" && reference.Unmap().IsLoopback()
}

func customIPv6DNSReferenceIsBootstrap(reference dnsResolverReference, bootstrapReferences []dnsResolverReference) bool {
	for _, bootstrap := range bootstrapReferences {
		if reference.DNSKey == bootstrap.DNSKey && reference.PolicyKey == bootstrap.PolicyKey &&
			reference.Index == bootstrap.Index && reference.Value == bootstrap.Value {
			return true
		}
	}
	return false
}

func customIPv6DNSResolverEndpoint(raw string) (listenerEndpoint, bool) {
	host, port, ok := dnsServerAddress(raw)
	if !ok {
		return listenerEndpoint{}, false
	}
	protocol := listenerUDP
	trimmed := strings.TrimSpace(raw)
	if schemeEnd := strings.Index(trimmed, "://"); schemeEnd >= 0 {
		switch strings.ToLower(trimmed[:schemeEnd]) {
		case "udp", "quic":
		case "tcp", "tls", "http", "https":
			protocol = listenerTCP
		default:
			// Special resolvers (system, dhcp, rcode) do not connect to
			// this URI endpoint. Leave unknown schemes to core validation.
			return listenerEndpoint{}, false
		}
	}
	return newListenerEndpoint(protocol, listenerFamilyGeneric, host, listenerPortRange{first: port, last: port}, "dns_resolver")
}

func rewriteCustomIPv6DNSReferenceAtIndex(value interface{}, index int, expected string, port int) (interface{}, bool) {
	replacement, ok := retargetCustomIPv6DNSServerAtPort(expected, port)
	if !ok {
		return value, false
	}
	switch servers := value.(type) {
	case string:
		if index != -1 || servers != expected {
			return value, false
		}
		return replacement, true
	case []string:
		if index < 0 || index >= len(servers) || servers[index] != expected {
			return value, false
		}
		rewritten := append([]string(nil), servers...)
		rewritten[index] = replacement
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
		rewritten[index] = replacement
		return rewritten, true
	default:
		return value, false
	}
}

func retargetCustomIPv6DNSServerAtPort(raw string, port int) (string, bool) {
	if port < 1 || port > 65535 || !isPlainDNSTransport(raw) {
		return raw, false
	}
	trimmed := strings.TrimSpace(raw)
	host, _, ok := dnsServerAddress(trimmed)
	if !ok {
		return raw, false
	}
	serverPrefix := ""
	if schemeEnd := strings.Index(trimmed, "://"); schemeEnd >= 0 {
		serverPrefix = trimmed[:schemeEnd+3]
	}
	start := strings.Index(raw, trimmed)
	if start < 0 {
		return raw, false
	}
	end := start + len(trimmed)
	replacement := serverPrefix + net.JoinHostPort(host, strconv.Itoa(port))
	return raw[:start] + replacement + raw[end:], true
}
