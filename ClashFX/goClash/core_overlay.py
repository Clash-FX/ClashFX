#!/usr/bin/env python3
"""Build the bundled mihomo core with ClashFX's temporary upstream fixes.

Keep the workaround small and fail closed when the pinned dependency changes so
an upstream update cannot silently drop or misapply it.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from typing import Iterator

from core_listener_constructor_overlay import patch_listener_constructor_cleanup
from core_tproxy_constructor_overlay import patch_tproxy_constructor_cleanup
from core_runtime_apply_overlay import patch_runtime_config_apply
from core_startup_selection_overlay import patch_startup_selection_overlay
from core_inbound_access_overlay import patch_inbound_access_state
from core_route_lifecycle_overlay import patch_route_lifecycle


SING_MODULE = "github.com/metacubex/sing"
EXPECTED_SING_VERSION = "v0.5.7"
MIHOMO_MODULE = "github.com/metacubex/mihomo"
EXPECTED_MIHOMO_VERSION = "v1.19.24"
MODULE_ROOT = pathlib.Path(__file__).resolve().parent
ORIGINAL_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN)"
)
PATCHED_IS_CLOSED = (
    "return IsMulti(err, io.EOF, net.ErrClosed, io.ErrClosedPipe, os.ErrClosed, "
    "syscall.EPIPE, syscall.ECONNRESET, syscall.ENOTCONN, syscall.ENOTSOCK, "
    "syscall.EBADF)"
)
ORIGINAL_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""
PATCHED_URL_TEST = """func (u *URLTest) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	// Now() can run while the candidates are still being tested and cache a
	// partial choice for ten seconds. Clear that value once all results are in
	// so the next selection uses the complete result set and tolerance.
	u.fastSingle.Reset()
	defer u.fastSingle.Reset()
	return u.GroupBase.URLTest(ctx, u.testUrl, expectedStatus)
}"""
ROUTE_PROXIES_SOURCE_SHA256 = "06226532477195683dce8f8ff6bc5657f322a26521cd7ee52c257e52579ce246"
PROBE_DIAGNOSTIC_IMPORTS = '''import (
	"context"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)'''
PROBE_DIAGNOSTIC_HELPERS = r'''type clashFXProbeError struct {
	Kind string `json:"kind"`
	Code string `json:"code"`
}

type clashFXProbeFailure struct {
	Message          string            `json:"message"`
	ClashFXProbeError clashFXProbeError `json:"clashfx_probe_error"`
}

func classifyClashFXProbeError(err error) clashFXProbeError {
	if err == nil {
		return clashFXProbeError{Kind: "unknown", Code: "probe_failed"}
	}

	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		if dnsErr.IsTimeout {
			return clashFXProbeError{Kind: "dns", Code: "dns_timeout"}
		}
		return clashFXProbeError{Kind: "dns", Code: "dns_resolution_failed"}
	}

	var unknownAuthority x509.UnknownAuthorityError
	var unknownAuthorityPointer *x509.UnknownAuthorityError
	if errors.As(err, &unknownAuthority) || errors.As(err, &unknownAuthorityPointer) {
		return clashFXProbeError{Kind: "tls", Code: "tls_unknown_authority"}
	}
	var invalidCertificate x509.CertificateInvalidError
	var invalidCertificatePointer *x509.CertificateInvalidError
	if (errors.As(err, &invalidCertificate) && invalidCertificate.Reason == x509.Expired) ||
		(errors.As(err, &invalidCertificatePointer) && invalidCertificatePointer != nil && invalidCertificatePointer.Reason == x509.Expired) {
		return clashFXProbeError{Kind: "tls", Code: "tls_expired"}
	}
	var hostnameError x509.HostnameError
	var hostnameErrorPointer *x509.HostnameError
	if errors.As(err, &hostnameError) || errors.As(err, &hostnameErrorPointer) {
		return clashFXProbeError{Kind: "tls", Code: "tls_name_mismatch"}
	}

	if errors.Is(err, context.DeadlineExceeded) {
		return clashFXProbeError{Kind: "timeout", Code: "probe_timeout"}
	}
	var networkError net.Error
	if errors.As(err, &networkError) && networkError.Timeout() {
		return clashFXProbeError{Kind: "timeout", Code: "probe_timeout"}
	}

	message := strings.ToLower(err.Error())
	if strings.Contains(message, "http need auth") ||
		strings.Contains(message, "proxy authentication required") ||
		strings.Contains(message, "authentication failed") ||
		strings.Contains(message, "authentication required") ||
		strings.Contains(message, "invalid credentials") ||
		strings.Contains(message, "401 unauthorized") ||
		strings.Contains(message, "407 proxy auth") {
		return clashFXProbeError{Kind: "authentication", Code: "authentication_failed"}
	}

	if strings.Contains(message, "quic: handshake") || strings.Contains(message, "quic handshake") {
		return clashFXProbeError{Kind: "quic", Code: "quic_handshake_failed"}
	}
	if strings.Contains(message, "certificate signed by unknown authority") ||
		strings.Contains(message, "x509: unknown authority") {
		return clashFXProbeError{Kind: "tls", Code: "tls_unknown_authority"}
	}
	if strings.Contains(message, "certificate has expired") ||
		strings.Contains(message, "certificate expired") {
		return clashFXProbeError{Kind: "tls", Code: "tls_expired"}
	}
	if strings.Contains(message, "certificate is valid for") ||
		strings.Contains(message, "certificate name mismatch") ||
		strings.Contains(message, "doesn't contain any ip sans") {
		return clashFXProbeError{Kind: "tls", Code: "tls_name_mismatch"}
	}
	if strings.Contains(message, "tls:") || strings.Contains(message, "tls handshake") ||
		strings.Contains(message, "x509:") || strings.Contains(message, "certificate verify failed") {
		return clashFXProbeError{Kind: "tls", Code: "tls_failure"}
	}

	var operationError *net.OpError
	if errors.As(err, &operationError) && operationError.Op == "dial" {
		return clashFXProbeError{Kind: "dial", Code: "dial_failed"}
	}
	if strings.Contains(message, "dial tcp ") || strings.Contains(message, "connection refused") ||
		strings.Contains(message, "no route to host") || strings.Contains(message, "network is unreachable") {
		return clashFXProbeError{Kind: "dial", Code: "dial_failed"}
	}

	var requestError *url.Error
	if errors.As(err, &requestError) || strings.Contains(message, "http: ") ||
		strings.Contains(message, "http request") {
		return clashFXProbeError{Kind: "http", Code: "http_request_failed"}
	}

	return clashFXProbeError{Kind: "unknown", Code: "probe_failed"}
}

func writeClashFXProbeFailure(w http.ResponseWriter, r *http.Request, status int, message string, diagnostic clashFXProbeError) {
	render.Status(r, status)
	render.JSON(w, r, clashFXProbeFailure{
		Message:          message,
		ClashFXProbeError: diagnostic,
	})
}
'''
UPSTREAM_PROBE_DIAGNOSTIC_TEST = r'''package route

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strings"
	"testing"

	"github.com/metacubex/http"
	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

type clashFXProbeTestProxy struct {
	urlTest func(context.Context) (uint16, error)
}

func (p *clashFXProbeTestProxy) Name() string { return "test-proxy" }
func (p *clashFXProbeTestProxy) Type() C.AdapterType { return C.Direct }
func (p *clashFXProbeTestProxy) Addr() string { return "" }
func (p *clashFXProbeTestProxy) SupportUDP() bool { return false }
func (p *clashFXProbeTestProxy) ProxyInfo() C.ProxyInfo { return C.ProxyInfo{} }
func (p *clashFXProbeTestProxy) MarshalJSON() ([]byte, error) { return []byte(`{}`), nil }
func (p *clashFXProbeTestProxy) DialContext(context.Context, *C.Metadata) (C.Conn, error) { return nil, nil }
func (p *clashFXProbeTestProxy) ListenPacketContext(context.Context, *C.Metadata) (C.PacketConn, error) { return nil, nil }
func (p *clashFXProbeTestProxy) SupportUOT() bool { return false }
func (p *clashFXProbeTestProxy) IsL3Protocol(*C.Metadata) bool { return false }
func (p *clashFXProbeTestProxy) Unwrap(*C.Metadata, bool) C.Proxy { return nil }
func (p *clashFXProbeTestProxy) Close() error { return nil }
func (p *clashFXProbeTestProxy) Adapter() C.ProxyAdapter { return p }
func (p *clashFXProbeTestProxy) AliveForTestUrl(string) bool { return false }
func (p *clashFXProbeTestProxy) DelayHistory() []C.DelayHistory { return nil }
func (p *clashFXProbeTestProxy) ExtraDelayHistories() map[string]C.ProxyState { return nil }
func (p *clashFXProbeTestProxy) LastDelayForTestUrl(string) uint16 { return 0 }
func (p *clashFXProbeTestProxy) URLTest(ctx context.Context, _ string, _ utils.IntRanges[uint16]) (uint16, error) {
	return p.urlTest(ctx)
}

func clashFXInvokeDelayHandler(proxy C.Proxy, target string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, target, nil)
	req = req.WithContext(context.WithValue(req.Context(), CtxKeyProxy, proxy))
	recorder := httptest.NewRecorder()
	getProxyDelay(recorder, req)
	return recorder
}

func clashFXDelayTarget(timeout string) string {
	query := url.Values{
		"url":      {"https://alice:node-secret@probe.example.test/check?token=query-secret"},
		"timeout":  {timeout},
		"expected": {"200"},
	}
	return "/delay?" + query.Encode()
}

func TestClashFXProbeErrorClassification(t *testing.T) {
	certificate := &x509.Certificate{}
	tests := []struct {
		name string
		err  error
		kind string
		code string
	}{
		{"dns", &net.DNSError{Err: "no such host", Name: "secret.example.test"}, "dns", "dns_resolution_failed"},
		{"dns timeout", &net.DNSError{Err: "i/o timeout", Name: "secret.example.test", IsTimeout: true}, "dns", "dns_timeout"},
		{"unknown authority", x509.UnknownAuthorityError{Cert: certificate}, "tls", "tls_unknown_authority"},
		{"unknown authority pointer", &x509.UnknownAuthorityError{Cert: certificate}, "tls", "tls_unknown_authority"},
		{"expired certificate", x509.CertificateInvalidError{Cert: certificate, Reason: x509.Expired}, "tls", "tls_expired"},
		{"expired certificate pointer", &x509.CertificateInvalidError{Cert: certificate, Reason: x509.Expired}, "tls", "tls_expired"},
		{"hostname mismatch", x509.HostnameError{Host: "secret.example.test", Certificate: certificate}, "tls", "tls_name_mismatch"},
		{"hostname mismatch pointer", &x509.HostnameError{Host: "secret.example.test", Certificate: certificate}, "tls", "tls_name_mismatch"},
		{"authentication", errors.New("authentication failed for alice:node-secret at 203.0.113.8"), "authentication", "authentication_failed"},
		{"TLS pattern", errors.New("tls: handshake failure for https://alice:node-secret@203.0.113.8/?token=query-secret"), "tls", "tls_failure"},
		{"QUIC pattern", errors.New("quic: handshake failed for 203.0.113.8"), "quic", "quic_handshake_failed"},
		{"dial pattern", errors.New("dial tcp 203.0.113.8:443: connection refused"), "dial", "dial_failed"},
		{"HTTP request", &url.Error{Op: "Head", URL: "https://alice:node-secret@203.0.113.8/?token=query-secret", Err: errors.New("request failed")}, "http", "http_request_failed"},
		{"deadline", context.DeadlineExceeded, "timeout", "probe_timeout"},
		{"unknown", errors.New("opaque failure for 203.0.113.8 with node-secret"), "unknown", "probe_failed"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := classifyClashFXProbeError(test.err)
			if got.Kind != test.kind || got.Code != test.code {
				t.Fatalf("classification = {%q, %q}, want {%q, %q}", got.Kind, got.Code, test.kind, test.code)
			}
		})
	}
}

func TestClashFXDelayHandlerPreservesSafeFailureEnvelope(t *testing.T) {
	proxy := &clashFXProbeTestProxy{urlTest: func(context.Context) (uint16, error) {
		return 23, &url.Error{Op: "Head", URL: "https://alice:node-secret@203.0.113.8/?token=query-secret", Err: errors.New("request failed")}
	}}
	response := clashFXInvokeDelayHandler(proxy, clashFXDelayTarget("1000"))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusServiceUnavailable)
	}
	var body clashFXProbeFailure
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode failure envelope: %v", err)
	}
	if body.Message != "An error occurred in the delay test" {
		t.Fatalf("message = %q", body.Message)
	}
	if body.ClashFXProbeError.Kind != "http" || body.ClashFXProbeError.Code != "http_request_failed" {
		t.Fatalf("diagnostic = %+v", body.ClashFXProbeError)
	}
	for _, secret := range []string{"node-secret", "203.0.113.8", "query-secret", "probe.example.test"} {
		if strings.Contains(response.Body.String(), secret) {
			t.Fatalf("response leaked %q: %s", secret, response.Body.String())
		}
	}
}

func TestClashFXDelayHandlerKeepsUnknownFailureUnknown(t *testing.T) {
	proxy := &clashFXProbeTestProxy{urlTest: func(context.Context) (uint16, error) {
		return 0, errors.New("opaque failure for 203.0.113.8 with node-secret and query-secret")
	}}
	response := clashFXInvokeDelayHandler(proxy, clashFXDelayTarget("1000"))
	var body clashFXProbeFailure
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode failure envelope: %v", err)
	}
	if body.Message != "An error occurred in the delay test" || body.ClashFXProbeError.Kind != "unknown" ||
		body.ClashFXProbeError.Code != "probe_failed" {
		t.Fatalf("unknown failure was misclassified: %+v", body)
	}
	for _, secret := range []string{"node-secret", "203.0.113.8", "query-secret"} {
		if strings.Contains(response.Body.String(), secret) {
			t.Fatalf("response leaked %q: %s", secret, response.Body.String())
		}
	}
}

func TestClashFXDelayHandlerZeroDelayAndSuccess(t *testing.T) {
	zero := clashFXInvokeDelayHandler(&clashFXProbeTestProxy{urlTest: func(context.Context) (uint16, error) {
		return 0, nil
	}}, clashFXDelayTarget("1000"))
	if zero.Code != http.StatusServiceUnavailable {
		t.Fatalf("zero-delay status = %d", zero.Code)
	}
	var failure clashFXProbeFailure
	if err := json.Unmarshal(zero.Body.Bytes(), &failure); err != nil {
		t.Fatalf("decode zero-delay envelope: %v", err)
	}
	if failure.Message != "An error occurred in the delay test" ||
		failure.ClashFXProbeError.Kind != "measurement" || failure.ClashFXProbeError.Code != "zero_delay" {
		t.Fatalf("zero-delay envelope = %+v", failure)
	}

	success := clashFXInvokeDelayHandler(&clashFXProbeTestProxy{urlTest: func(context.Context) (uint16, error) {
		return 37, nil
	}}, clashFXDelayTarget("1000"))
	if success.Code != http.StatusOK || strings.TrimSpace(success.Body.String()) != `{"delay":37}` {
		t.Fatalf("success = %d %s", success.Code, success.Body.String())
	}
}

func TestClashFXDelayHandlerTimeoutEnvelope(t *testing.T) {
	proxy := &clashFXProbeTestProxy{urlTest: func(ctx context.Context) (uint16, error) {
		<-ctx.Done()
		return 0, ctx.Err()
	}}
	response := clashFXInvokeDelayHandler(proxy, clashFXDelayTarget("1"))
	if response.Code != http.StatusGatewayTimeout {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusGatewayTimeout)
	}
	var body clashFXProbeFailure
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode timeout envelope: %v", err)
	}
	if body.Message != "Timeout" || body.ClashFXProbeError.Kind != "timeout" || body.ClashFXProbeError.Code != "probe_timeout" {
		t.Fatalf("timeout envelope = %+v", body)
	}
}
'''
QUEUE_SOURCE_SHA256 = "dce56d5c8e57c4a5df35c2960ced52ee19b4441864e9908692c3321be84e71de"
INBOUND_LISTENER_SOURCE_SHA256 = "0e059b1be9994fb8c4fbb8efe7bc03add9c797a284562114212a6a4c683019fd"
ROUTE_CONFIGS_SOURCE_SHA256 = "dc8bc7f031f292d1cbd9deede0b01c169689c9070fcc767aa81e402b7e41c018"
ORIGINAL_QUEUE_POP = """func (q *Queue[T]) Pop() (head T) {
	if len(q.items) == 0 {
		return
	}

	q.lock.Lock()
	head = q.items[0]
	q.items = q.items[1:]
	q.lock.Unlock()
	return head
}"""
PATCHED_QUEUE_POP = """func (q *Queue[T]) Pop() (head T) {
	q.lock.Lock()
	defer q.lock.Unlock()
	if len(q.items) == 0 {
		return
	}

	head = q.items[0]
	q.items = q.items[1:]
	return head
}"""
ORIGINAL_QUEUE_LAST = """func (q *Queue[T]) Last() (last T) {
	if len(q.items) == 0 {
		return
	}

	q.lock.RLock()
	last = q.items[len(q.items)-1]
	q.lock.RUnlock()
	return last
}"""
PATCHED_QUEUE_LAST = """func (q *Queue[T]) Last() (last T) {
	q.lock.RLock()
	defer q.lock.RUnlock()
	if len(q.items) == 0 {
		return
	}

	return q.items[len(q.items)-1]
}"""
ORIGINAL_PATCH_INBOUND_LISTENERS = """func PatchInboundListeners(newListenerMap map[string]C.InboundListener, tunnel C.Tunnel, dropOld bool) {
	inboundMux.Lock()
	defer inboundMux.Unlock()

	for name, newListener := range newListenerMap {
		if oldListener, ok := inboundListeners[name]; ok {
			if !oldListener.Config().Equal(newListener.Config()) {
				_ = oldListener.Close()
			} else {
				continue
			}
		}
		if err := newListener.Listen(tunnel); err != nil {
			log.Errorln("Listener %s listen err: %s", name, err.Error())
			continue
		}
		inboundListeners[name] = newListener
	}

	if dropOld {
		for name, oldListener := range inboundListeners {
			if _, ok := newListenerMap[name]; !ok {
				_ = oldListener.Close()
				delete(inboundListeners, name)
			}
		}
	}
}"""
PATCHED_PATCH_INBOUND_LISTENERS = """func PatchInboundListeners(newListenerMap map[string]C.InboundListener, tunnel C.Tunnel, dropOld bool) {
	inboundMux.Lock()
	defer inboundMux.Unlock()

	for name, newListener := range newListenerMap {
		if oldListener, ok := inboundListeners[name]; ok {
			oldConfig := oldListener.Config()
			newConfig := newListener.Config()
			if oldConfig == nil || newConfig == nil || !oldConfig.Equal(newConfig) {
				_ = oldListener.Close()
				delete(inboundListeners, name)
			} else {
				continue
			}
		}
		if err := newListener.Listen(tunnel); err != nil {
			// Some upstream listeners leave a nil transport after Listen fails,
			// yet their Close dereferences it. Contain cleanup panics so a bad
			// candidate cannot kill the core before deterministic rollback.
			func() {
				defer func() {
					if recover() != nil { log.Warnln("Listener %s failed-start cleanup panicked", name) }
				}()
				_ = newListener.Close()
			}()
			log.Errorln("Listener %s listen err: %s", name, err.Error())
			continue
		}
		inboundListeners[name] = newListener
	}

	if dropOld {
		for name, oldListener := range inboundListeners {
			if _, ok := newListenerMap[name]; !ok {
				_ = oldListener.Close()
				delete(inboundListeners, name)
			}
		}
	}
}

