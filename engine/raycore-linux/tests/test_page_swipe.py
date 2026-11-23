import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class PageSwipeTests(unittest.TestCase):
    def test_only_a_touchpad_gesture_the_page_leaves_unconsumed_is_forwarded_and_momentum_ends_it(self):
        with tempfile.TemporaryDirectory(prefix='ray-page-swipe-') as directory:
            binary = Path(directory) / 'page-swipe'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/page_swipe_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_page_channel_reads_acks_of_the_main_frame_only_and_maps_each_gesture(self):
        channel = (LINUX / 'ac_linux_page_channel.cc').read_text()
        ack = channel[channel.index('void LinuxPageChannel::OnInputEventAck('):]
        ack = ack[:ack.index('void LinuxPageChannel::ForwardSwipe(')]
        self.assertIn('if (shell_ || !hooks_ || !hooks_->swipe', ack)
        self.assertIn('main->GetRenderWidgetHost() != &widget', ack)
        self.assertIn('gesture.SourceDevice() != blink::mojom::GestureDevice::kTouchpad', ack)
        self.assertIn('delta_hint_units == ui::ScrollGranularity::kScrollByPrecisePixel', ack)
        self.assertIn('state == blink::mojom::InputEventResultState::kConsumed', ack)
        self.assertIn('inertial_phase == blink::mojom::InertialPhaseState::kMomentum', ack)
        for gesture in ('kGestureScrollEnd', 'kGestureFlingStart', 'kGestureFlingCancel'):
            self.assertIn(f'case Type::{gesture}:', ack)
        forward = channel[channel.index('void LinuxPageChannel::ForwardSwipe('):]
        forward = forward[:forward.index('\n}\n')]
        self.assertLess(forward.index('hooks_->shell_point.Run(*page_point)'), forward.index('hooks_->swipe.Run'))
        self.assertIn('void OnInputEventAck(', (LINUX / 'ac_linux_page_channel.h').read_text())

    def test_a_bound_tab_sends_its_swipes_to_its_own_shell_and_turns_chromium_overscroll_off(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        attach = host[host.index('void TabBinding::AttachPageChannel() {'):]
        attach = attach[:attach.index('std::optional<gfx::PointF> TabBinding::ShellPoint(')]
        self.assertIn('if (binding) binding->ReportSwipe(std::move(swipe));', attach)
        self.assertIn('contents_->SetOverscrollNavigationEnabled(false);', attach)
        report = host[host.index('void TabBinding::ReportSwipe(base::DictValue swipe) {'):]
        report = report[:report.index('\n}\n')]
        self.assertIn('if (!owner_ || !presented || !pane_visible) return;', report)
        self.assertIn('ray::linux_swipe::kPageSwipeEvent', report)
        self.assertIn('kPageSwipeEvent[] = "onPageSwipe"', (LINUX / 'ac_linux_page_swipe.h').read_text())
        shim = (REPO / 'apps/linux/src/shims/web/motion/swipe.ts').read_text()
        self.assertIn('event === "onPageSwipe"', shim)
        self.assertIn('"ac_linux_page_swipe.h"', (LINUX / 'BUILD.gn').read_text())


if __name__ == '__main__':
    unittest.main()
