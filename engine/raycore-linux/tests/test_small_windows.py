from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'
REPO = ROOT.parents[1]
PATCHES = ROOT.parent / 'patches'
PATCH = PATCHES / 'chromium-linux-window-minimum-size.patch'
BROWSER_VIEW = 'chrome/browser/ui/views/frame/browser_view.cc'
GLOBALS_157 = '''int (*g_ray_linux_window_tab_count)(const BrowserWindowInterface*) = nullptr;
bool (*g_ray_linux_shell_passes_point)(gfx::NativeView child,
                                         const gfx::Point& location) = nullptr;

namespace {

'''
MINIMUM_157 = '''
gfx::Size BrowserView::GetMinimumSize() const {
  auto* const layout = GetBrowserViewLayout();
  return layout ? layout->GetMinimumSize(this) : gfx::Size();
}

///////////////////////////////////////////////////////////////////////////////
// BrowserView, views::View overrides:
'''


class SmallWindowTests(unittest.TestCase):
    def setUp(self):
        self.host = (LINUX / 'ac_linux_host.cc').read_text()
        self.open = self.host[self.host.index('if (method == "RayShell.openWindow") {'):self.host.index('if (method == "RayShell.isDarkAppearance") {')]

    def test_the_minimum_and_the_default_size_are_the_macs(self):
        core = (LINUX / 'ac_linux_window_lifecycle.h').read_text()
        self.assertIn('kSmallWindowMinWidth = 420;', core)
        self.assertIn('kSmallWindowMinHeight = 300;', core)
        self.assertIn('kSmallWindowWidth = 900;', core)
        self.assertIn('kSmallWindowHeight = 640;', core)
        self.assertIn('kSmallWindowLargestShare = 0.8;', core)
        manager = (REPO / 'packages/shell/ios/WindowManager.swift').read_text()
        self.assertIn('window.minSize = NSSize(width: 420, height: 300)', manager)
        self.assertIn('static let smallDefaultSize = CGSize(width: 900, height: 640)', manager)
        self.assertIn('RayChromeWindowHost.littleFrame(for: size, minimumSize: window.minSize, visibleFrame: visible)', manager)
        self.assertNotIn('lift', manager)
        fit = (REPO / 'packages/raycore/ios/RayLittleFitMath.h').read_text()
        self.assertIn('kLargestShareOfScreen = 0.8;', fit)
        self.assertIn('std::round(visible * share)', fit)
        self.assertIn('size?: [number, number];', (REPO / 'packages/shell/src/windows.ts').read_text())

    def test_a_small_window_without_a_frame_opens_at_its_size_on_the_openers_display(self):
        frame = self.open.index('requested = linux_window::RequestedFrame(numbers, PrimaryScreenRect(), GlobalScreenCoordinates());')
        small = self.open.index('if (!utility && !requested && kind == linux_window::kSmallWindowKind) {')
        self.assertLess(frame, small)
        body = self.open[small:self.open.index('for (const auto& [native_id, host] : Hosts()) {', small)]
        self.assertIn('options->FindList("size")', body)
        self.assertIn('value.is_int() || value.is_double() ? value.GetDouble() : NAN', body)
        self.assertIn('requested = linux_window::RequestedSmallFrame(size, OpenerWorkArea(), GlobalScreenCoordinates());', body)
        area = self.host[self.host.index('linux_window::Rect ShellHostView::OpenerWorkArea() const {'):self.host.index('void ShellHostView::ReleaseStaleShellHover() {')]
        self.assertIn('screen->GetDisplayNearestWindow(widget->GetNativeWindow()).work_area()', area)

    def test_a_small_window_has_the_minimum_from_the_moment_it_is_one(self):
        self.assertIn('extern void (*g_ray_linux_minimum_size)(const BrowserWindowInterface*, gfx::Size* minimum);', self.host)
        hook = self.host[self.host.index('g_ray_linux_minimum_size = []('):self.host.index('g_ray_linux_unhandled_key = [](')]
        self.assertIn('Hosts().find(browser->GetSessionID().id())', hook)
        self.assertIn('found->second->MinimumSize(minimum);', hook)
        self.assertIn('if (small_ && !is_utility()) *minimum = gfx::Size(linux_window::kSmallWindowMinWidth, linux_window::kSmallWindowMinHeight);', self.host)
        setter = self.host[self.host.index('void set_small(bool small) {'):self.host.index('void MinimumSize(gfx::Size* minimum) const {')]
        self.assertLess(setter.index('small_ = small;'), setter.index('GetWidget()->OnSizeConstraintsChanged();'))
        self.assertIn('  if (small_ && !is_utility()) GetWidget()->OnSizeConstraintsChanged();\n  LayoutOverlay();', self.host)

    def test_the_bootstrap_names_the_window_kind_and_carries_the_openers_seed(self):
        bootstrap = self.host[self.host.index('base::DictValue ShellHostView::Bootstrap() const {'):self.host.index('void ShellHostView::LayoutOverlay()')]
        self.assertIn('bootstrap.Set("windowKind", WindowKind());', bootstrap)
        self.assertIn('if (small_ && !small_window_.empty()) bootstrap.Set("smallWindow", small_window_.Clone());', bootstrap)
        self.assertIn('return is_utility() ? kind_.c_str() : small_ ? linux_window::kSmallWindowKind : linux_window::kBrowserWindowKind;', self.host)
        seed = self.open[self.open.index('const base::DictValue* small_window ='):]
        seed = seed[:seed.index('const std::string* behind')]
        self.assertIn('kind == linux_window::kSmallWindowKind && options ? options->FindDict("smallWindow") : nullptr', seed)
        self.assertIn('if (small_window && (incognito || !small_json || small_json->size() > kPrivateWindowLimit)) {', seed)
        self.assertIn('if (small_window) opening.small_window = small_window->Clone();', self.open)
        self.assertIn('request.small_window = std::move(opening.small_window);', self.host)
        self.assertIn('small_window_ = std::move(request.small_window);', self.host)

    def test_browser_windows_advertise_it(self):
        self.assertIn('  if (!is_utility()) {\n    for (const char* capability : ray::linux_window::kSmallWindowCapabilities) capabilities.Append(capability);\n  }', self.host)
        self.assertIn('kSmallWindowCapabilities[] = {"RayShell.smallWindows"}', (LINUX / 'ac_linux_window_lifecycle.h').read_text())

    def test_the_minimum_size_patch_is_linux_only_and_last_in_the_series(self):
        steps = [line.split() for line in (PATCHES / 'series').read_text().splitlines() if line.startswith('chromium ')]
        names = [step[1] for step in steps]
        at = names.index('chromium-linux-window-minimum-size.patch')
        self.assertEqual(steps[at], ['chromium', 'chromium-linux-window-minimum-size.patch', 'linux'])
        self.assertGreater(at, names.index('chromium-linux-shell-above-input.patch'))
        self.assertGreater(at, names.index('chromium-linux-unhandled-key.patch'))
        self.assertEqual(names.count('chromium-linux-window-minimum-size.patch'), 1)

    def test_the_minimum_size_patch_applies_to_the_chromium_157_browser_view(self):
        if shutil.which('git') is None:
            self.skipTest('git is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-window-minimum-') as directory:
            target = Path(directory) / BROWSER_VIEW
            target.parent.mkdir(parents=True)
            target.write_text('\n' * 442 + GLOBALS_157 + '\n' * 5190 + MINIMUM_157)
            result = subprocess.run(['git', 'apply', '--whitespace=nowarn', str(PATCH)], cwd=directory,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            patched = target.read_text()
        self.assertIn('void (*g_ray_linux_minimum_size)(const BrowserWindowInterface*,\n'
                      '                                   gfx::Size* minimum) = nullptr;\n', patched)
        self.assertIn('  gfx::Size minimum = layout ? layout->GetMinimumSize(this) : gfx::Size();\n'
                      '  if (g_ray_linux_minimum_size) {\n    g_ray_linux_minimum_size(browser_.get(), &minimum);\n  }\n'
                      '  return minimum;\n', patched)


if __name__ == '__main__':
    unittest.main()
