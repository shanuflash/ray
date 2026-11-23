import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
PATCHES = ROOT.parent / 'patches'


class OpenUrlsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ray-open-urls-')
        cls.binary = Path(cls.directory.name) / 'open-urls'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                        str(ROOT / 'tests/open_urls_test.cc'), '-o', str(cls.binary)],
                       check=True, text=True, timeout=180)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], text=True, timeout=60, capture_output=True,
                                env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, 'ok\n')

    def test_only_plain_web_and_file_links_without_a_chromium_window_switch_go_to_the_shell(self):
        self.run_case('policy')

    def test_background_instances_and_a_running_ray_without_a_window_leave_links_to_chromium(self):
        self.run_case('instances')

    def test_links_wait_in_order_for_a_listening_window_up_to_a_limit(self):
        self.run_case('pending')

    def test_chromium_asks_ray_before_it_opens_a_launch_url_at_startup_and_for_a_running_process(self):
        patch = (PATCHES / 'chromium-linux-open-urls.patch').read_text()
        self.assertIn('+      deps += [ "//ray/linux:open_urls" ]', patch)
        self.assertIn('+#include "ray/linux/ac_linux_launch_urls.h"', patch)
        self.assertEqual(patch.count('RayShellTakesLaunchUrls('), 3)
        startup = patch[patch.index('"StartupBrowserCreator::Start"'):]
        self.assertIn('+    return ProcessCmdLineImpl(ray::LinuxLaunchWithoutUrls(cmd_line), cur_dir,', startup)
        running = patch[patch.rindex('+#if BUILDFLAG(IS_LINUX)'):]
        self.assertIn('+      RayShellTakesLaunchUrls(command_line, cur_dir, profile, false)) {\n+    return;', running)
        self.assertLess(running.index('RayShellTakesLaunchUrls'), running.index('Profiles last_opened_profiles;'))
        self.assertNotIn('//', '\n'.join(line for line in patch.splitlines() if line.startswith('+') and 'deps' not in line
                                         and '#include' not in line))
        series = (PATCHES / 'series').read_text().splitlines()
        self.assertIn('chromium chromium-linux-open-urls.patch linux', series)
        self.assertLess(series.index('chromium chromium-linux-open-urls.patch linux'), series.index('layer engine/chromium'))

    def test_the_glue_decides_from_the_core_and_strips_only_the_urls(self):
        glue = (LINUX / 'ac_linux_launch_urls.cc').read_text()
        take = glue[glue.index('bool TakeLinuxLaunchUrls('):glue.index('base::CommandLine LinuxLaunchWithoutUrls(')]
        self.assertIn('launch.background = raycore::BackgroundInstance();', take)
        self.assertIn('launch.has_window = !process_startup && Sink().has_window && Sink().has_window.Run();', take)
        self.assertLess(take.index('linux_open_urls::ShellTakesLaunch(launch)'), take.index('Pending().Add('))
        self.assertIn('if (!url.is_valid()) return false;', take)
        strip = glue[glue.index('base::CommandLine LinuxLaunchWithoutUrls('):glue.index('bool LinuxOpenUrlsPending(')]
        self.assertIn('base::CommandLine launch(command_line.GetProgram());', strip)
        self.assertIn('for (const auto& [name, value] : command_line.GetSwitches()) launch.AppendSwitchNative(name, value);', strip)
        self.assertNotIn('GetArgs', glue)
        self.assertNotIn('getenv', glue)

    def test_the_host_delivers_to_the_last_active_listening_browser_window_and_advertises_the_event(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('bool TakesOpenUrls() const { return browser_ && !is_utility() && !private_window() && !closing(); }', host)
        self.assertIn('bool OpenUrlsListening() const { return handler_ && open_urls_listener_ == renderer_generation_; }', host)
        deliver = host[host.index('void DeliverOpenUrls() {'):host.index('void BroadcastProfileLoaded(')]
        self.assertIn('if (!host->TakesOpenUrls() || !host->OpenUrlsListening()) continue;', deliver)
        self.assertIn('if (!chosen || host->activation() > chosen->activation()) chosen = host;', deliver)
        self.assertLess(deliver.index('if (!chosen) return;'), deliver.index('ray::TakeLinuxOpenUrls()'))
        self.assertIn('chosen->Event("RayShell", "onOpenURLs", base::Value(base::DictValue().Set("urls", std::move(urls))));', deliver)
        self.assertNotIn('"source"', deliver)
        self.assertNotIn('"pointer"', deliver)
        self.assertIn('if (TakesOpenUrls()) {\n    for (const char* capability : ray::linux_open_urls::kOpenUrlCapabilities) capabilities.Append(capability);', host)
        listen = host[host.index('if (method == ray::linux_open_urls::kListenCall) {'):]
        listen = listen[:listen.index('RayTabs.prepareTransfer')]
        self.assertLess(listen.index('if (!TakesOpenUrls())'), listen.index('open_urls_listener_ = renderer_generation_;'))
        self.assertIn('base::BindOnce(&DeliverOpenUrls)', listen)
        self.assertIn('ray::SetLinuxOpenUrlsSink(std::move(open_urls));', host)
        core = (LINUX / 'ac_linux_open_urls.h').read_text()
        self.assertIn('kEventCapability[] = "RayShell.onOpenURLs"', core)
        self.assertIn('kListenCall[] = "RayShell.listenForOpenURLs"', core)
        build = (LINUX / 'BUILD.gn').read_text()
        target = build[build.index('source_set("open_urls") {'):build.index('source_set("devtools_authority") {')]
        for name in ('ac_linux_launch_urls.cc', 'ac_linux_launch_urls.h', 'ac_linux_open_urls.cc', 'ac_linux_open_urls.h'):
            self.assertIn(f'"{name}"', target)
        self.assertIn('    ":open_urls",', build[build.index('source_set("linux") {'):])


if __name__ == '__main__':
    unittest.main()
