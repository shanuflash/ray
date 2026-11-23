import pathlib
import unittest

from support import compile_and_run

ROOT = pathlib.Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'


class SavedHistoryTests(unittest.TestCase):
    def test_a_woken_tab_takes_back_only_its_own_matching_saved_history(self):
        output = compile_and_run(self, 'saved-history', [
            LINUX / 'ac_linux_saved_history.cc', ROOT / 'tests/fixtures/saved_history_scenarios.cc',
        ])
        self.assertIn('saved history scenarios passed', output)

    def test_tab_create_asks_for_saved_history_only_without_an_adoption(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        create = host[host.index('void ShellHostView::CreateTabIn('):host.index('TabBinding* binding = BindingForKey(key);', host.index('void ShellHostView::CreateTabIn('))]
        self.assertIn('if (adoption_kind == "restore" || adoption_kind == "clone") {', create)
        self.assertLess(create.index('if (adoption_kind == "restore"'), create.index('ReadsSavedHistory('))
        self.assertIn('.off_the_record = profile->IsOffTheRecord()', create)
        self.assertIn('CreateTabFromSavedHistory(', create)
        engine = (LINUX / 'ac_linux_saved_history_engine.cc').read_text()
        self.assertIn('"ac_tab_history_generation"', engine)
        self.assertIn('saved_history::kTabHistoryDir', engine)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_saved_history.cc', 'ac_linux_saved_history.h', 'ac_linux_saved_history_engine.cc',
                     'ac_linux_saved_history_engine.h'):
            self.assertIn(f'"{name}"', build)

    def test_the_engine_writes_the_file_name_and_fields_the_reader_checks(self):
        writer = (ROOT.parent / 'chromium/src/chrome/browser/ray/ac_tab_restore_history.cc').read_text()
        self.assertIn('constexpr char kTabHistoryDir[] = "Ray Tab History";', writer)
        self.assertIn('constexpr char kTabHistoryCleared[] = "Ray Tab History Cleared";', writer)
        self.assertIn('constexpr int kTabHistoryVersion = 1;', writer)
        self.assertIn('AppendASCII(base::HexEncode(key_))', writer)
        for field in ('"version"', '"url"', '"virtualUrl"', '"generation"', '"state"'):
            self.assertIn(f'.Set({field}', writer)


if __name__ == '__main__':
    unittest.main()
