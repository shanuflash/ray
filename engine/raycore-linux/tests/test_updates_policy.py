import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray' / 'linux'


class UpdatesPolicyTests(unittest.TestCase):
    def test_two_fixed_urls_with_their_own_size_caps_and_only_2xx_bodies(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        code = r'''#include <cassert>
#include "ray/linux/ac_linux_updates_policy.h"
int main() {
  using namespace ray::linux_updates_policy;
  assert(UrlFor(Source::kKillSwitches) == "https://github.com/shanuflash/ray/switches.json");
  assert(UrlFor(Source::kReleases) == "https://api.github.com/repos/ray-browser/ray/releases?per_page=100");
  assert(MaxBytesFor(Source::kKillSwitches) == 16 * 1024);
  assert(MaxBytesFor(Source::kReleases) == 4 * 1024 * 1024);
  assert(SourceForMethod("RayShell.fetchKillSwitches") == Source::kKillSwitches);
  assert(SourceForMethod("RayUpdates.releases") == Source::kReleases);
  assert(!SourceForMethod("RayUpdates.fetch"));
  assert(!SourceForMethod("RayShell.fetch"));
  assert(!SourceForMethod(""));
  assert(AdmitFetch(0) && AdmitFetch(1));
  assert(!AdmitFetch(kMaxInFlight) && !AdmitFetch(-1));
  assert(ReportedStatus(true, 200, true) == 200);
  assert(ReportedStatus(true, 204, true) == 204);
  assert(ReportedStatus(true, 200, false) == 0);
  assert(ReportedStatus(false, 200, true) == 0);
  assert(ReportedStatus(true, 304, true) == 0);
  assert(ReportedStatus(true, 404, true) == 0);
  assert(ReportedStatus(true, 500, true) == 0);
  assert(CachesForProcess(Source::kKillSwitches, 200));
  assert(!CachesForProcess(Source::kKillSwitches, 0));
  assert(!CachesForProcess(Source::kReleases, 200));
  assert(kTimeoutSeconds == 20);
}
'''
        with tempfile.TemporaryDirectory(prefix='ray-updates-policy-test-') as scratch:
            scratch = pathlib.Path(scratch)
            cpp = scratch / 'updates.cc'
            cpp.write_text(code, encoding='utf-8')
            binary = scratch / 'updates'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Werror', '-fsanitize=address,undefined', '-I', str(SOURCE), str(cpp), '-o', str(binary)], capture_output=True, text=True)
            if compiled.returncode != 0:
                raise AssertionError(compiled.stderr)
            subprocess.run([str(binary)], check=True)

    def test_the_fetch_is_a_cookieless_get_with_no_redirects_on_the_system_network_context(self):
        fetcher = (LINUX / 'ac_linux_updates.cc').read_text()
        for needle in ['GURL(policy::UrlFor(source))', 'request->url = RequestUrl(source_)', 'request->method = "GET"', 'CredentialsMode::kOmit', 'RedirectMode::kError',
                       'system_network_context_manager()', 'GetSharedURLLoaderFactory()', 'DownloadToString(', 'policy::MaxBytesFor(source_)',
                       'base::Seconds(policy::kTimeoutSeconds)', 'policy::AdmitFetch(', 'cookies_allowed: NO', 'DCHECK_CURRENTLY_ON(content::BrowserThread::UI)']:
            self.assertIn(needle, fetcher)
        for absent in ['GetDefaultStoragePartition', 'Profile', 'SetHeader("Authorization"', 'AttachStringForUpload']:
            self.assertNotIn(absent, fetcher)

    def test_the_host_advertises_both_calls_and_takes_no_arguments_from_the_shell(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        bootstrap = host[host.index('base::DictValue ShellHostView::Bootstrap() const {'):host.index('void ShellHostView::LayoutOverlay()')]
        self.assertIn('.Append("RayShell.fetchKillSwitches")', bootstrap)
        self.assertIn('.Append("RayUpdates.releases")', bootstrap)
        route = host[host.index('if (const auto source = ray::linux_updates_policy::SourceForMethod(method)) {'):]
        route = route[:route.index('\n  if (method ==', 1)]
        self.assertIn('if (!values.empty())', route)
        self.assertIn('ray::linux_updates::Fetch(*source', route)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ['"ac_linux_updates.cc"', '"ac_linux_updates.h"', '"ac_linux_updates_policy.h"']:
            self.assertIn(name, build)

    def test_the_shell_policy_lets_the_intro_music_play_from_its_own_assets(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('case Directive::MediaSrc: return "media-src \'self\';";', host)
        self.assertIn('if (ext == ".wav") return "audio/wav";', host)

    def test_the_bootstrap_says_why_a_launch_runs_without_the_sandbox_only_when_it_does(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('command->HasSwitch(sandbox::policy::switches::kNoSandbox)', host)
        self.assertIn('GetSwitchValueASCII("ray-sandbox-decision")', host)
        self.assertIn('bootstrap.Set("sandboxDecision"', host)
        self.assertIn('"//sandbox/policy"', (LINUX / 'BUILD.gn').read_text())


if __name__ == '__main__':
    unittest.main()
