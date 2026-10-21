#!/usr/bin/env python3
"""Launch the unmodified candidate App on a disposable GitHub-hosted Mac only.

External test-only menu instrumentation calls existing menu actions. This is
automated App integration acceptance, not human GUI or authorization testing.
"""
import argparse
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


def command(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], stderr=subprocess.STDOUT, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--artifact-dir', type=Path, required=True)
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('backend', ROOT / 'scripts/run-hosted-helper-tun-acceptance.py')
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    failures, _ = backend.hosted_runner_gate()
    if failures:
        raise SystemExit('Refusing system/App actions: ' + '; '.join(failures))
    runner = pwd.getpwnam('runner')
    home = Path(runner.pw_dir)
    app = args.app.resolve(strict=True)
    artifact = args.artifact_dir.resolve()
    temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    assert app.is_relative_to(temp) and artifact.is_relative_to(temp)
    config = home / '.config/clashfx'
    assert not config.exists(), 'fresh hosted user must not have ClashFX data'
    for path in [backend.INSTALLED_HELPER_PATH, backend.APPROVED_CORE_PATH, backend.TRUST_RECEIPT_PATH, backend.LAUNCH_DAEMON_PATH]:
        assert not path.exists(), 'refusing to replace existing Helper resources'
    artifact.mkdir(parents=True, exist_ok=True)
    artifact.chmod(0o755)
    os.chown(artifact, runner.pw_uid, runner.pw_gid)
    report = {'status': 'running', 'source': os.environ['GITHUB_SHA'],
              'packageSource': os.environ.get('SOURCE_SHA', os.environ['GITHUB_SHA']), 'assertions': [],
              'fullAppLaunched': False, 'manualGUI': False, 'authorizationDialog': False,
              'instrumentation': 'external test-only dylib invokes existing NSMenuItem target/actions; signed payload hashes checked separately from Finder icon metadata'}
    report_path = artifact / 'report.json'
    def record(name, value=True):
        report['assertions'].append({'name': name, 'passed': bool(value)})
        report_path.write_text(json.dumps(report, indent=2))
        if not value:
            raise AssertionError(name)
    def user(args):
        return command(['sudo', '-u', 'runner', *args])
    def wait(check, name, timeout=60):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            try:
                last = check()
                if last:
                    return last
            except (OSError, ValueError, subprocess.CalledProcessError):
                pass
            time.sleep(0.15)
        raise AssertionError(name + ' timed out; last=' + repr(last))
    def port():
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            return s.getsockname()[1]
    fixture_api_secret = 'acceptance-fixture-only'
    def get(api, path):
        headers = {'Authorization': 'Bearer ' + fixture_api_secret} if api != remote_api else {}
        request = urllib.request.Request(f'http://127.0.0.1:{api}/{path}', headers=headers)
        with urllib.request.urlopen(request, timeout=1) as response:
            return json.load(response)
    mixed, api, remote_api = port(), port(), port()
    while len({mixed, api, remote_api}) != 3:
        remote_api = port(); api = port()
    def root(group, api_port, mixed_port=0):
        return {'mixed-port': mixed_port, 'port': 0, 'socks-port': 0, 'allow-lan': False,
                'bind-address': '127.0.0.1', 'external-controller': f'127.0.0.1:{api_port}',
                'secret': '', 'mode': 'rule', 'log-level': 'debug', 'ipv6': False,
                'dns': {'enable': False}, 'tun': {'enable': False},
                'proxy-groups': [{'name': group, 'type': 'select', 'proxies': ['DIRECT', 'REJECT']}],
                'rules': ['MATCH,DIRECT']}
    processes = []
    launched_pids = []
    installed = False
    network_before = {x: command(['scutil', '--' + x]) for x in ['proxy', 'dns']}
    stdout = (artifact / 'app-stdout.log').open('wb')
    bundle_hashes = {str(p.relative_to(app)): backend.file_sha256(p) for p in app.rglob('*') if p.is_file()}
    try:
        # Generate the unchanged production installer for this actual package.
        generator = object.__new__(backend.AcceptanceHarness)
        generator.probe_app = app
        generator.probe_executable = app / 'Contents/MacOS/ClashFX'
        generator.probe_core = app / 'Contents/Resources/mihomo_core'
        generator.core_path = generator.probe_core
        cdhash = re.search(r'CDHash=([a-f0-9]{40})', command(['codesign', '-dv', '--verbose=4', generator.probe_executable]).decode()).group(1)
        generator.approved_client_cdhashes = {str(app): cdhash}
        generator.expected_embedded_helper_sha256 = backend.file_sha256(app / 'Contents/Library/LaunchServices/com.clashfx.app.Helper')
        generator.install_generator_source = artifact / 'install-generator.swift'
        generator.install_generator = artifact / 'install-generator'
        generator.install_fixture_path = artifact / 'install-input.json'
        generator.production_install_script = artifact / 'install.sh'
        generator.metadata_stage_report = artifact / 'unused-install-metadata-observation.json'
        generator.instrumented_install_script = artifact / 'unused-instrumented-install.sh'
        generator._generate_production_install_script()
        installed = True  # cleanup partial installation too
        command(['/bin/bash', generator.production_install_script])
        record('productionInstallerForActualCandidate')
        config.mkdir(parents=True)
        for name, group in [('config', 'BOOTSTRAP'), ('Acceptance-A', 'LOCAL_A'), ('Acceptance-B', 'LOCAL_B')]:
            (config / (name + '.yaml')).write_text(json.dumps(root(group, api, mixed)))
        (config / 'Acceptance-Invalid.yaml').write_text('proxy-groups: [ malformed\n')
        defaults = {'selectConfigName': 'Acceptance-A', 'selectedLocalConfigName': 'Acceptance-A',
                    'proxyPortAutoSet': False, 'enhancedMode': False, 'claudeProxyLockEnabled': False,
                    'api-secret': fixture_api_secret, 'overrideConfigSecret': True, 'apiPort': api,
                    'appLanguage': 'en', 'AppleLanguages': ['en'], 'SUEnableAutomaticChecks': False,
                    'kRemoteControls': json.dumps([{'name': 'Acceptance-Remote', 'url': f'http://127.0.0.1:{remote_api}', 'secret': '', 'uuid': 'acceptance-remote'}]).encode(),
                    'selectedRemoteControlConfigID': ''}
        defaults_file = artifact / 'defaults.plist'
        defaults_file.write_bytes(plistlib.dumps(defaults))
        user(['defaults', 'import', 'com.clashfx.app', defaults_file])
        command(['chown', '-R', 'runner:staff', config])
        dylib = artifact / 'menu-driver.dylib'
        command(['clang', '-dynamiclib', '-fobjc-arc', '-fblocks', '-framework', 'Cocoa',
                 ROOT / 'scripts/candidate-app-menu-driver.m', '-o', dylib])
        command(['codesign', '--force', '--sign', '-', dylib])
        request_file, response_file = artifact / 'command.json', artifact / 'response.json'
        class Health(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(204); self.end_headers()
            def log_message(self, *unused):
                pass
        health = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Health)
        threading.Thread(target=health.serve_forever, daemon=True).start()
        def launch():
            # A previous quit/restart command must never replay in a new process.
            request_file.unlink(missing_ok=True)
            response_file.unlink(missing_ok=True)
            env = {k: v for k, v in os.environ.items() if k.startswith(('GITHUB_', 'RUNNER_', 'Image')) or k == 'CI'}
            env.update(HOME=str(home), DYLD_INSERT_LIBRARIES=str(dylib),
                       CLASHFX_ACCEPTANCE_COMMAND=str(request_file), CLASHFX_ACCEPTANCE_RESPONSE=str(response_file))
            p = subprocess.Popen(['sudo', '-u', 'runner', '/usr/bin/env', *[k+'='+v for k,v in env.items()], app / 'Contents/MacOS/ClashFX'], stdout=stdout, stderr=subprocess.STDOUT)
            processes.append(p)
            report['fullAppLaunched'] = True
            return p
        def menu(action, title=None, selector=None):
            request_id = uuid.uuid4().hex
            body = {'id': request_id, 'action': action}
            if title: body['title'] = title
            if selector: body['selector'] = selector
            staged = artifact / 'command.tmp'; staged.write_text(json.dumps(body)); os.replace(staged, request_file)
            response = wait(lambda: json.loads(response_file.read_text()) if response_file.exists() and json.loads(response_file.read_text()).get('id') == request_id else None, 'menu '+str(body), 20)
            if not response.get('ok'):
                raise AssertionError(response)
            (artifact / ('menu-'+request_id+'.json')).write_text(json.dumps(response, indent=2))
            return response
        def profile(group):
            return group in get(api, 'proxies').get('proxies', {})
        def healthy(group):
            wait(lambda: profile(group), group+' API readiness')
            time.sleep(2)
            record('profile-'+group+'-API', profile(group))
            status = command(['curl', '--silent', '--show-error', '--max-time', '4',
                              '--noproxy', '', '--proxy', f'http://127.0.0.1:{mixed}',
                              '--output', '/dev/null', '--write-out', '%{http_code}',
                              f'http://127.0.0.1:{health.server_port}/health']).decode()
            record('profile-'+group+'-real-proxy-forwarding', status == '204')
        launch()
        try: report['initialMenuSnapshot'] = menu('list')
        except Exception as error: report['initialMenuProbeError'] = str(error)
        healthy('LOCAL_A')
        launched_pids.append(menu('list')['pid'])
        record('coldStartFullCandidate')
        # A real independent candidate core serves the remote management API.
        remote_dir = artifact / 'remote-core'; remote_dir.mkdir()
        remote_file = remote_dir / 'remote.yaml'; remote_file.write_text(json.dumps(root('REMOTE', remote_api)))
        remote = subprocess.Popen([app / 'Contents/Resources/mihomo_core', '-d', remote_dir, '-f', remote_file], stdout=stdout, stderr=subprocess.STDOUT)
        processes.append(remote)
        wait(lambda: 'REMOTE' in get(remote_api, 'proxies').get('proxies', {}), 'remote fixture readiness')
        menu('invoke', title='Acceptance-Remote')
        time.sleep(2)
        remote_menu = menu('list')
        record('remoteMenuActionFullApp', any(x.get('title') == 'Acceptance-Remote' and x.get('state') == 1 for x in remote_menu.get('items', [])))
        # Local item title is localized in the actual menu; use its model-free
        # action item with state off, reported by the menu driver.
        items = remote_menu.get('items', [])
        local = [x for x in items if x.get('selector') == 'didSelectMenuItemWithSender:' and x.get('title') != 'Acceptance-Remote']
        assert len(local) == 1, local
        menu('invoke', title=local[0]['title'])
        healthy('LOCAL_A')
        record('remoteToLocalFullApp', any(x.get('title') == local[0]['title'] and x.get('selector') == 'didSelectMenuItemWithSender:' and x.get('state') == 1 for x in menu('list').get('items', [])))
        menu('invoke', title='Acceptance-B'); healthy('LOCAL_B')
        menu('invoke', title='Acceptance-A'); healthy('LOCAL_A')
        record('continuousProfileSwitchesFullApp')
        menu('invoke', title='Acceptance-Invalid')
        alert = wait(lambda: (lambda x: x if x.get('alert') else None)(menu('list')), 'invalid profile alert')
        record('invalidCandidateReportsFailure', alert['alert'].get('title') == 'Reload Config Fail')
        menu('dismiss')
        healthy('LOCAL_A')
        record('failedCandidatePreservesVerifiedProfile', any(x.get('title') == 'Acceptance-A' and x.get('selector') == 'actionSelectConfigWithSender:' and x.get('state') == 1 for x in menu('list').get('items', [])))
        menu('invoke', selector='actionQuit:')
        wait(lambda: not _pid_alive(launched_pids[-1]), 'exit before saved-remote cold start')
        user(['defaults', 'write', 'com.clashfx.app', 'selectedRemoteControlConfigID', '-string', 'acceptance-remote'])
        launch()
        def saved_remote_menu():
            snapshot = menu('list')
            return snapshot if any(x.get('title') == 'Acceptance-Remote' and x.get('state') == 1 for x in snapshot.get('items', [])) else None
        saved_remote = wait(saved_remote_menu, 'saved remote selected on cold start')
        launched_pids.append(saved_remote['pid'])
        # Record whether the local bootstrap had already run before persisted
        # remote restoration; do not pretend that an absent core was observed.
        try: report['savedRemoteStartHadLocalAPI'] = bool(get(api, 'version'))
        except OSError: report['savedRemoteStartHadLocalAPI'] = False
        menu('invoke', title=local[0]['title'])
        healthy('LOCAL_A')
        record('savedRemoteColdStartThenLocal', any(x.get('title') == local[0]['title'] and x.get('selector') == 'didSelectMenuItemWithSender:' and x.get('state') == 1 for x in menu('list').get('items', [])))
        for cycle in range(3):
            menu('invoke', selector='actionQuit:')
            wait(lambda: not _pid_alive(launched_pids[-1]), 'graceful app exit')
            launch(); healthy('LOCAL_A')
            next_pid = menu('list')['pid']; record('restart-new-PID-'+str(cycle), next_pid not in launched_pids)
            launched_pids.append(next_pid)
        record('threeGracefulTerminateRelaunchCycles')
        # Exercise production restartApp once, including its /usr/bin/open replacement.
        last_pid = launched_pids[-1]
        menu('invoke', selector='actionRestart:')
        request_file.unlink(missing_ok=True)
        wait(lambda: not _pid_alive(last_pid), 'production restart old process exit')
        healthy('LOCAL_A')
        def replacement_pid():
            rows = command(['ps', '-axo', 'pid=,comm=']).decode().splitlines()
            return next((int(row.split(maxsplit=1)[0]) for row in rows
                         if len(row.split(maxsplit=1)) == 2 and row.split(maxsplit=1)[1] == str(app / 'Contents/MacOS/ClashFX')
                         and int(row.split(maxsplit=1)[0]) not in launched_pids), None)
        launched_pids.append(wait(replacement_pid, 'LaunchServices replacement PID'))
        record('productionRestartActionAndLaunchServicesReplacement')
        report['status'] = 'passed'
    except BaseException as error:
        report['status'] = 'failed'
        report['failure'] = str(error)
        try: report['failureMenuSnapshot'] = menu('list')
        except Exception as probe_error: report['failureMenuProbeError'] = str(probe_error)
        raise
    finally:
        # All paths here are guarded by multiple disposable-hosted-runner signals.
        try:
            for row in command(['pgrep', '-f', str(app / 'Contents/MacOS/ClashFX')]).decode().split():
                pid = int(row)
                if pid != os.getpid(): os.kill(pid, signal.SIGTERM)
            time.sleep(3)
        except (subprocess.CalledProcessError, ProcessLookupError):
            pass
        for p in processes:
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
        if installed:
            subprocess.run(['launchctl', 'bootout', 'system/com.clashfx.app.Helper'], capture_output=True)
            for p in [backend.INSTALLED_HELPER_PATH, backend.APPROVED_CORE_PATH, backend.TRUST_RECEIPT_PATH, backend.LAUNCH_DAEMON_PATH]:
                subprocess.run(['chflags', 'nouchg', p], capture_output=True)
                p.unlink(missing_ok=True)
        log_dir = home / 'Library/Logs/ClashFX'
        if log_dir.exists(): shutil.copytree(log_dir, artifact / 'app-logs', dirs_exist_ok=True)
        report['networkUnchanged'] = all(command(['scutil', '--'+x]) == value for x,value in network_before.items())
        after_hashes = {str(p.relative_to(app)): backend.file_sha256(p) for p in app.rglob('*') if p.is_file()}
        changed = [name for name, digest in bundle_hashes.items() if after_hashes.get(name) != digest]
        added = sorted(set(after_hashes) - set(bundle_hashes))
        report['candidateBundleUnmodified'] = bundle_hashes == after_hashes
        report['bundleChangedFiles'] = changed
        report['bundleAddedFiles'] = added
        # Release AppLogoTool intentionally persists the Lab badge via the
        # Finder custom-icon file at the bundle root, outside signed Contents.
        report['candidateSignedPayloadUnmodified'] = not changed and set(added) <= {'Icon\r'}
        signature = subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', app], capture_output=True, text=True)
        report['postLaunchSignatureValid'] = signature.returncode == 0
        report['postLaunchSignatureDetail'] = signature.stderr
        if not report['networkUnchanged'] or not report['candidateSignedPayloadUnmodified'] or not report['postLaunchSignatureValid']:
            report['status'] = 'failed'
            report.setdefault('failure', 'Guest network or candidate payload/signature postconditions failed')
        report['appPIDs'] = launched_pids
        stdout.close()
        report_path.write_text(json.dumps(report, indent=2))
        # sudo-created diagnostics must be readable by the runner's artifact
        # uploader, including the install generator's private script and cache.
        for path in [artifact, *artifact.rglob('*')]:
            os.chown(path, runner.pw_uid, runner.pw_gid, follow_symlinks=False)
        print(json.dumps(report, indent=2), flush=True)
        if report['status'] != 'passed':
            for path in [artifact / 'app-stdout.log', *sorted((artifact / 'app-logs').glob('*.log'))]:
                if path.is_file():
                    print('Guest diagnostic:', path.name, flush=True)
                    print(path.read_text(errors='replace')[-12000:], flush=True)
        if not report['networkUnchanged']:
            raise AssertionError('Disposable guest proxy/DNS changed unexpectedly')
        if not report['candidateSignedPayloadUnmodified'] or not report['postLaunchSignatureValid']:
            raise AssertionError('Candidate signed payload or signature changed during acceptance')


def _pid_alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False


if __name__ == '__main__':
    main()
