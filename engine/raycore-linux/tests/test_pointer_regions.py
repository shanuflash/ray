import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'


class PointerRegionsTests(unittest.TestCase):
    def test_pass_regions_buttons_and_the_stale_hover_rule(self):
        with tempfile.TemporaryDirectory(prefix='ray-pointer-regions-') as directory:
            binary = Path(directory) / 'pointer-regions'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/pointer_regions_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_new_input_regions_hand_a_resting_pointer_to_the_page_through_auras_own_retargeting(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        regions = host[host.index('void ShellHostView::SetInputRegions('):host.index('std::vector<gfx::Rect> ShellHostView::ShellPass() const {')]
        self.assertLess(regions.index('ApplyShellInput();'), regions.index('ReleaseStaleShellHover();'))
        self.assertLess(regions.index('std::move(done).Run(true, base::Value());'), regions.index('  ReleaseStaleShellHover();\n}'))
        release = regions[regions.index('void ShellHostView::ReleaseStaleShellHover() {'):]
        self.assertIn('dispatcher->mouse_moved_handler()', release)
        self.assertIn('hovered && container->Contains(hovered)', release)
        self.assertIn('aura::Env::GetInstance()->IsMouseButtonDown()', release)
        self.assertIn('for (const gfx::Rect& rect : ShellPass())', release)
        stale = release.index('if (!ray::linux_window::ShellHoverIsStale(')
        move = release.index('ui::MouseEvent move(ui::EventType::kMouseMoved, location, location, ui::EventTimeForNow(), ui::EF_IS_SYNTHESIZED, 0);')
        self.assertLess(stale, release.index('tree_host->ConvertDIPToPixels(&location);'))
        self.assertLess(release.index('tree_host->ConvertDIPToPixels(&location);'), move)
        self.assertLess(move, release.index('tree_host->GetEventSink()->OnEventFromSource(&move);'))

    def test_the_edge_watcher_never_reads_a_synthesized_move(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        mouse = host[host.index('void ShellHostView::OnSidebarEdgeMouse('):host.index('void ShellHostView::ReportSidebarEdge(')]
        self.assertLess(mouse.index('if (event.flags() & ui::EF_IS_SYNTHESIZED) return;'), mouse.index('sidebar_edge_.Moved('))

    def test_the_core_is_built(self):
        self.assertIn('"ac_linux_pointer_regions.h"', (LINUX / 'BUILD.gn').read_text())


if __name__ == '__main__':
    unittest.main()
