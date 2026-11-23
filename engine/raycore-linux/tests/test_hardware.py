import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]
PATCHES = ROOT.parent / 'patches'
PATCH = PATCHES / 'chromium-linux-thin-scroll-bars.patch'
FIXTURE = ROOT / 'tests/fixtures/page_state.h'
THEME_SOURCE_157 = '''// static
size_t NativeTheme::UpdateNotificationDelayScoper::num_instances_ = 0;

// static
NativeTheme* NativeTheme::GetInstanceForNativeUi() {
  static base::NoDestructor<NativeUiTheme> s_native_theme;
  static bool initialized = false;
  if (!initialized) {
'''
THEME_SCROLLBAR_157 = '''}

bool NativeTheme::CalculateUseOverlayScrollbar() const {
  if (OsSettingsProviderSuppliesOverlayScrollbarPreference()) {
    return ShouldUseOverlayScrollbar(
        OsSettingsProvider::Get().PrefersOverlayScrollbars());
  }
  return use_overlay_scrollbar_;
}

}  // namespace ui
'''
THEME_HEADER_157 = '''  // underpinnings to the `OsSettingsProvider`, as well as replace
  // `NativeThemeObserver` with a `CallbackList`.
  void NotifyOnCaptionStyleUpdated();

  // Paints the provided `part`/`state`. This is largely a wrapper around
  // `PaintImpl()`.
  void Paint(
      cc::PaintCanvas* canvas,
'''


