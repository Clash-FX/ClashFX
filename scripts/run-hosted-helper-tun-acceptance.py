#!/usr/bin/env python3
"""Run real ClashFX Helper and Mihomo TUN acceptance on a disposable hosted Mac."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error


ROOT = Path(__file__).resolve().parents[1]
SERVICE_LABEL = "com.clashfx.app.Helper"
CLIENT_BUNDLE_ID = "com.clashfx.app"
HELPER_BUNDLE_ID = "com.clashfx.app.Helper"
APPROVED_CORE_PATH = Path("/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core")
TRUST_RECEIPT_PATH = Path("/Library/PrivilegedHelperTools/com.clashfx.app.Helper.trust.plist")
INSTALLED_HELPER_PATH = Path("/Library/PrivilegedHelperTools") / SERVICE_LABEL
LAUNCH_DAEMON_PATH = Path("/Library/LaunchDaemons") / f"{SERVICE_LABEL}.plist"
TRUST_RECEIPT_SCHEMA_VERSION = 1
UNRELATED_TEST_XATTR = "com.clashfx.acceptance"
UNRELATED_TEST_XATTR_VALUE = b"clashfx-unrelated-xattr-v1"
FINDER_INFO_VALUE = bytes(range(32))
RESOURCE_FORK_VALUE = b"clashfx-resource-fork-acceptance-v1"
TEST_DNS_SERVER = "198.18.0.2"
CORE_READY_TIMEOUT = 45
CORE_EXIT_TIMEOUT = 15
RESTORE_TIMEOUT = 25
RPC_TIMEOUT = 35
HELPER_RESTART_CYCLES = 3
PORT_RELEASE_TIMEOUT = 20
SYSTEM_DNS_QUERY_TIMEOUT = 12
RUNTIME_CONFIG_ACCEPTANCE_TIMEOUT = 300
FAKE_IP_NETWORK = ipaddress.ip_network("198.18.0.0/16")


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


def route_targets_restored(before, after):
    """Persistent routes remain exact; expired WASCLONED host-cache entries may fall back.

    Never tolerate changed next hop/interface, reject/blackhole or a missing UP flag.
    Keep raw observations in report.json rather than rewriting the evidence.
    """
    if set(before) != set(after):
        return False
    for address, expected in before.items():
        actual = after[address]
        if expected == actual:
            continue
        old_flags = set(expected.get("flags", "").strip("<>").split(","))
        new_flags = set(actual.get("flags", "").strip("<>").split(","))
        if "WASCLONED" not in old_flags:
            return False
        if any(expected.get(key) != actual.get(key) for key in ("gateway", "interface")):
            return False
        if "UP" not in new_flags or new_flags.intersection({"REJECT", "BLACKHOLE"}):
            return False
    return True


def command_result(command, timeout=8):
    return subprocess.run(command, check=False, capture_output=True, text=True, timeout=timeout)


def require_command_success(command, timeout=8):
    result = command_result(command, timeout)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"command failed ({result.returncode}): {command[0]}: {detail}")
    return result.stdout


def metadata_attribute_names(path):
    # CPython's os xattr API is Linux-only; use the native macOS tool.
    output = require_command_success(["/usr/bin/xattr", "-s", str(path)], 8)
    return set(output.splitlines())


def metadata_attribute_write(path, name, value):
    require_command_success(["/usr/bin/xattr", "-w", "-x", "-s", name, value.hex(), str(path)], 8)


def metadata_attribute_read(path, name):
    output = require_command_success(["/usr/bin/xattr", "-p", "-x", "-s", name, str(path)], 8)
    return bytes.fromhex(output)


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
    trust_policy_path = ROOT / "ProxyConfigHelper" / "ProxyConfigHelperTrustPolicy.h"
    app_info_path = ROOT / "ClashFX" / "Info.plist"
    with helper_info_path.open("rb") as stream:
        helper_info = plistlib.load(stream)
    with launchd_info_path.open("rb") as stream:
        launchd_info = plistlib.load(stream)
    trust_policy_text = trust_policy_path.read_text(encoding="utf-8")
    with app_info_path.open("rb") as stream:
        app_info = plistlib.load(stream)
    if (str(APPROVED_CORE_PATH) not in trust_policy_text or
            str(TRUST_RECEIPT_PATH) not in trust_policy_text or
            CLIENT_BUNDLE_ID not in trust_policy_text or
            not re.search(r"ClashFXHelperTrustReceiptSchemaVersion\s*=\s*1\b", trust_policy_text)):
        raise ValueError("ProxyConfigHelperTrustPolicy.h paths, bundle identifier, or receipt schema changed")
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
        "productionHelperSource": "ProxyConfigHelper/ProxyConfigHelper.m + ProxyConfigRemoteProcessProtocol.h + ProxyConfigHelperTrustPolicy.h",
        "productionHelperLaunchdSource": str(launchd_info_path.relative_to(ROOT)),
        "productionHelperTrustPolicySource": str(trust_policy_path.relative_to(ROOT)),
    }, helper_path, core_path, launchd_info


def verify_clean_guest_before_mutation():
    existing_paths = [
        Path("/Library/LaunchDaemons") / f"{SERVICE_LABEL}.plist",
        Path("/Library/PrivilegedHelperTools") / SERVICE_LABEL,
        APPROVED_CORE_PATH,
        TRUST_RECEIPT_PATH,
    ]
    present = [str(path) for path in existing_paths if os.path.lexists(path)]
    trust_directory = APPROVED_CORE_PATH.parent
    if trust_directory.is_dir() and not trust_directory.is_symlink():
        partial_installs = list(trust_directory.glob(TRUST_RECEIPT_PATH.name + ".tmp.*"))
        partial_installs.extend(trust_directory.glob(".clashfx-install.*"))
        present.extend(str(path) for path in partial_installs if os.path.lexists(path))
    if present:
        raise RuntimeError("refusing to replace an existing Helper or approved-core installation: " +
                           ", ".join(present))

    for directory in (Path("/"), Path("/Library"), Path("/Library/PrivilegedHelperTools")):
        try:
            info = directory.lstat()
        except FileNotFoundError:
            if directory == APPROVED_CORE_PATH.parent:
                continue  # A fresh hosted guest may have no helper installation directory.
            raise
        except OSError as error:
            raise RuntimeError(f"cannot inspect trusted-core parent directory {directory}: {error}") from error
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or
                info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
            raise RuntimeError(f"trusted-core parent directory is not a safe root-owned directory: {directory}")

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


def root_trust_file_is_safe(path, executable, expected_sha256=None):
    info = path.lstat()
    required_access = stat.S_IXUSR if executable else stat.S_IRUSR
    immutable_flag = getattr(stat, "UF_IMMUTABLE", None)
    if immutable_flag is None:
        raise RuntimeError("Python does not expose the macOS UF_IMMUTABLE file flag")
    for directory in (Path("/"), Path("/Library"), path.parent):
        directory_info = directory.lstat()
        if (not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != 0 or
                directory_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
            return False
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
            info.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH) or
            not info.st_mode & required_access or
            not getattr(info, "st_flags", 0) & immutable_flag):
        return False
    if expected_sha256 is not None:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        return digest == expected_sha256
    return True


def file_sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_identity(path):
    info = path.lstat()
    return info.st_dev, info.st_ino


def decode_install_plist(path):
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise RuntimeError(f"installed plist is not a dictionary: {path}")
    return value


def process_text_paths(pid):
    output = require_command_success([
        "/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"
    ], 8)
    return [line[1:] for line in output.splitlines() if line.startswith("n")]


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
        self.helper_path = INSTALLED_HELPER_PATH
        self.core_path = core_path
        self.launchd_template = launchd_template
        self.artifact_dir = artifact_dir
        self.temp_root = temp_root
        self.lifecycle = lifecycle
        self.client_root = temp_root / "clients"
        self.probe_app = self.client_root / "ProtoProbe.app"
        self.probe_executable = self.probe_app / "Contents" / "MacOS" / "ClashFX"
        self.probe_core = self.probe_app / "Contents" / "Resources" / "mihomo_core"
        self.transaction_app = self.client_root / "TxDriver.app"
        self.transaction_executable = self.transaction_app / "Contents" / "MacOS" / "ClashFX"
        self.test_core = self.transaction_app / "Contents" / "Resources" / "mihomo_core"
        self.unapproved_app = self.client_root / "UnapprovedClone.app"
        self.unapproved_executable = self.unapproved_app / "Contents" / "MacOS" / "ClashFX"
        self.transaction_manifest = temp_root / "production-transaction-manifest.json"
        self.transaction_report_path = artifact_dir / "production-transaction.json"
        self.transaction_client_available = False
        self.runtime_config_source = ROOT / "scripts" / "hosted-runtime-config-acceptance.swift"
        self.runtime_config_executable = temp_root / "hosted-runtime-config-acceptance"
        self.runtime_config_manifest = temp_root / "hosted-runtime-config-manifest.json"
        self.runtime_config_artifact_dir = artifact_dir / "runtime-config-acceptance"
        self.runtime_config_stdout = artifact_dir / "runtime-config-acceptance.stdout.log"
        self.runtime_config_stderr = artifact_dir / "runtime-config-acceptance.stderr.log"
        self.launchd_plist = LAUNCH_DAEMON_PATH
        self.install_generator_source = temp_root / "legacy-install-generator.swift"
        self.install_generator = temp_root / "legacy-install-generator"
        self.install_fixture_path = temp_root / "legacy-install-fixture.json"
        self.production_install_script = temp_root / "legacy-install.production.sh"
        self.instrumented_install_script = temp_root / "legacy-install.acceptance.sh"
        self.metadata_stage_report = temp_root / "metadata-stage-report.json"
        self.decorated_metadata = {}
        self.installed_paths_created = {}
        self.temporary_trust_paths_created = {}
        self.unexpected_install_leftovers = []
        self.trust_parent_existed_before_install = APPROVED_CORE_PATH.parent.exists()
        self.generated_install_script_sha256 = None
        self.instrumented_install_script_sha256 = None
        self.expected_embedded_helper_sha256 = None
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
        self.owned_core_source_path = None
        self.core_start_attempted = False
        self.harness_config_paths = set()
        self.core_home_by_config = {}
        self.core_log_path = None
        self.core_log_paths = []
        self.current_core_utuns = []
        self.created_utuns = []
        self.approved_client_cdhashes = {}
        self.trust_directory_created = None
        self.unapproved_client_cdhash = None
        self.exit_code = 0
        self.report = {
            "schemaVersion": 1,
            "status": "running",
            "scope": "real production Helper XPC + Helper-managed Mihomo TUN acceptance on a disposable GitHub-hosted macOS runner",
            "coverage": {
                "productionLegacyHelperInstallation": False,
                "metadataDecoratedAppInstallation": False,
                "productionHelperXPC": False,
                "adHocSignedClientBundleIdentity": False,
                "approvedClientCoreTrust": False,
                "unapprovedSameBundleIDRejected": False,
                "rootImmutableCoreExecuted": False,
                "helperManagedCore": False,
                "rapidHelperCoreLifecycle": False,
                "invalidConfigPathFailure": False,
                "productionInvalidConfigRuntimeFailure": False,
                "tunInterfaceAndRoutes": False,
                "controllerProxyAndDNSOwnership": False,
                "systemProxyCaptureAndEnable": False,
                "systemProxyExactRestore": False,
                "systemDNSOverride": False,
                "systemDNSExactRestore": False,
                "systemDNSResolverThroughTUN": False,
                "productionTransactionDNSOverrideRestore": False,
                "fullClashFXAppLaunched": False,
                "continuousRuntimeSwitches": False,
                "runtimeConfigRollback": False,
                "patchFailureRollback": False,
                "stableRuntimeEndpoints": False,
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
                "The production Legacy getInstallScript body is generated from the production Swift extension and run directly as root on the disposable hosted guest; SMAuthorization and the AppleScript authorization dialog are not exercised.",
                "The production installer receipt is verified with ProtoProbe first. TxDriver approval is added afterward by the controlled root acceptance fixture and is not attributed to the production installer.",
                "FinderInfo and ResourceFork are injected into the probe app and core resource. An acceptance-only read assertion confirms the staged copy strips those two attributes while retaining an unrelated xattr; the source bundle metadata remains intact.",
                "The actual installer-created launchd job starts the Helper. Its stdout and stderr are not redirected by the production launchd plist.",
                "When the companion source is present and its checks pass, the production SystemProxyManager.swift and ClaudeProxyLockTransaction.swift sources run in the separate TxDriver.app client against the real Helper XPC service.",
                "The standalone hosted runtime-config client exercises the production RuntimeConfigTransactionController and bounded DNS probe against the already-running Helper-managed TUN core; it does not launch the ClashFX GUI.",
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
        launch_services = self.probe_app / "Contents" / "Library" / "LaunchServices"
        launch_services.mkdir(parents=True, mode=0o755)
        source = ROOT / "scripts" / "helper-tun-acceptance-client.m"
        compile_output = require_command_success([
            "/usr/bin/clang", "-fmodules", "-fobjc-arc", "-O2", "-I", str(ROOT / "ProxyConfigHelper"),
            str(source), "-framework", "Foundation", "-o", str(self.probe_executable),
        ], 90)
        del compile_output
        bundled_helper = launch_services / SERVICE_LABEL
        shutil.copy2(self.helper_source_path, bundled_helper)
        bundled_helper.chmod(0o755)
        for client_core in (self.probe_core, self.test_core):
            shutil.copy2(self.core_path, client_core)
            client_core.chmod(0o755)
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
        self.approved_client_cdhashes[str(self.probe_app)] = self._sign_and_verify_client(self.probe_app)
        self._verify_signed_probe_helper(bundled_helper)
        self.report["build"]["probeClientPath"] = str(self.probe_executable)
        self.report["build"]["probeClientCorePath"] = str(self.probe_core)
        self.report["build"]["probeBundledHelperPath"] = str(bundled_helper)
        self.report["build"]["transactionClientBundlePath"] = str(self.transaction_app)
        self.report["build"]["transactionClientPath"] = str(self.transaction_executable)

    def _verify_signed_probe_helper(self, bundled_helper):
        source_sha256 = self.report["build"]["helperSHA256"]
        embedded_sha256 = file_sha256(bundled_helper)
        require_command_success(["/usr/bin/codesign", "--verify", "--strict", str(bundled_helper)], 15)
        details = command_result(["/usr/bin/codesign", "-dv", "--verbose=4", str(bundled_helper)], 15)
        signed_text = details.stdout + details.stderr
        identifier = re.search(r"^Identifier=(.+)$", signed_text, re.MULTILINE)
        valid = (details.returncode == 0 and identifier is not None and
                 identifier.group(1).strip() == HELPER_BUNDLE_ID)
        self.assertion("signed probe retains a valid embedded production Helper identity", valid,
                       {"helperPath": str(bundled_helper), "bundleIdentifier":
                        identifier.group(1).strip() if identifier else None,
                        "sourceHelperSHA256": source_sha256,
                        "embeddedHelperSHA256AfterProbeSigning": embedded_sha256,
                        "helperBytesChangedDuringProbeSigning": source_sha256 != embedded_sha256})
        self.expected_embedded_helper_sha256 = embedded_sha256
        self.report["build"]["embeddedHelperSHA256"] = embedded_sha256

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
        cdhash = re.search(r"^CDHash=(.+)$", signed_text, re.MULTILINE)
        cdhash_value = cdhash.group(1).strip().lower() if cdhash else None
        valid = (executable.is_file() and details.returncode == 0 and identifier is not None and
                 identifier.group(1).strip() == CLIENT_BUNDLE_ID and cdhash is not None and
                 re.fullmatch(r"[0-9a-f]{40}", cdhash_value or "") is not None)
        self.assertion(f"{app.stem} has required executable path and ad-hoc identity", valid,
                       {"bundlePath": str(app), "executablePath": str(executable),
                        "bundleIdentifier": identifier.group(1).strip() if identifier else None,
                        "clientCDHash": cdhash_value})
        return cdhash_value if valid else None

    def compile_transaction_client(self):
        source = ROOT / "scripts" / "helper-tun-production-transaction.swift"
        if not source.is_file():
            raise RuntimeError(f"required production transaction client is not present: {source}")
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
        self.approved_client_cdhashes[str(self.transaction_app)] = self._sign_and_verify_client(
            self.transaction_app)
        self.transaction_client_available = True
        self.report["coverage"]["adHocSignedClientBundleIdentity"] = True

    def compile_runtime_config_acceptance(self):
        sources = [
            self.runtime_config_source,
            ROOT / "ClashFX" / "General" / "Utils" / "RuntimeConfigTransactionController.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "RuntimeConfigReadbackPolicy.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "RuntimeConfigValidationRunner.swift",
            ROOT / "ClashFX" / "General" / "Managers" / "TunDNSTransactionController.swift",
            ROOT / "ClashFX" / "General" / "Managers" / "StartupProxyRecoveryPolicy.swift",
            ROOT / "ClashFX" / "General" / "Utils" / "ManagedOperationSettlement.swift",
        ]
        missing = [str(path) for path in sources if not path.is_file()]
        if missing:
            raise RuntimeError("hosted runtime acceptance build sources are missing: " + ", ".join(missing))
        require_command_success([
            "/usr/bin/swiftc", "-swift-version", "5", "-parse-as-library",
            *(str(path) for path in sources), "-framework", "Foundation",
            "-o", str(self.runtime_config_executable),
        ], 180)
        self.report["build"]["runtimeConfigAcceptanceSource"] = str(self.runtime_config_source.relative_to(ROOT))
        self.report["build"]["runtimeConfigAcceptancePath"] = str(self.runtime_config_executable)
        self.report["build"]["runtimeConfigAcceptanceSHA256"] = hashlib.sha256(
            self.runtime_config_executable.read_bytes()).hexdigest()

    def prepare_unapproved_client(self):
        shutil.copytree(self.probe_app, self.unapproved_app)
        marker = self.unapproved_app / "Contents" / "Resources" / "unapproved-client-marker"
        marker.write_text("same bundle identifier, unapproved code directory\n", encoding="utf-8")
        source = ROOT / "scripts" / "helper-tun-acceptance-client.m"
        require_command_success([
            "/usr/bin/clang", "-fmodules", "-fobjc-arc", "-O0", "-I",
            str(ROOT / "ProxyConfigHelper"), str(source), "-framework", "Foundation",
            "-o", str(self.unapproved_executable),
        ], 90)
        fake_cdhash = self._sign_and_verify_client(self.unapproved_app)
        approved_hashes = set(self.approved_client_cdhashes.values())
        self.assertion("same-bundle-ID clone has a distinct unapproved CDHash",
                       fake_cdhash not in approved_hashes,
                       {"bundleIdentifier": CLIENT_BUNDLE_ID,
                        "clientCDHash": fake_cdhash,
                        "approvedClientCDHashes": sorted(approved_hashes)})
        self.unapproved_client_cdhash = fake_cdhash

    def decorate_probe_app_metadata(self):
        decorations = {
            self.probe_app: {"com.apple.FinderInfo": FINDER_INFO_VALUE},
            self.probe_core: {
                "com.apple.FinderInfo": FINDER_INFO_VALUE,
                "com.apple.ResourceFork": RESOURCE_FORK_VALUE,
                UNRELATED_TEST_XATTR: UNRELATED_TEST_XATTR_VALUE,
            },
        }
        for path, attributes in decorations.items():
            if path.is_symlink() or not path.exists():
                raise RuntimeError(f"metadata test target is missing or is a symlink: {path}")
            existing = metadata_attribute_names(path)
            collisions = sorted(existing.intersection(attributes))
            if collisions:
                raise RuntimeError(f"refusing to overwrite preexisting test xattrs on {path}: {collisions}")
            for name, value in attributes.items():
                metadata_attribute_write(path, name, value)
            observed = {name: metadata_attribute_read(path, name)
                        for name in attributes}
            if observed != attributes:
                raise RuntimeError(f"metadata decorations did not round-trip on {path}")
            self.decorated_metadata[str(path)] = {name: value.hex()
                                                  for name, value in attributes.items()}

        details = command_result(["/usr/bin/codesign", "-dv", "--verbose=4", str(self.probe_app)], 15)
        signed_text = details.stdout + details.stderr
        cdhash = re.search(r"^CDHash=(.+)$", signed_text, re.MULTILINE)
        observed_cdhash = cdhash.group(1).strip().lower() if cdhash else None
        expected_cdhash = self.approved_client_cdhashes[str(self.probe_app)]
        self.assertion("display metadata decoration preserves the signed probe CDHash",
                       details.returncode == 0 and observed_cdhash == expected_cdhash,
                       {"expectedCDHash": expected_cdhash, "observedCDHash": observed_cdhash,
                        "decoratedPaths": self.decorated_metadata})

    def _production_install_constants(self):
        source = ROOT / "ClashFX" / "General" / "Managers" / "PrivilegedHelperManager.swift"
        source_text = source.read_text(encoding="utf-8")

        def string_constant(name):
            match = re.search(rf"^\s*static let {re.escape(name)}\s*=\s*\"([^\"]+)\"",
                              source_text, re.MULTILINE)
            if not match:
                raise RuntimeError(f"cannot extract production {name} constant from {source}")
            return match.group(1)

        constants = {
            "machServiceName": string_constant("machServiceName"),
            "approvedCorePath": string_constant("approvedCorePath"),
            "trustReceiptPath": string_constant("trustReceiptPath"),
        }
        if (constants["machServiceName"] != SERVICE_LABEL or
                Path(constants["approvedCorePath"]) != APPROVED_CORE_PATH or
                Path(constants["trustReceiptPath"]) != TRUST_RECEIPT_PATH):
            raise RuntimeError("production Helper trust constants no longer match the hosted acceptance paths")
        return constants

    def _generate_production_install_script(self):
        legacy_source = ROOT / "ClashFX" / "General" / "Managers" / "PrivilegedHelperManager+Legacy.swift"
        source_text = legacy_source.read_text(encoding="utf-8")
        method_start = source_text.find("    func getInstallScript(")
        method_end = source_text.find("    @discardableResult\n    func runScriptWithRootPermission(", method_start)
        if method_start < 0 or method_end <= method_start:
            raise RuntimeError(f"cannot extract production getInstallScript extension from {legacy_source}")
        production_methods = source_text[method_start:method_end]
        fixture = {
            **self._production_install_constants(),
            "appBundlePath": str(self.probe_app.resolve(strict=True)),
            "appExecutablePath": str(self.probe_executable.resolve(strict=True)),
            "clientCDHash": self.approved_client_cdhashes[str(self.probe_app)],
            "approvedSourcePath": str(self.probe_core.resolve(strict=True)),
            "coreSHA256": file_sha256(self.probe_core),
            "helperSHA256": self.expected_embedded_helper_sha256,
        }
        with self.install_fixture_path.open("w", encoding="utf-8") as stream:
            json.dump(fixture, stream, sort_keys=True)
            stream.write("\n")

        prelude = r'''import Foundation

private struct AcceptanceInstallFixture: Decodable {
    let machServiceName: String
    let approvedCorePath: String
    let trustReceiptPath: String
    let appBundlePath: String
    let appExecutablePath: String
    let clientCDHash: String
    let approvedSourcePath: String
    let coreSHA256: String
    let helperSHA256: String
}

private struct PrivilegedHelperTrustMaterial {
    let clientCDHash: String
    let approvedSourcePath: String
    let coreSHA256: String
    let helperSHA256: String
}

private enum AcceptanceInstallState {
    static var fixture: AcceptanceInstallFixture!
}

private struct AcceptanceBundleMainFacade {
    let bundlePath: String
    let executableURL: URL?
}

private enum AcceptanceBundleFacade {
    static var main: AcceptanceBundleMainFacade!
}

// The production extension refers to Bundle.main. This scoped alias supplies
// the signed probe bundle paths while the remaining Foundation APIs stay real.
private typealias Bundle = AcceptanceBundleFacade

private enum Logger {
    enum Level { case error }
    static func log(_ message: String, level: Level) {}
}

private final class PrivilegedHelperManager {
    static var machServiceName: String { AcceptanceInstallState.fixture.machServiceName }
    static var approvedCorePath: String { AcceptanceInstallState.fixture.approvedCorePath }
    static var trustReceiptPath: String { AcceptanceInstallState.fixture.trustReceiptPath }

    private let trustMaterial: PrivilegedHelperTrustMaterial

    init(trustMaterial: PrivilegedHelperTrustMaterial) {
        self.trustMaterial = trustMaterial
    }

    func cachedTrustMaterialForCurrentApp() -> PrivilegedHelperTrustMaterial? { nil }
    func trustMaterialForCurrentApp() -> PrivilegedHelperTrustMaterial? { trustMaterial }
}
'''
        suffix = r'''

@main
private struct LegacyInstallScriptGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "LegacyInstallScriptGenerator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "expected fixture JSON and output script paths"])
        }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(AcceptanceInstallFixture.self, from: fixtureData)
        AcceptanceInstallState.fixture = fixture
        AcceptanceBundleFacade.main = AcceptanceBundleMainFacade(
            bundlePath: fixture.appBundlePath,
            executableURL: URL(fileURLWithPath: fixture.appExecutablePath)
        )
        let trust = PrivilegedHelperTrustMaterial(
            clientCDHash: fixture.clientCDHash,
            approvedSourcePath: fixture.approvedSourcePath,
            coreSHA256: fixture.coreSHA256,
            helperSHA256: fixture.helperSHA256
        )
        let script = PrivilegedHelperManager(trustMaterial: trust).getInstallScript()
        guard script.hasPrefix("#!/bin/bash\nset -euo pipefail") else {
            throw NSError(domain: "LegacyInstallScriptGenerator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "production installer did not return a bash script"])
        }
        try script.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
    }
}
'''
        self.install_generator_source.write_text(
            prelude + "\nextension PrivilegedHelperManager {\n" + production_methods + "\n}\n" + suffix,
            encoding="utf-8")
        require_command_success([
            "/usr/bin/swiftc", "-swift-version", "5", "-parse-as-library",
            str(self.install_generator_source), "-framework", "Foundation",
            "-o", str(self.install_generator),
        ], 120)
        require_command_success([
            str(self.install_generator), str(self.install_fixture_path),
            str(self.production_install_script),
        ], 20)
        script = self.production_install_script.read_text(encoding="utf-8")
        if not script.startswith("#!/bin/bash\nset -euo pipefail"):
            raise RuntimeError("generated production installer script is missing its strict bash prologue")
        self.generated_install_script_sha256 = hashlib.sha256(script.encode()).hexdigest()

        observation = f'''# Acceptance-only read assertions after production metadata normalization.
for acceptancePath in "$stagedApp" "$stagedResources/mihomo_core"; do
    for acceptanceAttribute in com.apple.FinderInfo com.apple.ResourceFork; do
        if /usr/bin/xattr -p "$acceptanceAttribute" "$acceptancePath" >/dev/null 2>&1; then
            printf 'forbidden display metadata remains in staged app: %s %s\\n' "$acceptancePath" "$acceptanceAttribute" >&2
            exit 73
        fi
    done
done
acceptanceUnrelated=$(/usr/bin/xattr -p {shlex.quote(UNRELATED_TEST_XATTR)} "$stagedResources/mihomo_core")
[ "$acceptanceUnrelated" = {shlex.quote(UNRELATED_TEST_XATTR_VALUE.decode())} ] || exit 74
printf '%s\\n' '{{"forbiddenDisplayMetadataRemoved":true,"unrelatedXattrRetained":true}}' > {shlex.quote(str(self.metadata_stage_report))}
'''
        marker = "        # Check filesystem flag support while the existing service is still intact.\n"
        if script.count(marker) != 1:
            raise RuntimeError("production installer staging marker changed; cannot add metadata read assertion")
        instrumented = script.replace(marker, observation + marker, 1)
        self.instrumented_install_script.write_text(instrumented, encoding="utf-8")
        os.chmod(self.instrumented_install_script, 0o700)
        self.instrumented_install_script_sha256 = hashlib.sha256(instrumented.encode()).hexdigest()

    def _expected_approved_clients(self, bundle_paths):
        core_sha256 = file_sha256(self.core_path)
        entries = []
        for bundle_path in bundle_paths:
            bundle_path = Path(bundle_path)
            cdhash = self.approved_client_cdhashes.get(str(bundle_path))
            if not re.fullmatch(r"[0-9a-f]{40}", cdhash or ""):
                raise RuntimeError(f"approved client CDHash is not a lowercase 40-character digest: {cdhash}")
            source_path = bundle_path / "Contents" / "Resources" / "mihomo_core"
            entries.append({
                "BundleIdentifier": CLIENT_BUNDLE_ID,
                "ClientCDHash": cdhash,
                "ApprovedSourcePath": str(source_path.resolve(strict=True)),
                "CoreSHA256": core_sha256,
            })
        return entries

    def _expected_launchd_job(self):
        return {
            "Label": SERVICE_LABEL,
            "MachServices": {SERVICE_LABEL: True},
            "Program": str(self.helper_path),
            "ProgramArguments": [str(self.helper_path)],
        }

    def _track_install_file(self, path, expected_sha256):
        try:
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                    file_sha256(path) != expected_sha256):
                return False
            self.installed_paths_created[path] = {
                "identity": (info.st_dev, info.st_ino),
                "sha256": expected_sha256,
            }
            return True
        except OSError:
            return False

    def _matches_tracked_install_file(self, path, expected_sha256):
        tracked = self.installed_paths_created.get(path)
        if tracked is None or not os.path.lexists(path):
            return False
        try:
            info = path.lstat()
            return (stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
                    (info.st_dev, info.st_ino) == tracked["identity"] and
                    tracked["sha256"] == expected_sha256 and
                    file_sha256(path) == expected_sha256)
        except OSError:
            return False

    def _capture_fixture_install_outputs(self):
        self._track_install_file(self.helper_path, self.expected_embedded_helper_sha256)
        self._track_install_file(APPROVED_CORE_PATH, file_sha256(self.core_path))
        expected_production_receipt = {
            "SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
            "ApprovedClients": self._expected_approved_clients((self.probe_app,)),
        }
        try:
            if os.path.lexists(TRUST_RECEIPT_PATH):
                receipt = decode_install_plist(TRUST_RECEIPT_PATH)
                for bundles in ((self.probe_app,), (self.probe_app, self.transaction_app)):
                    expected = {"SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
                                "ApprovedClients": self._expected_approved_clients(bundles)}
                    if receipt == expected:
                        self._track_install_file(TRUST_RECEIPT_PATH, file_sha256(TRUST_RECEIPT_PATH))
                        break
        except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException):
            pass
        if os.path.lexists(APPROVED_CORE_PATH.parent):
            for path in APPROVED_CORE_PATH.parent.glob(TRUST_RECEIPT_PATH.name + ".tmp.*"):
                try:
                    info = path.lstat()
                    if (stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
                            decode_install_plist(path) == expected_production_receipt):
                        self.temporary_trust_paths_created[path] = {
                            "identity": (info.st_dev, info.st_ino),
                            "sha256": file_sha256(path),
                        }
                    else:
                        self.unexpected_install_leftovers.append({
                            "path": str(path),
                            "reason": "production receipt temporary has unexpected identity or contents",
                        })
                except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
                    self.unexpected_install_leftovers.append({"path": str(path), "reason": str(error)})
            for path in APPROVED_CORE_PATH.parent.glob(".clashfx-install.*"):
                self.unexpected_install_leftovers.append({
                    "path": str(path),
                    "reason": "production staging directory remained after installer exit; refusing unverified recursive removal",
                })
        try:
            if (os.path.lexists(self.launchd_plist) and
                    decode_install_plist(self.launchd_plist) == self._expected_launchd_job()):
                self._track_install_file(self.launchd_plist, file_sha256(self.launchd_plist))
        except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException):
            pass
        if not self.trust_parent_existed_before_install and os.path.lexists(APPROVED_CORE_PATH.parent):
            try:
                info = APPROVED_CORE_PATH.parent.lstat()
                if (stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and
                        not info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)):
                    self.trust_directory_created = (info.st_dev, info.st_ino)
            except OSError:
                pass
        service = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
        service_text = service.stdout + service.stderr
        self.bootstrapped = (service.returncode == 0 and str(self.launchd_plist) in service_text and
                             str(self.helper_path) in service_text)

    def _verify_production_install(self):
        core_sha256 = file_sha256(self.core_path)
        helper_sha256 = self.expected_embedded_helper_sha256
        expected_receipt = {
            "SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
            "ApprovedClients": self._expected_approved_clients((self.probe_app,)),
        }
        expected_job = self._expected_launchd_job()

        helper_info = self.helper_path.lstat()
        helper_hash = file_sha256(self.helper_path)
        details = command_result(["/usr/bin/codesign", "-dv", "--verbose=4", str(self.helper_path)], 15)
        signed_text = details.stdout + details.stderr
        identifier = re.search(r"^Identifier=(.+)$", signed_text, re.MULTILINE)
        helper_valid = (stat.S_ISREG(helper_info.st_mode) and helper_info.st_uid == 0 and
                        stat.S_IMODE(helper_info.st_mode) == 0o755 and helper_hash == helper_sha256 and
                        self._matches_tracked_install_file(self.helper_path, helper_sha256) and
                        details.returncode == 0 and identifier is not None and
                        identifier.group(1).strip() == HELPER_BUNDLE_ID)
        require_command_success(["/usr/bin/codesign", "--verify", "--strict", str(self.helper_path)], 15)

        core_info = APPROVED_CORE_PATH.lstat()
        core_hash = file_sha256(APPROVED_CORE_PATH)
        core_valid = (stat.S_ISREG(core_info.st_mode) and core_info.st_uid == 0 and
                      stat.S_IMODE(core_info.st_mode) == 0o555 and core_hash == core_sha256 and
                      self._matches_tracked_install_file(APPROVED_CORE_PATH, core_sha256) and
                      root_trust_file_is_safe(APPROVED_CORE_PATH, executable=True,
                                              expected_sha256=core_sha256))

        installed_receipt = decode_install_plist(TRUST_RECEIPT_PATH)
        receipt_hash = file_sha256(TRUST_RECEIPT_PATH)
        receipt_info = TRUST_RECEIPT_PATH.lstat()
        receipt_valid = (installed_receipt == expected_receipt and receipt_info.st_uid == 0 and
                         stat.S_IMODE(receipt_info.st_mode) == 0o444 and
                         self._matches_tracked_install_file(TRUST_RECEIPT_PATH, receipt_hash) and
                         root_trust_file_is_safe(TRUST_RECEIPT_PATH, executable=False,
                                                 expected_sha256=receipt_hash))

        launchd_job = decode_install_plist(self.launchd_plist)
        launchd_info = self.launchd_plist.lstat()
        launchd_hash = file_sha256(self.launchd_plist)
        launchd_valid = (launchd_job == expected_job and launchd_info.st_uid == 0 and
                         stat.S_IMODE(launchd_info.st_mode) == 0o644 and
                         self._matches_tracked_install_file(self.launchd_plist, launchd_hash))
        service = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
        service_text = service.stdout + service.stderr
        service_loaded = (service.returncode == 0 and str(self.launchd_plist) in service_text and
                          str(self.helper_path) in service_text)
        if service_loaded:
            self.bootstrapped = True

        self.assertion("production Legacy installer installed its exact helper, immutable core, probe-only receipt and launchd job",
                       helper_valid and core_valid and receipt_valid and launchd_valid and service_loaded,
                       {"helperPath": str(self.helper_path), "helperSHA256": helper_hash,
                        "expectedHelperSHA256": helper_sha256,
                        "helperIdentifier": identifier.group(1).strip() if identifier else None,
                        "corePath": str(APPROVED_CORE_PATH), "coreSHA256": core_hash,
                        "coreImmutableAndSafe": core_valid,
                        "receiptPath": str(TRUST_RECEIPT_PATH), "receiptSHA256": receipt_hash,
                        "productionReceipt": installed_receipt,
                        "launchDaemonPath": str(self.launchd_plist), "launchDaemon": launchd_job,
                        "launchDaemonLoaded": service_loaded})
        self.report["launchd"] = {
            "label": SERVICE_LABEL,
            "domain": "system",
            "plist": str(self.launchd_plist),
            "program": str(self.helper_path),
            "source": str((ROOT / "ProxyConfigHelper" / "Helper-Launchd.plist").relative_to(ROOT)),
            "productionMachServiceName": SERVICE_LABEL,
            "loadedBy": "production Legacy getInstallScript",
        }
        self.report["productionInstallerReceipt"] = {
            "schemaVersion": installed_receipt.get("SchemaVersion"),
            "approvedClients": installed_receipt.get("ApprovedClients"),
            "approvedClientCount": len(installed_receipt.get("ApprovedClients", [])),
            "receiptSHA256": receipt_hash,
            "verifiedBeforeAcceptanceFixtureAugmentation": True,
        }
        self.report["build"]["approvedCorePath"] = str(APPROVED_CORE_PATH)
        self.report["build"]["approvedCoreSHA256"] = core_sha256
        self.report["build"]["trustReceiptPath"] = str(TRUST_RECEIPT_PATH)

    def install_with_production_legacy_script(self):
        if not self.transaction_client_available or len(self.approved_client_cdhashes) != 2:
            raise RuntimeError("ProtoProbe and TxDriver must both be built and signed before hosted installation")
        core_sha256 = file_sha256(self.core_path)
        self.assertion("both client bundles contain the exact executable production core resource",
                       all(path.is_file() and os.access(path, os.X_OK) and
                           file_sha256(path) == core_sha256
                           for path in (self.probe_core, self.test_core)),
                       {"coreSHA256": core_sha256,
                        "clientCorePaths": [str(self.probe_core), str(self.test_core)]})
        existing = [path for path in (self.launchd_plist, self.helper_path,
                                      APPROVED_CORE_PATH, TRUST_RECEIPT_PATH)
                    if os.path.lexists(path)]
        if os.path.lexists(APPROVED_CORE_PATH.parent):
            existing.extend(APPROVED_CORE_PATH.parent.glob(TRUST_RECEIPT_PATH.name + ".tmp.*"))
            existing.extend(APPROVED_CORE_PATH.parent.glob(".clashfx-install.*"))
        if existing:
            raise RuntimeError("refusing to replace paths that appeared after the clean-guest gate: " +
                               ", ".join(map(str, existing)))
        if (not self.trust_parent_existed_before_install and
                os.path.lexists(APPROVED_CORE_PATH.parent)):
            raise RuntimeError("trusted-core directory appeared after the clean-guest gate")
        if self.decorated_metadata.get(str(self.probe_app)) is None:
            raise RuntimeError("probe metadata decoration must precede production installer generation")

        self._generate_production_install_script()
        self.bootstrap_attempted = True
        try:
            completed = subprocess.run(["/bin/bash", str(self.instrumented_install_script)],
                                       check=False, capture_output=True, text=True, timeout=180)
        except subprocess.TimeoutExpired as error:
            self._capture_fixture_install_outputs()
            raise RuntimeError("production Legacy installer exceeded its 180 second deadline") from error
        self._capture_fixture_install_outputs()
        if completed.returncode == 0:
            # The clean-guest gate proved this label unused immediately before
            # invoking the installer, so a successful final launchctl load is ours.
            self.bootstrapped = True
        if completed.returncode != 0:
            raise RuntimeError("production Legacy installer failed: " +
                               (completed.stderr or completed.stdout)[-4000:])

        expected_stage_report = {
            "forbiddenDisplayMetadataRemoved": True,
            "unrelatedXattrRetained": True,
        }
        with self.metadata_stage_report.open("r", encoding="utf-8") as stream:
            stage_report = json.load(stream)
        source_metadata_unchanged = True
        for raw_path, attributes in self.decorated_metadata.items():
            path = Path(raw_path)
            for name, expected_hex in attributes.items():
                try:
                    source_metadata_unchanged = (source_metadata_unchanged and
                        metadata_attribute_read(path, name).hex() == expected_hex)
                except OSError:
                    source_metadata_unchanged = False
        self.assertion("production staging strips only FinderInfo and ResourceFork from its private app copy",
                       stage_report == expected_stage_report and source_metadata_unchanged,
                       {"stagedCopy": stage_report,
                        "sourceMetadataUnchanged": source_metadata_unchanged,
                        "sourceXattrs": self.decorated_metadata})
        self._verify_production_install()
        self.report["productionLegacyInstaller"] = {
            "swiftSource": "ClashFX/General/Managers/PrivilegedHelperManager+Legacy.swift",
            "generatorFacade": "Bundle.main paths point at the signed ProtoProbe.app; trust material comes from fixture JSON",
            "generatedScriptSHA256": self.generated_install_script_sha256,
            "executionScriptSHA256": self.instrumented_install_script_sha256,
            "executionScriptInstrumentation": "read-only staged-xattr assertions before production codesign verification",
            "exitCode": completed.returncode,
            "stdoutTail": completed.stdout[-2000:],
            "stderrTail": completed.stderr[-2000:],
            "metadataStageReport": stage_report,
            "installedHelperPath": str(self.helper_path),
            "installedLaunchDaemonPath": str(self.launchd_plist),
        }

    def augment_installed_receipt_for_transaction_client(self):
        if not self.transaction_client_available or str(self.transaction_app) not in self.approved_client_cdhashes:
            raise RuntimeError("signed TxDriver is required for the controlled receipt fixture")
        if not self._matches_tracked_install_file(self.helper_path, self.expected_embedded_helper_sha256):
            raise RuntimeError("installed production Helper identity or expected hash changed before fixture receipt augmentation")
        if not self._matches_tracked_install_file(APPROVED_CORE_PATH,
                                                  self.report["build"]["approvedCoreSHA256"]):
            raise RuntimeError("installed production core identity or expected hash changed before fixture receipt augmentation")
        if not root_trust_file_is_safe(APPROVED_CORE_PATH, executable=True,
                                       expected_sha256=self.report["build"]["approvedCoreSHA256"]):
            raise RuntimeError("production-installed core is no longer immutable and trusted")
        with TRUST_RECEIPT_PATH.open("rb") as stream:
            original_receipt_bytes = stream.read()
        original_receipt = plistlib.loads(original_receipt_bytes)
        expected_original = {"SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
                             "ApprovedClients": self._expected_approved_clients((self.probe_app,))}
        original_hash = hashlib.sha256(original_receipt_bytes).hexdigest()
        self.assertion("production installer receipt approves exactly ProtoProbe before test-fixture augmentation",
                       original_receipt == expected_original and
                       root_trust_file_is_safe(TRUST_RECEIPT_PATH, executable=False,
                                               expected_sha256=original_hash),
                       {"receipt": original_receipt,
                        "expectedApprovedSourcePath": str(self.probe_core.resolve()),
                        "receiptSHA256": original_hash})
        if not self._matches_tracked_install_file(TRUST_RECEIPT_PATH, original_hash):
            raise RuntimeError("production receipt identity or expected hash changed before fixture augmentation")

        entries = self._expected_approved_clients((self.probe_app, self.transaction_app))
        receipt_bytes = plistlib.dumps({"SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
                                        "ApprovedClients": entries},
                                       fmt=plistlib.FMT_XML, sort_keys=True)
        receipt_sha256 = hashlib.sha256(receipt_bytes).hexdigest()
        temporary = TRUST_RECEIPT_PATH.parent / f".clashfx-acceptance-trust-{secrets.token_hex(8)}.tmp"
        temp_identity = None
        try:
            with temporary.open("xb") as stream:
                info = os.fstat(stream.fileno())
                temp_identity = (info.st_dev, info.st_ino)
                self.temporary_trust_paths_created[temporary] = {
                    "identity": temp_identity, "sha256": receipt_sha256,
                }
                stream.write(receipt_bytes)
                stream.flush()
                os.fsync(stream.fileno())
            os.chown(temporary, 0, 0)
            os.chmod(temporary, 0o444)
            tracked_receipt = self.installed_paths_created.get(TRUST_RECEIPT_PATH)
            if (tracked_receipt is None or tracked_receipt["identity"] != file_identity(TRUST_RECEIPT_PATH) or
                    tracked_receipt["sha256"] != file_sha256(TRUST_RECEIPT_PATH)):
                raise RuntimeError("trust receipt identity or expected hash changed before augmentation")
            require_command_success(["/usr/bin/chflags", "nouchg", str(TRUST_RECEIPT_PATH)], 8)
            os.replace(temporary, TRUST_RECEIPT_PATH)
            self.temporary_trust_paths_created.pop(temporary, None)
            if not self._track_install_file(TRUST_RECEIPT_PATH, receipt_sha256):
                raise RuntimeError("augmented trust receipt failed its expected hash or root ownership check")
            require_command_success(["/usr/bin/chflags", "uchg", str(TRUST_RECEIPT_PATH)], 8)
        finally:
            if os.path.lexists(temporary) and temp_identity is not None:
                info = temporary.lstat()
                if (stat.S_ISREG(info.st_mode) and info.st_uid == 0 and
                        (info.st_dev, info.st_ino) == temp_identity and
                        file_sha256(temporary) == receipt_sha256):
                    temporary.unlink()
                    self.temporary_trust_paths_created.pop(temporary, None)

        expected_augmented = {"SchemaVersion": TRUST_RECEIPT_SCHEMA_VERSION,
                              "ApprovedClients": entries}
        self.assertion("controlled root fixture adds TxDriver approval without replacing the installed helper or core",
                       decode_install_plist(TRUST_RECEIPT_PATH) == expected_augmented and
                       root_trust_file_is_safe(TRUST_RECEIPT_PATH, executable=False,
                                               expected_sha256=receipt_sha256) and
                       file_sha256(self.helper_path) == self.expected_embedded_helper_sha256 and
                       file_sha256(APPROVED_CORE_PATH) == self.report["build"]["approvedCoreSHA256"],
                       {"fixtureApprovedClients": entries,
                        "helperSHA256": file_sha256(self.helper_path),
                        "coreSHA256": file_sha256(APPROVED_CORE_PATH),
                        "receiptSHA256": receipt_sha256})
        self.report["testFixtureTrustAugmentation"] = {
            "performedBy": "hosted acceptance harness after production install and ProtoProbe XPC roundtrip",
            "productionInstallerApprovedClientCount": 1,
            "addedClientBundlePath": str(self.transaction_app),
            "addedClientCDHash": self.approved_client_cdhashes[str(self.transaction_app)],
            "doesNotClaimProductionInstallerApprovedTxDriver": True,
        }
        self.report["coverage"]["approvedClientCoreTrust"] = True
        self.report["build"]["approvedClients"] = entries

    def _status_uses_approved_core_source(self, status, expected_source=None):
        known_sources = {str(self.probe_core), str(self.test_core)}
        if expected_source is None:
            valid_sources = known_sources
        else:
            expected_source = str(expected_source)
            if expected_source not in known_sources:
                return False
            valid_sources = {expected_source}

        binary_path = status.get("binaryPath")
        source_path = status.get("sourceBinaryPath")
        if binary_path not in {str(APPROVED_CORE_PATH), *valid_sources}:
            return False
        if source_path is not None and source_path not in valid_sources:
            return False
        if binary_path in known_sources and source_path is not None and binary_path != source_path:
            return False
        return True

    def assert_running_core_executable(self, status, assertion_name):
        pid = status.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            self.assertion(assertion_name, False, {"status": status, "reason": "missing positive PID"})
        paths = process_text_paths(pid)
        root_core_is_safe = root_trust_file_is_safe(
            APPROVED_CORE_PATH, executable=True,
            expected_sha256=self.report["build"]["approvedCoreSHA256"])
        self.assertion(assertion_name, str(APPROVED_CORE_PATH) in paths and root_core_is_safe,
                       {"pid": pid, "actualExecutablePaths": paths,
                        "requiredRootExecutablePath": str(APPROVED_CORE_PATH),
                        "rootCoreImmutableAndTrusted": root_core_is_safe,
                        "statusBinaryPath": status.get("binaryPath"),
                        "statusSourceBinaryPath": status.get("sourceBinaryPath")})
        self.report["coverage"]["rootImmutableCoreExecuted"] = True

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
                            status.get("launchID") != launch_id or
                            not self._status_uses_approved_core_source(
                                status, self.owned_core_source_path)):
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

    @staticmethod
    def _pid_exists(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @staticmethod
    def _port_can_be_rebound(port, protocol):
        kind = socket.SOCK_STREAM if protocol == "TCP" else socket.SOCK_DGRAM
        with socket.socket(socket.AF_INET, kind) as probe:
            try:
                if kind == socket.SOCK_STREAM:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", port))
                if kind == socket.SOCK_STREAM:
                    probe.listen(1)
                return True
            except OSError:
                return False

    def wait_for_stopped_core_resources(self, pid, utuns, ports, timeout=PORT_RELEASE_TIMEOUT):
        deadline = time.monotonic() + timeout
        last = {}
        while time.monotonic() < deadline:
            process_gone = not self._pid_exists(pid)
            rebound = {name: self._port_can_be_rebound(port, protocol)
                       for name, protocol, port in ports}
            try:
                interfaces = self.lifecycle.utun_interfaces()
                remaining_routes = self.lifecycle.routes_via_utun(utuns)
                targets = {address: self.lifecycle.route_lookup(address)
                           for address, _category in self.lifecycle.ROUTE_TARGETS}
                routes_to_old_tun = {
                    address: route for address, route in targets.items()
                    if route.get("interface") in utuns
                }
                interfaces_gone = not set(utuns).intersection(interfaces)
                routes_gone = not remaining_routes and not routes_to_old_tun
                last = {
                    "pid": pid,
                    "processGone": process_gone,
                    "portsRebound": rebound,
                    "utunInterfaces": interfaces,
                    "ownedUtuns": utuns,
                    "ownedUtunsGone": interfaces_gone,
                    "routesViaOwnedUtuns": remaining_routes,
                    "routeTargets": targets,
                    "routeTargetsViaOwnedUtuns": routes_to_old_tun,
                    "ownedTunRoutesGone": routes_gone,
                }
                if process_gone and all(rebound.values()) and interfaces_gone and routes_gone:
                    return last
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                last = {**last, "pid": pid, "processGone": process_gone,
                        "portsRebound": rebound, "observationError": str(error)}
            time.sleep(0.25)
        return last

    def run_helper_core_restart_cycles(self, endpoint, token, config_path, core_home,
                                       baseline_utuns, controller_port, dns_port, mixed_port):
        ports = (
            ("controllerTCP", "TCP", controller_port),
            ("proxyTCP", "TCP", mixed_port),
            ("proxyUDP", "UDP", mixed_port),
            ("dnsTCP", "TCP", dns_port),
            ("dnsUDP", "UDP", dns_port),
        )
        cycles = []
        self.current_core_utuns = list(self.report["core"].get("newUtunInterfaces", []))
        for index in range(1, HELPER_RESTART_CYCLES + 1):
            old_launch_id = self.owned_launch_id
            old_pid = self.owned_core_pid
            old_utuns = list(self.current_core_utuns)
            before = self.rpc("coreStatus")
            self.assertion(
                f"Helper restart cycle {index} begins with the currently owned core",
                before.get("running") is True and before.get("launchID") == old_launch_id and
                before.get("pid") == old_pid and
                self._status_uses_approved_core_source(before, self.probe_core) and
                before.get("configPath") == str(config_path),
                {"launchID": old_launch_id, "pid": old_pid, "status": before},
            )

            self.rpc("stopCore")
            stopped = self.wait_for_core_exit(old_launch_id)
            self.assertion(
                f"Helper stop cycle {index} terminates the same launch",
                stopped.get("running") is False and stopped.get("launchID") == old_launch_id,
                {"launchID": old_launch_id, "pid": old_pid,
                 "lastTermination": stopped.get("lastTermination")},
            )
            released = self.wait_for_stopped_core_resources(old_pid, old_utuns, ports)
            self.assertion(
                f"Helper stop cycle {index} ends the old core process",
                released.get("processGone") is True,
                released,
            )
            self.assertion(
                f"Helper stop cycle {index} releases API, proxy and DNS ports",
                bool(released.get("portsRebound")) and all(released["portsRebound"].values()),
                released.get("portsRebound"),
            )
            self.assertion(
                f"Helper stop cycle {index} removes the old TUN interface and routes",
                released.get("ownedUtunsGone") is True and released.get("ownedTunRoutesGone") is True,
                {"ownedUtuns": old_utuns, "interfaces": released.get("utunInterfaces"),
                 "routesViaOwnedUtuns": released.get("routesViaOwnedUtuns"),
                 "routeTargetsViaOwnedUtuns": released.get("routeTargetsViaOwnedUtuns")},
            )

            before_start_utuns = self.lifecycle.utun_interfaces()
            self.core_start_attempted = True
            self.owned_core_source_path = str(self.probe_core)
            self.harness_config_paths.add(str(config_path))
            self.core_home_by_config[str(config_path)] = str(core_home)
            start_result = self.rpc(
                "startCore", binaryPath=str(self.probe_core),
                configPath=str(config_path), homeDir=str(core_home),
            )
            self.assertion(f"Helper accepted restart cycle {index}", start_result is None,
                           {"configPath": str(config_path), "homeDir": str(core_home)})
            status = self.rpc("coreStatus")
            new_launch_id = status.get("launchID")
            new_pid = status.get("pid")
            self.owned_launch_id = new_launch_id
            self.owned_core_pid = new_pid
            self.owned_core_source_path = str(self.probe_core)
            self.core_log_path = status.get("logPath")
            if self.core_log_path and self.core_log_path not in self.core_log_paths:
                self.core_log_paths.append(self.core_log_path)
            identity_ok = (
                status.get("running") is True and isinstance(new_launch_id, str) and bool(new_launch_id) and
                isinstance(new_pid, int) and new_pid > 0 and
                new_launch_id != old_launch_id and new_pid != old_pid
            )
            self.assertion(
                f"Helper restart cycle {index} creates a new launch ID and PID",
                identity_ok,
                {"previousLaunchID": old_launch_id, "previousPID": old_pid,
                 "status": status},
            )
            self.assertion(
                f"Helper restart cycle {index} reuses the isolated core and config",
                self._status_uses_approved_core_source(status, self.probe_core) and
                status.get("configPath") == str(config_path),
                {"configPath": status.get("configPath"), "expectedConfigPath": str(config_path),
                 "homeDir": str(core_home), "sourceBinaryPath": status.get("sourceBinaryPath"),
                 "logPath": self.core_log_path},
            )
            self.assert_running_core_executable(
                status, f"Helper restart cycle {index} executes the immutable approved core")
            uid = require_command_success(["/bin/ps", "-o", "uid=", "-p", str(new_pid)], 5).strip()
            self.assertion(f"Helper restart cycle {index} core remains root-owned in the guest",
                           uid == "0", {"pid": new_pid, "uid": uid})

            (version, api_config, new_utuns, active_tuns, tun_routes,
             route_observations, selected_route) = self.wait_for_tun_ready(
                endpoint, token, before_start_utuns, new_launch_id, new_pid)
            self.current_core_utuns = list(new_utuns)
            cycle = {
                "cycle": index,
                "stopped": {"launchID": old_launch_id, "pid": old_pid,
                            "resources": released},
                "started": {"launchID": new_launch_id, "pid": new_pid,
                            "configPath": str(config_path), "homeDir": str(core_home),
                            "logPath": self.core_log_path, "version": version,
                            "apiTun": api_config.get("tun"), "utunInterfaces": new_utuns,
                            "activeUtunInterfaces": active_tuns, "routesViaUtun": tun_routes,
                            "routeTargetQueries": route_observations,
                            "selectedRouteTarget": selected_route},
            }
            cycles.append(cycle)
            self.report["helperCoreRestartCycles"] = cycles
            self.report["core"].update({
                "pid": new_pid, "launchID": new_launch_id, "active": True,
                "configPath": str(config_path), "homeDir": str(core_home),
                "logPath": self.core_log_path, "version": version,
                "apiTun": api_config.get("tun"), "newUtunInterfaces": new_utuns,
                "activeUtunInterfaces": active_tuns, "routesViaNewUtun": tun_routes,
                "routeTargetQueries": route_observations,
                "selectedRouteTarget": selected_route,
            })
            self.assertion(
                f"Helper restart cycle {index} restores TUN, API and auto-route readiness",
                bool(active_tuns and tun_routes and selected_route["route"]["interface"] in new_utuns) and
                api_config.get("tun", {}).get("enable") is True,
                cycle["started"],
            )
            owned_ports = []
            for name, protocol, port in ports:
                owns = self.lifecycle.process_owns_socket(
                    new_pid, protocol, port, listening=(protocol == "TCP"))
                self.assertion(f"Helper restart cycle {index} core owns {name}", owns,
                               {"pid": new_pid, "protocol": protocol, "port": port})
                if owns:
                    owned_ports.append(name)
            cycle["started"]["ownedPorts"] = owned_ports
            self.report["core"]["ownedPorts"] = owned_ports
            self.report["core"]["allCreatedUtunInterfaces"] = list(self.created_utuns)

        self.report["coverage"]["rapidHelperCoreLifecycle"] = (
            len(cycles) == HELPER_RESTART_CYCLES and
            all(item.get("started", {}).get("pid") for item in cycles)
        )
        self.assertion("three real Helper stop/start cycles pass with the final core running",
                       self.report["coverage"]["rapidHelperCoreLifecycle"] is True,
                       {"cycles": len(cycles), "finalLaunchID": self.owned_launch_id,
                        "finalPID": self.owned_core_pid, "running": True})

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

    @staticmethod
    def _redact_secret(value, secret):
        if isinstance(value, str):
            return value.replace(secret, "<redacted>") if secret else value
        if isinstance(value, list):
            return [AcceptanceHarness._redact_secret(item, secret) for item in value]
        if isinstance(value, dict):
            return {key: AcceptanceHarness._redact_secret(item, secret)
                    for key, item in value.items()}
        return value

    @staticmethod
    def _completed_output(value):
        if value is None:
            return ""
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return str(value)

    def invoke_runtime_config_acceptance(self, endpoint, token, config_path, core_home):
        coverage_keys = (
            "continuousRuntimeSwitches",
            "runtimeConfigRollback",
            "patchFailureRollback",
            "stableRuntimeEndpoints",
        )
        for key in coverage_keys:
            self.report["coverage"][key] = False
        if self.runtime_config_artifact_dir.exists():
            raise RuntimeError("runtime-config acceptance artifact directory already exists")

        manifest = {
            "controllerURL": str(endpoint),
            "secret": str(token),
            "coreBinary": str(self.core_path),
            "configPath": str(config_path),
            "homeDir": str(core_home),
            "artifactDirectory": str(self.runtime_config_artifact_dir),
        }
        self.runtime_config_manifest.write_text(json.dumps(manifest, sort_keys=True), encoding="utf-8")
        self.runtime_config_manifest.chmod(0o600)
        safe_manifest = {**manifest, "secret": "<redacted>"}
        started = time.monotonic()
        try:
            completed = subprocess.run(
                [str(self.runtime_config_executable), "--manifest", str(self.runtime_config_manifest)],
                cwd=str(self.temp_root), check=False, capture_output=True, text=True,
                timeout=RUNTIME_CONFIG_ACCEPTANCE_TIMEOUT,
            )
        except subprocess.TimeoutExpired as error:
            stdout = self._completed_output(error.stdout).replace(token, "<redacted>")
            stderr = self._completed_output(error.stderr).replace(token, "<redacted>")
            self.runtime_config_stdout.write_text(stdout, encoding="utf-8")
            self.runtime_config_stderr.write_text(stderr, encoding="utf-8")
            self.runtime_config_stdout.chmod(0o644)
            self.runtime_config_stderr.chmod(0o644)
            if self.runtime_config_artifact_dir.is_dir():
                self.runtime_config_artifact_dir.chmod(0o755)
                report_path = self.runtime_config_artifact_dir / "report.json"
                if report_path.is_file():
                    report_path.chmod(0o644)
            self.report["runtimeConfigAcceptance"] = {
                "exitCode": None, "timedOut": True,
                "elapsedSeconds": round(time.monotonic() - started, 3),
                "manifest": safe_manifest,
                "reportPath": str(self.runtime_config_artifact_dir / "report.json"),
            }
            self.report["rawEvidence"] = sorted(set(self.report.get("rawEvidence", [])) | {
                self.runtime_config_stdout.name, self.runtime_config_stderr.name,
                "runtime-config-acceptance/report.json",
            })
            self.assertion("standalone production runtime-config acceptance finishes before its deadline",
                           False, self.report["runtimeConfigAcceptance"])
            return

        stdout = completed.stdout.replace(token, "<redacted>") if token else completed.stdout
        stderr = completed.stderr.replace(token, "<redacted>") if token else completed.stderr
        self.runtime_config_stdout.write_text(stdout, encoding="utf-8")
        self.runtime_config_stderr.write_text(stderr, encoding="utf-8")
        self.runtime_config_stdout.chmod(0o644)
        self.runtime_config_stderr.chmod(0o644)

        report_path = self.runtime_config_artifact_dir / "report.json"
        if self.runtime_config_artifact_dir.is_dir():
            self.runtime_config_artifact_dir.chmod(0o755)
        runtime_report = None
        report_error = None
        if report_path.is_file():
            try:
                with report_path.open("r", encoding="utf-8") as stream:
                    runtime_report = json.load(stream)
                runtime_report = self._redact_secret(runtime_report, token)
                with report_path.open("w", encoding="utf-8") as stream:
                    json.dump(runtime_report, stream, indent=2, sort_keys=True)
                    stream.write("\n")
                report_path.chmod(0o644)
            except (OSError, json.JSONDecodeError, TypeError) as error:
                report_error = type(error).__name__
        else:
            report_error = "report.json missing"

        observed = {}
        if isinstance(runtime_report, dict) and isinstance(runtime_report.get("coverage"), dict):
            raw_coverage = runtime_report["coverage"]
            observed = {key: raw_coverage.get(key) is True for key in coverage_keys}
            self.report["coverage"].update(observed)
        status = runtime_report.get("status") if isinstance(runtime_report, dict) else None
        passed = (completed.returncode == 0 and status == "passed" and
                  len(observed) == len(coverage_keys) and all(observed.values()))
        summary = {
            "status": status,
            "exitCode": completed.returncode,
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "coverage": observed,
            "assertionCount": len(runtime_report.get("assertions", []))
                if isinstance(runtime_report, dict) and isinstance(runtime_report.get("assertions"), list) else 0,
            "reportPath": str(report_path),
            "stdoutPath": str(self.runtime_config_stdout),
            "stderrPath": str(self.runtime_config_stderr),
            "manifest": safe_manifest,
        }
        if report_error:
            summary["reportError"] = report_error
        self.report["runtimeConfigAcceptance"] = summary
        self.report["rawEvidence"] = sorted(set(self.report.get("rawEvidence", [])) | {
            self.runtime_config_stdout.name, self.runtime_config_stderr.name,
            "runtime-config-acceptance/report.json",
        })
        self.assertion(
            "standalone production runtime-config acceptance passes every required backend contract",
            passed,
            summary,
        )

    def invoke_transaction_client(self, endpoint, token, config_path, alternate_path,
                                  invalid_path, core_home, proxy_port, socks_port, dns_port):
        manifest = {
            "controllerURL": endpoint,
            "secret": token,
            # This manifest is consumed by TxDriver, so its source must be the
            # core sealed into TxDriver.app rather than ProtoProbe.app.
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
        self.owned_core_source_path = str(self.test_core)
        self.core_log_path = current_status.get("logPath") or self.core_log_path
        if self.core_log_path:
            self.core_log_paths.append(self.core_log_path)
        self.report["core"]["binaryPath"] = current_status.get("binaryPath")
        self.report["core"]["sourceBinaryPath"] = current_status.get("sourceBinaryPath")
        self.assertion("production transaction restored the known-good Helper-managed runtime",
                       current_status.get("running") is True and
                       self._status_uses_approved_core_source(current_status, self.test_core) and
                       current_status.get("configPath") == str(config_path) and
                       isinstance(self.owned_launch_id, str) and self.owned_launch_id,
                       {"status": current_status,
                        "expectedRootBinaryPath": str(APPROVED_CORE_PATH),
                        "expectedBundledSourcePath": str(self.test_core),
                        "expectedGoodConfig": str(config_path)})
        self.assert_running_core_executable(
            current_status, "production transaction runs the immutable root-approved core")
        self.created_utuns = sorted(set(self.created_utuns) |
                                    (set(self.lifecycle.utun_interfaces()) -
                                     set(self.report["routeBaseline"]["utunInterfaces"])) )

        # Success intentionally committed an enabled proxy. Each failed transaction
        # restored that known-good checkpoint, as verified by the production client.
        # Restoring the pre-suite disabled state is a separate cleanup assertion.
        self.validate_system_proxy_enable(self.validate_proxy_snapshot(self.proxy_snapshot), proxy_port)
        self.report["productionRollbackProxyBaseline"] = {
            "kind": "committed-successful-transaction",
            "port": proxy_port,
            "checkpointRestoresVerifiedByProductionClient": coverage.get("productionSystemProxyCheckpointRestore") is True,
        }
        self.restore_proxy_now("after production transaction acceptance")

        dns_after = self.rpc("dnsSnapshot")
        dns_restored = dns_after == self.dns_snapshot
        self.assertion("production transaction leaves eligible DNS services at the captured baseline",
                       dns_restored,
                       {"expectedSHA256": canonical_hash(self.dns_snapshot),
                        "actualSHA256": canonical_hash(dns_after)})
        self.report["coverage"]["systemDNSExactRestore"] = (
            self.report["coverage"]["systemDNSExactRestore"] and dns_restored)

    def exercise_system_resolver_dns_hijack(self):
        name = f"clashfx-{secrets.token_hex(8)}.example.com"
        resolver_stdout = ""
        resolver_stderr = ""
        resolver_returncode = None
        resolver_error = None
        nameservers = []
        resolver_wait_started = time.monotonic()
        resolver_deadline = resolver_wait_started + min(8, SYSTEM_DNS_QUERY_TIMEOUT)
        while time.monotonic() < resolver_deadline:
            try:
                result = subprocess.run(
                    ["/usr/sbin/scutil", "--dns"], check=False, capture_output=True, text=True,
                    timeout=3,
                )
                resolver_stdout, resolver_stderr = result.stdout, result.stderr
                resolver_returncode = result.returncode
                nameservers = re.findall(
                    r"^\s*nameserver\[\d+\]\s*:\s*(\S+)\s*$",
                    resolver_stdout, re.MULTILINE,
                )
                if resolver_returncode == 0 and TEST_DNS_SERVER in nameservers:
                    break
            except subprocess.TimeoutExpired as error:
                resolver_stdout = self._completed_output(error.stdout)
                resolver_stderr = self._completed_output(error.stderr)
                resolver_error = "scutil --dns timed out"
                break
            except (OSError, subprocess.SubprocessError) as error:
                resolver_error = f"{type(error).__name__}: {error}"
                break
            time.sleep(0.25)

        query_stdout = ""
        query_stderr = ""
        query_returncode = None
        query_error = None
        try:
            result = subprocess.run(
                ["/usr/bin/dscacheutil", "-q", "host", "-a", "name", name],
                check=False, capture_output=True, text=True, timeout=SYSTEM_DNS_QUERY_TIMEOUT,
            )
            query_stdout, query_stderr, query_returncode = result.stdout, result.stderr, result.returncode
        except subprocess.TimeoutExpired as error:
            query_stdout = self._completed_output(error.stdout)
            query_stderr = self._completed_output(error.stderr)
            query_error = "dscacheutil timed out"
        except (OSError, subprocess.SubprocessError) as error:
            query_error = f"{type(error).__name__}: {error}"

        addresses = re.findall(
            r"^\s*ip_address:\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$",
            query_stdout, re.MULTILINE,
        )
        fake_ips = []
        for address in addresses:
            try:
                if ipaddress.ip_address(address) in FAKE_IP_NETWORK:
                    fake_ips.append(address)
            except ValueError:
                continue
        route = None
        route_error = None
        if fake_ips:
            try:
                route = self.lifecycle.route_lookup(fake_ips[0])
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                route_error = f"{type(error).__name__}: {error}"
        route_uses_owned_tun = bool(route and route.get("interface") in self.current_core_utuns)
        resolver_uses_test_server = TEST_DNS_SERVER in nameservers
        passed = (
            query_error is None and query_returncode == 0 and bool(fake_ips) and
            resolver_error is None and resolver_returncode == 0 and resolver_uses_test_server and
            route_uses_owned_tun
        )

        query_path = self.artifact_dir / "system-dns-dscacheutil.stdout.txt"
        resolver_path = self.artifact_dir / "system-dns-scutil-dns.txt"
        route_path = self.artifact_dir / "system-dns-fakeip-route.json"
        query_path.write_text(query_stdout, encoding="utf-8")
        resolver_path.write_text(resolver_stdout, encoding="utf-8")
        with route_path.open("w", encoding="utf-8") as stream:
            json.dump({"query": name, "fakeIPs": fake_ips, "route": route,
                       "routeError": route_error, "ownedTunInterfaces": self.current_core_utuns},
                      stream, indent=2, sort_keys=True)
            stream.write("\n")
        for path in (query_path, resolver_path, route_path):
            path.chmod(0o644)
        self.report["rawEvidence"] = sorted(set(self.report.get("rawEvidence", [])) | {
            query_path.name, resolver_path.name, route_path.name,
        })
        evidence = {
            "query": name,
            "dscacheutilReturnCode": query_returncode,
            "dscacheutilStdout": query_stdout,
            "dscacheutilStderr": query_stderr[-2000:],
            "dscacheutilError": query_error,
            "resolverCommand": "/usr/sbin/scutil --dns",
            "resolverReturnCode": resolver_returncode,
            "resolverWaitSeconds": round(min(time.monotonic(), resolver_deadline) - resolver_wait_started, 3),
            "resolverNameservers": nameservers,
            "resolverUsesTemporaryDNS": resolver_uses_test_server,
            "resolverStdoutPath": resolver_path.name,
            "resolverError": resolver_error,
            "route": route,
            "routeError": route_error,
            "routeUsesOwnedTun": route_uses_owned_tun,
            "fakeIPs": fake_ips,
            "fakeIPAddresses": [address for address in fake_ips
                                if ipaddress.ip_address(address) in FAKE_IP_NETWORK],
            "ownedTunInterfaces": self.current_core_utuns,
            "evidenceFiles": [query_path.name, resolver_path.name, route_path.name],
        }
        self.report["systemDNSResolverEvidence"] = evidence
        self.report["coverage"]["systemDNSResolverThroughTUN"] = passed
        self.assertion(
            "macOS system resolver receives a TUN DNS hijack fake IP and routes it through the active TUN",
            passed,
            evidence,
        )

    def exercise_dns_override(self):
        self.dns_may_be_dirty = True
        self.dns_recovery_snapshot = self.rpc("captureDNS", filterInterface=True)
        if self.dns_recovery_snapshot.get("version") != 2 or not self.dns_recovery_snapshot.get("services"):
            raise RuntimeError("Helper returned no transactional DNS capture scope")
        self.dns_recovery_snapshot["expectedServers"] = [TEST_DNS_SERVER]
        self.rpc("applyDNS", settings=self.dns_recovery_snapshot, servers=[TEST_DNS_SERVER])
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
        self.exercise_system_resolver_dns_hijack()
        self.rpc("restoreDNS", settings=self.dns_recovery_snapshot, filterInterface=True)
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
        self.owned_core_source_path = str(self.probe_core)
        self.harness_config_paths.add(str(missing_config))
        self.core_home_by_config[str(missing_config)] = str(home)
        result = self.rpc("startCore", binaryPath=str(self.probe_core),
                          configPath=str(missing_config), homeDir=str(home))
        self.assertion("Helper accepted process launch for invalid-config failure case", result is None)
        status = self.rpc("coreStatus")
        self.assertion("invalid-config launch records ProtoProbe's bundled source path",
                       self._status_uses_approved_core_source(status, self.probe_core),
                       {"binaryPath": status.get("binaryPath"),
                        "sourceBinaryPath": status.get("sourceBinaryPath"),
                        "expectedProbeCorePath": str(self.probe_core)})
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
        self.owned_core_source_path = None

    def run(self):
        self.compile_client()
        self.compile_transaction_client()
        self.compile_runtime_config_acceptance()
        self.prepare_unapproved_client()
        self.decorate_probe_app_metadata()
        self.install_with_production_legacy_script()

        helper_version = self.rpc("version")
        protocol_version = self.rpc("protocolVersion")
        self.assertion("production-installed Helper completes its ProtoProbe XPC version roundtrip",
                       isinstance(helper_version, str) and bool(helper_version) and protocol_version == 6,
                       {"helperVersion": helper_version, "protocolVersion": protocol_version,
                        "installedHelperPath": str(self.helper_path),
                        "productionInstallerReceipt": self.report.get("productionInstallerReceipt")})
        self.report["coverage"]["productionLegacyHelperInstallation"] = True
        self.report["coverage"]["metadataDecoratedAppInstallation"] = True
        self.report["coverage"]["productionHelperXPC"] = True
        self.report["productionLegacyInstaller"]["protoProbeVersionRoundtrip"] = {
            "helperVersion": helper_version,
            "protocolVersion": protocol_version,
            "passed": True,
        }

        self.augment_installed_receipt_for_transaction_client()

        started = time.monotonic()
        try:
            unapproved = subprocess.run(
                [str(self.unapproved_executable)],
                input=json.dumps({"operation": "version"}, separators=(",", ":")),
                check=False, capture_output=True, text=True, timeout=RPC_TIMEOUT,
            )
        except subprocess.TimeoutExpired as error:
            self.report["xpcCalls"].append({"client": "UnapprovedClone", "operation": "version",
                                              "ok": False,
                                              "elapsedSeconds": round(time.monotonic() - started, 3),
                                              "error": "client timed out while testing rejection"})
            raise RuntimeError("same-bundle-ID unapproved client did not receive a timely rejection") from error
        try:
            unapproved_response = json.loads(unapproved.stdout)
        except json.JSONDecodeError:
            unapproved_response = None
        denied = (unapproved.returncode != 0 and isinstance(unapproved_response, dict) and
                  unapproved_response.get("ok") is False and
                  isinstance(unapproved_response.get("error"), str) and
                  bool(unapproved_response["error"]))
        self.report["xpcCalls"].append({
            "client": "UnapprovedClone", "operation": "version", "ok": not denied,
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "exitCode": unapproved.returncode,
            "error": unapproved_response.get("error") if isinstance(unapproved_response, dict) else None,
        })
        self.assertion("Helper rejects an unapproved ad-hoc client with the same bundle identifier",
                       denied,
                       {"bundleIdentifier": CLIENT_BUNDLE_ID,
                        "clientCDHash": self.unapproved_client_cdhash,
                        "approvedClientCDHashes": sorted(self.approved_client_cdhashes.values()),
                        "exitCode": unapproved.returncode,
                        "response": unapproved_response,
                        "stderrTail": unapproved.stderr[-2000:]})
        self.report["coverage"]["unapprovedSameBundleIDRejected"] = True

        self.assertion("real Helper exposes production protocol version 6",
                       protocol_version == 6,
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
            "binaryPath": str(APPROVED_CORE_PATH),
            "sourceBinaryPath": str(self.probe_core),
            "startRequestBinaryPath": str(self.probe_core),
            "configPath": str(config_path),
            "homeDir": str(core_home),
            "ports": {"controller": controller_port, "dns": dns_port, "mixed": mixed_port},
            "startRequestedThrough": "ProxyConfigRemoteProcessProtocol.startMihomoCoreWithBinaryPath",
        }

        self.core_start_attempted = True
        self.owned_core_source_path = str(self.probe_core)
        self.harness_config_paths.add(str(config_path))
        self.core_home_by_config[str(config_path)] = str(core_home)
        start_result = self.rpc("startCore", binaryPath=str(self.probe_core),
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
                       self._status_uses_approved_core_source(status, self.probe_core) and
                       status.get("configPath") == str(config_path),
                       {"binaryPath": status.get("binaryPath"),
                        "sourceBinaryPath": status.get("sourceBinaryPath"),
                        "configPath": status.get("configPath"),
                        "expectedRootBinaryPath": str(APPROVED_CORE_PATH),
                        "expectedBundledSourcePath": str(self.probe_core),
                        "expectedConfigPath": str(config_path)})
        self.assert_running_core_executable(
            status, "Helper-launched Mihomo executable is the immutable root-approved core")
        core_uid = require_command_success(["/bin/ps", "-o", "uid=", "-p",
                                            str(self.owned_core_pid)], 5).strip()
        self.assertion("Helper-managed Mihomo process is root-owned in the hosted guest",
                       core_uid == "0", {"pid": self.owned_core_pid, "uid": core_uid})

        (version, api_config, new_utuns, active_tuns, tun_routes,
         route_observations, selected_route) = self.wait_for_tun_ready(
            endpoint, token, baseline_utuns, self.owned_launch_id, self.owned_core_pid)
        self.current_core_utuns = list(new_utuns)
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

        self.run_helper_core_restart_cycles(
            endpoint, token, config_path, core_home, baseline_utuns,
            controller_port, dns_port, mixed_port,
        )
        self.invoke_runtime_config_acceptance(endpoint, token, config_path, core_home)
        post_runtime_status = self.rpc("coreStatus")
        self.assertion(
            "runtime-config acceptance leaves the final Helper-managed core running",
            post_runtime_status.get("running") is True and
            post_runtime_status.get("launchID") == self.owned_launch_id and
            post_runtime_status.get("pid") == self.owned_core_pid and
            self._status_uses_approved_core_source(post_runtime_status, self.probe_core),
            {"status": post_runtime_status, "expectedLaunchID": self.owned_launch_id,
             "expectedPID": self.owned_core_pid},
        )

        self.proxy_may_be_dirty = True
        self.rpc("enableProxy", httpPort=mixed_port, socksPort=mixed_port, pac="",
                 filterInterface=False, ignoreList=["localhost", "127.0.0.1", "::1"])
        self.validate_system_proxy_enable(service_ids, mixed_port)
        self.report["coverage"]["systemProxyCaptureAndEnable"] = True
        self.restore_proxy_now("direct production Helper proxy exercise")
        self.exercise_dns_override()

        if self.transaction_client_available:
            status = self.rpc("coreStatus")
            self.assertion("phase handoff stops only the owned basic-lifecycle core",
                           status.get("launchID") == self.owned_launch_id and
                           status.get("pid") == self.owned_core_pid and
                           self._status_uses_approved_core_source(status, self.probe_core))
            self.rpc("stopCore")
            stopped = self.rpc("coreStatus")
            self.assertion("transaction phase begins with no active Helper-managed core", stopped.get("running") is False)
            self.owned_launch_id = None
            self.owned_core_pid = None
            self.owned_core_source_path = str(self.test_core)
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
            paths = process_text_paths(core_pid)
            if str(APPROVED_CORE_PATH) not in paths:
                self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                           "fallbackStopSkipped": "PID executable did not match immutable root core",
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
                if (executable != str(APPROVED_CORE_PATH.resolve()) or
                        arguments[1:5] != ["-f", config_path, "-d", home_dir]):
                    return False
                return str(APPROVED_CORE_PATH) in process_text_paths(pid)
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
                            str(Path(arguments[0]).resolve()) == str(APPROVED_CORE_PATH.resolve()) and
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
            _result, error = self._safe_rpc_cleanup("restoreDNS", settings=getattr(self, "dns_recovery_snapshot", None) or self.dns_snapshot,
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
            probe = command_result(["/bin/launchctl", "print", f"system/{SERVICE_LABEL}"], 8)
            missing_text = (probe.stdout + probe.stderr).lower()
            if probe.returncode != 0 and ("could not find service" in missing_text or
                                          "service not found" in missing_text):
                self.bootstrapped = False
                self.report["cleanup"] = {**self.report.get("cleanup", {}),
                                           "helperAlreadyUnloaded": True}
                return
            self.report["failures"].append({"phase": "cleanup", "operation": "launchctl-bootout",
                                            "message": (result.stderr or result.stdout).strip()})
            self.exit_code = self.exit_code or 1
            return
        self.bootstrapped = False
        self.report["cleanup"] = {**self.report.get("cleanup", {}), "helperBootedOut": True}

    def _remove_installed_root_trust(self):
        if self.bootstrapped:
            self.cleanup_assertion("installer paths remain intact until the Helper is booted out", False,
                                   {"service": SERVICE_LABEL,
                                    "reason": "launchd bootout did not complete; preserving live service files"})
            return
        failures = list(self.unexpected_install_leftovers)
        removed = []
        immutable_paths = {APPROVED_CORE_PATH, TRUST_RECEIPT_PATH}
        install_paths = (self.launchd_plist, self.helper_path, TRUST_RECEIPT_PATH, APPROVED_CORE_PATH)
        immutable_flag = getattr(stat, "UF_IMMUTABLE", None)
        for path in install_paths:
            tracked = self.installed_paths_created.get(path)
            if not os.path.lexists(path):
                if tracked is None:
                    removed.append(str(path))
                else:
                    failures.append({"path": str(path), "reason": "tracked installer path disappeared before cleanup"})
                continue
            if tracked is None:
                failures.append({"path": str(path), "reason": "path was not created with a verified identity and expected hash"})
                continue
            try:
                info = path.lstat()
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                        (info.st_dev, info.st_ino) != tracked["identity"] or
                        file_sha256(path) != tracked["sha256"]):
                    raise RuntimeError("path identity, file type, owner, or expected hash changed after install")
                if path in immutable_paths:
                    if immutable_flag is None:
                        raise RuntimeError("Python does not expose the macOS UF_IMMUTABLE file flag")
                    if getattr(info, "st_flags", 0) & immutable_flag:
                        require_command_success(["/usr/bin/chflags", "nouchg", str(path)], 8)
                path.unlink()
                if os.path.lexists(path):
                    raise RuntimeError("path remains after unlink")
                removed.append(str(path))
            except Exception as error:
                failures.append({"path": str(path), "reason": str(error)})

        for path, tracked in list(self.temporary_trust_paths_created.items()):
            if not os.path.lexists(path):
                failures.append({"path": str(path), "reason": "tracked temporary receipt disappeared before cleanup"})
                continue
            try:
                info = path.lstat()
                if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or
                        (info.st_dev, info.st_ino) != tracked["identity"] or
                        file_sha256(path) != tracked["sha256"]):
                    raise RuntimeError("temporary receipt identity, owner, or expected hash changed")
                path.unlink()
                if os.path.lexists(path):
                    raise RuntimeError("temporary receipt remains after unlink")
                removed.append(str(path))
                self.temporary_trust_paths_created.pop(path, None)
            except Exception as error:
                failures.append({"path": str(path), "reason": str(error)})

        paths_absent = all(not os.path.lexists(path) for path in install_paths)
        passed = not failures and paths_absent
        self.cleanup_assertion("fixture removed the installer-created launchd job, helper, root core and trust receipt",
                               passed,
                               {"removed": removed, "failures": failures,
                                "remaining": [str(path) for path in install_paths if os.path.lexists(path)]})
        self.report["cleanup"]["productionInstallPathsRemoved"] = passed
        self.report["cleanup"]["approvedCoreTrustPathsRemoved"] = (
            not os.path.lexists(APPROVED_CORE_PATH) and not os.path.lexists(TRUST_RECEIPT_PATH))

        if self.trust_directory_created is not None:
            try:
                directory = APPROVED_CORE_PATH.parent
                info = directory.lstat()
                if ((info.st_dev, info.st_ino) != self.trust_directory_created or
                        not stat.S_ISDIR(info.st_mode) or info.st_uid != 0):
                    raise RuntimeError("fixture trust directory identity changed")
                directory.rmdir()
                self.cleanup_assertion("fixture removed its empty trust directory", True, {})
            except Exception as error:
                self.cleanup_assertion("fixture removed its empty trust directory", False,
                                       {"reason": str(error)})

    def cleanup(self):
        cleanup = self.report.setdefault("cleanup", {})
        if self.bootstrapped and self.core_start_attempted and not (
                self.owned_launch_id and self.owned_core_pid):
            try:
                observed = self.rpc("coreStatus")
                launch_id = observed.get("launchID")
                pid = observed.get("pid")
                owned_request = (self._status_uses_approved_core_source(
                                     observed, self.owned_core_source_path) and
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
                        targets_restored = route_targets_restored(baseline["routeTargets"], current_targets)
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

        try:
            self._bootout_helper()
        except Exception as error:
            self.report["failures"].append({"phase": "cleanup", "operation": "launchctl-bootout",
                                            "message": str(error)})
            self.exit_code = self.exit_code or 1
        self._remove_installed_root_trust()

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
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True,
                        help="Xcode-built com.clashfx.app.Helper production executable")
    parser.add_argument("--core", required=True,
                        help="guest-built mihomo_core executable with the shipping overlay")
    parser.add_argument("--artifact-dir", required=True,
                        help="new report/log directory under RUNNER_TEMP")
    try:
        args = parser.parse_args()
    except UsageError as error:
        emit_json({"status": "error", "reason": str(error)})
        return 2

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

    try:
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
