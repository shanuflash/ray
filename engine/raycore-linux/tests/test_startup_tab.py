import pathlib
import tempfile
import unittest

from support import VALUES, compile_and_run

ROOT = pathlib.Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'


class StartupTabTests(unittest.TestCase):
    def test_the_launch_windows_saved_active_tab_is_started_before_the_shell(self):
        with tempfile.TemporaryDirectory(prefix='ray-startup-tab-') as directory:
            include = pathlib.Path(directory) / 'include'
            (include / 'base').mkdir(parents=True)
            (include / 'base/values.h').write_text(VALUES)
            output = compile_and_run(self, 'startup-tab', [
                LINUX / 'ac_linux_startup_tab.cc', ROOT / 'tests/fixtures/startup_tab_scenarios.cc',
            ], extra_includes=[include])
        self.assertIn('startup tab scenarios passed', output)


if __name__ == '__main__':
    unittest.main()
