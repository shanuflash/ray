#!/usr/bin/env python3
import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[4]
LINUX = REPO / 'scripts/linux'
ARCH = LINUX / 'arch'
ELF = pathlib.Path(shutil.which('true') or '/usr/bin/true')
DIGEST = 'ab' * 32

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('linux_formats', LINUX / 'linux_formats.py')
formats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formats)


def run(*args):
    return subprocess.run([str(arg) for arg in args], capture_output=True, text=True)


class DebVersionTests(unittest.TestCase):
    def test_a_nightly_sorts_before_its_stable(self):
        self.assertEqual(formats.deb_version('0.2.47'), '0.2.47')
        self.assertEqual(formats.deb_version('0.2.47-nightly.3'), '0.2.47~nightly.3')
        for bad in ('0.2', None):
            with self.assertRaisesRegex(ValueError, 'bad version'):
                formats.deb_version(bad)

    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg')
    def test_dpkg_upgrades_a_nightly_to_its_stable(self):
        def older(first, second):
            return run('dpkg', '--compare-versions', formats.deb_version(first), 'lt', formats.deb_version(second)).returncode == 0
        self.assertTrue(older('0.2.47-nightly.2', '0.2.47-nightly.10'))
        self.assertTrue(older('0.2.47-nightly.10', '0.2.47'))
        self.assertTrue(older('0.2.47', '0.2.48-nightly.1'))


@unittest.skipUnless(shutil.which('readelf') and ELF.is_file(), 'readelf and an ELF executable')
class DebDependsTests(unittest.TestCase):
    def runtime(self, scratch, needed):
        runtime = pathlib.Path(scratch) / 'usr/lib/ray'
        runtime.mkdir(parents=True)
        shutil.copyfile(ELF, runtime / 'chrome')
        shutil.copyfile(ELF, runtime / 'libqt6_shim.so')
        shutil.copyfile(ELF, runtime / 'libEGL.so')
        self.needed = needed
        return runtime

    def setUp(self):
        self.original = formats.needed_libraries
        formats.needed_libraries = lambda path: self.needed.get(path.name, [])

    def tearDown(self):
        formats.needed_libraries = self.original

    def test_sonames_map_to_packages_once_and_bundled_or_optional_ones_are_skipped(self):
        with tempfile.TemporaryDirectory() as scratch:
            runtime = self.runtime(scratch, {'chrome': ['libc.so.6', 'libnss3.so', 'libsmime3.so', 'libEGL.so', 'libgio-2.0.so.0', 'libglib-2.0.so.0']})
            packages = formats.deb_depends(runtime)
        self.assertRegex(packages[0], r'^libc6 \(>= 2\.[0-9]+\)$')
        self.assertEqual(packages.count('libnss3'), 1)
        self.assertEqual(packages.count('libglib2.0-0t64 | libglib2.0-0'), 1)
        self.assertIn('libgtk-3-0t64 | libgtk-3-0', packages)
        self.assertIn('libsecret-1-0', packages)
        self.assertIn('xdg-utils', packages)
        self.assertIn('curl', packages)
        self.assertFalse([package for package in packages if 'qt' in package.lower()])

    def test_an_unknown_soname_fails_the_build(self):
        with tempfile.TemporaryDirectory() as scratch:
            runtime = self.runtime(scratch, {'chrome': ['libc.so.6', 'libnew.so.1']})
            with self.assertRaisesRegex(ValueError, 'libnew.so.1'):
                formats.deb_depends(runtime)