// ValidateInboundListeners reports whether every requested named listener is
// registered with the requested config after Listen has succeeded.
func ValidateInboundListeners(requested map[string]C.InboundListener) error {
	inboundMux.Lock()
	defer inboundMux.Unlock()

	names := make([]string, 0, len(requested))
	for name := range requested {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		want := requested[name]
		actual, ok := inboundListeners[name]
		if !ok {
			return fmt.Errorf("inbound listener %q did not start", name)
		}
		if want == nil || actual.Name() != name || actual.Config() == nil || want.Config() == nil ||
			!actual.Config().Equal(want.Config()) {
			return fmt.Errorf("inbound listener %q is running with a different config", name)
		}
	}
	return nil
}"""

ORIGINAL_RECREATE_MIXED = r"""func ReCreateMixed(port int, tunnel C.Tunnel) {
	mixedMux.Lock()
	defer mixedMux.Unlock()

	var err error
	defer func() {
		if err != nil {
			log.Errorln("Start Mixed(http+socks) server error: %s", err.Error())
		}
	}()

	addr := genAddr(bindAddress, port, allowLan)

	shouldTCPIgnore := false
	shouldUDPIgnore := false

	if mixedListener != nil {
		if mixedListener.RawAddress() != addr {
			mixedListener.Close()
			mixedListener = nil
		} else {
			shouldTCPIgnore = true
		}
	}
	if mixedUDPLister != nil {
		if mixedUDPLister.RawAddress() != addr {
			mixedUDPLister.Close()
			mixedUDPLister = nil
		} else {
			shouldUDPIgnore = true
		}
	}

	if shouldTCPIgnore && shouldUDPIgnore {
		return
	}

	if portIsZero(addr) {
		return
	}

	mixedListener, err = mixed.New(addr, tunnel)
	if err != nil {
		return
	}

	mixedUDPLister, err = socks.NewUDP(addr, tunnel)
	if err != nil {
		mixedListener.Close()
		return
	}

	log.Infoln("Mixed(http+socks) proxy listening at: %s", mixedListener.Address())
}"""
PATCHED_RECREATE_MIXED = r"""func ReCreateMixed(port int, tunnel C.Tunnel) {
	mixedMux.Lock()
	defer mixedMux.Unlock()
	addr := genAddr(bindAddress, port, allowLan)
	if mixedListener != nil && mixedUDPLister != nil &&
		mixedListener.RawAddress() == addr && mixedUDPLister.RawAddress() == addr {
		return
	}
	if mixedListener != nil {
		_ = mixedListener.Close()
		mixedListener = nil
	}
	if mixedUDPLister != nil {
		_ = mixedUDPLister.Close()
		mixedUDPLister = nil
	}
	if portIsZero(addr) {
		return
	}
	tcpListener, err := mixed.New(addr, tunnel)
	if err != nil {
		log.Errorln("Start Mixed(http+socks) server error: %s", err)
		return
	}
	udpListener, err := socks.NewUDP(addr, tunnel)
	if err != nil {
		_ = tcpListener.Close()
		log.Errorln("Start Mixed(http+socks) server error: %s", err)
		return
	}
	mixedListener = tcpListener
	mixedUDPLister = udpListener
	log.Infoln("Mixed(http+socks) proxy listening at: %s", mixedListener.Address())
}"""

ORIGINAL_RECREATE_SOCKS = r"""func ReCreateSocks(port int, tunnel C.Tunnel) {
	socksMux.Lock()
	defer socksMux.Unlock()

	var err error
	defer func() {
		if err != nil {
			log.Errorln("Start SOCKS server error: %s", err.Error())
		}
	}()

	addr := genAddr(bindAddress, port, allowLan)

	shouldTCPIgnore := false
	shouldUDPIgnore := false

	if socksListener != nil {
		if socksListener.RawAddress() != addr {
			socksListener.Close()
			socksListener = nil
		} else {
			shouldTCPIgnore = true
		}
	}

	if socksUDPListener != nil {
		if socksUDPListener.RawAddress() != addr {
			socksUDPListener.Close()
			socksUDPListener = nil
		} else {
			shouldUDPIgnore = true
		}
	}

	if shouldTCPIgnore && shouldUDPIgnore {
		return
	}

	if portIsZero(addr) {
		return
	}

	tcpListener, err := socks.New(addr, tunnel)
	if err != nil {
		return
	}

	udpListener, err := socks.NewUDP(addr, tunnel)
	if err != nil {
		tcpListener.Close()
		return
	}

	socksListener = tcpListener
	socksUDPListener = udpListener

	log.Infoln("SOCKS proxy listening at: %s", socksListener.Address())
}"""
PATCHED_RECREATE_SOCKS = r"""func ReCreateSocks(port int, tunnel C.Tunnel) {
	socksMux.Lock()
	defer socksMux.Unlock()
	addr := genAddr(bindAddress, port, allowLan)
	if socksListener != nil && socksUDPListener != nil &&
		socksListener.RawAddress() == addr && socksUDPListener.RawAddress() == addr {
		return
	}
	if socksListener != nil {
		_ = socksListener.Close()
		socksListener = nil
	}
	if socksUDPListener != nil {
		_ = socksUDPListener.Close()
		socksUDPListener = nil
	}
	if portIsZero(addr) {
		return
	}
	tcpListener, err := socks.New(addr, tunnel)
	if err != nil {
		log.Errorln("Start SOCKS server error: %s", err)
		return
	}
	udpListener, err := socks.NewUDP(addr, tunnel)
	if err != nil {
		_ = tcpListener.Close()
		log.Errorln("Start SOCKS server error: %s", err)
		return
	}
	socksListener = tcpListener
	socksUDPListener = udpListener
	log.Infoln("SOCKS proxy listening at: %s", socksListener.Address())
}"""

GLOBAL_LISTENER_VALIDATION = r"""// ValidateGlobalListenerPorts confirms both halves of SOCKS/Mixed/TProxy.
// A TCP address alone is not evidence that the paired UDP bind succeeded.
func ValidateGlobalListenerPorts(expected Ports) error {
	check := func(name string, port int, active bool) error {
		if !active {
			return fmt.Errorf("global %s listener on port %d is not ready", name, port)
		}
		return nil
	}
	httpMux.Lock()
	ready := (expected.Port == 0 && httpListener == nil) || (expected.Port > 0 && httpListener != nil && httpListener.RawAddress() == genAddr(bindAddress, expected.Port, allowLan))
	httpMux.Unlock()
	if err := check("HTTP", expected.Port, ready); err != nil {
		return err
	}
	socksMux.Lock()
	ready = (expected.SocksPort == 0 && socksListener == nil && socksUDPListener == nil) || (expected.SocksPort > 0 && socksListener != nil && socksUDPListener != nil && socksListener.RawAddress() == genAddr(bindAddress, expected.SocksPort, allowLan) && socksUDPListener.RawAddress() == genAddr(bindAddress, expected.SocksPort, allowLan))
	socksMux.Unlock()
	if err := check("SOCKS TCP/UDP", expected.SocksPort, ready); err != nil {
		return err
	}
	mixedMux.Lock()
	ready = (expected.MixedPort == 0 && mixedListener == nil && mixedUDPLister == nil) || (expected.MixedPort > 0 && mixedListener != nil && mixedUDPLister != nil && mixedListener.RawAddress() == genAddr(bindAddress, expected.MixedPort, allowLan) && mixedUDPLister.RawAddress() == genAddr(bindAddress, expected.MixedPort, allowLan))
	mixedMux.Unlock()
	if err := check("Mixed TCP/UDP", expected.MixedPort, ready); err != nil {
		return err
	}
	redirMux.Lock()
	// Darwin supports TCP redirection; the upstream optional UDP attempt may fail.
	ready = (expected.RedirPort == 0 && redirListener == nil) || (expected.RedirPort > 0 && redirListener != nil && redirListener.RawAddress() == genAddr(bindAddress, expected.RedirPort, allowLan))
	redirMux.Unlock()
	if err := check("Redir TCP", expected.RedirPort, ready); err != nil {
		return err
	}
	tproxyMux.Lock()
	ready = (expected.TProxyPort == 0 && tproxyListener == nil && tproxyUDPListener == nil) || (expected.TProxyPort > 0 && tproxyListener != nil && tproxyUDPListener != nil && tproxyListener.RawAddress() == genAddr(bindAddress, expected.TProxyPort, allowLan) && tproxyUDPListener.RawAddress() == genAddr(bindAddress, expected.TProxyPort, allowLan))
	tproxyMux.Unlock()
	return check("TProxy TCP/UDP", expected.TProxyPort, ready)
}

