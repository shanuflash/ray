import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray' / 'linux'

SCENARIOS = r'''#include <cassert>
#include <cstdio>
#include "ray/linux/ac_linux_idle_policy.h"
using namespace ray::linux_idle;

int main() {
  assert((CleanThresholds({60, 0, -5, 1e9, 30, 60, 0.5}) == std::set<double>{30, 60}));
  std::vector<double> many;
  for (int i = 1; i <= 40; ++i) many.push_back(i * 10);
  assert(CleanThresholds(many).size() == kMaxThresholds);

  IdleWatch watch;
  assert(watch.empty());
  watch.Watch({60, 300});
  assert(watch.Update(10).empty());
  assert(watch.NextCheckSeconds(10) == 50);
  auto first = watch.Update(61);
  assert(first.size() == 1 && first[0].first == 60 && first[0].second);
  assert(watch.NextCheckSeconds(61) == kActivePollSeconds);
  assert(watch.Update(70).empty());
  auto both = watch.Update(301);
  assert(both.size() == 1 && both[0].first == 300 && both[0].second);
  auto back = watch.Update(0.2);
  assert(back.size() == 2 && !back[0].second && !back[1].second);
  watch.Watch({300});
  assert(watch.Update(400).size() == 1);
  watch.Watch({300, 900});
  auto kept = watch.Update(400);
  assert(kept.empty());
  assert(watch.NextCheckSeconds(400) == kActivePollSeconds);
  assert((watch.IdleAmong({300, 900}) == std::vector<double>{300}));
  assert(watch.IdleAmong({900}).empty());
  assert(watch.IdleAmong({42}).empty());
  watch.Watch({});
  assert(watch.empty());
  IdleWatch far;
  far.Watch({3600});
  assert(far.NextCheckSeconds(0) == kLongestWaitSeconds);
  IdleWatch near;
  near.Watch({5});
  assert(near.NextCheckSeconds(4.9) == 0.25);
  std::puts("idle scenarios passed");
}
'''


class SystemSignalsTests(unittest.TestCase):
    def test_idle_thresholds_flip_once_each_way_and_the_watch_polls_no_more_than_it_must(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-idle-') as scratch:
            scratch = pathlib.Path(scratch)
            (scratch / 'idle.cc').write_text(SCENARIOS)
            binary = scratch / 'idle'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I', str(SOURCE),
                                       str(scratch / 'idle.cc'), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_sleep_and_wake_come_from_logind_and_idle_from_the_platform_idle_time(self):
        signals = (LINUX / 'ac_linux_system_signals.cc').read_text()
        for needle in ['"org.freedesktop.login1"', '"PrepareForSleep"', 'ConnectToSignal(kLogindManager', 'ui::CalculateIdleTime()',
                       'idle_.NextCheckSeconds(idle_seconds)', '.Set("type", starting ? "sleep" : "wake")', '"willSleep"', '"didWake"']:
            self.assertIn(needle, signals)
        host = (LINUX / 'ac_linux_host.cc').read_text()
        bootstrap = host[host.index('base::DictValue ShellHostView::Bootstrap() const {'):host.index('void ShellHostView::LayoutOverlay()')]
        for capability in ['RaySystemSignals.watchIdle', 'RaySystemSignals.devPost']:
            self.assertIn(f'.Append("{capability}")', bootstrap)
        self.assertIn('host->Event("RaySystemSignals", "onSystemSignal"', host)
        self.assertIn('ray::LinuxSystemSignals::Get().WatchIdle(id_, {});', host)

    def test_a_watcher_that_registers_while_the_user_is_already_idle_hears_it_at_once(self):
        signals = (LINUX / 'ac_linux_system_signals.cc').read_text()
        watch = signals[signals.index('void LinuxSystemSignals::WatchIdle('):signals.index('void LinuxSystemSignals::Poll()')]
        replay = watch.index('for (double threshold : idle_.IdleAmong(kept)) {')
        self.assertLess(watch.index('idle_.Watch(all);'), replay)
        self.assertLess(replay, watch.index('Poll();'), 'the replay goes first, so Poll only adds what changed since')
        self.assertIn('.Set("threshold", threshold).Set("idle", true)', watch[replay:])

    def test_a_shell_renderer_that_goes_away_drops_its_idle_thresholds_and_the_next_one_registers_its_own(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        retire = host[host.index('  void RetireRenderer() {'):]
        retire = retire[:retire.index('\n  }\n')]
        self.assertIn('ray::LinuxSystemSignals::Get().WatchIdle(id_, {});', retire)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ['"ac_linux_system_signals.cc"', '"ac_linux_idle_policy.h"']:
            self.assertIn(name, build)


if __name__ == '__main__':
    unittest.main()