class PkgbuildTests(unittest.TestCase):
    def test_committed_srcinfo_matches_the_pkgbuild(self):
        result = run(ARCH / 'update-pkgbuild.sh', '--check')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_update_pins_the_release_tarball(self):
        with tempfile.TemporaryDirectory() as scratch:
            result = run(ARCH / 'update-pkgbuild.sh', '0.2.48-nightly.1', '--sha256', DIGEST, '--out', scratch)
            self.assertEqual(result.returncode, 0, result.stderr)
            pkgbuild = (pathlib.Path(scratch) / 'PKGBUILD').read_text()
            srcinfo = (pathlib.Path(scratch) / '.SRCINFO').read_text()
        self.assertIn('pkgver=0.2.48nightly.1\n', pkgbuild)
        self.assertIn('pkgrel=1\n', pkgbuild)
        self.assertIn(f"sha256sums=('{DIGEST}')\n", pkgbuild)
        self.assertIn('\tpkgver = 0.2.48nightly.1\n', srcinfo)
        self.assertIn('\tsource = ray-bin-0.2.48nightly.1.tar.xz::https://github.com/ray-browser/ray/releases/download/'
                      'v0.2.48-nightly.1/Ray-0.2.48-nightly.1-linux-x64.tar.xz\n', srcinfo)
        self.assertIn(f'\tsha256sums = {DIGEST}\n', srcinfo)
        self.assertNotIn('SKIP', pkgbuild + srcinfo)

    @unittest.skipUnless(shutil.which('makepkg'), 'makepkg')
    def test_srcinfo_is_what_makepkg_prints(self):
        with tempfile.TemporaryDirectory() as scratch:
            run(ARCH / 'update-pkgbuild.sh', '0.2.48', '--sha256', DIGEST, '--out', scratch)
            printed = subprocess.run(['makepkg', '--printsrcinfo'], cwd=scratch, capture_output=True, text=True)
            self.assertEqual(printed.stdout, (pathlib.Path(scratch) / '.SRCINFO').read_text())

    @unittest.skipUnless(shutil.which('vercmp'), 'vercmp')
    def test_pacman_sorts_a_nightly_before_its_stable(self):
        def pkgver(version):
            with tempfile.TemporaryDirectory() as scratch:
                run(ARCH / 'update-pkgbuild.sh', version, '--sha256', DIGEST, '--out', scratch)
                return next(line.split('=', 1)[1] for line in (pathlib.Path(scratch) / 'PKGBUILD').read_text().splitlines() if line.startswith('pkgver='))
        ordered = [pkgver(version) for version in ('0.2.46', '0.2.47-nightly.2', '0.2.47-nightly.10', '0.2.47', '0.2.48-nightly.1')]
        for older, newer in zip(ordered, ordered[1:]):
            self.assertEqual(run('vercmp', older, newer).stdout.strip(), '-1', f'{older} < {newer}')

    def test_publish_refuses_to_move_back_and_orders_nightlies_before_stables(self):
        script = (ARCH / 'publish-aur.sh').read_text()
        order_key = script[script.index('order_key() {'):script.index('\n}\n', script.index('order_key() {')) + 3]
        def newest(*versions):
            keys = ' '.join(f'"$(order_key {version})"' for version in versions)
            result = subprocess.run(['bash', '-c', f'{order_key}printf "%s\\n" {keys} | sort -V | tail -1'], capture_output=True, text=True)
            return result.stdout.strip()
        self.assertEqual(newest('0.2.47nightly.2', '0.2.47'), '0.2.47.1.0')
        self.assertEqual(newest('0.2.47nightly.10', '0.2.47nightly.2'), '0.2.47.0.10')
        self.assertEqual(newest('0.2.48nightly.1', '0.2.47'), '0.2.48.0.1')

    def test_bad_input_is_refused(self):
        self.assertEqual(run(ARCH / 'update-pkgbuild.sh', '0.2', '--sha256', DIGEST).returncode, 1)
        self.assertEqual(run(ARCH / 'update-pkgbuild.sh', '0.2.48', '--sha256', 'SKIP').returncode, 1)
        self.assertEqual(run(ARCH / 'update-pkgbuild.sh', '0.2.48').returncode, 1)


if __name__ == '__main__':
    unittest.main()
