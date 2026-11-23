from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'


def body(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


class StartupTabHistoryTests(unittest.TestCase):
    def setUp(self):
        self.host = (LINUX / 'ac_linux_host.cc').read_text()

    def test_the_startup_tab_reads_its_saved_history_before_the_session_entry_is_moved(self):
        started = body(self.host, 'void ShellHostView::StartedStartupTab(', '\n}\n')
        self.assertLess(started.index('const std::string address = saved->url;'), started.index('std::move(*saved)'))
        self.assertIn('ReadLinuxSavedTabHistory(browser_->GetProfile(), key, address,', started)
        self.assertNotIn('saved->url,', started[started.index('ReadLinuxSavedTabHistory'):])

    def test_a_saved_history_is_restored_and_loaded_at_once_instead_of_a_bare_page(self):
        opened = body(self.host, 'void ShellHostView::OpenStartupTab(', '\n}\n')
        restored = opened[opened.index('if (contents) {'):opened.index('} else {')]
        self.assertIn('InsertRestored(browser_->GetProfile(), history)', opened)
        self.assertIn('contents->GetController().LoadIfNecessary();', restored)
        self.assertNotIn('LoadURLWithParams', restored)
        self.assertIn('model->CloseWebContentsAt(index, TabCloseTypes::CLOSE_NONE);', restored)
        self.assertIn('startup_tab_ = StartupTab{url, contents->GetWeakPtr(), saved.tab_id};', opened)

    def test_the_shells_saved_history_create_adopts_the_startup_tab_for_its_key(self):
        create = body(self.host, 'void ShellHostView::CreateTabFromSavedHistory(', '\n}\n')
        take = 'if (content::WebContents* startup = TakeStartupTabForKey(key, GURL(String(args, "url")), profile)) {'
        self.assertIn(take, create)
        self.assertLess(create.index(take), create.index('ReadLinuxSavedTabHistory('))
        self.assertIn('return CreateTabAdopting(profile, std::move(plain), startup, std::move(done));', create)
        keyed = body(self.host, 'content::WebContents* ShellHostView::TakeStartupTabForKey(', '\n}\n')
        self.assertIn('startup_tab_->key != key || startup_tab_->url != url', keyed)
        self.assertIn('contents->GetBrowserContext() != profile', keyed)
        self.assertIn('if (host->BindsTab(contents)) return nullptr;', keyed)
        self.assertLess(keyed.index('BindsTab'), keyed.index('startup_tab_.reset();'))


if __name__ == '__main__':
    unittest.main()