// ValidateAdditionalGlobalListeners checks URL-based and QUIC globals, whose
// actual readiness cannot be inferred from the five basic proxy ports.
func ValidateAdditionalGlobalListeners(ssRaw, vmessRaw string, expectedTuic LC.TuicServer) error {
	return ValidateSelectedGlobalListeners(&ssRaw, &vmessRaw, &expectedTuic)
}

// PATCH must not reconstruct an unchanged URL global from its JSON readback.
func ValidateSelectedGlobalListeners(ssRaw, vmessRaw *string, expectedTuic *LC.TuicServer) error {
	if ssRaw != nil {
		ssMux.Lock()
		ssReady := shadowSocksListener == nil
		if *ssRaw != "" {
			addr, cipher, password, err := embedSS.ParseSSURL(*ssRaw)
			if err != nil {
				ssMux.Unlock()
				return fmt.Errorf("global Shadowsocks config is invalid")
			}
			want := LC.ShadowsocksServer{Enable: true, Listen: addr, Cipher: cipher, Password: password, Udp: true}
			ssReady = shadowSocksListener != nil && shadowSocksListener.Config() == want.String()
		}
		ssMux.Unlock()
		if !ssReady {
			return fmt.Errorf("global Shadowsocks listener is not ready")
		}
	}
	if vmessRaw != nil {
		vmessMux.Lock()
		ready := vmessListener == nil
		if *vmessRaw != "" {
			addr, user, password, err := sing_vmess.ParseVmessURL(*vmessRaw)
			if err != nil {
				vmessMux.Unlock()
				return fmt.Errorf("global VMess config is invalid")
			}
			want := LC.VmessServer{Enable: true, Listen: addr, Users: []LC.VmessUser{{Username: user, UUID: password, AlterID: 1}}}
			ready = vmessListener != nil && vmessListener.Config() == want.String()
		}
		vmessMux.Unlock()
		if !ready {
			return fmt.Errorf("global VMess listener is not ready")
		}
	}
	if expectedTuic != nil {
		normalized := normalizeTuicConfig(*expectedTuic)
		tuicMux.Lock()
		ready := tuicListener == nil
		if normalized.Enable {
			ready = tuicListener != nil && tuicListener.Config().String() == normalized.String()
		}
		tuicMux.Unlock()
		if !ready {
			return fmt.Errorf("global TUIC listener is not ready")
		}
	}
	return nil
}

