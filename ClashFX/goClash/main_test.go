package main

import "testing"

func TestSplitTunRouteExcludeEntriesAcceptsLocalhost(t *testing.T) {
	prefixes, domains, invalid := splitTunRouteExcludeEntries("127.0.0.1, localhost, *.local, +.example.com")

	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid entries: %v", invalid)
	}
	if got, want := len(prefixes), 1; got != want {
		t.Fatalf("prefix count = %d, want %d", got, want)
	}
	if got, want := domains, []string{"localhost", "*.local", "+.example.com"}; len(got) != len(want) {
		t.Fatalf("domains = %v, want %v", got, want)
	} else {
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("domains = %v, want %v", got, want)
			}
		}
	}
}

func TestSplitTunRouteExcludeEntriesAcceptsLegacyWildcards(t *testing.T) {
	prefixes, domains, invalid := splitTunRouteExcludeEntries("192.168.*, 10.*, 172.16.*, 172.31.*")

	if len(invalid) != 0 {
		t.Fatalf("unexpected invalid entries: %v", invalid)
	}
	if len(domains) != 0 {
		t.Fatalf("domains = %v, want none", domains)
	}
	want := []string{"192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/16", "172.31.0.0/16"}
	if len(prefixes) != len(want) {
		t.Fatalf("prefixes = %v, want %v", prefixes, want)
	}
	for i := range want {
		if prefixes[i].String() != want[i] {
			t.Fatalf("prefixes = %v, want %v", prefixes, want)
		}
	}
}

func TestSplitTunRouteExcludeEntriesRejectsInvalidText(t *testing.T) {
	_, _, invalid := splitTunRouteExcludeEntries("not valid")

	if got, want := invalid, []string{"not valid"}; len(got) != len(want) || got[0] != want[0] {
		t.Fatalf("invalid = %v, want %v", got, want)
	}
}

func TestPrependUniqueRulesAddsEnhancedCoreProcessRulesFirst(t *testing.T) {
	rawMap := map[string]interface{}{
		"rules": []interface{}{
			"DOMAIN-SUFFIX,example.com,DIRECT",
			"MATCH,Proxy",
		},
	}

	prependUniqueRules(rawMap, enhancedCoreProcessDirectRules)

	rules := rawMap["rules"].([]interface{})
	want := []string{
		"PROCESS-NAME,mihomo,DIRECT",
		"PROCESS-NAME,mihomo-bin,DIRECT",
		"PROCESS-NAME,mihomo_core,DIRECT",
		"DOMAIN-SUFFIX,example.com,DIRECT",
		"MATCH,Proxy",
	}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i := range want {
		if rules[i] != want[i] {
			t.Fatalf("rules = %v, want %v", rules, want)
		}
	}
}

func TestPrependUniqueRulesKeepsExistingEnhancedCoreProcessRule(t *testing.T) {
	rawMap := map[string]interface{}{
		"rules": []interface{}{
			"PROCESS-NAME,mihomo,DIRECT",
			"MATCH,Proxy",
		},
	}

	prependUniqueRules(rawMap, []string{"PROCESS-NAME,mihomo,DIRECT"})

	rules := rawMap["rules"].([]interface{})
	want := []string{"PROCESS-NAME,mihomo,DIRECT", "MATCH,Proxy"}
	if len(rules) != len(want) {
		t.Fatalf("rules = %v, want %v", rules, want)
	}
	for i := range want {
		if rules[i] != want[i] {
			t.Fatalf("rules = %v, want %v", rules, want)
		}
	}
}

func TestLockEnhancedLanBindingDisablesWildcardWhenAllowLanOff(t *testing.T) {
	rawMap := map[string]interface{}{
		"bind-address": "*",
	}

	lockEnhancedLanBinding(rawMap)

	if rawMap["allow-lan"] != false {
		t.Fatalf("allow-lan = %v, want false", rawMap["allow-lan"])
	}
	if rawMap["bind-address"] != "127.0.0.1" {
		t.Fatalf("bind-address = %v, want 127.0.0.1", rawMap["bind-address"])
	}
}

func TestLockEnhancedLanBindingPreservesExplicitAllowLan(t *testing.T) {
	rawMap := map[string]interface{}{
		"allow-lan":    true,
		"bind-address": "*",
	}

	lockEnhancedLanBinding(rawMap)

	if rawMap["allow-lan"] != true {
		t.Fatalf("allow-lan = %v, want true", rawMap["allow-lan"])
	}
	if rawMap["bind-address"] != "*" {
		t.Fatalf("bind-address = %v, want *", rawMap["bind-address"])
	}
}
