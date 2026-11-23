import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class AppActivationTests(unittest.TestCase):
    def test_the_app_resigns_once_no_ray_window_is_active_and_not_on_a_switch_between_them(self):
        with tempfile.TemporaryDirectory(prefix='ray-app-activation-') as directory:
            binary = Path(directory) / 'app-activation'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/app_activation_test.cc'), str(LINUX / 'ac_linux_window_lifecycle.cc'),
                            '-o', str(binary)], check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_event_is_the_macs_and_the_window_focus_event_is_its_counterpart(self):
        self.assertIn('kResignActiveEvent[] = "resignActive"', (LINUX / 'ac_linux_app_activation.h').read_text())
        self.assertIn('if quiet() { emit("resignActive") }', (REPO / 'packages/shell/ios/ShellModule.swift').read_text())
        alerts = (REPO / 'apps/browser/src/state/live/alerts.ts').read_text()
        self.assertIn('if (e.type === "resignActive") appActive = false;', alerts)
        self.assertIn('if (e.type === "focus") appActive = true;', alerts)

    def test_every_activation_change_and_a_closed_window_feed_the_settle(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        changed = host[host.index('void ShellHostView::OnWidgetActivationChanged('):]
        changed = changed[:changed.index('\n}\n')]
        self.assertLess(changed.index('WindowFocus().Observe(id_, active);'), changed.index('NoteAppActivation();'))
        self.assertLess(changed.index('NoteAppActivation();'), changed.index('if (!changed || is_utility() || window_id_.empty()) return;'))
        closing = host[host.index('ShellHostView::~ShellHostView() {'):]
        self.assertLess(closing.index('WindowFocus().Forget(id_);'), closing.index('NoteAppActivation();'))
        self.assertLess(closing.index('NoteAppActivation();'), closing.index('DropPlayer();'))

    def test_the_settle_reads_the_ledger_again_stays_quiet_during_a_dialog_and_tells_every_window(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        active = host[host.index('bool AnyRayToplevelActive() {'):host.index('void NoteAppActivation() {')]
        self.assertIn('if (WindowFocus().active() != 0) return true;', active)
        self.assertIn('aura::Env::GetInstance()->window_tree_hosts()', active)
        self.assertIn('widget->IsVisible() && widget->IsActive()', active)
        note = host[host.index('void NoteAppActivation() {'):host.index('void BroadcastWindowEvent(')]
        self.assertIn('AppActivationState().WindowsChanged(AnyRayToplevelActive())', note)
        self.assertIn('base::Milliseconds(linux_window::AppActivation::kSettleMs)', note)
        self.assertIn('std::ranges::none_of(Hosts(), [](const auto& entry) { return entry.second->DialogsPending(); })', note)
        settled = note.index('if (!AppActivationState().Settled(generation, AnyRayToplevelActive(), quiet)) return;')
        self.assertLess(settled, note.index('for (const auto& [id, host] : Hosts()) {'))
        self.assertIn('host->Event("RayShell", "onAppEvent", base::Value(base::DictValue()\n'
                      '              .Set("type", linux_window::kResignActiveEvent)));', note)

    def test_the_host_advertises_it(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('for (const char* capability : ray::linux_window::kAppActivationCapabilities) capabilities.Append(capability);', host)
        self.assertIn('kAppActivationCapabilities[] = {"RayShell.resignActive"}', (LINUX / 'ac_linux_app_activation.h').read_text())
        self.assertIn('"ac_linux_app_activation.h"', (LINUX / 'BUILD.gn').read_text())


if __name__ == '__main__':
    unittest.main()