// Match the defaults and datagram clamp applied by the pinned TUIC constructor.
func normalizeTuicConfig(c LC.TuicServer) LC.TuicServer {
	if c.MaxIdleTime == 0 {
		c.MaxIdleTime = 15000
	}
	if c.AuthenticationTimeout == 0 {
		c.AuthenticationTimeout = 1000
	}
	if c.CWND == 0 {
		c.CWND = 32
	}
	if c.MaxUdpRelayPacketSize == 0 {
		c.MaxUdpRelayPacketSize = 1500
	}
	overhead := tuicProtocol.PacketOverHeadV4
	if len(c.Token) == 0 {
		overhead = tuicProtocol.PacketOverHeadV5
	}
	maxSize := c.MaxUdpRelayPacketSize + overhead
	if maxSize > 1400 {
		maxSize = 1400
	}
	c.MaxUdpRelayPacketSize = maxSize - overhead
	return c
}"""
RUNTIME_LISTENER_VALIDATION = r"""package executor

import (
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/listener"
)

// ValidateRuntimeListeners shares startup and reload readiness policy.
func ValidateRuntimeListeners(cfg *config.Config, force bool) error {
	mux.Lock()
	defer mux.Unlock()
	return validateRuntimeListeners(cfg, force)
}
func validateRuntimeListeners(cfg *config.Config, force bool) error {
	if err := listener.ValidateInboundListeners(cfg.Listeners); err != nil {
		return err
	}
	if !force {
		return nil
	} // Non-forced upstream API requests intentionally keep global listeners.
	g := cfg.General
	if err := listener.ValidateGlobalListenerPorts(listener.Ports{Port: g.Port, SocksPort: g.SocksPort, MixedPort: g.MixedPort, RedirPort: g.RedirPort, TProxyPort: g.TProxyPort}); err != nil {
		return err
	}
	return listener.ValidateAdditionalGlobalListeners(g.ShadowSocksConfig, g.VmessConfig, g.TuicServer)
}"""

ORIGINAL_CONFIGS_APPLY = """\texecutor.ApplyConfig(cfg, force)
\trender.NoContent(w, r)"""
PATCHED_CONFIGS_APPLY = """\texecutor.ApplyConfig(cfg, force)
\tif err := executor.ValidateRuntimeListeners(cfg, force); err != nil {
\t\trender.Status(r, http.StatusBadRequest)
\t\trender.JSON(w, r, newError(err.Error()))
\t\treturn
\t}
\trender.NoContent(w, r)"""
CACHEFILE_SOURCE_SHA256 = {
    "component/profile/cachefile/cache.go": "42dff0ec9817dd1abef1d50192e99e012b34cf49b0a6fab897b8fcec2061dc95",
    "component/profile/cachefile/storage.go": "7d4d232edd115890457605a217eb0a790d1a68d13084f8b0e92903ad6c1be4dc",
    "component/profile/cachefile/etag.go": "6b98227e3a921db09563b1713d3b533440aa1a656d8154142b14517efca19ab9",
    "component/profile/cachefile/subscriptioninfo.go": "b5ed8f0f109ec8f28c70309800fc6b6c1bce8ff577fc323fd900e6cff9f1a24c",
    "component/profile/cachefile/fakeip.go": "1f98752ff24228483d6a52bc9902d5607762a6a0990d203a9e7bf35acf70ebbc",
}


def _replace_once(source: str, original: str, replacement: str, label: str) -> str:
    count = source.count(original)
    if count != 1:
        raise RuntimeError(f"Expected one {label} in pinned Mihomo source; found {count}")
    return source.replace(original, replacement, 1)


def _add_cache_read_lock(source: str, signature: str, receiver: str = "c") -> str:
    insertion = (
        f"{signature}\n"
        f"\t{receiver}.mu.RLock()\n"
        f"\tdefer {receiver}.mu.RUnlock()"
    )
    return _replace_once(source, signature, insertion, signature)


def _patch_cachefile_lifecycle(mihomo_root: pathlib.Path) -> None:
    cachefile_root = mihomo_root / "component" / "profile" / "cachefile"
    originals: dict[str, str] = {}
    for relative_path, expected_hash in CACHEFILE_SOURCE_SHA256.items():
        source_path = mihomo_root / relative_path
        original = source_path.read_text(encoding="utf-8")
        actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(
                f"Pinned CacheFile source changed at {source_path}; "
                "review the ClashFX cache lifecycle overlay"
            )
        originals[relative_path] = original
    for relative_path in originals:
        source_path = mihomo_root / relative_path
        os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
    os.chmod(
        cachefile_root,
        cachefile_root.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR,
    )

    cache_path = "component/profile/cachefile/cache.go"
    source = originals[cache_path]
    source = _replace_once(
        source,
        "// CacheFile store and update the cache file",
        "// CacheFile stores and updates the cache file. Every DB user must hold\n// mu.RLock for the complete operation; Close and Reopen take mu exclusively.",
        "CacheFile lifecycle comment",
    )
    source = _replace_once(
        source,
        "type CacheFile struct {\n\tDB *bbolt.DB\n}",
        "type CacheFile struct {\n\tmu     sync.RWMutex\n\tDB     *bbolt.DB\n\tclosed bool\n}",
        "CacheFile fields",
    )
    source = _add_cache_read_lock(
        source,
        "func (c *CacheFile) SetSelected(group, selected string) {",
    )
    source = _add_cache_read_lock(
        source,
        "func (c *CacheFile) SelectedMap() map[string]string {",
    )
    source = _replace_once(
        source,
        "func (c *CacheFile) Close() error {\n\treturn c.DB.Close()\n}",
        """func (c *CacheFile) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.DB == nil || c.closed {
		return nil
	}
	err := c.DB.Close()
	c.closed = true
	return err
}

