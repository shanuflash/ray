import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
FILES = [SOURCE / 'ray/linux' / f'ac_linux_{name}.cc' for name in ['page_messages', 'link_gesture', 'link_tabs', 'page_evaluation']]
FIXTURE = ROOT / 'tests/fixtures/page_state.h'


class PageMessageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ray-page-messages-')
        directory = Path(cls.directory.name)
        for source in FILES + [p.with_suffix('.h') for p in FILES]:
            for include in re.findall(r'#include "([^"]+)"', source.read_text()):
                if include.startswith('ray/'):
                    continue
                header = directory / include
                header.parent.mkdir(parents=True, exist_ok=True)
                header.write_text(f'#include "{FIXTURE}"\n#include <limits>\n')
        cls.binary = directory / 'page-messages'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-no-pie', '-I', str(directory),
                        '-I', str(SOURCE), *map(str, FILES), str(ROOT / 'tests/page_messages_test.cc'), '-o', str(cls.binary)],
                       check=True, text=True, timeout=90)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, name):
        subprocess.run([str(self.binary), name], check=True, text=True, timeout=10,
                       env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})

    def test_kinds_are_an_allowlist_with_bounded_envelopes(self):
        self.run_case('kinds')

    def test_only_the_current_primary_main_document_drives_tab_state(self):
        self.run_case('senders')

    def test_payloads_are_rebuilt_from_validated_fields(self):
        self.run_case('normalization')

    def test_now_playing_is_reduced_to_video_and_state_before_any_limit(self):
        self.run_case('now-playing-reports')

    def test_flooding_is_rate_limited_and_muted_per_document(self):
        self.run_case('budget')

    def test_link_modifier_options_match_macos(self):
        self.run_case('options')

    def test_block_autoplay_everywhere_covers_local_files_as_well_as_web_pages(self):
        self.run_case('options')
        autoplay = (SOURCE / 'ray/linux/ac_linux_autoplay.cc').read_text()
        self.assertIn('if (!LinuxAutoplayCoversScheme(url.scheme())) return false;', autoplay)
        self.assertNotIn('SchemeIsHTTPOrHTTPS', autoplay)

    def test_peek_and_split_require_a_matching_trusted_mouse_up(self):
        self.run_case('gestures')

    def test_evaluation_runs_only_pinned_operations(self):
        self.run_case('evaluation')

    def test_link_drops_need_a_real_drag_that_ended_over_the_page(self):
        self.run_case('link-drops')

    def test_a_drag_is_over_its_page_until_the_exit_settles(self):
        self.run_case('drag-over')

    def test_input_activity_is_announced_at_most_twice_a_second(self):
        self.run_case('activity')

    def test_a_plain_click_peeks_only_on_an_eligible_tab_and_otherwise_follows(self):
        self.run_case('other-sites')

    def test_new_tab_links_are_matched_with_the_macs_waits(self):
        self.run_case('link-tabs')

    def test_a_link_status_carries_the_pointers_distance_from_the_pages_bottom(self):
        self.run_case('status-geometry')
        host = (SOURCE / 'ray/linux/ac_linux_host.cc').read_text()
        self.assertIn('return status->TargetURL(url, host->PointerFromPageBottom(contents));', host)
        status = (SOURCE / 'ray/linux/ac_linux_page_status.cc').read_text()
        self.assertIn('if (from_bottom && !text.empty()) status.Set("fromBottom", *from_bottom);', status)

    def test_page_commits_are_stamped_per_document_and_reported_only_when_asked(self):
        self.run_case('commits')
        host = (SOURCE / 'ray/linux/ac_linux_host.cc').read_text()
        self.assertIn('for (const char* route : raycore::kLinuxPageCommitRoutes) capabilities.Append(route);', host)
        self.assertIn('if (name == raycore::kLinuxReportCommitsRoute) {', host)
        finished = host[host.index('void TabBinding::DidFinishNavigation('):host.index('void TabBinding::DidStartLoading()')]
        self.assertIn('if (handle->HasCommitted() && !handle->IsSameDocument()) {', finished)
        self.assertIn('headers ? headers->response_code() : 0', finished)
        self.assertIn('if (owner_ && owner_->ReportsCommits()) commits_.Report(state);', host)
        forget = host[host.index('  void ForgetRendererPageOptions() {'):]
        self.assertIn('reports_commits_ = false;', forget[:forget.index('\n  }\n')])
        mac = (ROOT.parents[1] / 'packages/raycore/ios/RayWebView+Navigation.mm').read_text()
        self.assertIn('withInitial[@"committedAt"] = @(_commits.at);', mac)
        self.assertIn('if (_commits.httpStatus > 0) withInitial[@"httpStatus"] = @(_commits.httpStatus);', mac)

    def test_the_host_routes_and_advertises_the_link_tab_calls(self):
        linux = SOURCE / 'ray/linux'
        routes = (linux / 'ac_linux_link_tabs.h').read_text()
        self.assertIn('kLinuxLinkTabRoutes[] = {"webView.setPeekOtherSiteTabs",\n'
                      '                                                      "webView.setLittleRayOpensNewTabLinks"};', routes)
        host = (linux / 'ac_linux_host.cc').read_text()
        self.assertIn('for (const char* route : raycore::kLinuxLinkTabRoutes) capabilities.Append(route);', host)
        self.assertIn('if (name == raycore::kLinuxPeekOtherSiteTabsRoute) {', host)
        self.assertIn('if (name == raycore::kLinuxNewTabLinksInPlaceRoute) {', host)
        retire = host[host.index('  void RetireRenderer() {'):]
        self.assertIn('ForgetRendererPageOptions();', retire[:retire.index('\n  }\n')])
        forget = host[host.index('  void ForgetRendererPageOptions() {'):]
        self.assertIn('PushPeekSiteTabs(peek_site_tabs_.Clear());', forget[:forget.index('\n  }\n')])
        self.assertIn('if (link && page_ && owner_->OpensNewTabLinksInPlace())', host)
        self.assertIn('ReportOpened(opened, url, target, disposition == WindowOpenDisposition::kNewForegroundTab);', host)

    def test_a_link_kept_in_place_closes_its_tab_once_chromium_has_put_it_in_a_strip(self):
        host = (SOURCE / 'ray/linux/ac_linux_host.cc').read_text()
        close = host[host.index('bool ShellHostView::CloseOfferedTab('):host.index('void ShellHostView::CloseOfferedTabInStrip(')]
        self.assertLess(close.index('if (host->BindsTab(contents)) return false;'), close.index('closing_offers_.insert(id);'))
        self.assertNotIn('offered_.erase(', close)
        in_strip = host[host.index('void ShellHostView::CloseOfferedTabInStrip('):host.index('std::optional<gfx::PointF> ShellHostView::ShellPoint(')]
        self.assertIn('if (index == TabStripModel::kNoTab || !closing_offers_.erase(id)) return;', in_strip)
        self.assertLess(in_strip.index('!closing_offers_.erase(id)'), in_strip.index('CloseWebContentsAt(index, TabCloseTypes::CLOSE_NONE);'))
        inserted = host[host.index('void ShellHostView::OnTabStripModelChanged('):]
        inserted = inserted[:inserted.index('if (selection.active_tab_changed())')]
        self.assertLess(inserted.index('if (closing_offers_.contains(TabId(inserted.contents))) {'),
                        inserted.index('NoteUnclaimedTab(inserted.contents'))
        self.assertIn('base::BindOnce(&ShellHostView::CloseOfferedTabInStrip, GetWeakPtr(),', inserted)
        listed = host[host.index('base::ListValue ShellHostView::UnclaimedTabsForShell() const {'):]
        self.assertIn('|| closing_offers_.contains(id)) continue;', listed[:listed.index('void ShellHostView::DetachViewports()')])

    def test_a_site_click_the_host_cannot_take_is_handed_back_to_the_page(self):
        channel = (SOURCE / 'ray/linux/ac_linux_page_channel.cc').read_text()
        peek = channel[channel.index('void LinuxPageChannel::Peek('):channel.index('base::CallbackListSubscription LinuxPageChannel::AddPageVideoListener')]
        self.assertEqual(peek.count('Follow(frame, asked,'), 5)
        self.assertIn('if (decision.outcome == LinuxLinkOutcome::kFollow) return Follow(frame, asked, decision.refused);', peek)
        self.assertIn('if (site && !sent && weak', peek)
        self.assertIn('.Set("url", url).Set("reason", reason).Set("follow", true)', channel)
        detach = channel[channel.index('void LinuxPageChannel::Detach() {'):channel.index('bool LinuxPageChannel::PeeksOtherSites() const')]
        self.assertIn('Call(main, "peekConfig", Json(base::Value(Options().PeekConfig())));', detach)
        self.assertIn('*type == LinuxPageMessageKind::kPeek ? budget->link_click : budget->budget', channel)


if __name__ == '__main__':
    unittest.main()
