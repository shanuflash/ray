import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]
FIXTURE = ROOT / 'tests/fixtures/page_state.h'


class AppearanceTests(unittest.TestCase):
    def test_the_three_modes_parse_and_the_call_is_advertised(self):
        with tempfile.TemporaryDirectory(prefix='ray-appearance-') as directory:
            header = Path(directory) / 'base/values.h'
            header.parent.mkdir(parents=True)
            header.write_text(f'#include "{FIXTURE}"\n')
            binary = Path(directory) / 'appearance'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', directory, '-I', str(SOURCE),
                            str(ROOT / 'tests/appearance_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_mode_becomes_chromiums_app_wide_color_scheme_override(self):
        glue = (LINUX / 'ac_linux_system.cc').read_text()
        self.assertIn('#include "ray/linux/ac_linux_appearance.h"', glue)
        invoke = glue[glue.index('void LinuxSystemInvoke('):]
        call = invoke[invoke.index('if (method == appearance::kSetAppearanceCall) {'):]
        call = call[:call.index('\n  }\n') + 4]
        self.assertIn('appearance::ParseAppearance(args[0].GetString())', call)
        self.assertIn('ui::NativeTheme::SetPreferredColorSchemeOverride(ColorSchemeOverride(*mode));', call)
        self.assertIn('return std::move(done).Run(true, base::Value());', call)
        override = glue[glue.index('std::optional<ui::NativeTheme::PreferredColorScheme> ColorSchemeOverride('):]
        override = override[:override.index('\n}\n')]
        self.assertIn('case appearance::Appearance::kDark:\n      return ui::NativeTheme::PreferredColorScheme::kDark;', override)
        self.assertIn('case appearance::Appearance::kLight:\n      return ui::NativeTheme::PreferredColorScheme::kLight;', override)
        self.assertIn('case appearance::Appearance::kAuto:\n      return std::nullopt;', override)
        self.assertIn('"ac_linux_appearance.h"', (LINUX / 'BUILD.gn').read_text())

    def test_the_host_answers_is_dark_from_the_same_native_theme(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('if (method == "RayShell.isDarkAppearance") {\n    return std::move(done).Run(true, base::Value(\n'
                      '        ui::NativeTheme::GetInstanceForNativeUi()->preferred_color_scheme() ==', host)
        self.assertIn('for (const char* capability : ray::linux_hardware::kHardwareCapabilities) capabilities.Append(capability);', host)


if __name__ == '__main__':
    unittest.main()