// Reopen replaces the database only while all CacheFile operations are gated.
func (c *CacheFile) Reopen(path string, mode os.FileMode, options *bbolt.Options) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.DB != nil && !c.closed {
		return nil
	}
	db, err := bbolt.Open(path, mode, options)
	if err != nil {
		return err
	}
	c.DB = db
	c.closed = false
	return nil
}""",
        "CacheFile.Close implementation",
    )
    source = _replace_once(
        source,
        "defaultCache = &CacheFile{\n\t\tDB: db,\n\t}",
        "defaultCache = &CacheFile{\n\t\tDB: db,\n\t\tclosed: db == nil,\n\t}",
        "CacheFile initialization",
    )
    source = source.replace("else if c.DB == nil {", "else if c.DB == nil || c.closed {")
    (cachefile_root / "cache.go").write_text(source, encoding="utf-8")

    # These methods access DB directly. Put their complete bodies under the
    # CacheFile read gate so Close and Reopen can take its exclusive side.
    signatures_by_file = {
        "component/profile/cachefile/storage.go": [
            "func (c *CacheFile) GetStorage(key string) []byte {",
            "func (c *CacheFile) SetStorage(key string, data []byte) {",
        ],
        "component/profile/cachefile/etag.go": [
            "func (c *CacheFile) SetETagWithHash(url string, etagWithHash EtagWithHash) {",
            "func (c *CacheFile) GetETagWithHash(key string) (etagWithHash EtagWithHash) {",
        ],
        "component/profile/cachefile/subscriptioninfo.go": [
            "func (c *CacheFile) SetSubscriptionInfo(name string, userInfo string) {",
            "func (c *CacheFile) GetSubscriptionInfo(name string) (userInfo string) {",
        ],
        "component/profile/cachefile/fakeip.go": [
            "func (c *FakeIpStore) GetByHost(host string) (ip netip.Addr, exist bool) {",
            "func (c *FakeIpStore) PutByHost(host string, ip netip.Addr) {",
            "func (c *FakeIpStore) GetByIP(ip netip.Addr) (host string, exist bool) {",
            "func (c *FakeIpStore) PutByIP(ip netip.Addr, host string) {",
            "func (c *FakeIpStore) DelByIP(ip netip.Addr) {",
            "func (c *FakeIpStore) FlushFakeIP() error {",
        ],
    }
    for relative_path, signatures in signatures_by_file.items():
        source = originals[relative_path]
        for signature in signatures:
            receiver = "c.CacheFile" if "FakeIpStore" in signature else "c"
            source = _add_cache_read_lock(source, signature, receiver)
        source = source.replace("if c.DB == nil {", "if c.DB == nil || c.closed {")
        source = source.replace("else if c.DB == nil {", "else if c.DB == nil || c.closed {")
        (mihomo_root / relative_path).write_text(source, encoding="utf-8")

    storage_path = mihomo_root / "component/profile/cachefile/storage.go"
    source = storage_path.read_text(encoding="utf-8")
    source = _replace_once(
        source,
        "\t\t\tc.DeleteStorage(key)",
        "\t\t\tc.deleteStorageLocked(key)",
        "corrupt-storage deletion",
    )
    source = _replace_once(
        source,
        """func (c *CacheFile) DeleteStorage(key string) {
	if c.DB == nil || c.closed {
		return
	}
	err := c.DB.Batch(func(t *bbolt.Tx) error {
		bucket := t.Bucket(bucketStorage)
		if bucket == nil {
			return nil
		}
		return bucket.Delete([]byte(key))
	})
	if err != nil {
		log.Warnln("[CacheFile] delete cache from %s failed: %s", c.DB.Path(), err.Error())
	}
}""",
        """func (c *CacheFile) DeleteStorage(key string) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	c.deleteStorageLocked(key)
}

