package main

import "strconv"

const defaultMixedPort = 7890

// portValueOrZero coerces the value of a YAML port field (parsed by yaml.v3
// into an `interface{}`) to an int. yaml.v3 normally yields `int` for integer
// scalars, but configurations imported from various subscription providers
// occasionally surface ports as strings ("7890"), int64, uint64, or float64;
// a direct `.(int)` type assertion silently produces 0 for any of those,
// causing the fallback below to either trigger spuriously or fail to trigger.
// Any unrecognised representation falls through to 0 (which then triggers
// the fallback in ensureDefaultProxyPort - the safer side of the choice).
func portValueOrZero(raw interface{}) int {
	switch v := raw.(type) {
	case int:
		return v
	case int64:
		return int(v)
	case uint64:
		return int(v)
	case float64:
		return int(v)
	case string:
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

// ensureDefaultProxyPort guarantees rawMap has a usable `mixed-port` so the
// GUI's port-readiness check (ClashConfig.usedHttpPort in Swift) always
// resolves to a real listening port. Strategy mirrors ClashX.Meta
// (MetaCubeX/ClashX.Meta ClashX/goClash/main.go parseDefaultConfigThenStart):
//
//  1. If `mixed-port` is already > 0, keep it.
//  2. Otherwise promote the user's existing `port` or `socks-port` into
//     `mixed-port` and drop the source field, so mihomo doesn't try to
//     bind the same number twice.
//  3. Only when no port is configured at all, inject the default 7890.
//
// Finally, drop any leftover `port` / `socks-port` that happens to equal
// the resolved mixed-port to avoid double-bind conflicts when the user
// configured them redundantly.
func ensureDefaultProxyPort(rawMap map[string]interface{}) {
	if portValueOrZero(rawMap["mixed-port"]) > 0 {
		return
	}

	switch {
	case portValueOrZero(rawMap["port"]) > 0:
		rawMap["mixed-port"] = portValueOrZero(rawMap["port"])
		delete(rawMap, "port")
	case portValueOrZero(rawMap["socks-port"]) > 0:
		rawMap["mixed-port"] = portValueOrZero(rawMap["socks-port"])
		delete(rawMap, "socks-port")
	default:
		rawMap["mixed-port"] = defaultMixedPort
	}

	mixedPort := portValueOrZero(rawMap["mixed-port"])
	if portValueOrZero(rawMap["port"]) == mixedPort {
		delete(rawMap, "port")
	}
	if portValueOrZero(rawMap["socks-port"]) == mixedPort {
		delete(rawMap, "socks-port")
	}
}
