#!/usr/bin/env python3
"""Run real ClashFX Helper and Mihomo TUN acceptance on a disposable hosted Mac."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
SERVICE_LABEL = "com.clashfx.app.Helper"
CLIENT_BUNDLE_ID = "com.clashfx.app"
HELPER_BUNDLE_ID = "com.clashfx.app.Helper"
TEST_DNS_SERVER = "203.0.113.53"
CORE_READY_TIMEOUT = 45
CORE_EXIT_TIMEOUT = 15
RESTORE_TIMEOUT = 25
RPC_TIMEOUT = 35


class UsageError(Exception):
    pass


class SmokeInterrupted(Exception):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"interrupted by signal {signum}")


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def emit_json(value):
    print(json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)


def is_relative_to(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def hosted_runner_gate():
    """Require multiple GitHub-hosted runner signals before any system action."""
    env = os.environ
    failures = []
    if sys.platform != "darwin":
        failures.append("sys.platform must be darwin")
    if env.get("GITHUB_ACTIONS") != "true":
        failures.append("GITHUB_ACTIONS must equal true")
    if env.get("RUNNER_ENVIRONMENT") != "github-hosted":
        failures.append("RUNNER_ENVIRONMENT must equal github-hosted")
    if env.get("RUNNER_OS") != "macOS":
        failures.append("RUNNER_OS must equal macOS")
    if env.get("CI") != "true":
        failures.append("CI must equal true")
    if not env.get("ImageOS", "").startswith("macos"):
        failures.append("ImageOS must identify a GitHub macOS runner image")
    if not env.get("ImageVersion"):
        failures.append("ImageVersion must identify the hosted runner image revision")

    effective_uid = os.geteuid() if hasattr(os, "geteuid") else None
    if effective_uid != 0:
        failures.append("effective uid must be 0")

    expected_runner_workspace = Path("/Users/runner/work")
    workspace_raw = env.get("GITHUB_WORKSPACE", "")
    runner_workspace_raw = env.get("RUNNER_WORKSPACE", "")
    runner_temp_raw = env.get("RUNNER_TEMP", "")
    repository = env.get("GITHUB_REPOSITORY", "")
    run_id = env.get("GITHUB_RUN_ID", "")
    run_attempt = env.get("GITHUB_RUN_ATTEMPT", "")

    try:
        workspace = Path(workspace_raw).resolve(strict=True)
        runner_workspace = Path(runner_workspace_raw).resolve(strict=True)
        runner_temp = Path(runner_temp_raw).resolve(strict=True)
        expected_workspace = expected_runner_workspace.resolve(strict=True)
        repo_name = repository.rsplit("/", 1)[-1]
        relative_workspace = workspace.relative_to(expected_workspace)
        if workspace != ROOT.resolve(strict=True):
            failures.append("GITHUB_WORKSPACE must be this repository root")
        standard_checkout = (
            len(relative_workspace.parts) == 2 and bool(repo_name) and
            tuple(part.casefold() for part in relative_workspace.parts) ==
            (repo_name.casefold(), repo_name.casefold())
        )
        if not standard_checkout:
            failures.append("GITHUB_WORKSPACE must use the standard hosted checkout path")
        allowed_runner_workspaces = {expected_workspace, workspace.parent}
        if runner_workspace not in allowed_runner_workspaces:
            failures.append("RUNNER_WORKSPACE must resolve to /Users/runner/work or its repository directory")
        if runner_temp.name != "_temp" or not is_relative_to(runner_temp, expected_workspace):
            failures.append("RUNNER_TEMP must be the hosted runner's work/_temp directory")
    except (OSError, ValueError):
        failures.append("workspace paths must resolve inside /Users/runner/work")

    if not repository or "/" not in repository:
        failures.append("GITHUB_REPOSITORY is required")
    if not run_id.isdigit() or int(run_id) <= 0:
        failures.append("GITHUB_RUN_ID must be a positive run id")
    if not run_attempt.isdigit() or int(run_attempt) <= 0:
        failures.append("GITHUB_RUN_ATTEMPT must be a positive attempt")
    if not env.get("GITHUB_SHA") or not env.get("GITHUB_JOB"):
        failures.append("GITHUB_SHA and GITHUB_JOB are required")

    return failures, effective_uid


def command_result(command, timeout=8):
    return subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)


def require_command_success(command, timeout=8):
    result = command_result(command, timeout)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"command failed ({result.returncode}): {command[0]}: {detail}")
    return result.stdout


def validate_build_inputs(raw_helper, raw_core, runner_temp):
    helper_path = Path(raw_helper).expanduser().resolve(strict=True)
    core_path = Path(raw_core).expanduser().resolve(strict=True)
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    for path, label, flag, basename in ((helper_path, "production Helper", "--helper", SERVICE_LABEL),
                                        (core_path, "mihomo_core", "--core", "mihomo_core")):
        if path.name != basename:
            raise ValueError(f"{flag} basename must be {basename}")
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"{label} is missing or not executable: {path}")
        if not (is_relative_to(path, workspace) or is_relative_to(path, runner_temp)):
            raise ValueError(f"{label} must resolve inside GITHUB_WORKSPACE or RUNNER_TEMP: {path}")

    helper_info_path = ROOT / "ProxyConfigHelper" / "Helper-Info.plist"
    launchd_info_path = ROOT / "ProxyConfigHelper" / "Helper-Launchd.plist"
    app_info_path = ROOT / "ClashFX" / "Info.plist"
    with helper_info_path.open("rb") as stream:
        helper_info = plistlib.load(stream)
    with launchd_info_path.open("rb") as stream:
        launchd_info = plistlib.load(stream)
    with app_info_path.open("rb") as stream:
        app_info = plistlib.load(stream)
    if helper_info.get("CFBundleIdentifier") != HELPER_BUNDLE_ID:
        raise ValueError("production Helper-Info.plist bundle identifier changed")
    authorized = helper_info.get("SMAuthorizedClients")
    if not isinstance(authorized, list) or not authorized or CLIENT_BUNDLE_ID not in authorized[0]:
        raise ValueError("production SMAuthorizedClients does not authorize com.clashfx.app")
    if launchd_info.get("Label") != SERVICE_LABEL:
        raise ValueError("production Helper-Launchd.plist label changed")
    if launchd_info.get("MachServices") != {SERVICE_LABEL: True}:
        raise ValueError("production Helper-Launchd.plist MachServices entry changed")
    app_authorized = (app_info.get("SMPrivilegedExecutables") or {}).get(HELPER_BUNDLE_ID)
    if not isinstance(app_authorized, str) or not app_authorized:
        raise ValueError("production ClashFX Info.plist does not declare SMPrivilegedExecutables for the Helper")

    require_command_success(["/usr/bin/codesign", "--verify", "--strict", str(helper_path)], 15)
    details = command_result(["/usr/bin/codesign", "-dv", "--verbose=4", str(helper_path)], 15)
    detail_text = details.stdout + details.stderr
    identifier = re.search(r"^Identifier=(.+)$", detail_text, re.MULTILINE)
    if details.returncode != 0 or not identifier or identifier.group(1).strip() != HELPER_BUNDLE_ID:
        raise ValueError("embedded Helper code signature identifier must be com.clashfx.app.Helper")

    # Xcode embeds Helper-Info.plist and Helper-Launchd.plist in the production
    # Mach-O. Check those payload markers so this cannot quietly exercise a
    # lookalike process with the same launchd service name.
    helper_bytes = helper_path.read_bytes()
    embedded_markers = (b"SMAuthorizedClients", b"MachServices", SERVICE_LABEL.encode(),
                        CLIENT_BUNDLE_ID.encode())
    if any(marker not in helper_bytes for marker in embedded_markers):
        raise ValueError("built Helper is missing its embedded production XPC/launchd metadata")

    return {
        "helperSourcePath": str(helper_path),
        "helperPath": str(helper_path),
        "helperBundleIdentifier": identifier.group(1).strip(),
        "helperSHA256": hashlib.sha256(helper_bytes).hexdigest(),
        "corePath": str(core_path),
        "coreSHA256": hashlib.sha256(core_path.read_bytes()).hexdigest(),
        "clientBundleIdentifier": CLIENT_BUNDLE_ID,
        "authorizedClientRequirement": authorized[0],
        "productionAppPrivilegedHelperRequirement": app_authorized,
        "machService": SERVICE_LABEL,
        "productionHelperSource": "ProxyConfigHelper/ProxyConfigHelper.m + ProxyConfigRemoteProcessProtocol.h",
        "productionHelperLaunchdSource": str(launchd_info_path.relative_to(ROOT)),
    }, helper_path, core_path, launchd_info


def verify_clean_guest_before_mutation():
    existing_paths = [
        Path("/Library/LaunchDaemons") / f"{SERVICE_LABEL}.plist",
        Path("/Library/PrivilegedHelperTools") / SERVICE_LABEL,
    ]
    present = [str(path) for path in existing_paths if path.exists()]
    if present:
        raise RuntimeError("refusing to replace an existing Helper installation: " + ", ".join(present))

    print_output = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"])
    if print_output.returncode == 0:
        raise RuntimeError(f"refusing because launchd service {SERVICE_LABEL} is already loaded")
    missing_text = (print_output.stdout + print_output.stderr).lower()
    if "could not find service" not in missing_text and "not found" not in missing_text:
        raise RuntimeError("could not establish that the production Helper launchd label is unused")

    process_output = require_command_success(["/bin/ps", "-axo", "pid=,comm="], 8)
    forbidden = {"ClashFX", SERVICE_LABEL, "mihomo_core"}
    found = []
    for line in process_output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
        except ValueError:
            continue
        name = Path(fields[1].strip()).name
        if pid != os.getpid() and name in forbidden:
            found.append({"pid": pid, "name": name})
    if found:
        raise RuntimeError(f"refusing because app/helper/core processes already exist: {found}")


def canonical_hash(value):
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(encoded).hexdigest()


def normalized_proxy_state(snapshot):
    normalized = dict(snapshot)
    service_ids_key = "__ClashFXCapturedServiceIDs"
    if isinstance(normalized.get(service_ids_key), list):
        normalized[service_ids_key] = sorted(normalized[service_ids_key])
    return normalized


def copy_log(source, destination):
    try:
        shutil.copyfile(source, destination)
        Path(destination).chmod(0o644)
        return True
    except (OSError, TypeError):
        return False


class AcceptanceHarness:
    def __init__(self, build_metadata, helper_path, core_path, launchd_template,
                 artifact_dir, temp_root, lifecycle):
        self.helper_source_path = helper_path
        self.helper_path = temp_root / "production-helper" / SERVICE_LABEL
        self.core_path = core_path
        self.launchd_template = launchd_template
        self.artifact_dir = artifact_dir
        self.temp_root = temp_root
        self.lifecycle = lifecycle
        self.client_root = temp_root / "clients"
        self.probe_app = self.client_root / "ProtoProbe.app"
        self.probe_executable = self.probe_app / "Contents" / "MacOS" / "ClashFX"
        self.transaction_app = self.client_root / "TxDriver.app"
        self.transaction_executable = self.transaction_app / "Contents" / "MacOS" / "ClashFX"
        self.test_core = self.transaction_app / "Contents" / "Resources" / "mihomo_core"
        self.transaction_manifest = temp_root / "production-transaction-manifest.json"
        self.transaction_report_path = artifact_dir / "production-transaction.json"
        self.transaction_client_available = False
        self.launchd_plist = temp_root / "com.clashfx.app.Helper.acceptance.plist"
        self.helper_stdout = temp_root / "helper.stdout.log"
        self.helper_stderr = temp_root / "helper.stderr.log"
        self.bootstrapped = False
        self.bootstrap_attempted = False
        self.proxy_snapshot = None
        self.dns_snapshot = None
        self.proxy_may_be_dirty = False
        self.dns_may_be_dirty = False
        self.transaction_stdout = temp_root / "transaction.stdout.log"
        self.transaction_stderr = temp_root / "transaction.stderr.log"
        self.owned_launch_id = None
        self.owned_core_pid = None
        self.core_start_attempted = False
        self.harness_config_paths = set()
        self.core_home_by_config = {}
        self.core_log_path = None
        self.core_log_paths = []
        self.created_utuns = []
        self.exit_code = 0
        self.report = {
            "schemaVersion": 1,
            "status": "running",
            "scope": "real production Helper XPC + Helper-managed Mihomo TUN acceptance on a disposable GitHub-hosted macOS runner",
            "coverage": {
                "productionHelperXPC": False,
                "adHocSignedClientBundleIdentity": False,
                "helperManagedCore": False,
                "invalidConfigPathFailure": False,
                "productionInvalidConfigRuntimeFailure": False,
                "tunInterfaceAndRoutes": False,
                "controllerProxyAndDNSOwnership": False,
                "systemProxyCaptureAndEnable": False,
                "systemProxyExactRestore": False,
                "systemDNSOverride": False,
                "systemDNSExactRestore": False,
                "productionTransactionDNSOverrideRestore": False,
                "fullClashFXAppLaunched": False,
                "productionSystemProxyManager": False,
                "ClaudeProxyLockTransactionRollback": False,
                "disableErrorOrCallerCancellationInjection": False,
            },
            "build": build_metadata,
            "assertions": [],
            "xpcCalls": [],
            "failures": [],
            "scopeNotes": [
                "The full ClashFX GUI and AppDelegate are never launched.",
                "When the companion source is present and its checks pass, the production SystemProxyManager.swift and ClaudeProxyLockTransaction.swift sources run in the separate TxDriver.app client against the real Helper XPC service.",
                "A separate ProtoProbe XPC pass verifies Helper DNS override and exact restoration; transaction-level DNS coverage is reported separately.",
                "Helper disable-error and transaction caller-cancellation injection are not claimed as covered.",
                "The core API's HTTP client explicitly bypasses ambient system proxies.",
            ],
        }

    def assertion(self, name, passed, evidence=None):
        self.report["assertions"].append({"name": name, "passed": bool(passed), "evidence": evidence})
        if not passed:
            raise RuntimeError(f"acceptance assertion failed: {name}")

    def cleanup_assertion(self, name, passed, evidence=None):
        self.report["assertions"].append({"name": name, "passed": bool(passed), "evidence": evidence})
        if not passed:
            self.report["failures"].append({"phase": "cleanup", "operation": name,
                                            "message": "cleanup verification did not pass"})
            self.exit_code = self.exit_code or 1

    def rpc(self, operation, **values):
        request = {"operation": operation, **values}
        started = time.monotonic()
        try:
            completed = subprocess.run(
                [str(self.probe_executable)],
                input=json.dumps(request, separators=(",", ":")),
                check=False,
                capture_output=True,
                text=True,
                timeout=RPC_TIMEOUT,
            )
        except subprocess.TimeoutExpired as error:
            self.report["xpcCalls"].append({"operation": operation, "ok": False,
                                              "elapsedSeconds": round(time.monotonic() - started, 3),
                                              "error": "client process timed out"})
            raise RuntimeError(f"Helper XPC operation {operation} timed out") from error
        elapsed = round(time.monotonic() - started, 3)
        try:
            response = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            record = {"operation": operation, "ok": False, "elapsedSeconds": elapsed,
                      "exitCode": completed.returncode,
                      "stderrTail": completed.stderr[-2000:]}
            self.report["xpcCalls"].append(record)
            raise RuntimeError(f"Helper XPC client returned invalid JSON for {operation}: {record}") from error
        self.report["xpcCalls"].append({"client": "ProtoProbe", "operation": operation,
                                          "ok": bool(response.get("ok")),
                                          "elapsedSeconds": elapsed,
                                          "error": response.get("error")})
        if completed.returncode != 0 or response.get("ok") is not True:
            raise RuntimeError(f"Helper XPC operation {operation} failed: {response.get('error') or completed.stderr[-2000:]}")
        return response.get("result")

    def compile_client(self):
        for app in (self.probe_app, self.transaction_app):
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True, mode=0o755)
            (contents / "Resources").mkdir(mode=0o755)
        source = ROOT / "scripts" / "helper-tun-acceptance-client.m"
        compile_output = require_command_success([
            "/usr/bin/clang", "-fmodules", "-fobjc-arc", "-O2", "-I", str(ROOT / "ProxyConfigHelper"),
            str(source), "-framework", "Foundation", "-o", str(self.probe_executable),
        ], 90)
        del compile_output
        self.helper_path.parent.mkdir(mode=0o700)
        shutil.copy2(self.helper_source_path, self.helper_path)
        self.helper_path.chmod(0o755)
        shutil.copy2(self.core_path, self.test_core)
        self.test_core.chmod(0o755)
        info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "ClashFX",
            "CFBundleIdentifier": CLIENT_BUNDLE_ID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "ClashFX",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": True,
        }
        for app in (self.probe_app, self.transaction_app):
            with (app / "Contents" / "Info.plist").open("wb") as stream:
                plistlib.dump(info, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        self._sign_and_verify_client(self.probe_app)
        self.report["coverage"]["adHocSignedClientBundleIdentity"] = True
        self.report["build"]["probeClientPath"] = str(self.probe_executable)
        self.report["build"]["transactionClientBundlePath"] = str(self.transaction_app)
        self.report["build"]["transactionClientPath"] = str(self.transaction_executable)

    def _sign_and_verify_client(self, app):
        executable = app / "Contents" / "MacOS" / "ClashFX"
        require_command_success([
            "/usr/bin/codesign", "--force", "--sign", "-", "--identifier", CLIENT_BUNDLE_ID,
            "--timestamp=none", str(app),
        ], 30)
        require_command_success(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], 20)
        details = command_result(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], 15)
        signed_text = details.stdout + details.stderr
        identifier = re.search(r"^Identifier=(.+)$", signed_text, re.MULTILINE)
        valid = (executable.is_file() and details.returncode == 0 and identifier is not None and
                 identifier.group(1).strip() == CLIENT_BUNDLE_ID)
        self.assertion(f"{app.stem} has required executable path and ad-hoc identity", valid,
                       {"bundlePath": str(app), "executablePath": str(executable),
                        "bundleIdentifier": identifier.group(1).strip() if identifier else None})

    def compile_transaction_client(self):
        source = ROOT / "scripts" / "helper-tun-production-transaction.swift"
        if not source.is_file():
            self.report["transactionClient"] = {
                "status": "skipped",
                "reason": f"production transaction client is not present: {source}",
            }
            return False
        sources = [
            source,
            ROOT / "ClashFX" / "General" / "Managers" / "SystemProxyManager.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "ClaudeProxyLockTransaction.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "SystemProxyOperationPolicy.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "ManagedOperationSettlement.swift",
        ]
        missing = [str(path) for path in sources if not path.is_file()]
        if missing:
            raise RuntimeError("transaction-client build sources are missing: " + ", ".join(missing))
        require_command_success([
            "/usr/bin/swiftc", "-swift-version", "5", "-parse-as-library",
            "-import-objc-header", str(ROOT / "ProxyConfigHelper" / "ProxyConfigRemoteProcessProtocol.h"),
            *(str(path) for path in sources), "-framework", "Foundation", "-framework", "SystemConfiguration",
            "-o", str(self.transaction_executable),
        ], 120)
        self._sign_and_verify_client(self.transaction_app)
        self.transaction_client_available = True
        return True
        self.assertion("bundled core has fixed production resource name",
                       self.test_core.name == "mihomo_core" and os.access(self.test_core, os.X_OK),
                       {"path": str(self.test_core),
                        "sha256": hashlib.sha256(self.test_core.read_bytes()).hexdigest()})
        self.report["build"]["helperStagedPath"] = str(self.helper_path)
        self.report["build"]["helperStagedSHA256"] = hashlib.sha256(self.helper_path.read_bytes()).hexdigest()
        self.report["build"]["transactionClientPath"] = str(self.transaction_executable)

    def prepare_launchd_job(self):
        job = dict(self.launchd_template)
        job["ProgramArguments"] = [str(self.helper_path)]
        job["RunAtLoad"] = True
        job["StandardOutPath"] = str(self.helper_stdout)
        job["StandardErrorPath"] = str(self.helper_stderr)
        with self.launchd_plist.open("wb") as stream:
            plistlib.dump(job, stream, fmt=plistlib.FMT_XML, sort_keys=True)
        os.chmod(self.launchd_plist, 0o644)

    def bootstrap_helper(self):
        self.bootstrap_attempted = True
        result = command_result(["/bin/launchctl", "bootstrap", "system", str(self.launchd_plist)], 25)
        if result.returncode != 0:
            probe = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
            if probe.returncode == 0 and str(self.helper_path) in probe.stdout:
                self.bootstrapped = True
            raise RuntimeError(f"launchctl bootstrap failed: {(result.stderr or result.stdout).strip()}")
        self.bootstrapped = True
        self.report["launchd"] = {
            "label": SERVICE_LABEL,
            "domain": "system",
            "plist": str(self.launchd_plist),
            "program": str(self.helper_path),
            "source": str((ROOT / "ProxyConfigHelper" / "Helper-Launchd.plist").relative_to(ROOT)),
            "productionMachServiceName": SERVICE_LABEL,
        }

    def helper_pid(self):
        output = require_command_success(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
        match = re.search(r"\bpid\s*=\s*(\d+)", output)
        if not match:
            return None
        pid = int(match.group(1))
        uid_text = require_command_success(["/bin/ps", "-o", "uid=", "-p", str(pid)], 5).strip()
        if uid_text != "0":
            raise RuntimeError(f"production Helper launchd process {pid} is not root (uid={uid_text})")
        return pid

    def wait_for_core_exit(self, expected_launch_id, timeout=CORE_EXIT_TIMEOUT):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            last = self.rpc("coreStatus")
            if last.get("launchID") != expected_launch_id:
                raise RuntimeError("Helper core launch ID changed while waiting for failed core exit")
            if last.get("running") is False and last.get("lastTermination"):
                return last
            time.sleep(0.25)
        raise TimeoutError(f"Helper-managed failed core did not exit within {timeout}s: {last}")

    def wait_for_tun_ready(self, endpoint, token, baseline_utuns, launch_id, pid):
        deadline = time.monotonic() + CORE_READY_TIMEOUT
        last_error = "waiting for Mihomo API, TUN interface, and auto-route"
        last_status_check = 0.0
        while time.monotonic() < deadline:
            try:
                if time.monotonic() - last_status_check >= 1.0:
                    status = self.rpc("coreStatus")
                    last_status_check = time.monotonic()
                    if (status.get("running") is not True or status.get("pid") != pid or
                            status.get("launchID") != launch_id):
                        raise RuntimeError("Helper status lost the current test core launch identity")
                version = self.lifecycle.api_json(endpoint, token, "/version")
                config = self.lifecycle.api_json(endpoint, token, "/configs")
                current_utuns = self.lifecycle.utun_interfaces()
                created = sorted(set(current_utuns) - set(baseline_utuns))
                self.created_utuns = sorted(set(self.created_utuns) | set(created))
                active = [self.lifecycle.inspect_utun(name) for name in created]
                active = [item for item in active if item["up"] and item["ipv4"]]
                routes = self.lifecycle.routes_via_utun(created)
                if active and routes:
                    route_observations = []
                    selected = None
                    for address, category in self.lifecycle.ROUTE_TARGETS:
                        route = self.lifecycle.route_lookup(address)
                        item = {"address": address, "category": category, "route": route}
                        route_observations.append(item)
                        if route["interface"] in created:
                            selected = item
                            break
                    if selected:
                        tun_config = config.get("tun") or {}
                        if (tun_config.get("enable") is not True or
                                tun_config.get("auto-route") is not True or
                                tun_config.get("auto-detect-interface") is not True):
                            last_error = f"/configs reported unexpected TUN settings: {tun_config}"
                            time.sleep(0.35)
                            continue
                        self.assertion("Mihomo API reports TUN enabled and auto-route",
                                       True, {"version": version, "tun": tun_config})
                        return version, config, created, active, routes, route_observations, selected
                    last_error = "no reserved/public route selected through the new utun"
                else:
                    last_error = "new utun is not UP with IPv4 and an auto-route"
            except (OSError, RuntimeError, urllib.error.URLError, subprocess.SubprocessError,
                    ValueError, KeyError) as error:
                last_error = str(error)
            time.sleep(0.35)
        raise TimeoutError(f"timed out waiting for Helper-managed TUN readiness: {last_error}")

    def validate_proxy_snapshot(self, snapshot):
        if not isinstance(snapshot, dict):
            raise RuntimeError("Helper returned a malformed proxy snapshot")
        if snapshot.get("__ClashFXProxyCaptureError"):
            raise RuntimeError(f"Helper could not capture system proxy: {snapshot['__ClashFXProxyCaptureError']}")
        service_ids = snapshot.get("__ClashFXCapturedServiceIDs")
        if not isinstance(service_ids, list) or not service_ids:
            raise RuntimeError("Helper proxy snapshot did not enumerate any network services")
        return service_ids

    def validate_system_proxy_enable(self, service_ids, port):
        actual = self.rpc("proxySnapshot")
        expected_keys = ("HTTPEnable", "HTTPSEnable", "SOCKSEnable")
        mismatches = []
        for service_id in service_ids:
            settings = actual.get(service_id)
            if not isinstance(settings, dict):
                mismatches.append({"serviceID": service_id, "reason": "missing proxy dictionary"})
                continue
            for key in expected_keys:
                if settings.get(key) != 1:
                    mismatches.append({"serviceID": service_id, "key": key,
                                       "actual": settings.get(key)})
            for key in ("HTTPProxy", "HTTPSProxy", "SOCKSProxy"):
                if settings.get(key) != "127.0.0.1":
                    mismatches.append({"serviceID": service_id, "key": key,
                                       "actual": settings.get(key)})
            for key in ("HTTPPort", "HTTPSPort", "SOCKSPort"):
                if settings.get(key) != port:
                    mismatches.append({"serviceID": service_id, "key": key,
                                       "actual": settings.get(key)})
        self.assertion("Helper enabled loopback proxy settings on every captured network service",
                       not mismatches,
                       {"serviceCount": len(service_ids), "port": port, "mismatches": mismatches})
        self.report["systemProxyDuring"] = {
            "serviceCount": len(service_ids), "enabledPort": port,
            "snapshotSHA256": canonical_hash(actual),
        }

    def restore_proxy_now(self, phase):
        self.rpc("restoreProxy", httpPort=0, socksPort=0, settings=self.proxy_snapshot,
                 filterInterface=False)
        actual = self.rpc("proxySnapshot")
        matches = (isinstance(actual, dict) and
                   normalized_proxy_state(actual) == normalized_proxy_state(self.proxy_snapshot))
        self.assertion(f"{phase}: Helper restored the captured proxy snapshot exactly",
                       matches,
                       {"beforeSHA256": canonical_hash(normalized_proxy_state(self.proxy_snapshot)),
                        "afterSHA256": canonical_hash(normalized_proxy_state(actual))
                        if isinstance(actual, dict) else None})
        self.report["coverage"]["systemProxyExactRestore"] = matches
        self.proxy_may_be_dirty = not matches

    def invoke_transaction_client(self, endpoint, token, config_path, alternate_path,
                                  invalid_path, core_home, proxy_port, socks_port, dns_port):
        manifest = {
            "controllerURL": endpoint,
            "secret": token,
            "coreBinary": str(self.test_core),
            "homeDir": str(core_home),
            "goodConfig": str(config_path),
            "alternateConfig": str(alternate_path),
            "invalidConfig": str(invalid_path),
            "proxyPort": proxy_port,
            "socksPort": socks_port,
            "dnsPort": dns_port,
            "outputJSON": str(self.transaction_report_path),
        }
        self.transaction_manifest.write_text(json.dumps(manifest, sort_keys=True, indent=2),
                                             encoding="utf-8")
        safe_manifest = dict(manifest)
        safe_manifest["secret"] = "<redacted>"
        self.proxy_may_be_dirty = True
        self.dns_may_be_dirty = True
        started = time.monotonic()
        try:
            completed = subprocess.run(
            [str(self.transaction_executable), "--manifest", str(self.transaction_manifest)],
                cwd=str(self.temp_root), check=False, capture_output=True, text=True, timeout=180,
            )
        except subprocess.TimeoutExpired as error:
            self.report["transactionClient"] = {
                "exitCode": None,
                "elapsedSeconds": round(time.monotonic() - started, 3),
                "timedOut": True,
                "manifest": safe_manifest,
            }
            raise RuntimeError("production TxDriver exceeded its 180 second deadline") from error

        self.transaction_stdout.write_text(completed.stdout, encoding="utf-8", errors="replace")
        self.transaction_stderr.write_text(completed.stderr, encoding="utf-8", errors="replace")
        if not self.transaction_report_path.is_file():
            raise RuntimeError("TxDriver did not write its report; " + completed.stdout[-1200:])
        self.transaction_report_path.chmod(0o644)
        with self.transaction_report_path.open("r", encoding="utf-8") as stream:
            transaction_report = json.load(stream)
        self.report["productionTransaction"] = transaction_report
        self.report["transactionClient"] = {
            "exitCode": completed.returncode,
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "manifest": safe_manifest,
            "stdoutTail": completed.stdout[-4000:],
            "stderrTail": completed.stderr[-4000:],
            "reportPath": str(self.transaction_report_path),
        }

        coverage = transaction_report.get("coverage")
        if not isinstance(coverage, dict):
            raise RuntimeError("TxDriver report must contain a coverage object")
        required_coverage = (
            "productionHelperXPC",
            "productionClaudeTransactionSuccess",
            "productionSystemProxyEnable",
            "productionClaudeRuntimeFailureRollback",
            "actualInvalidConfigNotReady",
            "runtimeRestoredWithProductionHelper",
            "productionSystemProxyCheckpointRestore",
            "realSCPreferencesLockFailure",
            "failedTransactionPreferenceCommitDeltaZero",
        )
        missing_coverage = [key for key in required_coverage if coverage.get(key) is not True]
        self.assertion("production transaction client reports both production failure rollbacks",
                       completed.returncode == 0 and transaction_report.get("status") == "passed" and
                       transaction_report.get("controlPassed") is True and not missing_coverage,
                       {"status": transaction_report.get("status"),
                        "controlPassed": transaction_report.get("controlPassed"),
                        "missingOrFalseCoverage": missing_coverage,
                        "coverage": coverage})
        self.report["coverage"]["productionSystemProxyManager"] = True
        self.report["coverage"]["ClaudeProxyLockTransactionRollback"] = True
        self.report["coverage"]["productionInvalidConfigRuntimeFailure"] = (
            coverage.get("actualInvalidConfigNotReady") is True and
            coverage.get("productionClaudeRuntimeFailureRollback") is True)
        self.report["coverage"]["productionTransactionDNSOverrideRestore"] = (
            coverage.get("systemDNSOverride") is True and coverage.get("systemDNSExactRestore") is True)

        current_status = self.rpc("coreStatus")
        self.owned_launch_id = current_status.get("launchID")
        self.owned_core_pid = current_status.get("pid")
        self.core_log_path = current_status.get("logPath") or self.core_log_path
        if self.core_log_path:
            self.core_log_paths.append(self.core_log_path)
        self.assertion("production transaction restored the known-good Helper-managed runtime",
                       current_status.get("running") is True and
                       current_status.get("binaryPath") == str(self.test_core) and
                       current_status.get("configPath") == str(config_path) and
                       isinstance(self.owned_launch_id, str) and self.owned_launch_id,
                       {"status": current_status,
                        "expectedBinaryPath": str(self.test_core),
                        "expectedGoodConfig": str(config_path)})
        self.created_utuns = sorted(set(self.created_utuns) |
                                    (set(self.lifecycle.utun_interfaces()) -
                                     set(self.report["routeBaseline"]["utunInterfaces"])) )

        proxy_after = self.rpc("proxySnapshot")
        proxy_restored = (isinstance(proxy_after, dict) and
                          normalized_proxy_state(proxy_after) == normalized_proxy_state(self.proxy_snapshot))
        self.assertion("production transaction leaves all proxy services at the captured baseline",
                       proxy_restored,
                       {"expectedSHA256": canonical_hash(normalized_proxy_state(self.proxy_snapshot)),
                        "actualSHA256": canonical_hash(normalized_proxy_state(proxy_after))
                        if isinstance(proxy_after, dict) else None})
        self.report["coverage"]["systemProxyExactRestore"] = proxy_restored

        dns_after = self.rpc("dnsSnapshot")
        dns_restored = dns_after == self.dns_snapshot
        self.assertion("production transaction leaves eligible DNS services at the captured baseline",
                       dns_restored,
                       {"expectedSHA256": canonical_hash(self.dns_snapshot),
                        "actualSHA256": canonical_hash(dns_after)})
        self.report["coverage"]["systemDNSExactRestore"] = (
            self.report["coverage"]["systemDNSExactRestore"] and dns_restored)

    def exercise_dns_override(self):
        self.dns_may_be_dirty = True
        self.rpc("overrideDNS", servers=[TEST_DNS_SERVER], filterInterface=True)
        actual_during = self.rpc("dnsSnapshot")
        mismatches = []
        for service_id, settings in actual_during.items():
            addresses = settings.get("ServerAddresses") if isinstance(settings, dict) else None
            if addresses != [TEST_DNS_SERVER]:
                mismatches.append({"serviceID": service_id, "serverAddresses": addresses})
        self.assertion("real Helper XPC applied DNS override to eligible Ethernet/Wi-Fi services",
                       bool(actual_during) and not mismatches,
                       {"serviceCount": len(actual_during), "server": TEST_DNS_SERVER,
                        "mismatches": mismatches})
        self.report["coverage"]["systemDNSOverride"] = True
        self.report["systemDNSDuring"] = {
            "serviceCount": len(actual_during), "snapshotSHA256": canonical_hash(actual_during),
            "testServer": TEST_DNS_SERVER,
        }
        self.rpc("restoreDNS", settings=self.dns_snapshot, filterInterface=True)
        restored = self.rpc("dnsSnapshot")
        exact = restored == self.dns_snapshot
        self.assertion("real Helper XPC restored the captured eligible DNS snapshot exactly",
                       exact,
                       {"beforeSHA256": canonical_hash(self.dns_snapshot),
                        "afterSHA256": canonical_hash(restored)})
        self.report["coverage"]["systemDNSExactRestore"] = exact
        self.report["coverage"]["productionTransactionDNSOverrideRestore"] = False
        self.dns_may_be_dirty = not exact
        self.dns_may_be_dirty = not exact

    def run_invalid_config_case(self, baseline_utuns, baseline_default, baseline_targets):
        home = self.temp_root / "invalid-core-home"
        home.mkdir()
        missing_config = self.temp_root / "intentionally-missing-config.yaml"
        self.core_start_attempted = True
        self.harness_config_paths.add(str(missing_config))
        self.core_home_by_config[str(missing_config)] = str(home)
        result = self.rpc("startCore", binaryPath=str(self.test_core),
                          configPath=str(missing_config), homeDir=str(home))
        self.assertion("Helper accepted process launch for invalid-config failure case", result is None)
        status = self.rpc("coreStatus")
        launch_id = status.get("launchID")
        if not isinstance(launch_id, str) or not launch_id:
            raise RuntimeError("Helper did not report a launch ID for the invalid-config case")
        self.owned_launch_id = launch_id
        self.owned_core_pid = status.get("pid")
        self.core_log_path = status.get("logPath")
        if self.core_log_path:
            self.core_log_paths.append(self.core_log_path)
        status = self.wait_for_core_exit(launch_id)
        summary = status.get("lastTermination", "")
        summary_status = re.search(r"\bstatus=(\d+)", summary)
        self.assertion("invalid config exits through the real Helper-managed core process",
                       status.get("running") is False and summary_status is not None and
                       int(summary_status.group(1)) != 0,
                       {"launchID": launch_id, "pid": status.get("pid"),
                        "lastTermination": summary})
        if status.get("logPath"):
            self.core_log_path = status["logPath"]
        current_utuns = self.lifecycle.utun_interfaces()
        self.assertion("invalid-config failure creates no persistent TUN interface",
                       current_utuns == baseline_utuns,
                       {"before": baseline_utuns, "after": current_utuns})
        current_default = self.lifecycle.default_route()
        current_targets = {address: self.lifecycle.route_lookup(address)
                           for address in baseline_targets}
        self.assertion("invalid-config failure leaves captured routes unchanged",
                       current_default == baseline_default and current_targets == baseline_targets,
                       {"defaultRouteBefore": baseline_default,
                        "defaultRouteAfter": current_default,
                        "routeTargetsBefore": baseline_targets,
                        "routeTargetsAfter": current_targets})
        self.report["invalidConfigCase"] = {
            "launchID": launch_id,
            "exitSummary": summary,
            "configPath": str(missing_config),
            "configFileExisted": missing_config.exists(),
        }
        self.report["coverage"]["invalidConfigPathFailure"] = True
        self.owned_launch_id = None
        self.owned_core_pid = None

    def run(self):
        self.compile_client()
        self.compile_transaction_client()
        self.prepare_launchd_job()
        self.bootstrap_helper()

        helper_version = self.rpc("version")
        protocol_version = self.rpc("protocolVersion")
        self.assertion("real Helper exposes production protocol version 4",
                       protocol_version == 4,
                       {"helperVersion": helper_version, "protocolVersion": protocol_version})
        self.report["coverage"]["productionHelperXPC"] = True
        helper_pid = self.helper_pid()
        self.assertion("production Helper is launched by the system domain as root",
                       helper_pid is not None,
                       {"pid": helper_pid, "uid": 0, "launchdLabel": SERVICE_LABEL})
        self.report["helper"] = {
            "pid": helper_pid,
            "uid": 0,
            "version": helper_version,
            "protocolVersion": protocol_version,
            "machService": SERVICE_LABEL,
            "clientExecutable": str(self.probe_executable),
            "clientBundleIdentifier": CLIENT_BUNDLE_ID,
        }

        self.proxy_snapshot = self.rpc("proxySnapshot")
        self.dns_snapshot = self.rpc("dnsSnapshot")
        service_ids = self.validate_proxy_snapshot(self.proxy_snapshot)
        if not isinstance(self.dns_snapshot, dict):
            raise RuntimeError("Helper returned a malformed DNS snapshot")
        self.report["before"] = {
            "proxySnapshotSHA256": canonical_hash(normalized_proxy_state(self.proxy_snapshot)),
            "proxyServiceCount": len(service_ids),
            "dnsSnapshotSHA256": canonical_hash(self.dns_snapshot),
            "dnsServiceCount": len(self.dns_snapshot),
        }

        baseline_utuns = self.lifecycle.utun_interfaces()
        baseline_default = self.lifecycle.default_route()
        route_targets = {address: self.lifecycle.route_lookup(address)
                         for address, _category in self.lifecycle.ROUTE_TARGETS}
        self.report["routeBaseline"] = {
            "utunInterfaces": baseline_utuns,
            "defaultRoute": baseline_default,
            "routeTargets": route_targets,
            "stateSHA256": canonical_hash({"utunInterfaces": baseline_utuns,
                                            "defaultRoute": baseline_default,
                                            "routeTargets": route_targets}),
        }
        initial_core_status = self.rpc("coreStatus")
        self.assertion("Helper has no pre-existing test or application core",
                       initial_core_status.get("running") is False,
                       {"running": initial_core_status.get("running"),
                        "launchID": initial_core_status.get("launchID")})

        self.run_invalid_config_case(baseline_utuns, baseline_default, route_targets)

        reserved_ports = set()
        controller_port = self.lifecycle.free_port(reserved_ports)
        dns_port = self.lifecycle.free_port(reserved_ports)
        mixed_port = self.lifecycle.free_port(reserved_ports)
        token = secrets.token_hex(24)
        config = self.lifecycle.make_config(controller_port, dns_port, mixed_port, token)
        config_path = self.temp_root / "mihomo-config.json"
        config_path.write_text(json.dumps(config, sort_keys=True), encoding="utf-8")
        alternate_config = dict(config)
        alternate_config["log-level"] = "warning"
        alternate_path = self.temp_root / "mihomo-alternate-config.json"
        alternate_path.write_text(json.dumps(alternate_config, sort_keys=True), encoding="utf-8")
        invalid_path = self.temp_root / "mihomo-invalid-config.yaml"
        invalid_path.write_text("tun: [\n", encoding="utf-8")
        core_home = self.temp_root / "core-home"
        core_home.mkdir()
        endpoint = f"http://127.0.0.1:{controller_port}"
        self.report["core"] = {
            "binaryPath": str(self.test_core),
            "configPath": str(config_path),
            "homeDir": str(core_home),
            "ports": {"controller": controller_port, "dns": dns_port, "mixed": mixed_port},
            "startRequestedThrough": "ProxyConfigRemoteProcessProtocol.startMihomoCoreWithBinaryPath",
        }

        self.core_start_attempted = True
        self.harness_config_paths.add(str(config_path))
        self.core_home_by_config[str(config_path)] = str(core_home)
        start_result = self.rpc("startCore", binaryPath=str(self.test_core),
                                configPath=str(config_path), homeDir=str(core_home))
        self.assertion("real Helper accepted the valid TUN core start request", start_result is None)
        status = self.rpc("coreStatus")
        self.owned_launch_id = status.get("launchID")
        self.owned_core_pid = status.get("pid")
        self.core_log_path = status.get("logPath")
        if self.core_log_path:
            self.core_log_paths.append(self.core_log_path)
        if (status.get("running") is not True or not isinstance(self.owned_launch_id, str) or
                not self.owned_launch_id or not isinstance(self.owned_core_pid, int) or
                self.owned_core_pid <= 0):
            raise RuntimeError(f"Helper did not report the launched core identity: {status}")
        self.assertion("Helper status identifies the bundled core and exact test config",
                       status.get("binaryPath") == str(self.test_core) and
                       status.get("configPath") == str(config_path),
                       {"binaryPath": status.get("binaryPath"),
                        "configPath": status.get("configPath"),
                        "expectedBinaryPath": str(self.test_core),
                        "expectedConfigPath": str(config_path)})
        core_uid = require_command_success(["/bin/ps", "-o", "uid=", "-p",
                                            str(self.owned_core_pid)], 5).strip()
        self.assertion("Helper-managed Mihomo process is root-owned in the hosted guest",
                       core_uid == "0", {"pid": self.owned_core_pid, "uid": core_uid})

        (version, api_config, new_utuns, active_tuns, tun_routes,
         route_observations, selected_route) = self.wait_for_tun_ready(
            endpoint, token, baseline_utuns, self.owned_launch_id, self.owned_core_pid)
        self.report["coverage"]["helperManagedCore"] = True
        self.report["coverage"]["tunInterfaceAndRoutes"] = True
        self.report["core"].update({
            "version": version,
            "pid": self.owned_core_pid,
            "launchID": self.owned_launch_id,
            "active": True,
            "apiTun": api_config.get("tun"),
            "newUtunInterfaces": new_utuns,
            "activeUtunInterfaces": active_tuns,
            "routesViaNewUtun": tun_routes,
            "routeTargetQueries": route_observations,
            "selectedRouteTarget": selected_route,
        })
        self.assertion("new TUN interface and an auto-route belong to this Helper-managed core",
                       bool(active_tuns and tun_routes and
                            selected_route["route"]["interface"] in new_utuns),
                       {"launchID": self.owned_launch_id, "pid": self.owned_core_pid,
                        "newUtuns": new_utuns, "selectedRoute": selected_route})

        owned_ports = []
        for protocol, port in (("TCP", controller_port), ("TCP", mixed_port),
                               ("TCP", dns_port), ("UDP", dns_port)):
            listening = protocol == "TCP"
            owns = self.lifecycle.process_owns_socket(self.owned_core_pid, protocol, port,
                                                       listening=listening)
            self.assertion(f"Helper-managed core PID owns {protocol} port {port}", owns,
                           {"pid": self.owned_core_pid, "protocol": protocol, "port": port})
            if owns:
                owned_ports.append({"protocol": protocol, "port": port})
        self.report["core"]["ownedPorts"] = owned_ports
        self.report["coverage"]["controllerProxyAndDNSOwnership"] = len(owned_ports) == 4

        for transport, name in (("udp", "example.com"), ("tcp", "example.net")):
            address = self.lifecycle.query_dns(dns_port, transport, name)
            self.assertion(f"real core answers {transport.upper()} fake-IP DNS", address.startswith("198.18."),
                           {"transport": transport, "query": name, "fakeIP": address})
            self.report.setdefault("dnsQueries", {})[transport] = {"query": name, "fakeIP": address}

        self.proxy_may_be_dirty = True
        self.rpc("enableProxy", httpPort=mixed_port, socksPort=mixed_port, pac="",
                 filterInterface=False, ignoreList=["localhost", "127.0.0.1", "::1"])
        self.validate_system_proxy_enable(service_ids, mixed_port)
        self.report["coverage"]["systemProxyCaptureAndEnable"] = True
        self.restore_proxy_now("direct production Helper proxy exercise")
        self.exercise_dns_override()

        if self.transaction_client_available:
            self.invoke_transaction_client(endpoint, token, config_path, alternate_path, invalid_path,
                                           core_home, mixed_port, mixed_port, dns_port)
        else:
            self.report["coverage"]["productionSystemProxyManager"] = False
            self.report["coverage"]["ClaudeProxyLockTransactionRollback"] = False
            self.report["coverage"]["systemDNSOverride"] = False
            self.report["coverage"]["systemDNSExactRestore"] = False
            self.report["scopeNotes"].append(
                "The companion Swift transaction client was unavailable, so transaction and DNS-override coverage is false."
            )

    def _safe_rpc_cleanup(self, operation, **values):
        try:
            return self.rpc(operation, **values), None
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": operation,
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1
            return None, error

    def _fallback_stop_owned_core(self, launch_id, core_pid):
        if core_pid is None or launch_id is None:
            return
        try:
            status = self.rpc("coreStatus")
        except Exception as error:
            self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                       "xpcStatusUnavailable": str(error)}
            self._fallback_stop_core_by_exact_arguments()
            return
        if status.get("launchID") != launch_id or status.get("pid") != core_pid:
            self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                       "fallbackStopSkipped": "Helper launch identity no longer matches"}
            return
        if not status.get("running"):
            return
        try:
            executable = require_command_success(["/usr/sbin/lsof", "-a", "-p",
                                                   str(core_pid), "-d", "txt", "-Fn"], 5)
            paths = [line[1:] for line in executable.splitlines() if line.startswith("n")]
            if str(self.test_core) not in paths:
                self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                           "fallbackStopSkipped": "PID executable did not match bundled test core",
                                           "observedExecutables": paths}
                return
            os.kill(core_pid, signal.SIGTERM)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                try:
                    os.kill(core_pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                       "fallbackStopSentToOwnedCorePid": core_pid}
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": "owned-core-fallback-stop",
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1

    def _fallback_stop_core_by_exact_arguments(self):
        if not self.core_start_attempted or not self.harness_config_paths:
            return

        def matches_owned_command(pid, config_path, home_dir):
            try:
                output = require_command_success(["/bin/ps", "-p", str(pid), "-o", "args="], 5).strip()
                arguments = shlex.split(output)
                if len(arguments) < 5:
                    return False
                executable = str(Path(arguments[0]).resolve())
                if (executable != str(self.test_core.resolve()) or
                        arguments[1:5] != ["-f", config_path, "-d", home_dir]):
                    return False
                text_paths = require_command_success([
                    "/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"
                ], 5)
                return str(self.test_core) in [line[1:] for line in text_paths.splitlines()
                                               if line.startswith("n")]
            except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
                return False

        try:
            process_list = require_command_success(["/bin/ps", "-axo", "pid=,args="], 8)
            matches = []
            for line in process_list.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) != 2:
                    continue
                try:
                    pid = int(fields[0])
                except ValueError:
                    continue
                if pid == os.getpid():
                    continue
                for config_path, home_dir in self.core_home_by_config.items():
                    try:
                        arguments = shlex.split(fields[1])
                    except ValueError:
                        continue
                    if (len(arguments) >= 5 and
                            str(Path(arguments[0]).resolve()) == str(self.test_core.resolve()) and
                            arguments[1:5] == ["-f", config_path, "-d", home_dir] and
                            matches_owned_command(pid, config_path, home_dir)):
                        matches.append({"pid": pid, "configPath": config_path, "homeDir": home_dir})
                        break
            if not matches:
                return

            stopped = []
            for item in matches:
                pid = item["pid"]
                config_path = item["configPath"]
                home_dir = item["homeDir"]
                if matches_owned_command(pid, config_path, home_dir):
                    os.kill(pid, signal.SIGTERM)
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        if not matches_owned_command(pid, config_path, home_dir):
                            break
                        time.sleep(0.1)
                still_owned = matches_owned_command(pid, config_path, home_dir)
                stopped.append({**item, "terminateSent": True, "stillRunning": still_owned})
                if still_owned:
                    self.report["failures"].append({
                        "phase": "cleanup", "operation": "owned-core-fallback-stop",
                        "message": f"owned core PID {pid} did not exit after SIGTERM",
                    })
                    self.exit_code = self.exit_code or 1
            self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                       "fallbackCoreProcessMatches": stopped}
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": "owned-core-process-scan",
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1

    def _restore_system_state(self):
        if self.proxy_snapshot is not None and self.proxy_may_be_dirty:
            _result, error = self._safe_rpc_cleanup(
                "restoreProxy", httpPort=0, socksPort=0, settings=self.proxy_snapshot,
                filterInterface=False)
            if error is None:
                actual_snapshot, actual_error = self._safe_rpc_cleanup("proxySnapshot")
                matches = (actual_error is None and isinstance(actual_snapshot, dict) and
                           normalized_proxy_state(actual_snapshot) ==
                           normalized_proxy_state(self.proxy_snapshot))
                self.cleanup_assertion("system proxy settings exactly match the captured all-service snapshot",
                                       matches,
                                       {"beforeSHA256": canonical_hash(normalized_proxy_state(self.proxy_snapshot)),
                                        "afterSHA256": canonical_hash(normalized_proxy_state(actual_snapshot))
                                        if isinstance(actual_snapshot, dict) else None})
                self.report["coverage"]["systemProxyExactRestore"] = matches
                self.report["cleanup"] = {**self.report.get("cleanup", {}), "proxyRestored": matches}
        if self.dns_snapshot is not None and self.dns_may_be_dirty:
            _result, error = self._safe_rpc_cleanup("restoreDNS", settings=self.dns_snapshot,
                                                    filterInterface=True)
            if error is None:
                actual_snapshot, actual_error = self._safe_rpc_cleanup("dnsSnapshot")
                matches = actual_error is None and actual_snapshot == self.dns_snapshot
                self.cleanup_assertion("system DNS settings exactly match the captured Ethernet/Wi-Fi snapshot",
                                       matches,
                                       {"beforeSHA256": canonical_hash(self.dns_snapshot),
                                        "afterSHA256": canonical_hash(actual_snapshot) if actual_snapshot is not None else None})
                self.report["coverage"]["systemDNSExactRestore"] = matches
                self.report["cleanup"] = {**self.report.get("cleanup", {}), "dnsRestored": matches}

    def _bootout_helper(self):
        if not self.bootstrapped:
            return
        result = command_result(["/bin/launchctl", "bootout", f"system/{SERVICE_LABEL}"], 20)
        if result.returncode != 0:
            self.report["failures"].append({"phase": "cleanup", "operation": "launchctl-bootout",
                                            "message": (result.stderr or result.stdout).strip()})
            self.exit_code = self.exit_code or 1
            return
        self.bootstrapped = False
        self.report["cleanup"] = {**self.report.get("cleanup", {}), "helperBootedOut": True}

    def cleanup(self):
        cleanup = self.report.setdefault("cleanup", {})
        if self.bootstrapped and self.core_start_attempted and not (
                self.owned_launch_id and self.owned_core_pid):
            try:
                observed = self.rpc("coreStatus")
                launch_id = observed.get("launchID")
                pid = observed.get("pid")
                owned_request = (observed.get("binaryPath") == str(self.test_core) and
                                 observed.get("configPath") in self.harness_config_paths and
                                 isinstance(launch_id, str) and launch_id and
                                 isinstance(pid, int) and pid > 0)
                if observed.get("running") is True and owned_request:
                    self.owned_launch_id = launch_id
                    self.owned_core_pid = pid
                    self.core_log_path = observed.get("logPath")
                    if self.core_log_path:
                        self.core_log_paths.append(self.core_log_path)
                    cleanup["adoptedCoreFromHarnessStartRequest"] = {
                        "launchID": launch_id, "pid": pid,
                        "configPath": observed.get("configPath"),
                    }
            except Exception as error:
                self.report["failures"].append({"phase": "cleanup", "operation": "recover-core-launch-identity",
                                                "message": str(error)})
                self.exit_code = self.exit_code or 1
                self._fallback_stop_core_by_exact_arguments()
        if self.bootstrapped and self.owned_launch_id and self.owned_core_pid:
            launch_id = self.owned_launch_id
            core_pid = self.owned_core_pid
            try:
                status = self.rpc("coreStatus")
                if status.get("launchID") == launch_id and status.get("pid") == core_pid:
                    if status.get("running") is True:
                        _result, error = self._safe_rpc_cleanup("stopCore")
                        if error is not None:
                            self._fallback_stop_owned_core(launch_id, core_pid)
                    else:
                        cleanup["coreAlreadyExited"] = True
                else:
                    self.report["failures"].append({
                        "phase": "cleanup", "operation": "stopCore",
                        "message": "skipped because Helper launch ID/PID no longer matches this harness",
                    })
                    self.exit_code = self.exit_code or 1
            except Exception as error:
                self.report["failures"].append({"phase": "cleanup", "operation": "core-status-before-stop",
                                                "message": str(error)})
                self.exit_code = self.exit_code or 1
                self._fallback_stop_owned_core(launch_id, core_pid)

            if launch_id:
                try:
                    deadline = time.monotonic() + 8
                    final_status = None
                    while time.monotonic() < deadline:
                        final_status = self.rpc("coreStatus")
                        if (final_status.get("launchID") == launch_id and
                                final_status.get("running") is False):
                            break
                        time.sleep(0.25)
                    stopped = (final_status is not None and
                               final_status.get("launchID") == launch_id and
                               final_status.get("running") is False)
                    self.cleanup_assertion("Helper reports the same test launch stopped", stopped,
                                           {"expectedLaunchID": launch_id, "status": final_status})
                    cleanup["coreStoppedThroughHelper"] = stopped
                except Exception as error:
                    self.report["failures"].append({"phase": "cleanup", "operation": "verify-core-stop",
                                                    "message": str(error)})
                    self.exit_code = self.exit_code or 1

        self._restore_system_state()

        try:
            current_utuns = self.lifecycle.utun_interfaces()
            remaining_routes = self.lifecycle.routes_via_utun(self.created_utuns)
            route_restored = True
            default_restored = True
            baseline = self.report.get("routeBaseline")
            if baseline:
                route_restored = False
                default_restored = False
                targets_restored = False
                deadline = time.monotonic() + RESTORE_TIMEOUT
                last = None
                last_error = None
                while time.monotonic() < deadline:
                    try:
                        current_utuns = self.lifecycle.utun_interfaces()
                        current_default = self.lifecycle.default_route()
                        current_targets = {address: self.lifecycle.route_lookup(address)
                                           for address in baseline["routeTargets"]}
                        remaining_routes = self.lifecycle.routes_via_utun(self.created_utuns)
                        last = {"utunInterfaces": current_utuns,
                                "defaultRoute": current_default,
                                "routeTargets": current_targets,
                                "routesViaTestUtuns": remaining_routes}
                        route_restored = current_utuns == baseline["utunInterfaces"] and not remaining_routes
                        default_restored = current_default == baseline["defaultRoute"]
                        targets_restored = current_targets == baseline["routeTargets"]
                        if route_restored and default_restored and targets_restored:
                            break
                    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                        last_error = str(error)
                    time.sleep(0.35)
                self.report["after"] = last
                if last is None and last_error:
                    cleanup["routeObservationError"] = last_error
                if last is not None:
                    last["stateSHA256"] = canonical_hash({
                        "utunInterfaces": last["utunInterfaces"],
                        "defaultRoute": last["defaultRoute"],
                        "routeTargets": last["routeTargets"],
                    })
                self.cleanup_assertion("TUN interface and route tables returned to their captured baseline",
                                       route_restored and default_restored and targets_restored,
                                       {"utunRestored": route_restored,
                                        "defaultRouteRestored": default_restored,
                                        "routeTargetsRestored": targets_restored,
                                        "final": last})
                cleanup["tunRoutesRestored"] = route_restored and default_restored and targets_restored
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": "verify-route-restoration",
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1

        self._bootout_helper()

        unique_core_logs = list(dict.fromkeys(self.core_log_paths))
        for index, source in enumerate(unique_core_logs):
            name = "mihomo_core.log" if index == len(unique_core_logs) - 1 else f"mihomo_core-{index + 1}.log"
            copied = copy_log(source, self.artifact_dir / name)
            cleanup[name + "Copied"] = copied
        for source, name in ((self.helper_stdout, "helper.stdout.log"),
                             (self.helper_stderr, "helper.stderr.log"),
                             (self.transaction_stdout, "transaction.stdout.log"),
                             (self.transaction_stderr, "transaction.stderr.log")):
            copied = copy_log(source, self.artifact_dir / name)
            cleanup[name + "Copied"] = copied
        try:
            process_output = require_command_success(["/bin/ps", "-axo", "pid=,comm="], 8)
            remaining = []
            for line in process_output.splitlines():
                fields = line.strip().split(None, 1)
                if len(fields) != 2:
                    continue
                try:
                    pid = int(fields[0])
                except ValueError:
                    continue
                name = Path(fields[1].strip()).name
                if pid != os.getpid() and name in {"ClashFX", SERVICE_LABEL, "mihomo_core"}:
                    remaining.append({"pid": pid, "name": name})
            self.cleanup_assertion("no ClashFX client, Helper, or mihomo_core process remains",
                                   not remaining, {"processes": remaining})
            cleanup["ownedProcessesRemaining"] = remaining
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": "process-cleanup-check",
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1

        if self.bootstrap_attempted and not self.bootstrapped:
            result = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
            missing = result.returncode != 0 and "could not find service" in (
                result.stdout + result.stderr).lower()
            if not missing:
                self.report["failures"].append({"phase": "cleanup", "operation": "verify-launchd-unloaded",
                                                "message": (result.stderr or result.stdout).strip()})
                self.exit_code = self.exit_code or 1
            cleanup["helperServiceUnloaded"] = missing

        self.report["status"] = "passed" if self.exit_code == 0 and not self.report["failures"] else "failed"
        self.report["finishedAtUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.report["artifactDirectory"] = str(self.artifact_dir)
        self.report["rawLogs"] = sorted(path.name for path in self.artifact_dir.iterdir()
                                         if path.name.endswith(".log"))
        try:
            with (self.artifact_dir / "report.json").open("w", encoding="utf-8") as stream:
                json.dump(self.report, stream, indent=2, sort_keys=True)
                stream.write("\n")
            (self.artifact_dir / "report.json").chmod(0o644)
        except OSError as error:
            self.report["status"] = "failed"
            self.report["failures"].append({"phase": "artifact", "message": str(error)})
            self.exit_code = self.exit_code or 1
        shutil.rmtree(self.temp_root, ignore_errors=True)


def load_lifecycle_module():
    # The existing smoke owns the DNS packet, API, socket, and route inspectors.
    # Import it without executing its standalone-core main routine.
    import importlib.util
    source = ROOT / "scripts" / "verify-ci-tun-lifecycle.py"
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("clashfx_ci_tun_lifecycle", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load route/DNS inspector module: {source}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    gate_failures, effective_uid = hosted_runner_gate()
    if gate_failures:
        emit_json({"status": "refused", "scope": "no system actions were attempted",
                   "gateFailures": gate_failures,
                   "environment": {"platform": sys.platform, "effectiveUid": effective_uid,
                                   "githubActions": os.environ.get("GITHUB_ACTIONS"),
                                   "runnerEnvironment": os.environ.get("RUNNER_ENVIRONMENT"),
                                   "runnerOS": os.environ.get("RUNNER_OS"),
                                   "imageOS": os.environ.get("ImageOS")}})
        return 2

    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True,
                        help="Xcode-built com.clashfx.app.Helper production executable")
    parser.add_argument("--core", required=True,
                        help="guest-built mihomo_core executable with the shipping overlay")
    parser.add_argument("--artifact-dir", required=True,
                        help="new report/log directory under RUNNER_TEMP")
    try:
        args = parser.parse_args()
        runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
        build_metadata, helper_path, core_path, launchd_template = validate_build_inputs(
            args.helper, args.core, runner_temp)
        verify_clean_guest_before_mutation()
        lifecycle = load_lifecycle_module()
        artifact_dir = Path(args.artifact_dir).expanduser().resolve()
        if not is_relative_to(artifact_dir, runner_temp):
            raise ValueError("--artifact-dir must be inside RUNNER_TEMP")
        if artifact_dir.exists():
            raise ValueError(f"artifact directory already exists: {artifact_dir}")
    except (UsageError, OSError, ValueError, RuntimeError, KeyError, ImportError,
            subprocess.SubprocessError) as error:
        emit_json({"status": "refused", "scope": "no system service or settings were changed",
                   "reason": str(error), "effectiveUid": effective_uid})
        return 2

    artifact_dir.mkdir(mode=0o755, parents=True, exist_ok=False)
    artifact_dir.chmod(0o755)
    temp_root = Path(tempfile.mkdtemp(prefix="clashfx-helper-tun-acceptance-", dir=runner_temp))
    harness = AcceptanceHarness(build_metadata, helper_path, core_path, launchd_template,
                                artifact_dir, temp_root, lifecycle)

    def handle_signal(signum, _frame):
        raise SmokeInterrupted(signum)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    try:
        harness.run()
    except SmokeInterrupted as error:
        harness.report["failures"].append({"phase": "signal", "signal": error.signum})
        harness.exit_code = 128 + error.signum
    except Exception as error:
        harness.report["failures"].append({"phase": "run", "type": type(error).__name__,
                                           "message": str(error)})
        harness.exit_code = harness.exit_code or 1
    finally:
        harness.cleanup()

    emit_json(harness.report)
    return harness.exit_code


if __name__ == "__main__":
    sys.exit(main())
