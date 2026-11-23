#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[4]
LINUX = REPO / 'scripts/linux'
VERSION = '0.2.44-nightly.3'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


sys.dont_write_bytecode = True
packaging = module('packaging', LINUX / 'package.py')


def fake_engine(root):
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
    (ui / 'index.html').write_text('<html></html>')
    return output, ui


def fake_cli(directory, version=VERSION, platform='linux-x64', top=None, sidecar=True):
    directory.mkdir(parents=True, exist_ok=True)
    name = f'ray-cli-{version}-{platform}.tar.gz'
    top = top or f'ray-cli-{version}'
    tarball = directory / name
    with tarfile.open(tarball, 'w:gz') as packed:
        for member, body in ((f'{top}/bin/ray', b'#!/bin/sh\necho ray\n'), (f'{top}/python/README', b'python')):
            info = tarfile.TarInfo(member)
            info.size = len(body)
            info.mode = 0o755
            packed.addfile(info, io.BytesIO(body))
    if sidecar:
        digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
        (directory / (name + '.sha256')).write_text(f'{digest}  {name}\n')
    return tarball


class PackageVersionAndCliTests(unittest.TestCase):
    def test_release_package_carries_version_cli_installer_and_digest(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = fake_engine(root)
            tarball = fake_cli(root / 'cli')
            archive = packaging.package(output, ui, root / 'ray.tar.xz', version=VERSION, cli=tarball)
            with tarfile.open(archive) as packed:
                version = packed.getmember('ray/lib/ray/VERSION')
                self.assertEqual(packed.extractfile(version).read().decode(), VERSION + '\n')
                self.assertEqual(version.mode & 0o777, 0o644)
                installer = packed.getmember('ray/lib/ray/cli/ray-cli-install.sh')
                self.assertEqual(installer.mode & 0o777, 0o755)
                self.assertEqual(packed.extractfile(installer).read(), (REPO / 'apps/cli/install.sh').read_bytes())
                shipped = packed.getmember(f'ray/lib/ray/cli/{tarball.name}')
                self.assertEqual(shipped.mode & 0o777, 0o644)
                self.assertEqual(packed.extractfile(shipped).read(), tarball.read_bytes())
                digest = packed.extractfile('ray/lib/ray/cli/ray-cli.sha256').read().decode().split()
                self.assertEqual(digest, [hashlib.sha256(tarball.read_bytes()).hexdigest(), tarball.name])
                self.assertEqual(packed.getmember('ray/lib/ray/cli').mode & 0o777, 0o755)

    def test_dev_package_has_neither_version_nor_cli(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = fake_engine(root)
            archive = packaging.package(output, ui, root / 'dev.tar.xz')
            with tarfile.open(archive) as packed:
                names = packed.getnames()
            self.assertNotIn('ray/lib/ray/VERSION', names)
            self.assertFalse(any(name.startswith('ray/lib/ray/cli') for name in names))
            archive = packaging.package(output, ui, root / 'versioned.tar.xz', version='1.2.3')
            with tarfile.open(archive) as packed:
                self.assertEqual(packed.extractfile('ray/lib/ray/VERSION').read(), b'1.2.3\n')
                self.assertFalse(any(name.startswith('ray/lib/ray/cli') for name in packed.getnames()))

    def test_versions_follow_the_contract(self):
        for good in ('0.2.44', '0.2.44-nightly.3', '10.20.30-rc.1'):
            self.assertEqual(packaging.check_version(good), good)
        for bad in ('0.2', 'v0.2.44', '0.2.44-nightly', '0.2.44-Nightly.1', '0.2.44-nightly.1.2', '0.2.44\n', '', None):
            with self.assertRaises(ValueError):
                packaging.check_version(bad)

    def test_cli_tarball_must_match_version_platform_digest_and_layout(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = fake_engine(root)
            cases = {
                'other version': (fake_cli(root / 'a', version='0.2.43'), 'not ray-cli-0.2.44-nightly.3-linux-x64'),
                'mac tarball': (fake_cli(root / 'b', platform='macos-arm64'), 'linux-x64'),
                'stray top': (fake_cli(root / 'c', top='other'), 'outside ray-cli-0.2.44-nightly.3/'),
            }
            for label, (tarball, message) in cases.items():
                with self.subTest(label), self.assertRaisesRegex(ValueError, message):
                    packaging.package(output, ui, root / f'{label}.tar.xz', version=VERSION, cli=tarball)
            with self.assertRaisesRegex(ValueError, 'needs --version'):
                packaging.package(output, ui, root / 'unversioned.tar.xz', cli=fake_cli(root / 'd'))
            tampered = fake_cli(root / 'e')
            (root / 'e' / (tampered.name + '.sha256')).write_text('0' * 64 + '  ' + tampered.name + '\n')
            with self.assertRaisesRegex(ValueError, 'says'):
                packaging.package(output, ui, root / 'tampered.tar.xz', version=VERSION, cli=tampered)
            unchecked = fake_cli(root / 'f', sidecar=False)
            self.assertTrue(packaging.package(output, ui, root / 'unchecked.tar.xz', version=VERSION, cli=unchecked).is_file())
            self.assertFalse((root / 'other version.tar.xz').exists())

    def test_command_line_requires_version_with_cli(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = fake_engine(root)
            tarball = fake_cli(root / 'cli')
            base = [sys.executable, '-I', str(LINUX / 'package.py'), '--out', str(output), '--ui', str(ui)]
            refused = subprocess.run(base + ['--destination', str(root / 'a.tar.xz'), '--cli', str(tarball)], capture_output=True, text=True, timeout=60)
            self.assertEqual(refused.returncode, 2)
            self.assertIn('--cli needs --version', refused.stderr)
            bad = subprocess.run(base + ['--destination', str(root / 'b.tar.xz'), '--version', '1.2'], capture_output=True, text=True, timeout=60)
            self.assertEqual(bad.returncode, 2)
            self.assertIn('bad version', bad.stderr)
            made = subprocess.run(base + ['--destination', str(root / 'c.tar.xz'), '--version', VERSION, '--cli', str(tarball)], capture_output=True, text=True, timeout=120)
            self.assertEqual(made.returncode, 0, made.stderr)
            self.assertTrue((root / 'c.tar.xz').is_file())

    def test_system_install_carries_version_and_cli(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = pathlib.Path(scratch)
            output, ui = fake_engine(root)
            tarball = fake_cli(root / 'cli')
            archive = packaging.package(output, ui, root / 'ray.tar.xz', version=VERSION, cli=tarball)
            with tarfile.open(archive) as packed:
                packed.extractall(root / 'extracted', filter='tar')
            result = subprocess.run([str(root / 'extracted/ray/install.sh'), '--prefix', '/opt/ray', '--destdir', str(root / 'stage')],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            installed = root / 'stage/opt/ray/lib/ray'
            self.assertEqual((installed / 'VERSION').read_text(), VERSION + '\n')
            self.assertEqual((installed / 'cli/ray-cli-install.sh').stat().st_mode & 0o777, 0o755)
            self.assertEqual((installed / f'cli/{tarball.name}').read_bytes(), tarball.read_bytes())
            self.assertTrue((installed / 'cli/ray-cli.sha256').is_file())


class ArchPackageTests(unittest.TestCase):
    def source(self, pkgver):
        result = subprocess.run(['bash', '-c', 'source "$1" && pkgver=$2 && source <(grep "^source=" "$1") && printf "%s" "${source[0]}"',
                                 'bash', str(LINUX / 'arch/PKGBUILD'), pkgver], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_source_is_the_release_tarball_of_the_package_version(self):
        release = 'https://github.com/ray-browser/ray/releases/download'
        self.assertEqual(self.source('0.2.44nightly.3'), f'ray-bin-0.2.44nightly.3.tar.xz::{release}/v{VERSION}/Ray-{VERSION}-linux-x64.tar.xz')
        self.assertEqual(self.source('0.2.45'), f'ray-bin-0.2.45.tar.xz::{release}/v0.2.45/Ray-0.2.45-linux-x64.tar.xz')


@unittest.skipUnless(shutil.which('shasum'), 'shasum')
class PublishLinuxAssetsTests(unittest.TestCase):
    STABLE = '0.2.48'
    NAMES = ('Ray-{v}-linux-x64.tar.xz', 'Ray-{v}-linux-x64.deb', 'Ray-{v}-linux-x64.AppImage',
             'ray-bin-{v}.src.tar.gz', 'ray-cli-{v}-linux-x64.tar.gz')

    def linux_section(self):
        script = (REPO / '.claude/skills/release/scripts/publish.sh').read_text()
        return script[script.index('linux="$dist/linux"'):script.index('windows="$dist/windows"')]

    def publish(self, dist):
        script = 'die() { echo "error: $*" >&2; exit 1; }\nassets=()\n' + self.linux_section() + 'printf "asset %s\\n" "${assets[@]##*/}"\n'
        return subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=30,
                              env={**os.environ, 'dist': str(dist), 'version': self.STABLE}, cwd=dist)

    def assets(self, result):
        return {line.split(' ', 1)[1] for line in result.stdout.splitlines() if line.startswith('asset ')}

    def dist(self, scratch, provenance_extra=''):
        dist = pathlib.Path(scratch)
        linux = dist / 'linux'
        linux.mkdir()
        for template in self.NAMES:
            name = template.format(v=self.STABLE)
            (linux / name).write_bytes(name.encode())
            (linux / f'{name}.sha256').write_text(f'{hashlib.sha256(name.encode()).hexdigest()}  {name}\n')
        (linux / 'provenance.txt').write_text(f'engine key {"a" * 40} (exact), from /engine\n{provenance_extra}')
        return dist, linux

    def test_every_linux_asset_and_its_digest_join_the_release(self):
        with tempfile.TemporaryDirectory() as scratch:
            dist, _ = self.dist(scratch)
            result = self.publish(dist)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = {template.format(v=self.STABLE) + suffix for template in self.NAMES for suffix in ('', '.sha256')}
            self.assertEqual(self.assets(result), expected)

    def test_the_arch_source_package_is_required(self):
        with tempfile.TemporaryDirectory() as scratch:
            dist, linux = self.dist(scratch)
            (linux / f'ray-bin-{self.STABLE}.src.tar.gz').unlink()
            result = self.publish(dist)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f'has no ray-bin-{self.STABLE}.src.tar.gz', result.stderr)

    def test_a_missing_deb_fails_unless_the_release_dropped_it(self):
        with tempfile.TemporaryDirectory() as scratch:
            dist, linux = self.dist(scratch)
            (linux / f'Ray-{self.STABLE}-linux-x64.deb').unlink()
            (linux / f'Ray-{self.STABLE}-linux-x64.deb.sha256').unlink()
            result = self.publish(dist)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f'has no Ray-{self.STABLE}-linux-x64.deb', result.stderr)
            with (linux / 'provenance.txt').open('a') as provenance:
                provenance.write('deb dropped: it failed scripts/linux/deb-install-test.sh in run 1\n')
            result = self.publish(dist)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(f'Ray-{self.STABLE}-linux-x64.deb', self.assets(result))
            self.assertIn(f'Ray-{self.STABLE}-linux-x64.AppImage', self.assets(result))
            self.assertIn('ships without the .deb', result.stdout)

    def test_a_wrong_digest_fails(self):
        with tempfile.TemporaryDirectory() as scratch:
            dist, linux = self.dist(scratch)
            (linux / f'ray-bin-{self.STABLE}.src.tar.gz').write_bytes(b'changed')
            result = self.publish(dist)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("don't match their .sha256 files", result.stderr)


class ReleaseScriptTests(unittest.TestCase):
    def run_release(self, *args):
        return subprocess.run(['bash', str(LINUX / 'release.sh'), *args], capture_output=True, text=True, timeout=60, cwd=REPO)

    def test_help_and_argument_errors(self):
        usage = self.run_release('--help')
        self.assertEqual(usage.returncode, 0)
        for text in ('--engine exact', '--allow-dirty', 'gh release upload', 'dist/<version>/linux'):
            self.assertIn(text, usage.stdout)
        self.assertEqual(self.run_release().returncode, 64)
        self.assertEqual(self.run_release('0.2.44', '--bogus').returncode, 64)
        self.assertIn('neither a stable', self.run_release('0.2.44-rc.1').stderr)
        self.assertIn('MARKETING_VERSION', self.run_release('99.0.0').stderr)
        self.assertIn('needs exact, nearest or a directory', self.run_release('99.0.0', '--engine').stderr)

    def test_script_is_valid_bash_without_comments(self):
        source = (LINUX / 'release.sh').read_text()
        self.assertEqual(subprocess.run(['bash', '-n', str(LINUX / 'release.sh')]).returncode, 0)
        lines = [line.strip() for line in source.splitlines()[1:]]
        self.assertFalse([line for line in lines if line.startswith('#')])
        self.assertTrue(os.access(LINUX / 'release.sh', os.X_OK))


if __name__ == '__main__':
    unittest.main()
