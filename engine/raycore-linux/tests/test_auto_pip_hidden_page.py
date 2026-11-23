import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'


def body(source, start, end):
    text = source[source.index(start):]
    return text[:text.index(end)]


class HiddenPageDepartureTests(unittest.TestCase):
    def test_a_departure_waits_for_the_page_to_be_hidden_or_the_wait_to_run_out_and_a_return_cancels_it(self):
        with tempfile.TemporaryDirectory(prefix='ray-auto-pip-hidden-') as directory:
            binary = Path(directory) / 'auto-pip-hidden'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/auto_pip_hidden_page_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_departure_is_told_on_the_task_after_the_page_turns_hidden(self):
        service = (LINUX / 'ac_linux_auto_pip_service.cc').read_text()
        depart = body(service, '  void Depart(base::OnceClosure depart) {', '  void Return() {')
        self.assertIn('wait_.Depart(GetWebContents().GetVisibility() == content::Visibility::VISIBLE)', depart)
        self.assertIn('base::Milliseconds(linux_auto_pip::kHiddenPageWaitMs)', depart)
        changed = body(service, '  void OnVisibilityChanged(content::Visibility visibility) override {', ' private:')
        self.assertIn('visibility == content::Visibility::VISIBLE) return;', changed)
        self.assertIn('PostTask(', changed)

    def test_the_host_hides_a_tab_from_auto_pip_only_once_its_page_is_hidden_and_shows_it_at_once(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        presentations = body(host, 'void ShellHostView::SetPresentations(', 'void ShellHostView::StripCommand(')
        self.assertIn('raycore::DepartWhenLinuxPageHidden(contents.get(), base::BindOnce(&TellAutoPictureInPictureDeparted, contents));', presentations)
        self.assertLess(presentations.index('raycore::ReturnBeforeLinuxPageHidden(contents.get());'),
                        presentations.index('helper->OnTabActivatedChanged(true);'))
        self.assertNotIn('OnTabActivatedChanged(visible)', presentations)
        told = body(host, 'void TellAutoPictureInPictureDeparted(', 'void ShellHostView::SetPresentations(')
        self.assertIn('g_ray_linux_tab_shown(contents.get()) == 1)) return;', told)
        self.assertIn('helper->OnTabActivatedChanged(false);', told)

    def test_automatic_document_picture_in_picture_is_no_longer_refused(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertNotIn('g_ray_linux_refuses_document_picture_in_picture', host)

    def test_a_fresh_picture_in_picture_says_whether_its_tab_was_left(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('.Set("active", active).Set("kind", pip_kind_).Set("leftTab", shown != 1));', host)
        media = (LINUX / 'ac_linux_page_media.cc').read_text()
        self.assertIn('reporter_.SetPictureInPicture({std::move(kind), active}, left_tab);', media)


if __name__ == '__main__':
    unittest.main()
