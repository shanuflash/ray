#!/usr/bin/env python3
import argparse
import importlib.util
import gzip
import hashlib
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

BUILD = pathlib.Path(__file__).resolve().parents[1]
REPO = BUILD.parents[2]
sys.path.insert(0, str(BUILD))


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


target = module('target', BUILD / 'target_config.py')
series = module('series', BUILD.parent / 'series.py')
helium = module('helium', BUILD / '03-helium.py')
RAY_THEME = REPO / 'engine/chromium/src/chrome/app/theme'
LINUX_LOGOS = {f'chrome/app/theme/chromium/linux/product_logo_{size}.png': RAY_THEME / f'chromium/product_logo_{size}.png' for size in (24, 48, 64, 128, 256)}
LINUX_LOGOS.update({f'chrome/app/theme/default_100_percent/chromium/linux/product_logo_{size}.png': RAY_THEME / f'default_100_percent/chromium/product_logo_{size}.png' for size in (16, 32)})
packaging = module('packaging', REPO / 'scripts/linux/package.py')
formats = packaging.linux_formats



class RetireSeriesBaseTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = pathlib.Path(scratch.name)
        self.src = self.root / 'src'
        self.base = self.root / 'series-base-linux-x64'

    def checkout(self, version):
        major, minor, build, patch = version.split('.')
        (self.src / 'chrome').mkdir(parents=True, exist_ok=True)
        (self.src / 'chrome/VERSION').write_text(f'MAJOR={major}\nMINOR={minor}\nBUILD={build}\nPATCH={patch}\n')

    def captured(self, path=None):
        path = path or self.base
        path.mkdir(parents=True)
        (path / 'value').write_text('base\n')

    def retire(self, version='157.0.8103.50'):
        result = subprocess.run([str(BUILD / 'retire-series-base.sh'), str(self.src), str(self.base), version], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_a_base_for_the_synced_version_stays(self):
        self.checkout('157.0.8103.50')
        self.captured()
        self.assertEqual(self.retire(), '')
        self.assertEqual((self.base / 'value').read_text(), 'base\n')

    def test_a_version_move_sets_the_base_aside_under_the_old_version(self):
        self.checkout('156.0.8078.79')
        self.captured()
        self.assertIn('156.0.8078.79', self.retire())
        self.assertFalse(self.base.exists())
        self.assertEqual((self.root / 'series-base-linux-x64.156.0.8078.79/value').read_text(), 'base\n')

    def test_a_taken_name_gets_a_number_and_no_checkout_reads_as_unknown(self):
        self.captured(self.root / 'series-base-linux-x64.unknown')
        self.captured()
        self.retire()
        self.assertFalse(self.base.exists())
        self.assertTrue((self.root / 'series-base-linux-x64.unknown.1/value').is_file())

    def test_no_base_is_a_no_op(self):
        self.checkout('156.0.8078.79')
        self.assertEqual(self.retire(), '')
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['src'])

    def test_usage_and_sync_wiring(self):
        self.assertIn('retire-series-base.sh SRC BASE VERSION', subprocess.run([str(BUILD / 'retire-series-base.sh'), '--help'], text=True, capture_output=True, check=True).stdout)
        self.assertEqual(subprocess.run([str(BUILD / 'retire-series-base.sh')], capture_output=True).returncode, 64)
        sync = (BUILD / '01-sync.sh').read_text()
        self.assertLess(sync.index('retire-series-base.sh'), sync.index('gclient sync'))
        self.assertLess(sync.index('retire-series-base.sh'), sync.index('git -C src fetch'))

