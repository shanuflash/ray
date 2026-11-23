import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray' / 'linux'
PATCHES = ROOT.parents[0] / 'patches'

SCENARIOS = r'''#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>
#include "ray/linux/ac_linux_geoclue_policy.h"
using namespace ray::linux_geoclue;

int main() {
  auto fix = FixFrom({{"Latitude", 48.8566}, {"Longitude", 2.3522}, {"Accuracy", 25}, {"Altitude", 35}, {"Heading", -1}, {"Speed", -1}});
  assert(fix && fix->latitude == 48.8566 && fix->longitude == 2.3522 && fix->accuracy == 25);
  assert(fix->altitude == 35 && !fix->heading && !fix->speed);
  auto moving = FixFrom({{"Latitude", 1}, {"Longitude", 2}, {"Heading", 90}, {"Speed", 3}, {"Accuracy", -5}});
  assert(moving && moving->heading == 90 && moving->speed == 3 && moving->accuracy == kDefaultAccuracyMeters);
  assert(!FixFrom({{"Latitude", 1}}));
  assert(!FixFrom({{"Latitude", 91}, {"Longitude", 0}}));
  assert(!FixFrom({{"Latitude", 0}, {"Longitude", 181}}));
  assert(!FixFrom({{"Latitude", std::numeric_limits<double>::quiet_NaN()}, {"Longitude", 0}}));
  assert(!FixFrom({{"Latitude", -1.79769e308}, {"Longitude", 0}}));
  auto no_altitude = FixFrom({{"Latitude", 0}, {"Longitude", 0}, {"Altitude", -1.79769e308}});
  assert(no_altitude && !no_altitude->altitude);
  assert(fix->acquired_seconds == 0);
  assert(AccuracyLevel(true) == 8 && AccuracyLevel(false) == 4);
  assert(RetuneFor(false, false, true, false, false) == Retune::kNothing);
  assert(RetuneFor(true, false, false, true, true) == Retune::kNothing);
  assert(RetuneFor(true, false, true, false, false) == Retune::kRemember);
  assert(RetuneFor(true, false, true, true, true) == Retune::kRequestAndRestart);
  assert(RetuneFor(true, false, true, true, false) == Retune::kRequestAndRestartWhenStarted);
  assert(RetuneFor(true, true, false, true, true) == Retune::kRequestAndRestart);
  assert(DeniedByDesktop("org.freedesktop.DBus.Error.AccessDenied: Agent rejected 'ray'"));
  assert(DeniedByDesktop("Geolocation disabled for UID 1000"));
  assert(!DeniedByDesktop("org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.GeoClue2 was not provided"));
  std::puts("geoclue scenarios passed");
}
'''


