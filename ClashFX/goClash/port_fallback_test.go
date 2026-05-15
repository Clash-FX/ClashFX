package main

import (
	"reflect"
	"testing"
)

func TestPortValueOrZero(t *testing.T) {
	tests := []struct {
		name string
		in   interface{}
		want int
	}{
		{"nil", nil, 0},
		{"int", 7890, 7890},
		{"int zero", 0, 0},
		{"int negative", -1, -1},
		{"int64", int64(7890), 7890},
		{"uint64", uint64(7890), 7890},
		{"float64", float64(7890), 7890},
		{"string numeric", "7890", 7890},
		{"string non-numeric", "abc", 0},
		{"string empty", "", 0},
		{"bool", true, 0},
		{"map", map[string]int{"x": 1}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := portValueOrZero(tt.in)
			if got != tt.want {
				t.Errorf("portValueOrZero(%v) = %d, want %d", tt.in, got, tt.want)
			}
		})
	}
}

func TestEnsureDefaultProxyPort(t *testing.T) {
	tests := []struct {
		name string
		in   map[string]interface{}
		want map[string]interface{}
	}{
		{
			name: "empty map injects default mixed-port",
			in:   map[string]interface{}{},
			want: map[string]interface{}{"mixed-port": defaultMixedPort},
		},
		{
			name: "keep existing mixed-port",
			in:   map[string]interface{}{"mixed-port": 7891},
			want: map[string]interface{}{"mixed-port": 7891},
		},
		{
			name: "promote port to mixed-port",
			in:   map[string]interface{}{"port": 7890},
			want: map[string]interface{}{"mixed-port": 7890},
		},
		{
			name: "promote socks-port to mixed-port when no port",
			in:   map[string]interface{}{"socks-port": 1080},
			want: map[string]interface{}{"mixed-port": 1080},
		},
		{
			name: "port wins over socks-port when both present",
			in:   map[string]interface{}{"port": 7890, "socks-port": 1080},
			want: map[string]interface{}{"mixed-port": 7890, "socks-port": 1080},
		},
		{
			name: "drop socks-port when it equals promoted mixed-port",
			in:   map[string]interface{}{"port": 7890, "socks-port": 7890},
			want: map[string]interface{}{"mixed-port": 7890},
		},
		{
			name: "mixed-port zero treated as missing",
			in:   map[string]interface{}{"mixed-port": 0, "port": 7890},
			want: map[string]interface{}{"mixed-port": 7890},
		},
		{
			name: "string port still promotes",
			in:   map[string]interface{}{"port": "7890"},
			want: map[string]interface{}{"mixed-port": 7890},
		},
		{
			name: "int64 mixed-port respected",
			in:   map[string]interface{}{"mixed-port": int64(7891)},
			want: map[string]interface{}{"mixed-port": int64(7891)},
		},
		{
			name: "non-port fields preserved",
			in:   map[string]interface{}{"port": 7890, "external-controller": "127.0.0.1:9090"},
			want: map[string]interface{}{"mixed-port": 7890, "external-controller": "127.0.0.1:9090"},
		},
		{
			name: "all three zero uses default, explicit zeros preserved",
			in:   map[string]interface{}{"mixed-port": 0, "port": 0, "socks-port": 0},
			want: map[string]interface{}{"mixed-port": defaultMixedPort, "port": 0, "socks-port": 0},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ensureDefaultProxyPort(tt.in)
			if !reflect.DeepEqual(tt.in, tt.want) {
				t.Errorf("after ensureDefaultProxyPort = %v, want %v", tt.in, tt.want)
			}
		})
	}
}
