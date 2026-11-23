import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class DesktopCoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ray-desktop-core-')
        cls.binary = Path(cls.directory.name) / 'desktop-core'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                        str(ROOT / 'tests/desktop_core_test.cc'), '-o', str(cls.binary)],
                       check=True, text=True, timeout=180)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, scenario):
        with tempfile.TemporaryDirectory(prefix=f'ray-desktop-{scenario}-') as root:
            result = subprocess.run([str(self.binary), scenario, os.path.realpath(root)], text=True, timeout=60,
                                    capture_output=True, env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_desktop_entries_parse_strictly_and_exec_quoting_round_trips(self):
        self.run_case('entries')

    def test_the_installed_entry_must_start_this_copy_and_handle_web_links(self):
        self.run_case('installed')

    def test_default_browser_asks_xdg_settings_only_for_an_installed_copy_and_reports_what_it_says(self):
        self.run_case('default-browser')

    def test_launch_at_login_writes_reads_and_removes_the_autostart_entry_without_following_links(self):
        self.run_case('login')

    def test_external_links_refuse_schemes_that_run_or_read_local_content(self):
        self.run_case('schemes')

    def test_the_host_advertises_and_routes_the_system_calls(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('for (const char* capability : ray::linux_desktop::kSystemCapabilities) capabilities.Append(capability);', host)
        self.assertIn('if (raycore::LinuxSystemInvokes(method)) {\n    return raycore::LinuxSystemInvoke(method, values, std::move(done));', host)
        core = (LINUX / 'ac_linux_desktop_core.h').read_text()
        for name in ('RaySystem.isDefaultBrowser', 'RaySystem.setAsDefaultBrowser', 'RaySystem.launchAtLoginStatus',
                     'RaySystem.setLaunchAtLogin', 'RayApp.openExternalURL'):
            self.assertIn(f'"{name}"', core)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_desktop_core.cc', 'ac_linux_desktop_core.h', 'ac_linux_system.cc', 'ac_linux_system.h'):
            self.assertIn(f'"{name}"', build)

    def test_background_instances_never_run_a_tool_write_the_entry_or_open_an_app(self):
        glue = (LINUX / 'ac_linux_system.cc').read_text()
        invoke = glue[glue.index('void LinuxSystemInvoke('):]
        default_browser = invoke[invoke.index('"RaySystem.isDefaultBrowser"'):invoke.index('"RaySystem.launchAtLoginStatus"')]
        self.assertLess(default_browser.index('BackgroundInstance()'), default_browser.index('Worker()'))
        login = invoke[invoke.index('"RaySystem.setLaunchAtLogin"'):]
        self.assertLess(login.index('BackgroundInstance()'), login.index('Worker()'))
        external = glue[glue.index('void OpenExternalUrl('):glue.index('bool LinuxSystemInvokes(')]
        self.assertLess(external.index('ExternalSchemeAllowed'), external.index('BackgroundInstance()'))
        self.assertLess(external.index('BackgroundInstance()'), external.index('platform_util::OpenExternal(url)'))
        self.assertEqual(glue.count('platform_util::OpenExternal'), 1)
        self.assertNotIn('getenv', glue)
        self.assertNotIn('base/environment.h', glue)
        self.assertNotIn('getenv', (LINUX / 'ac_linux_desktop_core.cc').read_text())

    def test_the_packaged_desktop_entry_is_the_one_the_engine_looks_for(self):
        package = (REPO / 'scripts/linux/package.py').read_text()
        self.assertIn("'share/applications/ray.desktop'", package)
        for needed in ('Type=Application', 'Exec=ray %U', 'x-scheme-handler/http;', 'x-scheme-handler/https;'):
            self.assertIn(needed, package)
        install = (REPO / 'scripts/linux/install.sh').read_text()
        self.assertIn('s|^Exec=ray |Exec=$prefix/bin/ray |', install)
        self.assertIn('"$target/share/applications/ray.desktop"', install)


if __name__ == '__main__':
    unittest.main()
