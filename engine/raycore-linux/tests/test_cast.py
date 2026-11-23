import os
from pathlib import Path
import re
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


class CastTests(unittest.TestCase):
    def test_requests_parse_exactly_and_the_test_sink_needs_its_switch_and_an_own_data_dir(self):
        with tempfile.TemporaryDirectory(prefix='ray-cast-') as directory:
            binary = Path(directory) / 'cast'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/cast_core_test.cc'), '-o', str(binary)], check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_six_calls_and_two_events_are_the_ones_the_shell_and_the_mac_use(self):
        core = (LINUX / 'ac_linux_cast_core.h').read_text()
        calls = re.findall(r'inline constexpr char k\w+Call\[\] = "(media\.\w+)";', core)
        shell = (REPO / 'apps/linux/src/hostCast.ts').read_text()
        verbs = re.search(r'const CAST_VERBS = \[([^\]]*)\];', shell).group(1)
        self.assertEqual(sorted(calls), sorted(f'media.{verb}' for verb in re.findall(r'"(\w+)"', verbs)))
        api = (REPO / 'packages/raycore/src/engine/api.ts').read_text()
        for call in calls:
            self.assertIn(f'"{call}":', api)
        for event in ('media.castDialog', 'media.castRoutes'):
            self.assertIn(f'"{event}"', core)
            self.assertIn(f'"{event}":', api)

    def test_the_port_keeps_the_macs_dialog_and_route_logic(self):
        linux = (LINUX / 'ac_linux_cast.cc').read_text()
        mac = (REPO / 'engine/raycore/src/ray/core/ac_cast_dialog.mm').read_text()
        for line in ('ui_->StartCasting(sink_id, static_cast<media_router::MediaCastMode>(cast_mode));',
                     '->HideMediaRouterDialog();', 'media_router::MediaRouterDialogActivationLocation::TOOLBAR',
                     'watcher->media_router()->TerminateRoute(route_id);', 'fullscreen_blocker_.RunAndReset();',
                     'MaybeRegisterTestMediaRouteProvider('):
            self.assertIn(line, linux)
            self.assertIn(line.replace('ui_->StartCasting(sink_id, static_cast', 'ui_->StartCasting(sink_id, static_cast'), mac)
        for key in ('"id"', '"open"', '"header"', '"permissionRejected"', '"castingStarted"', '"sinks"', '"name"', '"status"',
                    '"state"', '"icon"', '"modes"', '"routeId"', '"issue"', '"sink"', '"description"', '"source"'):
            self.assertIn(key, linux)
        install = body(linux, 'void InstallLinuxCast(', 'bool ShowLinuxCastDialog(')
        self.assertIn('g_ray_wants_cast_dialog = &WantsCastDialog;', install)
        self.assertIn('g_ray_cast_dialog = &HandleCastDialog;', install)
        self.assertNotIn('#import', linux)

    def test_the_host_routes_the_calls_delivers_both_events_and_advertises_the_calls(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        route = body(host, 'if (raycore::linux_cast::IsCastCall(name)) {', 'if (name == raycore::linux_capture::kChangeCaptureSourceCall ||')
        self.assertIn('raycore::linux_cast::ParseCastRequest(', route)
        self.assertIn('host_->BindingForKey(request->tab)', route)
        self.assertIn('raycore::ShowLinuxCastDialog(binding->contents())', route)
        self.assertIn('!watched->IsOffTheRecord() && !private_request', route)
        self.assertIn('for (const char* capability : raycore::linux_cast::kCastCapabilities) capabilities.Append(capability);', host)
        start = body(host, 'raycore::InstallLinuxCast(', 'g_ray_auto_picture_in_picture_off = true;')
        self.assertIn('host->BindingForContents(contents)', start)
        self.assertIn('state.Set("tabId", binding->key());', start)
        self.assertEqual(start.count('host->Event("RayMedia", "media",'), 2)
        self.assertIn('raycore::LinuxProfileNameForPath(profile->GetPath().value())', start)
        self.assertIn('if (host->private_window()) continue;', start)

    def test_the_test_provider_is_built_into_the_linux_layer_behind_its_switch(self):
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_cast.cc', 'ac_linux_cast_core.h', '//ray/core/ac_test_media_route_provider.cc', '//components/media_router/browser'):
            self.assertIn(f'"{name}"', build)
        apply = (ROOT / 'apply.sh').read_text()
        for name in ('ac_test_media_route_provider.h', 'ac_test_media_route_provider.cc'):
            self.assertIn(f'copy_file "$here/../raycore/src/ray/core/{name}" "$src/ray/core/{name}"', apply)
            self.assertIn(f'ray/core/{name}', apply.split('--paths)')[1].split(';;')[0])
        provider = (REPO / 'engine/raycore/src/ray/core/ac_test_media_route_provider.cc').read_text()
        self.assertIn('TestFlag("mediaRouteProvider")', provider)
        switches = (SOURCE / 'ray/core/ac_launch_switches_linux.cc').read_text()
        flag = body(switches, 'bool TestFlag(std::string_view key) {', '\n}\n')
        self.assertIn('linux_cast::kTestProviderFlag', flag)
        self.assertIn('linux_cast::kTestSinkSwitch', flag)
        self.assertIn('switches::kUserDataDir', flag)
        self.assertIn('switches::kProcessType', flag)


if __name__ == '__main__':
    unittest.main()
