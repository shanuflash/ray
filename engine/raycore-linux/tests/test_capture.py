import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


def body(source, start, end):
    text = source[source.index(start):]
    return text[:text.index(end)]


class CaptureTests(unittest.TestCase):
    def test_requests_parse_exactly_and_switching_needs_one_enabled_share_instead_button(self):
        with tempfile.TemporaryDirectory(prefix='ray-capture-') as directory:
            binary = Path(directory) / 'capture'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/capture_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_switch_and_stop_use_chromiums_tab_sharing_infobar_and_capture_indicator(self):
        source = (LINUX / 'ac_linux_capture.cc').read_text()
        switch = body(source, 'bool ShareLinuxTabInstead(', 'bool StopLinuxCapture(')
        self.assertIn('infobars::InfoBarDelegate::TAB_SHARING_INFOBAR_DELEGATE', switch)
        self.assertIn('content::RenderFrameHost::FromID(sharing->capturer_id())', switch)
        self.assertLess(switch.index('linux_capture::SharesInstead('), switch.index('found->ShareThisTabInstead();'))
        stop = source[source.index('bool StopLinuxCapture('):]
        self.assertIn('StopMediaCapturing(capturer, MediaStreamCaptureIndicator::MediaType::kDisplayMedia)', stop)

    def test_the_host_routes_both_calls_only_to_tabs_of_its_own_session_and_advertises_them(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        route = body(host, 'if (name == raycore::linux_capture::kChangeCaptureSourceCall ||', 'if (name == raycore::kLinuxPeekOtherSiteTabsRoute) {')
        self.assertIn('raycore::linux_capture::ParseCaptureRequest(', route)
        self.assertIn('raycore::linux_capture::ReachesTab(', route)
        self.assertIn('host_->BindingForKey(request->target)', route)
        self.assertIn('for (const char* capability : raycore::linux_capture::kCaptureCapabilities) capabilities.Append(capability);', host)
        self.assertIn('"ac_linux_capture.cc"', (LINUX / 'BUILD.gn').read_text())
        cast = (REPO / 'apps/linux/src/hostCast.ts').read_text()
        self.assertIn('supports(`media.${verb}`)', cast)


if __name__ == '__main__':
    unittest.main()
