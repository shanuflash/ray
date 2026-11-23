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
PATCH = PATCHES / 'chromium-linux-unhandled-key.patch'
DELEGATE = 'chrome/browser/ui/browser_web_contents_delegate/browser_web_contents_delegate.cc'
CHROMIUM_157 = '''  return window_->PreHandleKeyboardEvent(event);
}

bool BrowserWebContentsDelegate::HandleKeyboardEvent(
    content::WebContents* source,
    const input::NativeWebKeyboardEvent& event) {
  DevToolsWindow* devtools_window =
      DevToolsWindow::GetInstanceForInspectedWebContents(source);
  return (devtools_window && devtools_window->ForwardKeyboardEvent(event)) ||
         window_->HandleKeyboardEvent(event);
}
'''


class PageKeysTests(unittest.TestCase):
    def test_only_a_plain_or_shifted_escape_key_down_in_a_showing_page_counts(self):
        with tempfile.TemporaryDirectory(prefix='ray-page-keys-') as directory:
            binary = Path(directory) / 'page-keys'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/page_keys_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_event_is_the_one_the_mac_sends_and_the_shared_page_handles(self):
        core = (LINUX / 'ac_linux_page_keys.h').read_text()
        self.assertIn('kCommandEvent[] = "command"', core)
        self.assertIn('kEscapeCommand[] = "escape"', core)
        self.assertIn('[target emit:@"command" payload:@{@"command" : @"escape", @"text" : @""}];',
                      (REPO / 'packages/raycore/ios/RayWindowController.mm').read_text())
        self.assertIn('onCommand: "command"', (REPO / 'packages/raycore/src/pageEvents.ts').read_text())
        self.assertIn('else if (command === "escape") escapePressed(tabId, "page");',
                      (REPO / 'apps/browser/src/components/window/TabWebView.tsx').read_text())

    def test_the_host_reports_it_to_the_tabs_own_page_and_leaves_the_key_to_chromium(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('extern void (*g_ray_linux_unhandled_key)(content::WebContents*, const input::NativeWebKeyboardEvent&);', host)
        hook = host[host.index('g_ray_linux_unhandled_key = []('):host.index('g_ray_linux_renderer_unresponsive = [](')]
        self.assertIn('.raw_key_down = event.GetType() == blink::WebInputEvent::Type::kRawKeyDown', hook)
        self.assertIn('.key_code = event.windows_key_code', hook)
        for modifier in ('kControlKey', 'kAltKey', 'kMetaKey'):
            self.assertIn(f'(modifiers & blink::WebInputEvent::{modifier}) != 0', hook)
        self.assertNotIn('kShiftKey', hook)
        self.assertIn('if (host->ReportUnhandledEscape(contents)) return;', hook)
        report = host[host.index('bool ShellHostView::ReportUnhandledEscape('):host.index('std::string ShellHostView::ExtensionTabKey(')]
        self.assertLess(report.index('binding->contents() != contents'), report.index('PageTakesEscape(!!binding->page(), binding->presented, binding->pane_visible)'))
        self.assertIn('.Set("command", ray::linux_keys::kEscapeCommand).Set("text", "")', report)
        self.assertIn('binding->page()->EmitDocument(ray::linux_keys::kCommandEvent,', report)

    def test_browser_windows_advertise_it(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('  if (!is_utility()) {\n    for (const char* capability : ray::linux_keys::kPageKeyCapabilities) capabilities.Append(capability);\n  }', host)
        self.assertIn('kPageKeyCapabilities[] = {"tab.unhandledEscape"}', (LINUX / 'ac_linux_page_keys.h').read_text())
        self.assertIn('"ac_linux_page_keys.h"', (LINUX / 'BUILD.gn').read_text())

    def test_the_hook_patch_is_linux_only_and_after_the_scroll_bar_patch(self):
        steps = [line.split() for line in (PATCHES / 'series').read_text().splitlines() if line.startswith('chromium ')]
        names = [step[1] for step in steps]
        at = names.index('chromium-linux-unhandled-key.patch')
        self.assertEqual(steps[at], ['chromium', 'chromium-linux-unhandled-key.patch', 'linux'])
        self.assertGreater(at, names.index('chromium-linux-thin-scroll-bars.patch'))
        self.assertEqual(names.count('chromium-linux-unhandled-key.patch'), 1)

    def test_the_hook_patch_applies_to_the_chromium_157_delegate_and_runs_before_the_window(self):
        if shutil.which('git') is None:
            self.skipTest('git is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-unhandled-key-') as directory:
            target = Path(directory) / DELEGATE
            target.parent.mkdir(parents=True)
            target.write_text('\n' * 330 + CHROMIUM_157)
            result = subprocess.run(['git', 'apply', '--whitespace=nowarn', str(PATCH)], cwd=directory,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            patched = target.read_text()
        self.assertIn('void (*g_ray_linux_unhandled_key)(\n    content::WebContents*,\n'
                      '    const input::NativeWebKeyboardEvent&) = nullptr;\n', patched)
        body = patched[patched.index('bool BrowserWebContentsDelegate::HandleKeyboardEvent('):]
        self.assertLess(body.index('g_ray_linux_unhandled_key(source, event);'), body.index('DevToolsWindow* devtools_window'))


if __name__ == '__main__':
    unittest.main()
