import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class SwitcherKeysTests(unittest.TestCase):
    def test_keys_map_like_the_mac_and_windows_switchers(self):
        with tempfile.TemporaryDirectory(prefix='ray-switcher-keys-') as directory:
            binary = Path(directory) / 'switcher-keys'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/switcher_keys_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_a_bound_shortcut_pressed_in_the_switcher_reaches_it_before_being_held_back(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        pressed = host[host.index('bool ShellHostView::AcceleratorPressed('):host.index('TabBinding* ShellHostView::Binding(int id)')]
        capture = pressed[pressed.index('if (switcher_capture_) {'):pressed.index('if (command != "tabSwitcher") return true;')]
        self.assertIn('ray::linux_switcher::SwitcherKey(', capture)
        self.assertIn('accelerator.IsRepeat()', capture)
        self.assertIn('.Set("type", "switcherKey").Set("key", key)', capture)

    def test_the_close_key_is_the_one_the_shared_switcher_handles(self):
        self.assertIn('"close"', (LINUX / 'ac_linux_switcher_keys.h').read_text())
        self.assertIn('key: "escape" | "next" | "previous" | "close"', (REPO / 'packages/shell/src/lifecycle.ts').read_text())
        self.assertIn('if (e.type === "switcherKey" && e.key === "close") void closeSwitcherRow();',
                      (REPO / 'apps/browser/src/state/sidebar/effects.ts').read_text())
        self.assertIn('"ac_linux_switcher_keys.h",', (LINUX / 'BUILD.gn').read_text())


if __name__ == '__main__':
    unittest.main()
