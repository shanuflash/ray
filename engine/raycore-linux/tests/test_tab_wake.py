from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'


def body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


class TabWakeTests(unittest.TestCase):
    def setUp(self):
        self.host = (LINUX / 'ac_linux_host.cc').read_text()

    def test_ready_is_kept_until_the_woken_page_can_take_it(self):
        start = body(self.host, 'void TabBinding::DidStartNavigation(', 'void TabBinding::Rebind(')
        self.assertIn('wake_ready_pending = !PresentNow("ready", base::DictValue());', start)
        self.assertNotIn('ReportPresentation("ready"', start)
        finish = body(self.host, 'void TabBinding::DidFinishNavigation(', 'void TabBinding::DidStartLoading()')
        committed = finish[finish.index('if (handle->HasCommitted() && !handle->IsSameDocument()) {'):finish.index('ReportNavigation();')]
        self.assertIn('if (wake_ready_pending) {', committed)
        self.assertIn('base::BindOnce(&TabBinding::ReportWoke, GetWeakPtr())', committed)
        woke = body(self.host, 'void TabBinding::ReportWoke() {', '\n}\n')
        self.assertIn('if (!wake_ready_pending) return;', woke)
        self.assertIn('wake_ready_pending = !PresentNow("ready", base::DictValue());', woke)

    def test_a_new_sleep_or_another_page_forgets_a_pending_ready(self):
        discarded = body(self.host, 'void TabBinding::WasDiscarded() {', '\n}\n')
        self.assertLess(discarded.index('wake_ready_pending = false;'), discarded.index('ReportPresentation("discarded"'))
        rebind = body(self.host, 'void TabBinding::Rebind(', '\n}\n')
        self.assertIn('discard_reported = false;\n  wake_ready_pending = false;', rebind)

    def test_present_now_says_whether_the_page_took_the_event(self):
        present = body(self.host, 'bool TabBinding::PresentNow(', '\n}\n')
        self.assertIn('return page_ && page_->EmitPresentation(std::move(name), base::Value(std::move(data)));', present)
        state = (LINUX / 'ac_linux_page_state.cc').read_text()
        emit = body(state, 'bool LinuxPageState::EmitPresentation(', '\n}\n')
        self.assertIn('auto request = lease_->CapturePresentation();', emit)
        self.assertIn('return request && request->lease &&', emit)


if __name__ == '__main__':
    unittest.main()