class GeoClueTests(unittest.TestCase):
    def test_a_geoclue_location_becomes_a_position_only_when_it_is_a_real_coordinate(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-geoclue-') as scratch:
            scratch = pathlib.Path(scratch)
            (scratch / 'geoclue.cc').write_text(SCENARIOS)
            binary = scratch / 'geoclue'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined', '-I', str(SOURCE),
                                       str(scratch / 'geoclue.cc'), '-o', str(binary)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_chrome_asks_the_linux_layer_for_its_location_provider_and_the_layer_answers_with_geoclue(self):
        patch = (PATCHES / 'chromium-linux-geolocation.patch').read_text()
        self.assertIn('+ChromeContentBrowserClient::OverrideSystemLocationProvider() {', patch)
        self.assertIn('+std::unique_ptr<device::LocationProvider> (*g_ray_linux_location_provider)() = nullptr;', patch)
        self.assertIn('chromium chromium-linux-geolocation.patch linux', (PATCHES / 'series').read_text())
        provider = (LINUX / 'ac_linux_geoclue.cc').read_text()
        for needle in ['g_ray_linux_location_provider = &CreateLinuxLocationProvider;', '"GetClient"', '"LocationUpdated"', '"Start"',
                       'geoclue::FixFrom(values)', 'content::GetUIThreadTaskRunner({})', 'kPositionUnavailable']:
            self.assertIn(needle, provider)
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('ray::InstallLinuxLocationProvider();', host)
        self.assertIn('.Append("RayLocation.locationPermission")', host)

    def test_a_precise_request_after_a_coarse_one_raises_the_running_client_and_its_end_lowers_it(self):
        provider = (LINUX / 'ac_linux_geoclue.cc').read_text()
        start = provider[provider.index('void StartProvider(bool enable_high_accuracy) override {'):]
        start = start[:start.index('\n  }\n')]
        self.assertIn('if (relay_ && relay_->high_accuracy() == enable_high_accuracy) return;', start)
        self.assertIn('StopProvider();', start)
        watch = provider[provider.index('void Watch('):provider.index('bool DeniedByDesktop()')]
        self.assertEqual(watch.count('Retune();'), 2, 'Watch and Unwatch both retune the shared client')
        self.assertIn('Start(WantsHighAccuracy());', watch)
        retune = provider[provider.index('void Retune() {'):provider.index('void RequestAccuracy() {')]
        self.assertIn('geoclue::RetuneFor(', retune)
        self.assertIn('return Restart();', retune)
        self.assertIn('restart_when_started_ = true;', retune)
        self.assertIn('if (std::exchange(restart_when_started_, false)) return Restart();', provider)
        self.assertIn('if (state_ != State::kStarting || !client_.IsValid()) return;', provider, 'a Start answered after Stop leaves the client stopped')

    def test_a_reply_or_signal_from_a_stopped_session_is_dropped_instead_of_reaching_the_next(self):
        provider = (LINUX / 'ac_linux_geoclue.cc').read_text()
        geoclue = provider[provider.index('class GeoClue {'):provider.index('class GeoClueLocationProvider')]
        for callback in ['&GeoClue::GotClient', '&GeoClue::Started', '&GeoClue::LocationUpdated', '&GeoClue::FixRead']:
            for at in [i for i in range(len(geoclue)) if geoclue.startswith(callback, i)]:
                bound = geoclue[at:geoclue.index(')', geoclue.index('GetWeakPtr', at)) + 1]
                self.assertIn('session_.GetWeakPtr()', bound, f'{callback} is tied to its session')
        location = geoclue[geoclue.index('writer.AppendString("Location");'):geoclue.index('void LocationUpdated(')]
        self.assertIn('session_.GetWeakPtr()', location, 'the first Location read is tied to its session')
        end = geoclue[geoclue.index('void EndSession() {'):]
        self.assertIn('session_.InvalidateWeakPtrs();', end[:end.index('}')])
        for method in ['void Start(bool high_accuracy) {', 'void GiveUp(const std::string& reason) {', 'void Stop() {']:
            body = geoclue[geoclue.index(method):]
            body = body[:body.index('\n  }\n')]
            self.assertIn('EndSession();', body, f'{method} ends the session before another can start')
        stop = geoclue[geoclue.index('void Stop() {'):]
        stop = stop[:stop.index('\n  }\n')]
        self.assertLess(stop.index('EndSession();'), stop.index('latest_.reset();'))
        for timer in ['&GeoClue::NoFirstFix', '&GeoClue::Stop']:
            self.assertIn(f'{timer}, weak_factory_.GetWeakPtr()', geoclue, 'timers outlive sessions')

    def test_a_cached_fix_keeps_the_time_geoclue_reported_it_instead_of_each_delivery_time(self):
        provider = (LINUX / 'ac_linux_geoclue.cc').read_text()
        result = provider[provider.index('device::mojom::GeopositionResultPtr ResultOf('):provider.index('class Relay')]
        self.assertIn('base::Time::FromSecondsSinceUnixEpoch(fix->acquired_seconds)', result)
        self.assertNotIn('position->timestamp = base::Time::Now();', result)
        read = provider[provider.index('void FixRead('):provider.index('void NoFirstFix()')]
        self.assertLess(read.index('fix->acquired_seconds = base::Time::Now().InSecondsFSinceUnixEpoch();'), read.index('latest_ = fix;'))
        watch = provider[provider.index('void Watch('):provider.index('void Unwatch(')]
        self.assertIn('relay->Send(latest_)', watch, 'a new watcher still gets the cached fix at once, with its own time')


if __name__ == '__main__':
    unittest.main()