func (c *CacheFile) deleteStorageLocked(key string) {
	if c.DB == nil || c.closed {
		return
	}
	err := c.DB.Batch(func(t *bbolt.Tx) error {
		bucket := t.Bucket(bucketStorage)
		if bucket == nil {
			return nil
		}
		return bucket.Delete([]byte(key))
	})
	if err != nil {
		log.Warnln("[CacheFile] delete cache from %s failed: %s", c.DB.Path(), err.Error())
	}
}""",
        "DeleteStorage implementation",
    )
    storage_path.write_text(source, encoding="utf-8")

    fakeip_path = mihomo_root / "component/profile/cachefile/fakeip.go"
    source = fakeip_path.read_text(encoding="utf-8")
    source = _replace_once(
        source,
        "func (c *FakeIpStore) FlushFakeIP() error {\n\tc.CacheFile.mu.RLock()\n\tdefer c.CacheFile.mu.RUnlock()\n",
        "func (c *FakeIpStore) FlushFakeIP() error {\n\tc.CacheFile.mu.RLock()\n\tdefer c.CacheFile.mu.RUnlock()\n\tif c.DB == nil || c.closed {\n\t\treturn nil\n\t}\n",
        "FlushFakeIP closed-cache guard",
    )
    fakeip_path.write_text(source, encoding="utf-8")

    subprocess.check_call(
        [
            "gofmt",
            "-w",
            str(cachefile_root / "cache.go"),
            str(cachefile_root / "storage.go"),
            str(cachefile_root / "etag.go"),
            str(cachefile_root / "subscriptioninfo.go"),
            str(cachefile_root / "fakeip.go"),
        ]
    )


DNS_SERVER_SOURCE_SHA256 = "322c9390c917161c924776806920472153bf46d4f154e26cd7c478cfc05a1dff"
PATCHED_DNS_SERVER_SOURCE = r"""package dns

import (
    "context"
    "net"
    "sync"

    "github.com/metacubex/mihomo/adapter/inbound"
    "github.com/metacubex/mihomo/common/sockopt"
    "github.com/metacubex/mihomo/component/resolver"
    "github.com/metacubex/mihomo/log"
    D "github.com/miekg/dns"
)

var (
    address string
    server = &Server{}
    serverLifecycle sync.Mutex
    dnsDefaultTTL uint32 = 600
)

type Server struct {
    serviceLock sync.RWMutex
    service resolver.Service
    tcpServer *D.Server
    udpServer *D.Server
}

func (s *Server) ServeDNS(w D.ResponseWriter, r *D.Msg) {
    s.serviceLock.RLock()
    service := s.service
    s.serviceLock.RUnlock()
    if service == nil {
        m := new(D.Msg)
        m.SetRcode(r, D.RcodeServerFailure)
        _ = w.WriteMsg(m)
        return
    }
    msg, err := service.ServeMsg(context.Background(), r)
    if err != nil {
        m := new(D.Msg)
        m.SetRcode(r, D.RcodeServerFailure)
        _ = w.WriteMsg(m)
        return
    }
    msg.Compress = true
    _ = w.WriteMsg(msg)
}

