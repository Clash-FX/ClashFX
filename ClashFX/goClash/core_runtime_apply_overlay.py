#!/usr/bin/env python3
"""Patch pinned Mihomo sources for serialized runtime config application."""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import subprocess


MODULE_ROOT = pathlib.Path(__file__).resolve().parent
EXECUTOR_SOURCE_SHA256 = "f24ea2ebcd7c5ad2cefb17afcaf238035b746cb539bdab6c196b18796c392e87"
HUB_SOURCE_SHA256 = "c83c32a99bb50c59512411acf83ee2e64659e67cf0dcfe3c15eb3c7e061fec7c"
CONFIGS_SOURCE_SHA256 = "dc8bc7f031f292d1cbd9deede0b01c169689c9070fcc767aa81e402b7e41c018"

ORIGINAL_APPLY_CONFIG_LOCK = """func ApplyConfig(cfg *config.Config, force bool) {
	mux.Lock()
	defer mux.Unlock()
"""
PATCHED_APPLY_CONFIG_LOCK = """func ApplyConfig(cfg *config.Config, force bool) {
	mux.Lock()
	defer mux.Unlock()
	applyConfig(cfg, force)
}

func applyConfig(cfg *config.Config, force bool) {
"""

ORIGINAL_GET_GENERAL = """func GetGeneral() *config.General {
	ports := listener.GetPorts()"""
PATCHED_GET_GENERAL = """func GetGeneral() *config.General {
	return rawGetGeneral()
}

// GetGeneralSafe returns a consistent snapshot with runtime config mutation.
func GetGeneralSafe() *config.General {
	mux.Lock()
	defer mux.Unlock()
	return rawGetGeneral()
}

func rawGetGeneral() *config.General {
	ports := listener.GetPorts()"""

RUNTIME_APPLY_APIS = """func ApplyConfigAndValidate(cfg *config.Config, force bool) error {
	mux.Lock()
	defer mux.Unlock()
	applyConfig(cfg, force)
	return validateRuntimeListeners(cfg, force)
}

// WithRuntimeConfigLock serializes a runtime mutation with config apply and validation.
func WithRuntimeConfigLock(body func()) {
	mux.Lock()
	defer mux.Unlock()
	body()
}

var runtimeMutationRequestMu sync.Mutex
var runtimeMutationGateFactoryMu sync.RWMutex
var runtimeMutationGateFactory func() func(func() error) error

// SetRuntimeMutationGateFactory installs the lifecycle gate used by embedded HTTP mutations.
func SetRuntimeMutationGateFactory(factory func() func(func() error) error) {
	runtimeMutationGateFactoryMu.Lock()
	runtimeMutationGateFactory = factory
	runtimeMutationGateFactoryMu.Unlock()
}

// BeginRuntimeMutation captures the current lifecycle gate at request entry.
func BeginRuntimeMutation() func(func() error) error {
	runtimeMutationGateFactoryMu.RLock()
	factory := runtimeMutationGateFactory
	runtimeMutationGateFactoryMu.RUnlock()
	gate := runRuntimeMutation
	if factory != nil {
		if configuredGate := factory(); configuredGate != nil {
			gate = configuredGate
		}
	}
	return func(body func() error) error {
		runtimeMutationRequestMu.Lock()
		defer runtimeMutationRequestMu.Unlock()
		return gate(body)
	}
}

func runRuntimeMutation(body func() error) error {
	return body()
}

"""

ORIGINAL_HUB_APPLY_CONFIG = """func ApplyConfig(cfg *config.Config) {
	applyRoute(cfg)
	executor.ApplyConfig(cfg, true)
}"""
PATCHED_HUB_APPLY_CONFIG = """func ApplyConfig(cfg *config.Config) {
	applyRoute(cfg)
	executor.ApplyConfig(cfg, true)
}

func ApplyConfigAndValidate(cfg *config.Config) error {
	if err := executor.ApplyConfigAndValidate(cfg, true); err != nil {
		return err
	}
	applyRoute(cfg)
	return nil
}"""

ORIGINAL_GET_CONFIGS = """func getConfigs(w http.ResponseWriter, r *http.Request) {
	general := executor.GetGeneral()
	render.JSON(w, r, general)
}"""
PATCHED_GET_CONFIGS = """func getConfigs(w http.ResponseWriter, r *http.Request) {
	general := executor.GetGeneralSafe()
	render.JSON(w, r, general)
}"""