class TargetTests(unittest.TestCase):
    def test_mac_defaults(self):
        config = target.configuration('mac', env={})
        self.assertEqual((config['AC_TARGET_CPU'], config['GN_OUT_CONFIGS'], config['AC_CHROMIUM_TARGET']), ('arm64', 'Release_GN_arm64', 'chrome_framework'))

    def test_linux_architectures_and_reject_traversal(self):
        for cpu in ('x64', 'arm64'):
            config = target.configuration('linux', cpu, {})
            self.assertEqual(config['GN_OUT_CONFIGS'], f'Release_GN_linux_{cpu}')
            self.assertEqual(config['AC_CHROMIUM_TARGET'], 'chrome chrome_sandbox')
        for value in ('../Release', 'a/b', '..', '/tmp/out', 'out;touch'):
            with self.assertRaises(ValueError):
                target.configuration('linux', 'x64', {'GN_OUT_CONFIGS': value})

    def test_shell_flags(self):
        for platform in ('mac', 'linux'):
            result = subprocess.run(['bash', '-c', 'source "$1/env.sh"; source "$1/gn_defines.sh"; printf "%s\\n" "${_gn_args[@]}"', 'bash', str(BUILD)], env=dict(os.environ, AC_TARGET_OS=platform, AC_TARGET_CPU='x64'), text=True, capture_output=True, check=True)
            self.assertIn('target_cpu="x64"', result.stdout)
            self.assertIn(f'target_os="{platform}"', result.stdout)
            self.assertIn('enable_cdm_host_verification=' + ('false' if platform == 'linux' else 'true'), result.stdout)
            for flag in ('enable_cdm_storage_id', 'enable_rlz'):
                assignments = [line for line in result.stdout.splitlines() if line.startswith(flag + '=')]
                self.assertEqual(assignments, [flag + '=' + ('false' if platform == 'linux' else 'true')])
            self.assertIn('enable_widevine=true', result.stdout)
            self.assertIn('proprietary_codecs=true', result.stdout)
            if platform == 'mac':
                self.assertIn('alternate_cdm_storage_id_key="968b476909da4373b08903c28e859454"', result.stdout)
            self.assertEqual('use_vaapi=true' in result.stdout, platform == 'linux')

    def test_linux_layer_materializes_launch_target_and_detects_drift(self):
        layer = REPO / 'engine/raycore-linux'
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            env = dict(os.environ, CHROMIUM_SRC=str(root))
            def apply(*args):
                return subprocess.run([str(layer / 'apply.sh'), *args], env=env, text=True, capture_output=True)
            for path in LINUX_LOGOS:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_bytes(b'helium logo\n')
            result = apply()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path, directory in series.layer_paths(str(layer)):
                self.assertTrue((root / path).is_dir() if directory else (root / path).is_file(), path)
            self.assertEqual(apply('--check').returncode, 0)
            for path in ('ray/core/BUILD.gn', 'ray/core/ac_launch_switches.h', 'ray/core/ac_launch_switches_linux.cc', 'ray/linux/ac_linux_launch_config.h'):
                original = (root / path).read_bytes()
                (root / path).write_text('drift\n')
                self.assertNotEqual(apply('--check').returncode, 0, path)
                self.assertEqual(apply().returncode, 0)
                self.assertEqual((root / path).read_bytes(), original)
            self.assertEqual((root / 'ray/core/ac_launch_switches.h').read_bytes(), (REPO / 'engine/raycore/src/ray/core/ac_launch_switches.h').read_bytes())
            build = (root / 'ray/core/BUILD.gn').read_text()
            self.assertIn('assert(is_linux)', build)
            self.assertNotIn('frameworks', build)
            self.assertNotIn('//ray/linux"', build)

    def test_linux_layer_replaces_helium_window_logos_with_ray(self):
        layer = REPO / 'engine/raycore-linux'
        self.assertLessEqual(set(LINUX_LOGOS), {path for path, directory in series.layer_paths(str(layer)) if not directory})
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            env = dict(os.environ, CHROMIUM_SRC=str(root))
            def apply(*args):
                return subprocess.run([str(layer / 'apply.sh'), *args], env=env, text=True, capture_output=True)
            for path in LINUX_LOGOS:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_bytes(b'helium logo\n')
            result = apply()
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path, source in LINUX_LOGOS.items():
                self.assertEqual((root / path).read_bytes(), source.read_bytes(), path)
            result = apply('--check')
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for path in LINUX_LOGOS:
                original = (root / path).read_bytes()
                (root / path).write_bytes(b'helium logo\n')
                self.assertIn(f'drift: {path}', apply('--check').stderr)
                (root / path).unlink()
                self.assertIn(f'drift: {path}', apply('--check').stderr)
                untouched = [other for other in LINUX_LOGOS if other != path]
                for other in untouched:
                    (root / other).write_bytes(b'helium logo\n')
                result = apply()
                self.assertNotEqual(result.returncode, 0, path)
                self.assertIn(f"{path} isn't in the tree", result.stderr)
                self.assertFalse((root / path).exists(), path)
                for other in untouched:
                    self.assertEqual((root / other).read_bytes(), b'helium logo\n', other)
                (root / path).write_bytes(original)
                result = apply()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                result = apply('--check')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class SeriesFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.repo = self.root / 'repo'
        self.here = self.repo / 'engine/patches'
        (self.here / 'build').mkdir(parents=True)
        shutil.copy2(BUILD.parent / 'series.py', self.here / 'series.py')
        for name in ('pathguard.py', 'target_config.py'):
            shutil.copy2(BUILD / name, self.here / 'build' / name)
        guard = self.here / 'build/pathguard.py'
        guard.write_text(guard.read_text().replace("return os.path.realpath(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, 'chromium-build'))", f'return {str(self.root / "protected-unused")!r}'))
        game = self.here / 'build/game-resource.sh'
        game.write_text('#!/usr/bin/env bash\nexit 0\n')
        game.chmod(0o755)
        for platform in ('mac', 'linux'):
            patch = self.here / f'{platform}.patch'
            patch.write_text(f'--- a/value\n+++ b/value\n@@ -1 +1 @@\n-base\n+{platform}\n')
            layer = self.repo / f'engine/{platform}'
            (layer / 'src/owned').mkdir(parents=True)
            (layer / 'src/owned/name').write_text(platform)
            script = layer / 'apply.sh'
            script.write_text('''#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in --paths) printf '%s\\n' shared/external.h; exit 0 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
src=$CHROMIUM_SRC
mkdir -p "$src/owned" "$src/shared"
cp "$here/src/owned/name" "$src/owned/name"
cp "$here/../external.h" "$src/shared/external.h"
''')
            script.chmod(0o755)
        (self.repo / 'engine/external.h').write_text('replacement header\n')
        (self.here / 'series').write_text('chromium mac.patch mac\nchromium linux.patch linux\nlayer engine/mac mac\nlayer engine/linux linux\n')
        self.tree = self.root / 'tree'
        self.tree.mkdir()
        (self.tree / 'value').write_text('base\n')
        (self.tree / 'shared').mkdir()
        (self.tree / 'shared/external.h').write_text('original header\n')
        self.base = self.root / 'base'
        self.env = dict(os.environ, CHROMIUM_SRC=str(self.tree), AC_SERIES_BASE=str(self.base), AC_CHROMIUM_BUILD=str(self.root / 'build'))

    def tearDown(self):
        self.temp.cleanup()

    def run_command(self, command, *args, platform='linux', success=True):
        result = subprocess.run([sys.executable, str(self.here / 'series.py'), command, '--platform', platform, '--cpu', 'x64', *map(str, args)], env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_every_command_selects_linux_and_reapplies_cleanly(self):
        files = self.run_command('files')
        self.assertNotIn('mac.patch:', files.stdout)
        self.run_command('capture-base')
        self.assertEqual((self.base / 'value').read_text(), 'base\n')
        self.assertEqual((self.base / 'shared/external.h').read_text(), 'original header\n')
        self.run_command('apply')
        self.run_command('apply')
        self.assertEqual((self.tree / 'value').read_text(), 'linux\n')
        self.assertEqual((self.tree / 'owned/name').read_text(), 'linux')
        self.assertEqual((self.tree / 'shared/external.h').read_text(), 'replacement header\n')
        self.run_command('check')
        (self.tree / 'shared/external.h').write_text('header drift\n')
        self.run_command('check', success=False)
        self.run_command('apply')
        materialized = self.root / 'materialized'
        self.run_command('materialize', '--until', 'linux.patch', materialized)
        self.assertEqual((materialized / 'value').read_text(), 'linux\n')
        self.assertEqual((materialized / 'shared/external.h').read_text(), 'original header\n')
        full = self.root / 'materialized-layer'
        self.run_command('materialize', '--until', 'engine/linux', full)
        self.assertEqual((full / 'shared/external.h').read_text(), 'replacement header\n')
        self.run_command('materialize', '--until', 'mac.patch', self.root / 'inactive', success=False)
        (self.tree / 'value').write_text('drift\n')
        self.run_command('check', success=False)

    def test_mac_selection_and_separate_default_base(self):
        self.run_command('capture-base', platform='mac')
        self.run_command('apply', platform='mac')
        self.run_command('check', platform='mac')
        self.assertEqual((self.tree / 'value').read_text(), 'mac\n')
        env = dict(self.env)
        env.pop('AC_SERIES_BASE')
        result = subprocess.run([sys.executable, str(self.here / 'series.py'), 'check', '--platform', 'linux', '--cpu', 'arm64'], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('series-base-linux-arm64', result.stderr)

    def test_base_cannot_be_reused_for_another_platform(self):
        self.run_command('capture-base')
        result = self.run_command('capture-base', platform='mac', success=False)
        self.assertIn('use a separate base', result.stderr)

    def test_unknown_selector_is_rejected(self):
        with (self.here / 'series').open('a') as stream:
            stream.write('chromium linux.patch windows\n')
        self.run_command('files', success=False)


class HeliumTests(unittest.TestCase):
    def test_linux_skips_have_no_macos_requirements(self):
        skips = helium.platform_skips('linux')
        self.assertFalse(any('/macos/' in name for name in skips))
        self.assertIn('helium/linux/rename-chrome-binary.patch', skips)
        self.assertIn('helium/linux/change-chromium-branding.patch', skips)
        self.assertIn('helium/macos/change-keychain-name.patch', helium.platform_skips('mac'))

    def test_linux_icon_generation_never_calls_sips(self):
        with mock.patch.object(helium.shutil, 'which', side_effect=lambda name: '/usr/bin/' + name if name in ('sips', 'magick') else None), mock.patch.object(helium.subprocess, 'run', return_value=argparse.Namespace(returncode=0)) as run:
            helium.resize_icon(pathlib.Path('input.png'), pathlib.Path('output.png'), 48, 'linux')
        self.assertEqual(run.call_args.args[0][0], 'magick')

    def test_pin_stage_requires_current_tree_and_actual_matching_submodule(self):
        pins = helium.pins()
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            (root / 'chrome').mkdir()
            (root / 'chromium_version.txt').write_text(pins['chromium']['version'])
            (root / 'deps.ini').write_text('')
            version = root / 'chrome/VERSION'
            def write_version(text):
                version.write_text(''.join(f'{key}={value}\n' for key, value in zip(('MAJOR', 'MINOR', 'BUILD', 'PATCH'), text.split('.'))))
            ctx = argparse.Namespace(hc=root, hm=root / 'linux', tree=root, platform='linux', platform_repo='helium-linux')
            def git(repo, *args):
                section = 'helium-chromium' if repo == ctx.hc else 'helium-linux'
                if args[:3] == ('rev-parse', '--verify', '-q'):
                    return argparse.Namespace(stdout=args[3].split(':', 1)[1] + '-tree', returncode=0)
                out = pins[section]['commit'] if args == ('rev-parse', 'HEAD') else '160000 commit ' + pins['helium-linux']['helium_chromium_commit'] + '\thelium-chromium' if args[0] == 'ls-tree' else ''
                return argparse.Namespace(stdout=out, returncode=0)
            with mock.patch.object(helium, 'git', side_effect=git), mock.patch.dict(os.environ, CHROMIUM_VERSION=pins['chromium']['version']):
                write_version(pins['chromium']['version'])
                helium.stage_pins(ctx)
                write_version('155.0.8059.84')
                with self.assertRaisesRegex(helium.StageError, 'the tree is Chromium 155'):
                    helium.stage_pins(ctx)
                write_version(pins['chromium']['version'])
                with mock.patch.object(helium, 'git', side_effect=lambda repo, *args: argparse.Namespace(stdout='160000 commit mismatched\thelium-chromium', returncode=0) if args[0] == 'ls-tree' else git(repo, *args)):
                    with self.assertRaisesRegex(helium.StageError, 'submodule does not match'):
                        helium.stage_pins(ctx)


class PackagingTests(unittest.TestCase):
    def test_packaged_ui_sits_beside_binary_and_runtime_files_survive(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = root / 'out', root / 'ui'
            output.mkdir()
            ui.mkdir()
            for name in packaging.REQUIRED:
                if name == 'locales':
                    (output / name).mkdir()
                    (output / name / 'en-US.pak').write_bytes(b'locale')
                else:
                    (output / name).write_bytes(b'runtime')
            (output / 'chrome').chmod(0o755)
            (output / 'libEGL.so').write_bytes(b'library')
            (ui / 'index.html').write_text('<html></html>')
            archive = packaging.package(output, ui, root / 'ray.tar.xz')
            with tarfile.open(archive) as packed:
                self.assertIn('ray/lib/ray/ray-ui/index.html', packed.getnames())
                self.assertIn('ray/lib/ray/libEGL.so', packed.getnames())
                self.assertNotIn('--no-sandbox', packed.extractfile('ray/bin/ray').read().decode())
                policy = packed.extractfile('ray/share/polkit-1/actions/dev.ray.linux.policy').read().decode()
                self.assertIn('<action id="dev.ray.linux.reauthenticate">', policy)
                self.assertIn('<allow_active>auth_self</allow_active>', policy)
                self.assertIn('<allow_any>no</allow_any>', policy)
                start = policy.index('<action id="dev.ray.linux.update">')
                update = policy[start:policy.index('</action>', start)]
                self.assertIn('<allow_active>yes</allow_active>', update)
                self.assertIn('<allow_inactive>auth_self</allow_inactive>', update)
                self.assertIn('<allow_any>auth_self</allow_any>', update)
                self.assertNotIn('auth_self_keep', policy)
                self.assertNotIn('<!--', policy)
            with self.assertRaises(ValueError):
                packaging.package(output, ui, archive)

    def test_content_blocker_ships_beside_the_binary_with_its_bridge_page(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui, ubo = root / 'out', root / 'ui', root / 'ubo'
            output.mkdir()
            ui.mkdir()
            (ubo / 'js').mkdir(parents=True)
            (ubo / '_metadata').mkdir()
            (ubo / '_metadata/verified_contents.json').write_text('{}')
            for name in packaging.REQUIRED:
                if name == 'locales':
                    (output / name).mkdir()
                else:
                    (output / name).write_bytes(b'runtime')
            (output / 'chrome').chmod(0o755)
            (ui / 'index.html').write_text('<html></html>')
            for name in packaging.BRIDGE_SCRIPTS:
                (ubo / name).write_text('')
            (ubo / 'manifest.json').write_text('{"manifest_version": 2, "key": "k", "version": "1.75.0.22"}')
            archive = packaging.package(output, ui, root / 'ray.tar.xz', ubo)
            with tarfile.open(archive) as packed:
                names = packed.getnames()
                for name in ['manifest.json', 'js/vapi-client.js', 'ray-linux-bridge.html', 'ray-linux-bridge.js']:
                    self.assertIn(f'ray/lib/ray/extensions/ublock/{name}', names)
                self.assertFalse(any('_metadata' in name for name in names))
                bridge = packed.extractfile('ray/lib/ray/extensions/ublock/ray-linux-bridge.js').read()
                self.assertEqual(bridge, (packaging.BRIDGE / 'ray-linux-bridge.js').read_bytes())
            (ubo / 'js/vapi-client.js').unlink()
            with self.assertRaisesRegex(ValueError, 'vapi-client'):
                packaging.package(output, ui, root / 'missing.tar.xz', ubo)
            (ubo / 'js/vapi-client.js').write_text('')
            (ubo / 'manifest.json').write_text('{"manifest_version": 3}')
            with self.assertRaisesRegex(ValueError, 'keyed uBlock Origin'):
                packaging.package(output, ui, root / 'unkeyed.tar.xz', ubo)

    def fake_package(self, root, sandbox=False, **formats):
        output, ui = root / 'out', root / 'ui'
        output.mkdir()
        ui.mkdir()
        if sandbox:
            (output / 'chrome_sandbox').write_bytes(b'helper')
            (output / 'chrome_sandbox').chmod(0o755)
        for name in packaging.REQUIRED:
            if name == 'locales':
                (output / name).mkdir()
                (output / name / 'en-US.pak').write_bytes(b'locale')
            else:
                (output / name).write_bytes(b'runtime')
        (output / 'chrome').chmod(0o755)
        (ui / 'index.html').write_text('<html></html>')
        archive = packaging.package(output, ui, root / 'ray.tar.xz', version=formats.get('version'), deb=formats.get('deb'), appimage=formats.get('appimage'))
        extracted = root / 'extracted'
        with tarfile.open(archive) as packed:
            self.assertIn('ray/install.sh', packed.getnames())
            self.assertTrue(packed.getmember('ray/install.sh').mode & 0o111)
            packed.extractall(extracted, filter='tar')
        return archive, extracted / 'ray'

    def test_installer_puts_the_polkit_policy_where_polkit_reads_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            _, package_root = self.fake_package(root)
            installer = package_root / 'install.sh'
            usage = subprocess.run([str(installer), '--help'], capture_output=True, text=True, timeout=30)
            self.assertEqual(usage.returncode, 0, usage.stderr)
            self.assertIn('/usr/share/polkit-1/actions', usage.stdout)
            for prefix in ['/usr', '/opt/ray', '/usr/local']:
                destdir = root / ('dest' + prefix.replace('/', '-'))
                result = subprocess.run([str(installer), '--prefix', prefix, '--destdir', str(destdir)],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                policy = destdir / 'usr/share/polkit-1/actions/dev.ray.linux.policy'
                source_policy = (REPO / 'scripts/linux/dev.ray.linux.policy').read_text()
                self.assertIn('>/usr/lib/ray/ray-update<', source_policy)
                if prefix == '/usr':
                    self.assertEqual(policy.read_text(), source_policy)
                else:
                    self.assertNotIn('dev.ray.linux.update', policy.read_text())
                    self.assertIn('<action id="dev.ray.linux.reauthenticate">', policy.read_text())
                self.assertEqual(policy.stat().st_mode & 0o777, 0o644)
                installed = destdir / prefix.lstrip('/')
                self.assertEqual(oct((installed / 'lib/ray/ray-update').stat().st_mode & 0o777), oct(0o755))
                self.assertEqual(oct((installed / 'lib/ray/linux-update.pem').stat().st_mode & 0o777), oct(0o644))
                self.assertEqual([path.name for path in (installed / 'lib').iterdir()], ['ray'])
                self.assertTrue((installed / 'lib/ray/chrome').is_file())
                self.assertTrue(os.access(installed / 'lib/ray/chrome', os.X_OK))
                self.assertTrue((installed / 'lib/ray/ray-ui/index.html').is_file())
                launcher = (installed / 'bin/ray').read_text()
                self.assertIn(f'exec "{prefix}/lib/ray/ray-launch" "$@"', launcher)
                self.assertTrue(os.access(installed / 'lib/ray/ray-launch', os.X_OK))
                self.assertNotIn(str(destdir), launcher)
                self.assertTrue(os.access(installed / 'bin/ray', os.X_OK))
                desktop = (installed / 'share/applications/ray.desktop').read_text()
                self.assertIn(f'Exec={prefix}/bin/ray %U', desktop)
                self.assertFalse((installed / 'install.sh').exists())
                self.assertFalse((installed / 'share/polkit-1').exists() and prefix != '/usr')
                self.assertFalse((destdir / 'etc').exists())
            for bad in ['relative', '/opt/a|b', '/opt/a&b', '/opt/a b']:
                refused = subprocess.run([str(installer), '--prefix', bad, '--destdir', str(root / 'refused')],
                                         capture_output=True, text=True, timeout=30)
                self.assertNotEqual(refused.returncode, 0, bad)
                self.assertFalse((root / 'refused').exists(), bad)

    def test_package_modes_do_not_follow_the_builders_umask(self):
        with tempfile.TemporaryDirectory() as scratch:
            previous = os.umask(0o002)
            try:
                archive, _ = self.fake_package(pathlib.Path(scratch))
            finally:
                os.umask(previous)
            with tarfile.open(archive) as packed:
                modes = {member.name: member.mode & 0o7777 for member in packed.getmembers() if not member.issym()}
            self.assertEqual({name: oct(mode) for name, mode in modes.items() if mode not in (0o644, 0o755)}, {})
            self.assertEqual(modes['ray/lib/ray/ray-ui/index.html'], 0o644)
            self.assertEqual(modes['ray/lib/ray/ray-ui'], 0o755)
            self.assertEqual(modes['ray/lib/ray/chrome'], 0o755)
            self.assertEqual(modes['ray/install.sh'], 0o755)

    @unittest.skipUnless(shutil.which('fakeroot'), 'fakeroot is required')
    def test_root_install_owns_every_file_as_root_whoever_unpacked_the_package(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            _, package_root = self.fake_package(root)
            destdir = root / 'dest'
            script = 'set -e; chown -R 1000:1000 "$1"; "$1/install.sh" --prefix /usr --destdir "$2"; find "$2" -printf "%U:%G %p\\n"'
            result = subprocess.run(['fakeroot', 'bash', '-c', script, 'install', str(package_root), str(destdir)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            owners = [line for line in result.stdout.splitlines() if line.strip()]
            self.assertTrue(any(line.endswith('/usr/lib/ray/chrome') for line in owners), owners)
            self.assertEqual([line for line in owners if not line.startswith('0:0 ')], [])

    def test_package_ships_an_apparmor_profile_that_lets_the_sandbox_create_user_namespaces(self):
        profile = REPO / 'scripts/linux/ray.apparmor'
        with tempfile.TemporaryDirectory() as scratch:
            _, package_root = self.fake_package(pathlib.Path(scratch))
            self.assertEqual((package_root / 'share/apparmor.d/ray').read_text(), profile.read_text())
        text = profile.read_text()
        self.assertIn('profile ray /usr/lib/ray/chrome flags=(unconfined) {\n', text)
        self.assertIn('  userns,\n', text)
        self.assertNotIn('#', text)
        parser = shutil.which('apparmor_parser')
        if parser and pathlib.Path('/etc/apparmor.d/abi/4.0').exists():
            parsed = subprocess.run([parser, '--skip-kernel-load', '--skip-cache', '--names', str(profile)],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual((parsed.returncode, parsed.stdout.strip()), (0, 'ray'), parsed.stderr)

    def test_installer_refuses_parent_segments_and_a_non_root_system_install_up_front(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            _, package_root = self.fake_package(root)
            installer = package_root / 'install.sh'
            for bad in ['/usr/../etc', '/opt/ray/..', '/../usr']:
                refused = subprocess.run([str(installer), '--prefix', bad, '--destdir', str(root / 'dotdot')],
                                         capture_output=True, text=True, timeout=30)
                self.assertNotEqual(refused.returncode, 0, bad)
                self.assertFalse((root / 'dotdot').exists(), bad)
            if os.geteuid() == 0:
                self.skipTest('the non-root refusal needs a non-root user')
            target = root / 'system'
            refused = subprocess.run([str(installer), '--prefix', str(target)], capture_output=True, text=True, timeout=30)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn('root', refused.stderr)
            self.assertFalse(target.exists())

    def test_the_package_ships_the_sandbox_helper_as_chrome_sandbox_and_starts_through_the_launcher(self):
        with tempfile.TemporaryDirectory() as scratch:
            archive, package_root = self.fake_package(pathlib.Path(scratch), sandbox=True)
            self.assertTrue((package_root / 'lib/ray/chrome-sandbox').is_file())
            self.assertFalse((package_root / 'lib/ray/chrome_sandbox').exists())
            self.assertEqual((package_root / 'lib/ray/ray-launch').read_bytes(), (REPO / 'scripts/linux/ray-launch').read_bytes())
            self.assertIn('exec "$ray_bin_dir/../lib/ray/ray-launch" "$@"', (package_root / 'bin/ray').read_text())
            with tarfile.open(archive) as packed:
                self.assertEqual(packed.getmember('ray/lib/ray/chrome-sandbox').mode & 0o7777, 0o755)

    def launcher_run(self, root, env, extra=()):
        runtime = root / 'lib/ray'
        runtime.mkdir(parents=True)
        shutil.copyfile(REPO / 'scripts/linux/ray-launch', runtime / 'ray-launch')
        (runtime / 'ray-launch').chmod(0o755)
        (runtime / 'chrome').write_text(env.get('chrome', '#!/usr/bin/env bash\nprintf "%s\\n" "$@"\n'))
        (runtime / 'chrome').chmod(0o755)
        proc = root / 'proc'
        for name, value in env.get('proc', {}).items():
            (proc / name).parent.mkdir(parents=True, exist_ok=True)
            (proc / name).write_text(value)
        script = (runtime / 'ray-launch').read_text().replace('/proc/sys/', f'{proc}/sys/').replace('/etc/apparmor.d/', f'{root}/apparmor.d/')
        (runtime / 'ray-launch').write_text(script)
        if env.get('profile'):
            (root / 'apparmor.d').mkdir()
            (root / 'apparmor.d/ray').write_text(env['profile'].replace('CHROME', str((runtime / 'chrome').resolve())))
        variables = {'PATH': os.environ['PATH'], **env.get('vars', {})}
        if 'APPIMAGE' in variables:
            variables.setdefault('APPDIR', str(root.resolve()))
        return subprocess.run([str(runtime / 'ray-launch'), '--marker', *extra], capture_output=True, text=True, timeout=30, env=variables)

    def test_the_launcher_keeps_the_sandbox_and_runs_without_it_only_when_asked(self):
        restricted = {'sys/kernel/apparmor_restrict_unprivileged_userns': '1'}
        cases = [
            ('user namespaces', {}, (), 0, ['--marker']),
            ('a profile grants userns', {'proc': restricted, 'profile': 'profile ray CHROME flags=(unconfined) {\n  userns,\n}\n'}, (), 0, ['--marker']),
            ('AppImage, restricted', {'proc': restricted, 'vars': {'APPIMAGE': '/tmp/Ray.AppImage'}}, (), 1, None),
            ('AppImage, clone off', {'proc': {'sys/kernel/unprivileged_userns_clone': '0'}, 'vars': {'APPIMAGE': '/tmp/Ray.AppImage'}}, (), 1, None),
            ('extracted, restricted', {'proc': restricted}, (), 1, None),
            ('namespaces off', {'proc': {'sys/user/max_user_namespaces': '0'}}, (), 1, None),
            ('asked', {'proc': restricted}, ('--no-sandbox',), 0, None),
            ('AppImage, asked', {'proc': restricted, 'vars': {'APPIMAGE': '/tmp/Ray.AppImage'}}, ('--no-sandbox',), 0, None),
            ('APPIMAGE without APPDIR', {'proc': restricted, 'vars': {'APPIMAGE': '/tmp/Ray.AppImage', 'APPDIR': ''}}, (), 1, None),
        ]
        for label, env, extra, code, expected in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as scratch:
                result = self.launcher_run(pathlib.Path(scratch), env, extra)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                lines = result.stdout.splitlines()
                if expected is not None:
                    self.assertEqual(lines, expected)
                if code == 1:
                    self.assertEqual(lines, [])
                    self.assertIn("can't start Chromium's sandbox", result.stderr)
                if label == 'APPIMAGE without APPDIR':
                    self.assertNotIn("Ray won't run without the sandbox", result.stderr)
                if label.startswith('AppImage') and code == 1:
                    self.assertIn("Ray won't run without the sandbox", result.stderr)
                    self.assertIn("Install Ray's .deb, which sets up the sandbox helper and its AppArmor profile", result.stderr)
                if label == 'AppImage, restricted':
                    self.assertIn('allow user namespaces with sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0.', result.stderr)
                if label == 'AppImage, clone off':
                    self.assertIn('allow user namespaces with sudo sysctl -w kernel.unprivileged_userns_clone=1.', result.stderr)
                if label in ('asked', 'AppImage, asked'):
                    self.assertEqual(lines, ['--ray-sandbox-decision=Ray was started with --no-sandbox', '--marker', '--no-sandbox'])

    def test_an_instance_with_its_own_user_data_dir_keeps_its_crash_dumps_there(self):
        cases = [
            ('default profile', (), {}, ''),
            ('own data dir', ('--user-data-dir=/scratch/one',), {}, '/scratch/one/Crash Reports'),
            ('last data dir wins', ('--user-data-dir=/scratch/one', '--user-data-dir=/scratch/two'), {}, '/scratch/two/Crash Reports'),
            ('no sandbox', ('--user-data-dir=/scratch/one', '--no-sandbox'), {}, '/scratch/one/Crash Reports'),
            ('chosen by the caller', ('--user-data-dir=/scratch/one',), {'BREAKPAD_DUMP_LOCATION': '/dumps'}, '/dumps'),
        ]
        for label, extra, variables, expected in cases:
            with self.subTest(label), tempfile.TemporaryDirectory() as scratch:
                root = pathlib.Path(scratch)
                result = self.launcher_run(root, {'vars': variables, 'chrome': '#!/usr/bin/env bash\nprintf "%s\\n" "${BREAKPAD_DUMP_LOCATION:-}"\n'}, extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [expected])

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb is required')
    def test_the_deb_installs_under_usr_with_a_setuid_helper_the_policy_and_the_apparmor_profile(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            deb = root / 'ray.deb'
            self.fake_package(root, sandbox=True, version='0.2.47-nightly.3', deb=deb)
            control = subprocess.run(['dpkg-deb', '-f', str(deb), 'Package', 'Version', 'Architecture'], capture_output=True, text=True, check=True).stdout
            self.assertEqual(control.split(), ['Package:', 'ray', 'Version:', '0.2.47~nightly.3', 'Architecture:', 'amd64'])
            listing = subprocess.run(['dpkg-deb', '-c', str(deb)], capture_output=True, text=True, check=True).stdout
            entries = {line.split()[-1] if '->' not in line else line.split()[-3]: line.split()[:2] for line in listing.splitlines()}
            self.assertEqual(entries['./usr/lib/ray/chrome-sandbox'], ['-rwsr-xr-x', 'root/root'])
            self.assertEqual(entries['./usr/lib/ray/chrome'], ['-rwxr-xr-x', 'root/root'])
            self.assertIn('./usr/share/polkit-1/actions/dev.ray.linux.policy', entries)
            self.assertIn('./usr/share/ray/apparmor/ray', entries)
            self.assertIn('./usr/bin/ray -> ../lib/ray/ray-launch', listing)
            unpacked = root / 'deb'
            subprocess.run(['dpkg-deb', '-x', str(deb), str(unpacked)], check=True)
            self.assertIn('Exec=/usr/bin/ray %U', (unpacked / 'usr/share/applications/ray.desktop').read_text())
            self.assertFalse((unpacked / 'usr/share/apparmor.d').exists())
            scripts = root / 'control'
            subprocess.run(['dpkg-deb', '-e', str(deb), str(scripts)], check=True)
            postinst = (scripts / 'postinst').read_text()
            self.assertIn('chmod 4755 "$helper"', postinst)
            self.assertIn('apparmor_parser -r /etc/apparmor.d/ray', postinst)
            self.assertIn('rm -f /etc/apparmor.d/ray', (scripts / 'postrm').read_text())
            self.assertIn('update-alternatives --install "/usr/bin/$name" "$name" /usr/bin/ray 100', postinst)
            self.assertIn('for name in x-www-browser gnome-www-browser', postinst)
            prerm = (scripts / 'prerm').read_text()
            self.assertIn('update-alternatives --remove "$name" /usr/bin/ray', prerm)
            self.assertIn('if [ "$1" = remove ]; then', prerm)
            self.assertNotIn('deconfigure', prerm)
            for rollback in ('abort-remove', 'abort-deconfigure', 'abort-upgrade'):
                self.assertIn(f'[ "$1" = {rollback} ]', postinst)
            fields = subprocess.run(['dpkg-deb', '-f', str(deb), 'Depends', 'Provides'], capture_output=True, text=True, check=True).stdout
            self.assertIn('Provides: www-browser', fields)
            for package in ('libc6 (>= 2.17)', 'libgtk-3-0t64 | libgtk-3-0', 'libsecret-1-0', 'xdg-utils', 'curl', 'openssl'):
                self.assertIn(package, fields)
            self.assertIn('Upstream-Name: Ray', (unpacked / 'usr/share/doc/ray/copyright').read_text())
            with gzip.open(unpacked / 'usr/share/doc/ray/changelog.gz', 'rt') as changelog:
                self.assertIn('ray (0.2.47~nightly.3) stable', changelog.read())
            sums = dict(reversed(line.split('  ', 1)) for line in (scripts / 'md5sums').read_text().splitlines())
            self.assertEqual(sums['usr/lib/ray/chrome'], hashlib.md5((unpacked / 'usr/lib/ray/chrome').read_bytes()).hexdigest())
            self.assertIn('usr/share/doc/ray/copyright', sums)
            self.assertFalse([name for name in sums if name.startswith('usr/bin/')])

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb is required')
    def test_a_deb_needs_a_version(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            with self.assertRaisesRegex(ValueError, 'needs --version'):
                self.fake_package(root, sandbox=True, deb=root / 'ray.deb')
            self.assertFalse((root / 'ray.tar.xz').exists())

    def test_the_appimage_carries_no_setuid_helper_runs_the_launcher_and_has_the_type_2_header(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            runtime = root / 'runtime'
            runtime.write_bytes(b'\x7fELF\x02\x01\x01\x00AI\x02' + bytes(500))
            built = {}
            def fake_mksquashfs(command, check, stdout):
                built['app'] = pathlib.Path(command[1])
                built['names'] = sorted(str(path.relative_to(built['app'])) for path in built['app'].rglob('*'))
                built['apprun'] = os.readlink(built['app'] / 'AppRun')
                built['desktop'] = (built['app'] / 'ray.desktop').read_text()
                pathlib.Path(command[2]).write_bytes(bytes(int(command[4])) + b'squashfs')
            with mock.patch.object(formats.subprocess, 'run', fake_mksquashfs):
                _, package_root = self.fake_package(root, sandbox=True)
                formats.build_appimage(package_root, root / 'Ray.AppImage', {'runtime': runtime, 'mksquashfs': root / 'mksquashfs'})
            self.assertEqual(built['apprun'], 'lib/ray/ray-launch')
            self.assertIn('Exec=AppRun %U', built['desktop'])
            self.assertNotIn('lib/ray/chrome-sandbox', built['names'])
            self.assertNotIn('install.sh', built['names'])
            self.assertIn('lib/ray/chrome', built['names'])
            image = (root / 'Ray.AppImage').read_bytes()
            self.assertEqual(image[8:11], b'AI\x02')
            self.assertTrue(image.endswith(b'squashfs'))
            self.assertTrue(os.access(root / 'Ray.AppImage', os.X_OK))

    def test_arch_package_installs_the_policy_through_the_installer(self):
        pkgbuild = (REPO / 'scripts/linux/arch/PKGBUILD').read_text()
        self.assertIn("'polkit'", pkgbuild)
        self.assertNotRegex(pkgbuild, r'(^|\s)#')
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            _, package_root = self.fake_package(root)
            srcdir, pkgdir = package_root.parent, root / 'pkg'
            pkgdir.mkdir()
            script = f'set -euo pipefail; source "$1"; srcdir="$2"; pkgdir="$3"; cd "$srcdir"; package'
            result = subprocess.run(['bash', '-c', script, 'pkgbuild', str(REPO / 'scripts/linux/arch/PKGBUILD'), str(srcdir), str(pkgdir)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((pkgdir / 'usr/share/polkit-1/actions/dev.ray.linux.policy').is_file())
            self.assertTrue((pkgdir / 'usr/bin/ray').is_file())
            self.assertTrue((pkgdir / 'usr/lib/ray/chrome').is_file())
        if shutil.which('makepkg'):
            with tempfile.TemporaryDirectory() as scratch:
                shutil.copy(REPO / 'scripts/linux/arch/PKGBUILD', scratch)
                info = subprocess.run(['makepkg', '--printsrcinfo'], cwd=scratch, capture_output=True, text=True, timeout=60)
                self.assertEqual(info.returncode, 0, info.stderr)
                self.assertIn('depends = polkit', info.stdout)


if __name__ == '__main__':
    unittest.main()