class HardwareTests(unittest.TestCase):
    def test_the_reply_has_the_macs_fields_with_bounded_honest_values(self):
        with tempfile.TemporaryDirectory(prefix='ray-hardware-') as directory:
            header = Path(directory) / 'base/values.h'
            header.parent.mkdir(parents=True)
            header.write_text(f'#include "{FIXTURE}"\n')
            binary = Path(directory) / 'hardware'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', directory, '-I', str(SOURCE),
                            str(ROOT / 'tests/hardware_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_fields_are_the_shared_type_and_the_macs_reply(self):
        shared = (REPO / 'packages/shell/src/app.ts').read_text()
        self.assertIn('export type HardwareInfo = {\n  chip: string;\n  gpu?: string;\n  memoryGB: number;\n  displays: number;\n'
                      '  maxScale: number;\n  hardwareDecode: { av1: boolean; vp9: boolean; hevc: boolean; h264: boolean };\n};', shared)
        mac = (REPO / 'packages/shell/ios/CrashReports.swift').read_text()
        core = (LINUX / 'ac_linux_hardware.h').read_text()
        for key in ('chip', 'memoryGB', 'hardwareDecode', 'gpu', 'displays', 'maxScale', 'av1', 'vp9', 'hevc', 'h264'):
            self.assertIn(f'"{key}"', mac)
            self.assertEqual(core.count(f'.Set("{key}",'), 1, key)
        self.assertIn('/ 1_073_741_824).rounded()', mac)
        self.assertIn('std::round(static_cast<double>(bytes) / 1073741824.0)', core)

    def test_the_values_come_from_chromium_and_the_cpu_name_is_read_off_the_ui_thread(self):
        glue = (LINUX / 'ac_linux_system.cc').read_text()
        chip = glue[glue.index('std::string ReadChip() {'):glue.index('void ReplyHardware(')]
        self.assertIn('base::ScopedBlockingCall blocking(FROM_HERE, base::BlockingType::MAY_BLOCK);', chip)
        self.assertIn('return base::SysInfo::CPUModelName();', chip)
        reply = glue[glue.index('void ReplyHardware('):glue.index('bool LinuxSystemInvokes(')]
        for line in ('base::SysInfo::AmountOfTotalPhysicalMemory().InBytes()', 'content::GpuDataManager::GetInstance()',
                     'manager->GetGPUInfo()', 'gpu_info.active_gpu().device_string, gpu_info.gl_renderer',
                     'gpu_info.video_decode_accelerator_supported_profiles', 'screen->GetNumDisplays()',
                     'attached.device_scale_factor()'):
            self.assertIn(line, reply)
        self.assertIn('Worker()->PostTaskAndReplyWithResult(FROM_HERE, base::BindOnce(&ReadChip),', glue)
        for name in ('kH264First', 'kVp9First', 'kHevcFirst', 'kAv1First', 'kHevcExtendedFirst'):
            self.assertIn(f'hardware::{name}', glue[glue.index('static_assert(gpu::H264PROFILE_BASELINE'):glue.index('std::string ReadChip() {')])

    def test_the_host_advertises_and_routes_both_calls(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('for (const char* capability : ray::linux_hardware::kHardwareCapabilities) capabilities.Append(capability);', host)
        core = (LINUX / 'ac_linux_hardware.h').read_text()
        self.assertIn('kHardwareCapabilities[] = {"RayApp.hardwareInfo", "RaySystem.setThinScrollBars",\n'
                      '                                                         "RayShell.setAppearance"};', core)
        glue = (LINUX / 'ac_linux_system.cc').read_text()
        invokes = glue[glue.index('bool LinuxSystemInvokes('):glue.index('void LinuxSystemInvoke(')]
        self.assertIn('hardware::kHardwareCapabilities', invokes)
        self.assertIn('"ac_linux_hardware.h"', (LINUX / 'BUILD.gn').read_text())
        capabilities = (REPO / 'apps/linux/src/hostCapabilities.ts').read_text()
        self.assertIn('thinScrollBars: has("RaySystem.setThinScrollBars")', capabilities)
        fallbacks = (REPO / 'apps/linux/src/appModuleFallbacks.ts').read_text()
        self.assertIn('if (hostSupports(`${name}.${method}`, host)) return undefined;', fallbacks)

    def test_thin_scroll_bars_take_one_boolean_and_go_through_the_native_theme(self):
        glue = (LINUX / 'ac_linux_system.cc').read_text()
        call = glue[glue.index('if (method == hardware::kThinScrollBarsCall) {'):]
        call = call[:call.index('const bool changing')]
        self.assertIn('if (args.size() != 1 || !args[0].is_bool()) {', call)
        self.assertIn('ui::NativeTheme::SetRayLinuxThinScrollBars(args[0].GetBool());', call)
        self.assertIn('return std::move(done).Run(true, base::Value());', call)
        self.assertIn('AsyncFunction("setThinScrollBars") { (thin: Bool) in ThinScrollBars.set(thin) }',
                      (REPO / 'packages/shell/ios/SystemModule.swift').read_text())

    def test_the_scroll_bar_patch_is_linux_only_and_follows_the_open_urls_patch(self):
        steps = [line.split() for line in (PATCHES / 'series').read_text().splitlines() if line.startswith('chromium ')]
        at = [step[1] for step in steps].index('chromium-linux-thin-scroll-bars.patch')
        self.assertEqual(steps[at], ['chromium', 'chromium-linux-thin-scroll-bars.patch', 'linux'])
        self.assertEqual(steps[at - 1][1], 'chromium-linux-open-urls.patch')
        self.assertEqual([step[1] for step in steps].count('chromium-linux-thin-scroll-bars.patch'), 1)

    def test_the_scroll_bar_patch_applies_to_the_chromium_157_native_theme(self):
        if shutil.which('git') is None:
            self.skipTest('git is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-thin-scroll-bars-') as directory:
            theme = Path(directory) / 'ui/native_theme'
            theme.mkdir(parents=True)
            (theme / 'native_theme.cc').write_text('\n' * 171 + THEME_SOURCE_157 + '\n' * 450 + THEME_SCROLLBAR_157)
            (theme / 'native_theme.h').write_text('\n' * 453 + THEME_HEADER_157)
            result = subprocess.run(['git', 'apply', '--whitespace=nowarn', str(PATCH)], cwd=directory,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            source = (theme / 'native_theme.cc').read_text()
            header = (theme / 'native_theme.h').read_text()
        self.assertIn('namespace {\nbool g_ray_linux_thin_scroll_bars = false;\n}\n\n// static\n'
                      'void NativeTheme::SetRayLinuxThinScrollBars(bool thin) {\n'
                      '  if (g_ray_linux_thin_scroll_bars == thin) {\n    return;\n  }\n'
                      '  g_ray_linux_thin_scroll_bars = thin;\n'
                      '  GetInstanceForNativeUi()->OnToolkitSettingsChanged(false);\n}\n', source)
        self.assertIn('    return ShouldUseOverlayScrollbar(\n        g_ray_linux_thin_scroll_bars ||\n'
                      '        OsSettingsProvider::Get().PrefersOverlayScrollbars());\n', source)
        self.assertIn('  void NotifyOnCaptionStyleUpdated();\n\n  static void SetRayLinuxThinScrollBars(bool thin);\n', header)


if __name__ == '__main__':
    unittest.main()