PATCHED_UPDATE_CONFIGS = '''func updateConfigs(w http.ResponseWriter, r *http.Request) {
	gate := executor.BeginRuntimeMutation()
	req := struct {
		Path    string `json:"path"`
		Payload string `json:"payload"`
	}{}
	if err := render.DecodeJSON(r.Body, &req); err != nil {
		render.Status(r, http.StatusBadRequest)
		render.JSON(w, r, ErrBadRequest)
		return
	}

	force := r.URL.Query().Get("force") == "true"
	if req.Payload == "" {
		if req.Path == "" { // default path unneeded any safe check
			req.Path = C.Path.Config()
		} else {
			if !filepath.IsAbs(req.Path) {
				render.Status(r, http.StatusBadRequest)
				render.JSON(w, r, newError("path is not a absolute path"))
				return
			}

			if !C.Path.IsSafePath(req.Path) {
				render.Status(r, http.StatusBadRequest)
				render.JSON(w, r, newError(C.Path.ErrNotSafePath(req.Path).Error()))
				return
			}
		}
	}

	var cfg *config.Config
	err := gate(func() error {
		if err := r.Context().Err(); err != nil {
			return err
		}
		var parseErr error
		if req.Payload != "" {
			cfg, parseErr = executor.ParseWithBytes([]byte(req.Payload))
		} else {
			cfg, parseErr = executor.ParseWithPath(req.Path)
		}
		if parseErr != nil {
			return parseErr
		}
		if err := r.Context().Err(); err != nil {
			return err
		}
		return executor.ApplyConfigAndValidate(cfg, force)
	})
	if err != nil {
		render.Status(r, http.StatusBadRequest)
		render.JSON(w, r, newError(err.Error()))
		return
	}

	render.NoContent(w, r)
}'''


def _replace_once(source: str, original: str, replacement: str, label: str) -> str:
    count = source.count(original)
    if count != 1:
        raise RuntimeError(f"Expected one {label} in pinned Mihomo source; found {count}")
    return source.replace(original, replacement, 1)


def _read_pinned_source(path: pathlib.Path, expected_sha256: str, label: str) -> str:
    raw = path.read_bytes()
    actual_sha256 = hashlib.sha256(raw).hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"Pinned {label} source changed at {path}; "
            "review the ClashFX runtime apply overlay"
        )
    return raw.decode("utf-8")


def _write_go_source(path: pathlib.Path, source: str) -> None:
    os.chmod(path.parent, path.parent.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
    path.write_text(source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(path)])


