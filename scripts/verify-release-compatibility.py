#!/usr/bin/env python3
"""Read-only build gates. A declared minimum is necessary, not runtime proof."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess


def version(value):
    parts = [int(part) for part in str(value).split('.')]
    return tuple((parts + [0, 0, 0])[:3])


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def verify_sdk():
    sdk = Path(command('xcrun', '--sdk', 'macosx', '--show-sdk-path'))
    with (sdk / 'SDKSettings.plist').open('rb') as stream:
        target = plistlib.load(stream)['SupportedTargets']['macosx']
    minimum = target['MinimumDeploymentTarget']
    if version(minimum) > version('10.14'):
        raise RuntimeError(f'SDK minimum is {minimum}; select a toolchain supporting macOS 10.14. '
                           'Do not raise the release deployment target to make the build pass.')
    print(f'SDK deployment floor: {minimum}; macOS 10.14 target accepted')


def verify_binary(path):
    archs = command('xcrun', 'lipo', '-archs', str(path)).split()
    for arch, ceiling in [('x86_64', '10.14'), ('arm64', '11.0')]:
        if arch not in archs:
            raise RuntimeError(f'{path}: missing {arch}')
        output = command('xcrun', 'otool', '-arch', arch, '-l', str(path))
        minima = []
        for block in output.split('Load command'):
            if re.search(r'cmd LC_BUILD_VERSION\b', block):
                match = re.search(r'\bminos\s+([\d.]+)', block)
            elif re.search(r'cmd LC_VERSION_MIN_MACOSX\b', block):
                match = re.search(r'\bversion\s+([\d.]+)', block)
            else:
                continue
            if match:
                minima.append(match.group(1))
        if not minima or any(version(value) > version(ceiling) for value in minima):
            raise RuntimeError(f'{path}: {arch} minimum {minima or "unknown"} exceeds {ceiling}')
        print(f'{path.name}: {arch} minimum {", ".join(minima)}')


def verify_app(path):
    with (path / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    minimum = info.get('LSMinimumSystemVersion')
    if minimum is None or version(minimum) > version('10.14'):
        raise RuntimeError(f'App LSMinimumSystemVersion is {minimum!r}, expected <= 10.14')
    for arch, ceiling in [('x86_64', '10.14'), ('arm64', '11.0')]:
        declared = info.get('LSMinimumSystemVersionByArchitecture', {}).get(arch)
        if declared is not None and version(declared) > version(ceiling):
            raise RuntimeError(f'App {arch} Info.plist minimum is {declared}, expected <= {ceiling}')
    verify_binary(path / 'Contents/MacOS' / info['CFBundleExecutable'])
    for name in ['mihomo_core', 'com.clashfx.app.Helper']:
        matches = [candidate for candidate in path.rglob(name) if candidate.is_file()]
        if len(matches) != 1:
            raise RuntimeError(f'Expected exactly one bundled {name}, found {len(matches)}')
        verify_binary(matches[0])
    print('App, helper and core architecture/minimum-version gates passed; old-system runtime testing still required')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', action='store_true')
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    if not args.sdk and args.app is None:
        parser.error('specify --sdk or --app')
    if args.sdk:
        verify_sdk()
    if args.app is not None:
        verify_app(args.app)
