#!/usr/bin/env python3
"""Build, verify, and replace the local SpotMenu installation on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = 'SpotMenu.app'
BUNDLE_ID = 'com.github.kmikiy.SpotMenu'
APPLICATIONS = Path('/Applications')
PLIST = 'Contents/Info.plist'
EXECUTABLE = 'Contents/MacOS/SpotMenu'
KEYBOARD_SHORTCUTS_REVISION = '045cf174010beb335fa1d2567d18c057b8787165'
RELEASE_SHA256 = '00394a4ce7413e9fbb8d9df11c0154dde011a74fc1b013f4a9e613883c2dcb8c'
SPARKLE_SHA256 = '995f913935fe903d50b3be5344fc52a638f56b39ef7984bf7a44244786d28638'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def git_revision():
    revision = subprocess.check_output(
        ['git', '-C', ROOT, 'rev-parse', '--short', 'HEAD'], text=True
    ).strip()
    status = subprocess.check_output(['git', '-C', ROOT, 'status', '--porcelain'], text=True)
    return f'{revision}-dirty' if status else revision


def signing_identity():
    configured = subprocess.run(
        ['git', '-C', ROOT, 'config', '--local', '--get', 'spotmenu.signingIdentity'],
        text=True, capture_output=True,
    )
    if configured.returncode == 1:
        return '-'
    configured.check_returncode()
    identity = configured.stdout.strip()
    if not re.fullmatch(r'[0-9a-fA-F]{40}', identity):
        raise SystemExit('spotmenu.signingIdentity must be a certificate fingerprint.')
    return identity


def signing_requirement(identity):
    return f'identifier "{BUNDLE_ID}" and certificate leaf = H"{identity}"'


def sign_app(app, stage):
    entitlements = stage / 'SpotMenu.entitlements'
    values = (ROOT / 'SpotMenu/SpotMenu.entitlements').read_text()
    entitlements.write_text(values.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', BUNDLE_ID))
    identity = signing_identity()
    flags = [] if identity == '-' else [
        f'-r=designated => {signing_requirement(identity)}',
    ]
    run('codesign', '--force', '--timestamp=none', '--sign', identity,
        '--entitlements', entitlements, *flags, app)


def copy_swift(source, destination):
    destination.mkdir()
    for path in sorted(source.rglob('*.swift')):
        output = destination / path.relative_to(source)
        output.parent.mkdir(parents=True, exist_ok=True)
        code = re.sub(r'^#Preview[^\n]*\{\n.*?^\}\n', '', path.read_text(), flags=re.M | re.S)
        output.write_text(code.replace('@State ', '@LocalBuildState '))
    # The macOS 27 command-line SDK ships the State wrapper without the Xcode macros.
    (destination / 'LocalBuildState.swift').write_text(
        'import SwiftUI\ntypealias LocalBuildState<Value> = State<Value>\n'
    )
    return sorted(destination.rglob('*.swift'))


def unpack_verified(archive, digest, destination):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise SystemExit(f'Unexpected checksum for {archive}')
    run('ditto', '-x', '-k', archive, destination)


def build_with_command_line_tools(stage, cache):
    if platform.machine() != 'arm64':
        raise SystemExit('Command-line builds need Apple Silicon.')
    pins_path = ROOT / 'SpotMenu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    pins = {pin['identity']: pin['state'] for pin in json.loads(pins_path.read_text())['pins']}
    if (pins['keyboardshortcuts']['revision'] != KEYBOARD_SHORTCUTS_REVISION
            or pins['sparkle']['version'] != '2.8.1'):
        raise SystemExit('Update the Command Line Tools build inputs for the new dependency pins.')
    app = stage / APP_NAME
    unpack_verified(cache / 'SpotMenu-v2.3.0.zip', RELEASE_SHA256, stage)
    unpack_verified(cache / 'Sparkle-sdk.zip', SPARKLE_SHA256, stage / 'sparkle-sdk')
    keyboard = cache / 'KeyboardShortcuts'
    keyboard_source = stage / 'keyboard-checkout'
    keyboard_source.mkdir()
    archived = subprocess.check_output(['git', '-C', keyboard, 'archive', KEYBOARD_SHORTCUTS_REVISION])
    run('tar', '-x', '-C', keyboard_source, input=archived)
    keyboard_sources = copy_swift(keyboard_source / 'Sources/KeyboardShortcuts', stage / 'keyboard')
    bundle_accessor = stage / 'resource_bundle_accessor.swift'
    bundle_accessor.write_text('''import Foundation
extension Bundle {
    static let module = Bundle(url: Bundle.main.resourceURL!.appendingPathComponent(
        "KeyboardShortcuts_KeyboardShortcuts.bundle"
    ))!
}
''')
    flags = ['-target', 'arm64-apple-macos13.0', '-module-cache-path', stage / 'module-cache', '-O']
    run('swiftc', *flags, '-emit-library', '-static', '-emit-module',
        '-emit-module-path', stage / 'KeyboardShortcuts.swiftmodule',
        '-module-name', 'KeyboardShortcuts', '-o', stage / 'libKeyboardShortcuts.a',
        *keyboard_sources, bundle_accessor)

    app_sources = copy_swift(ROOT / 'SpotMenu', stage / 'source')
    sparkle = stage / 'sparkle-sdk/Sparkle.xcframework/macos-arm64_x86_64'
    run('swiftc', *flags, '-module-name', 'SpotMenu', '-I', stage, '-F', sparkle,
        '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        '-o', stage / 'SpotMenu', *app_sources, stage / 'libKeyboardShortcuts.a')

    # Reuse the verified release assets and replace the executable and app metadata.
    shutil.copy2(stage / 'SpotMenu', app / EXECUTABLE)
    (app / 'Contents/CodeResources').unlink(missing_ok=True)
    with (app / PLIST).open('rb') as file:
        metadata = plistlib.load(file)
    with (ROOT / 'SpotMenu/Info.plist').open('rb') as file:
        metadata.update(plistlib.load(file))
    project = (ROOT / 'SpotMenu.xcodeproj/project.pbxproj').read_text()
    metadata['CFBundleShortVersionString'] = re.search(r'MARKETING_VERSION = ([0-9.]+);', project)[1]
    with (app / PLIST).open('wb') as file:
        plistlib.dump(metadata, file)
    run('/bin/sh', ROOT / 'Scripts/stamp-git-version.sh', ROOT, app / PLIST)

    return app


def build(stage, cache):
    xcode = subprocess.run(['xcodebuild', '-version'], capture_output=True).returncode == 0
    if xcode:
        run('xcodebuild', '-project', ROOT / 'SpotMenu.xcodeproj', '-scheme', 'SpotMenu',
            '-configuration', 'Release', '-derivedDataPath', stage / 'DerivedData',
            'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'ENABLE_HARDENED_RUNTIME=NO', 'build')
        app = stage / 'DerivedData/Build/Products/Release' / APP_NAME
    else:
        app = build_with_command_line_tools(stage, cache)
    sign_app(app, stage)
    return app


def verify(app):
    run('codesign', '--verify', '--deep', '--strict', app)
    identity = signing_identity()
    if identity != '-':
        run('codesign', '--verify', '--strict', f'-R={signing_requirement(identity)}', app)
    with (app / PLIST).open('rb') as file:
        metadata = plistlib.load(file)
    revision = metadata.get('SpotMenuGitCommit', '')
    if metadata.get('CFBundleIdentifier') != BUNDLE_ID or revision != git_revision():
        raise SystemExit('The app does not match the current source revision.')
    return f"{metadata['CFBundleShortVersionString']} ({revision})"


def stop_installed_app(app):
    executable = str(app / EXECUTABLE)
    processes = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    pids = [int(pid) for line in processes.splitlines()
            for pid, command in [line.strip().split(maxsplit=1)] if command == executable]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        for _ in range(50):
            time.sleep(0.1)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
        else:
            raise SystemExit('Quit the installed SpotMenu before replacing it.')


def install(app):
    target = APPLICATIONS / APP_NAME
    with tempfile.TemporaryDirectory(prefix='.SpotMenu-install-', dir=APPLICATIONS) as folder:
        staged = Path(folder) / APP_NAME
        old = Path(folder) / 'Previous SpotMenu.app'
        run('ditto', app, staged)
        version = verify(staged)
        if target.exists():
            with (target / PLIST).open('rb') as file:
                if plistlib.load(file).get('CFBundleIdentifier') != BUNDLE_ID:
                    raise SystemExit(f'Unexpected application at {target}')
            stop_installed_app(target)
            target.rename(old)
        try:
            staged.rename(target)
            verify(target)
            if old.exists():
                run('/usr/bin/trash', old)
        except BaseException:
            if target.exists():
                target.rename(staged)
            if old.exists():
                old.rename(target)
            raise
    print(f'Installed SpotMenu {version} at {target}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--dependency-cache', type=Path, default=ROOT.parent,
        help='Location of the pinned ZIPs and KeyboardShortcuts checkout (default: parent directory)',
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--build-only', type=Path, metavar='APP', help='Stage an app bundle without installing it')
    mode.add_argument('--install-built', type=Path, metavar='APP', help='Install a previously staged bundle and retire it to the Trash')
    args = parser.parse_args()
    if args.install_built:
        staged = args.install_built.resolve()
        if staged == APPLICATIONS / APP_NAME:
            parser.error('--install-built requires a separate staging path')
        verify(staged)
        install(staged)
        run('/usr/bin/trash', staged)
        return
    with tempfile.TemporaryDirectory(prefix='spotmenu-build-') as folder:
        app = build(Path(folder), args.dependency_cache)
        verify(app)
        if args.build_only:
            if args.build_only.exists():
                parser.error(f'Staging path already exists: {args.build_only}')
            run('ditto', app, args.build_only)
        else:
            install(app)


if __name__ == '__main__':
    main()