def patch_runtime_config_apply(mihomo_root: pathlib.Path) -> None:
    """Patch runtime config routes and listener snapshots in a copied Mihomo tree."""
    mihomo_root = pathlib.Path(mihomo_root)
    executor_path = mihomo_root / "hub" / "executor" / "executor.go"
    hub_path = mihomo_root / "hub" / "hub.go"
    configs_path = mihomo_root / "hub" / "route" / "configs.go"
    listener_path = mihomo_root / "listener" / "listener.go"

    executor_source = _read_pinned_source(
        executor_path, EXECUTOR_SOURCE_SHA256, "executor"
    )
    hub_source = _read_pinned_source(hub_path, HUB_SOURCE_SHA256, "hub")
    configs_source = _read_pinned_source(configs_path, CONFIGS_SOURCE_SHA256, "config route")
    listener_source = listener_path.read_text(encoding="utf-8")

    listener_source = _replace_once(
        listener_source,
        "\tvmessListener       *sing_vmess.Listener",
        "\tvmessListener       *sing_vmess.Listener\n\tlastShadowSocksConfig string\n\tlastVmessConfig       string",
        "raw global URL config state",
    )
    listener_source = _replace_once(
        listener_source,
        """func GetTuicConf() LC.TuicServer {
	if tuicListener == nil {
		return LC.TuicServer{Enable: false}
	}
	return tuicListener.Config()
}

func AllowLan() bool {""",
        """func GetTuicConf() LC.TuicServer {
	if tuicListener == nil {
		return LC.TuicServer{Enable: false}
	}
	return tuicListener.Config()
}

// GetLastShadowSocksConfig returns the exact URL used to configure the global service.
func GetLastShadowSocksConfig() string {
	ssMux.Lock()
	defer ssMux.Unlock()
	return lastShadowSocksConfig
}

// GetLastVmessConfig returns the exact URL used to configure the global service.
func GetLastVmessConfig() string {
	vmessMux.Lock()
	defer vmessMux.Unlock()
	return lastVmessConfig
}

// GetLastTuicConfig returns the last requested TUIC service configuration.
func GetLastTuicConfig() LC.TuicServer {
	tuicMux.Lock()
	defer tuicMux.Unlock()
	return LastTuicConf
}

func AllowLan() bool {""",
        "global listener config snapshot APIs",
    )
    listener_source = _replace_once(
        listener_source,
        """func ReCreateShadowSocks(shadowSocksConfig string, tunnel C.Tunnel) {
	ssMux.Lock()
	defer ssMux.Unlock()""",
        """func ReCreateShadowSocks(shadowSocksConfig string, tunnel C.Tunnel) {
	ssMux.Lock()
	defer ssMux.Unlock()
	lastShadowSocksConfig = shadowSocksConfig""",
        "save raw Shadowsocks URL",
    )
    listener_source = _replace_once(
        listener_source,
        """func ReCreateVmess(vmessConfig string, tunnel C.Tunnel) {
	vmessMux.Lock()
	defer vmessMux.Unlock()""",
        """func ReCreateVmess(vmessConfig string, tunnel C.Tunnel) {
	vmessMux.Lock()
	defer vmessMux.Unlock()
	lastVmessConfig = vmessConfig""",
        "save raw VMess URL",
    )

    executor_source = _replace_once(
        executor_source,
        ORIGINAL_APPLY_CONFIG_LOCK,
        PATCHED_APPLY_CONFIG_LOCK,
        "executor.ApplyConfig lock",
    )
    executor_source = _replace_once(
        executor_source,
        ORIGINAL_GET_GENERAL,
        PATCHED_GET_GENERAL,
        "executor.GetGeneral implementation",
    )
    executor_source = _replace_once(
        executor_source,
        "func initInnerTcp() {",
        RUNTIME_APPLY_APIS + "func initInnerTcp() {",
        "executor runtime apply insertion point",
    )

    hub_source = _replace_once(
        hub_source,
        ORIGINAL_HUB_APPLY_CONFIG,
        PATCHED_HUB_APPLY_CONFIG,
        "hub.ApplyConfig implementation",
    )

    configs_source = _replace_once(
        configs_source,
        ORIGINAL_GET_CONFIGS,
        PATCHED_GET_CONFIGS,
        "GET /configs handler",
    )

    patch_start = configs_source.index("func patchConfigs(w http.ResponseWriter, r *http.Request) {")
    patch_end = configs_source.index("\nfunc updateConfigs(w http.ResponseWriter, r *http.Request) {", patch_start)
    patch_source = configs_source[patch_start:patch_end]
    patch_source = _replace_once(
        patch_source,
        "func patchConfigs(w http.ResponseWriter, r *http.Request) {",
        "func patchConfigs(w http.ResponseWriter, r *http.Request) {\n\tgate := executor.BeginRuntimeMutation()",
        "PATCH runtime gate capture",
    )
    patch_source = _replace_once(
        patch_source,
        "\tif general.AllowLan != nil {",
        """\tgateErr := gate(func() error {
		var contextErr error
		executor.WithRuntimeConfigLock(func() {
			if err := r.Context().Err(); err != nil {
				contextErr = err
				return
			}
			func() {
	if general.AllowLan != nil {""",
        "PATCH mutation gate and runtime config lock",
    )
    patch_source = _replace_once(
        patch_source,
        "\trender.NoContent(w, r)\n}",
        """\trender.NoContent(w, r)
			}()
		})
		return contextErr
	})
	if gateErr != nil {
		render.Status(r, http.StatusBadRequest)
		render.JSON(w, r, newError(gateErr.Error()))
		return
	}
}""",
        "PATCH runtime gate completion",
    )
    patch_source = _replace_once(patch_source,
        """	if general.SkipAuthPrefixes != nil {
		inbound.SetSkipAuthPrefixes(*general.SkipAuthPrefixes)
	}

	if general.LanAllowedIPs != nil {
		inbound.SetAllowedIPs(*general.LanAllowedIPs)
	}

	if general.LanDisAllowedIPs != nil {
		inbound.SetDisAllowedIPs(*general.LanDisAllowedIPs)
	}""",
        "",
        "PATCH defer access policy publication",
    )
    patch_source = _replace_once(
        patch_source,
        """\tif general.Sniffing != nil {
		tunnel.SetSniffing(*general.Sniffing)
	}

	if general.TcpConcurrent != nil {
		dialer.SetTcpConcurrent(*general.TcpConcurrent)
	}

	if general.InterfaceName != nil {
		dialer.DefaultInterface.Store(*general.InterfaceName)
	}""",
        "",
        "PATCH defer non-listener mutations",
    )
    configs_source = _replace_once(configs_source, '"net/netip"', '"fmt"\n\t"net/netip"', "PATCH rollback error import")
    patch_source = _replace_once(patch_source,
        "\tif general.AllowLan != nil {",
        """    previousAllowLan := listener.AllowLan()
    previousBindAddress := listener.BindAddress()
    previousPorts := *listener.GetPorts()
    previousShadowSocksConfig := listener.GetLastShadowSocksConfig()
    previousVmessConfig := listener.GetLastVmessConfig()
    previousTuicConfig := listener.GetLastTuicConfig()
    restoreRuntimeListeners := func(cause error) error {
        listener.SetAllowLan(previousAllowLan)
        listener.SetBindAddress(previousBindAddress)

        // Release request-owned sockets before restoring the previous topology.
        // A new URL global may have moved onto an old basic listener's port.
        if general.ShadowSocksConfig != nil {
            listener.ReCreateShadowSocks("", tunnel.Tunnel)
        }
        if general.VmessConfig != nil {
            listener.ReCreateVmess("", tunnel.Tunnel)
        }
        if general.TuicServer != nil {
            listener.ReCreateTuic(LC.TuicServer{}, tunnel.Tunnel)
        }

        listener.ReCreateHTTP(0, tunnel.Tunnel)
        listener.ReCreateSocks(0, tunnel.Tunnel)
        listener.ReCreateRedir(0, tunnel.Tunnel)
        listener.ReCreateTProxy(0, tunnel.Tunnel)
        listener.ReCreateMixed(0, tunnel.Tunnel)

        listener.ReCreateHTTP(previousPorts.Port, tunnel.Tunnel)
        listener.ReCreateSocks(previousPorts.SocksPort, tunnel.Tunnel)
        listener.ReCreateRedir(previousPorts.RedirPort, tunnel.Tunnel)
        listener.ReCreateTProxy(previousPorts.TProxyPort, tunnel.Tunnel)
        listener.ReCreateMixed(previousPorts.MixedPort, tunnel.Tunnel)

        var restoreSS *string
        var restoreVmess *string
        var restoreTuic *LC.TuicServer
        if general.ShadowSocksConfig != nil {
            listener.ReCreateShadowSocks(previousShadowSocksConfig, tunnel.Tunnel)
            restoreSS = &previousShadowSocksConfig
        }
        if general.VmessConfig != nil {
            listener.ReCreateVmess(previousVmessConfig, tunnel.Tunnel)
            restoreVmess = &previousVmessConfig
        }
        if general.TuicServer != nil {
            listener.ReCreateTuic(previousTuicConfig, tunnel.Tunnel)
            restoreTuic = &previousTuicConfig
        }

        var restoreErr error
        addRestoreError := func(err error) {
            if err == nil {
                return
            }
            if restoreErr == nil {
                restoreErr = err
            } else {
                restoreErr = fmt.Errorf("%v; %w", restoreErr, err)
            }
        }
        addRestoreError(listener.ValidateGlobalListenerPorts(previousPorts))
        addRestoreError(listener.ValidateSelectedGlobalListeners(restoreSS, restoreVmess, restoreTuic))
        if restoreErr != nil {
            return fmt.Errorf("listener change failed (%v); previous listeners could not be restored: %w", cause, restoreErr)
        }
        return cause
    }
	if general.AllowLan != nil {""", "PATCH previous basic listener snapshot")
    patch_source = _replace_once(patch_source,
        "\tports := listener.GetPorts()",
        """	ports := listener.GetPorts()
    expectedPorts := *ports
    expectedPorts.Port = pointerOrDefault(general.Port, ports.Port)
    expectedPorts.SocksPort = pointerOrDefault(general.SocksPort, ports.SocksPort)
    expectedPorts.RedirPort = pointerOrDefault(general.RedirPort, ports.RedirPort)
    expectedPorts.TProxyPort = pointerOrDefault(general.TProxyPort, ports.TProxyPort)
    expectedPorts.MixedPort = pointerOrDefault(general.MixedPort, ports.MixedPort)
    expectedTuic := pointerOrDefaultTuicServer(general.TuicServer, listener.GetLastTuicConfig())""", "PATCH expected listener ports")
    patch_source = _replace_once(patch_source,
        "\tlistener.ReCreateTun(pointerOrDefaultTun(general.Tun, listener.LastTunConf), tunnel.Tunnel)",
        "", "PATCH defer TUN mutation until listener confirmation")
    patch_source = _replace_once(patch_source,
        "\tlistener.ReCreateShadowSocks(pointerOrDefault(general.ShadowSocksConfig, ports.ShadowSocksConfig), tunnel.Tunnel)",
        "\tif general.ShadowSocksConfig != nil { listener.ReCreateShadowSocks(*general.ShadowSocksConfig, tunnel.Tunnel) }", "PATCH explicit Shadowsocks only")
    patch_source = _replace_once(patch_source,
        "\tlistener.ReCreateVmess(pointerOrDefault(general.VmessConfig, ports.VmessConfig), tunnel.Tunnel)",
        "\tif general.VmessConfig != nil { listener.ReCreateVmess(*general.VmessConfig, tunnel.Tunnel) }", "PATCH explicit VMess only")
    patch_source = _replace_once(patch_source,
        "\tlistener.ReCreateTuic(pointerOrDefaultTuicServer(general.TuicServer, listener.LastTuicConf), tunnel.Tunnel)",
        "\tif general.TuicServer != nil { listener.ReCreateTuic(expectedTuic, tunnel.Tunnel) }", "PATCH explicit TUIC only")
    patch_source = _replace_once(patch_source,
        "\tif general.Mode != nil {",
        """    if err := listener.ValidateGlobalListenerPorts(expectedPorts); err != nil {
        contextErr = restoreRuntimeListeners(err)
        return
    }
    var requestedTuic *LC.TuicServer
	if general.TuicServer != nil {
		requestedTuic = &expectedTuic
	}
	if err := listener.ValidateSelectedGlobalListeners(general.ShadowSocksConfig, general.VmessConfig, requestedTuic); err != nil {
		contextErr = restoreRuntimeListeners(err)
		return
	}
    if general.Tun != nil {
        listener.ReCreateTun(pointerOrDefaultTun(general.Tun, listener.LastTunConf), tunnel.Tunnel)
    }
	if general.SkipAuthPrefixes != nil || general.LanAllowedIPs != nil || general.LanDisAllowedIPs != nil {
		skip := inbound.SkipAuthPrefixes()
		allowed := inbound.AllowedIPs()
		disallowed := inbound.DisAllowedIPs()
		if general.SkipAuthPrefixes != nil {
			skip = *general.SkipAuthPrefixes
		}
		if general.LanAllowedIPs != nil {
			allowed = *general.LanAllowedIPs
		}
		if general.LanDisAllowedIPs != nil {
			disallowed = *general.LanDisAllowedIPs
		}
		inbound.SetAccessPrefixes(skip, allowed, disallowed)
	}
	if general.Sniffing != nil {
		tunnel.SetSniffing(*general.Sniffing)
	}
	if general.TcpConcurrent != nil {
		dialer.SetTcpConcurrent(*general.TcpConcurrent)
	}
	if general.InterfaceName != nil {
		dialer.DefaultInterface.Store(*general.InterfaceName)
	}
	if general.Mode != nil {""", "PATCH actual listener readiness")
    patch_start = configs_source.index("func patchConfigs(w http.ResponseWriter, r *http.Request) {")
    patch_end = configs_source.index("\nfunc updateConfigs(w http.ResponseWriter, r *http.Request) {", patch_start)
    configs_source = (
        configs_source[:patch_start]
        + patch_source
        + configs_source[patch_end:]
    )

    update_start = configs_source.index("func updateConfigs(w http.ResponseWriter, r *http.Request) {")
    update_end = configs_source.index("\nfunc updateGeoDatabases(w http.ResponseWriter, r *http.Request) {", update_start)
    configs_source = (
        configs_source[:update_start]
        + PATCHED_UPDATE_CONFIGS
        + configs_source[update_end:]
    )

    _write_go_source(executor_path, executor_source)
    _write_go_source(hub_path, hub_source)
    _write_go_source(configs_path, configs_source)
    _write_go_source(listener_path, listener_source)


def patch_runtime_http_apply_test(mihomo_root: pathlib.Path) -> None:
    """Inject the route-package regression test into a temporary Mihomo tree."""
    mihomo_root = pathlib.Path(mihomo_root)
    route_root = mihomo_root / "hub" / "route"
    test_source_path = MODULE_ROOT / "testdata" / "runtime_http_apply_test.go"
    test_path = route_root / "runtime_http_apply_test.go"
    if not test_source_path.is_file():
        raise RuntimeError(f"Runtime HTTP overlay test source is missing: {test_source_path}")
    if test_path.exists():
        raise RuntimeError(f"Refusing to overwrite unexpected overlay test file {test_path}")

    os.chmod(route_root, route_root.stat().st_mode | stat.S_IWUSR | stat.S_IXUSR)
    test_source = test_source_path.read_text(encoding="utf-8")
    test_path.write_text(test_source, encoding="utf-8")
    subprocess.check_call(["gofmt", "-w", str(test_path)])


__all__ = ["patch_runtime_config_apply", "patch_runtime_http_apply_test"]