func (s *Server) SetService(service resolver.Service) {
    s.serviceLock.Lock()
    s.service = service
    s.serviceLock.Unlock()
}

// ReCreateServer owns publication and shutdown. It waits for the DNS library's
// started notification so an immediate suspend cannot miss a pending listener.
func ReCreateServer(addr string, service resolver.Service) {
    serverLifecycle.Lock()
    defer serverLifecycle.Unlock()
    if addr == address && service != nil {
        server.SetService(service)
        return
    }
    if server.tcpServer != nil {
        _ = server.tcpServer.Shutdown()
        server.tcpServer = nil
    }
    if server.udpServer != nil {
        _ = server.udpServer.Shutdown()
        server.udpServer = nil
    }
    server.SetService(nil)
    address = ""
    if addr == "" || service == nil { return }
    _, port, err := net.SplitHostPort(addr)
    if port == "0" || port == "" || err != nil { return }

    packet, err := inbound.ListenPacket("udp", addr)
    if err != nil {
        log.Errorln("Start DNS server(UDP) error: %s", err.Error())
        return
    }
    listener, err := inbound.Listen("tcp", addr)
    if err != nil {
        _ = packet.Close()
        log.Errorln("Start DNS server(TCP) error: %s", err.Error())
        return
    }
    if err := sockopt.UDPReuseaddr(packet); err != nil {
        log.Warnln("Failed to Reuse UDP Address: %s", err)
    }
    current := &Server{service: service}
    current.udpServer = &D.Server{Addr: addr, PacketConn: packet, Handler: current}
    current.tcpServer = &D.Server{Addr: addr, Listener: listener, Handler: current}
    server = current
    address = addr
    start := func(protocol string, dnsServer *D.Server) bool {
        started := make(chan bool, 1)
        var once sync.Once
        notify := func(ready bool) { once.Do(func() { started <- ready }) }
        dnsServer.NotifyStartedFunc = func() { notify(true) }
        go func() {
            defer notify(false) // Exit before startup is a failure, not readiness.
            if err := dnsServer.ActivateAndServe(); err != nil {
                log.Errorln("Start DNS server(%s) error: %s", protocol, err.Error())
            }
            if dnsServer.PacketConn != nil { _ = dnsServer.PacketConn.Close() }
            if dnsServer.Listener != nil { _ = dnsServer.Listener.Close() }
        }()
        return <-started
    }
    if !start("UDP", current.udpServer) {
        _ = listener.Close()
        current.SetService(nil)
        address = ""
        return
    }
    if !start("TCP", current.tcpServer) {
        _ = current.udpServer.Shutdown()
        current.SetService(nil)
        address = ""
        return
    }
    log.Infoln("DNS server(UDP) listening at: %s", packet.LocalAddr().String())
    log.Infoln("DNS server(TCP) listening at: %s", listener.Addr().String())
}
"""


def _patch_dns_server_lifecycle(mihomo_root: pathlib.Path) -> None:
    source_path = mihomo_root / "dns" / "server.go"
    original = source_path.read_bytes()
    if hashlib.sha256(original).hexdigest() != DNS_SERVER_SOURCE_SHA256:
        raise RuntimeError("Pinned DNS server source changed; review the lifecycle overlay")
    os.chmod(source_path, source_path.stat().st_mode | stat.S_IWUSR)
    source_path.write_text(PATCHED_DNS_SERVER_SOURCE, encoding="utf-8")
    formatted = subprocess.check_output(["gofmt", str(source_path)], text=True)
    source_path.write_text(formatted, encoding="utf-8")


def _patch_queue_races(mihomo_root: pathlib.Path) -> None:
    queue_path = mihomo_root / "common" / "queue" / "queue.go"
    original = queue_path.read_text(encoding="utf-8")
    actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
    if actual_hash != QUEUE_SOURCE_SHA256:
        raise RuntimeError(
            f"Pinned queue source changed at {queue_path}; "
            "review the ClashFX queue race overlay"
        )

    source = _replace_once(original, ORIGINAL_QUEUE_POP, PATCHED_QUEUE_POP, "Queue.Pop")
    source = _replace_once(source, ORIGINAL_QUEUE_LAST, PATCHED_QUEUE_LAST, "Queue.Last")
    os.chmod(queue_path, queue_path.stat().st_mode | stat.S_IWUSR)
    queue_path.write_text(source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(queue_path)])


def _patch_inbound_listener_transactions(mihomo_root: pathlib.Path) -> None:
    listener_path = mihomo_root / "listener" / "listener.go"
    original = listener_path.read_text(encoding="utf-8")
    actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
    if actual_hash != INBOUND_LISTENER_SOURCE_SHA256:
        raise RuntimeError(
            f"Pinned inbound listener source changed at {listener_path}; "
            "review the ClashFX inbound listener transaction overlay"
        )

    source = _replace_once(
        original,
        '''import (
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"''',
        '''import (
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"''',
        "pinned inbound listener imports",
    )
    source = _replace_once(
        source,
        ORIGINAL_PATCH_INBOUND_LISTENERS,
        PATCHED_PATCH_INBOUND_LISTENERS,
        "PatchInboundListeners implementation",
    )
    source = _replace_once(source, '"github.com/metacubex/mihomo/listener/tuic"', '"github.com/metacubex/mihomo/listener/tuic"\n\ttuicProtocol "github.com/metacubex/mihomo/transport/tuic"', "TUIC normalization constants")
    source = _replace_once(source, "func ReCreateTuic(config LC.TuicServer, tunnel C.Tunnel) {", "func ReCreateTuic(config LC.TuicServer, tunnel C.Tunnel) {\n\tconfig = normalizeTuicConfig(config)", "TUIC stable config normalization")
    source = _replace_once(source, ORIGINAL_RECREATE_MIXED, PATCHED_RECREATE_MIXED, "atomic Mixed TCP/UDP pair")
    source = _replace_once(source, ORIGINAL_RECREATE_SOCKS, PATCHED_RECREATE_SOCKS, "atomic SOCKS TCP/UDP pair")
    source += GLOBAL_LISTENER_VALIDATION
    os.chmod(listener_path.parent, listener_path.parent.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    os.chmod(listener_path, listener_path.stat().st_mode | stat.S_IWUSR)
    listener_path.write_text(source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(listener_path)])

    executor_path = mihomo_root / "hub" / "executor" / "clashfx_listener_validation.go"
    if executor_path.exists():
        raise RuntimeError("Pinned core unexpectedly contains ClashFX listener readiness helper")
    os.chmod(executor_path.parent, executor_path.parent.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    executor_path.write_text(RUNTIME_LISTENER_VALIDATION, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(executor_path)])


def _patch_probe_diagnostics(mihomo_root: pathlib.Path) -> None:
    route_path = mihomo_root / "hub" / "route" / "proxies.go"
    original = route_path.read_text(encoding="utf-8")
    actual_hash = hashlib.sha256(original.encode("utf-8")).hexdigest()
    if actual_hash != ROUTE_PROXIES_SOURCE_SHA256:
        raise RuntimeError(
            f"Pinned proxy route source changed at {route_path}; "
            "review the ClashFX probe diagnostics overlay"
        )

    source = _replace_once(
        original,
        '''import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"

	"github.com/metacubex/chi"
	"github.com/metacubex/chi/render"
	"github.com/metacubex/http"
)''',
        PROBE_DIAGNOSTIC_IMPORTS,
        "pinned proxy route imports",
    )
    source = _replace_once(
        source,
        "func getProxyDelay(w http.ResponseWriter, r *http.Request) {",
        PROBE_DIAGNOSTIC_HELPERS + "\nfunc getProxyDelay(w http.ResponseWriter, r *http.Request) {",
        "getProxyDelay helper insertion point",
    )
    source = _replace_once(
        source,
        '''if ctx.Err() != nil {
		render.Status(r, http.StatusGatewayTimeout)
		render.JSON(w, r, ErrRequestTimeout)
		return
	}''',
        '''if ctx.Err() != nil {
		writeClashFXProbeFailure(w, r, http.StatusGatewayTimeout, "Timeout", classifyClashFXProbeError(ctx.Err()))
		return
	}''',
        "proxy delay timeout response",
    )
    source = _replace_once(
        source,
        '''if err != nil || delay == 0 {
		render.Status(r, http.StatusServiceUnavailable)
		if err != nil && delay != 0 {
			render.JSON(w, r, err)
		} else {
			render.JSON(w, r, newError("An error occurred in the delay test"))
		}
		return
	}''',
        '''if err != nil || delay == 0 {
		diagnostic := clashFXProbeError{Kind: "measurement", Code: "zero_delay"}
		if err != nil {
			diagnostic = classifyClashFXProbeError(err)
		}
		writeClashFXProbeFailure(w, r, http.StatusServiceUnavailable, "An error occurred in the delay test", diagnostic)
		return
	}''',
        "proxy delay failure response",
    )

    test_path = route_path.parent / "clashfx_probe_diagnostics_test.go"
    if test_path.exists():
        raise RuntimeError(f"Refusing to overwrite unexpected overlay test file {test_path}")
    os.chmod(route_path.parent, route_path.parent.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    os.chmod(route_path, route_path.stat().st_mode | stat.S_IWUSR)
    route_path.write_text(source, encoding="utf-8")
    test_path.write_text(UPSTREAM_PROBE_DIAGNOSTIC_TEST, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(route_path), str(test_path)])


def _remove_tree(path: pathlib.Path) -> None:
    if not path.exists():
        return
    for root, directories, files in os.walk(path):
        root_path = pathlib.Path(root)
        os.chmod(root_path, root_path.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
        for name in directories + files:
            child = root_path / name
            os.chmod(child, child.stat().st_mode | stat.S_IWUSR)
    shutil.rmtree(path)


def _resolve_module(module: str, expected_version: str) -> pathlib.Path:
    subprocess.check_call(
        ["go", "mod", "download", module],
        cwd=MODULE_ROOT,
    )
    module_info = subprocess.check_output(
        ["go", "list", "-m", "-f", "{{.Version}}\n{{.Dir}}", module],
        text=True,
        cwd=MODULE_ROOT,
    ).splitlines()
    if len(module_info) != 2:
        raise RuntimeError(f"Unable to resolve {module}")

    version, module_dir = module_info
    if version != expected_version:
        raise RuntimeError(
            f"Review the ClashFX core overlay before updating {module}: "
            f"expected {expected_version}, found {version}"
        )
    return pathlib.Path(module_dir)


@contextmanager
def core_modfile() -> Iterator[str]:
    # A fresh CI runner has the version in go.sum but no extracted module
    # directory yet. Download the pinned module before asking Go for its path.
    sing_source_module = _resolve_module(SING_MODULE, EXPECTED_SING_VERSION)
    mihomo_source_module = _resolve_module(MIHOMO_MODULE, EXPECTED_MIHOMO_VERSION)

    sing_source = sing_source_module / "common" / "exceptions" / "error.go"
    sing_original = sing_source.read_text(encoding="utf-8")
    if sing_original.count(ORIGINAL_IS_CLOSED) != 1:
        raise RuntimeError(
            f"The expected IsClosed implementation changed in {sing_source}; "
            "review the ClashFX overlay"
        )

    mihomo_source = mihomo_source_module / "adapter" / "outboundgroup" / "urltest.go"
    mihomo_original = mihomo_source.read_text(encoding="utf-8")
    if mihomo_original.count(ORIGINAL_URL_TEST) != 1:
        raise RuntimeError(
            f"The expected URLTest implementation changed in {mihomo_source}; "
            "review the ClashFX overlay"
        )

    temp_dir = pathlib.Path(tempfile.mkdtemp(prefix="clashfx-core-workaround-"))
    workaround_root = MODULE_ROOT / ".clashfx-core-workaround"
    if workaround_root.exists():
        _remove_tree(temp_dir)
        raise RuntimeError(
            f"Temporary core workaround already exists at {workaround_root}; "
            "another build may be running"
        )
    try:
        workaround_root.mkdir()
        sing_replacement_module = workaround_root / "sing"
        shutil.copytree(sing_source_module, sing_replacement_module)
        sing_replacement = sing_replacement_module / "common" / "exceptions" / "error.go"
        os.chmod(sing_replacement, sing_replacement.stat().st_mode | stat.S_IWUSR)
        sing_replacement.write_text(
            sing_original.replace(ORIGINAL_IS_CLOSED, PATCHED_IS_CLOSED),
            encoding="utf-8",
        )

        mihomo_replacement_module = workaround_root / "mihomo"
        shutil.copytree(mihomo_source_module, mihomo_replacement_module)
        mihomo_replacement = (
            mihomo_replacement_module / "adapter" / "outboundgroup" / "urltest.go"
        )
        os.chmod(mihomo_replacement, mihomo_replacement.stat().st_mode | stat.S_IWUSR)
        mihomo_replacement.write_text(
            mihomo_original.replace(ORIGINAL_URL_TEST, PATCHED_URL_TEST),
            encoding="utf-8",
        )
        _patch_cachefile_lifecycle(mihomo_replacement_module)
        _patch_queue_races(mihomo_replacement_module)
        _patch_inbound_listener_transactions(mihomo_replacement_module)
        patch_listener_constructor_cleanup(mihomo_replacement_module)
        patch_tproxy_constructor_cleanup(mihomo_replacement_module)
        patch_runtime_config_apply(mihomo_replacement_module)
        patch_inbound_access_state(mihomo_replacement_module)
        patch_startup_selection_overlay(mihomo_replacement_module)
        patch_route_lifecycle(mihomo_replacement_module)
        _patch_dns_server_lifecycle(mihomo_replacement_module)
        _patch_probe_diagnostics(mihomo_replacement_module)

        modfile = temp_dir / "clashfx.mod"
        modfile.write_text(
            (MODULE_ROOT / "go.mod").read_text(encoding="utf-8") +
            f"\nreplace {SING_MODULE} => ./.clashfx-core-workaround/sing\n" +
            f"replace {MIHOMO_MODULE} => ./.clashfx-core-workaround/mihomo\n",
            encoding="utf-8",
        )
        shutil.copy2(MODULE_ROOT / "go.sum", temp_dir / "clashfx.sum")
        yield str(modfile)
    finally:
        _remove_tree(temp_dir)
        _remove_tree(workaround_root)
