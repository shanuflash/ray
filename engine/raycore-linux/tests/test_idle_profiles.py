import pathlib
import tempfile
import unittest

from support import VALUES, compile_and_run

ROOT = pathlib.Path(__file__).resolve().parents[1]
LINUX = ROOT / 'src/ray/linux'


class IdleProfileTests(unittest.TestCase):
    def test_an_idle_profile_unloads_only_when_nothing_keeps_it(self):
        with tempfile.TemporaryDirectory(prefix='ray-idle-profiles-') as directory:
            include = pathlib.Path(directory) / 'include'
            (include / 'base').mkdir(parents=True)
            (include / 'base/values.h').write_text(VALUES)
            output = compile_and_run(self, 'idle-profiles', [
                LINUX / 'ac_linux_idle_profiles.cc', ROOT / 'tests/fixtures/idle_profiles_scenarios.cc',
            ], extra_includes=[include])
        self.assertIn('idle profile scenarios passed', output)

    def test_the_host_routes_and_advertises_the_name_the_shell_gates_on(self):
        header = (LINUX / 'ac_linux_idle_profiles.h').read_text()
        host = (LINUX / 'ac_linux_host.cc').read_text()
        shell = (ROOT.parents[1] / 'apps/linux/src/hostCapabilities.ts').read_text()
        self.assertIn('inline constexpr char kLinuxUnloadIdleProfileCall[] = "profiles.unloadIdle";', header)
        self.assertIn('export const UNLOAD_IDLE_PROFILES_CALL = "profiles.unloadIdle";', shell)
        self.assertIn('capabilities.Append(raycore::kLinuxUnloadIdleProfileCall);', host)
        route = host[host.index('if (name == raycore::kLinuxUnloadIdleProfileCall) {'):host.index('if (name == "profiles.loaded") {')]
        self.assertIn('UnloadLinuxIdleProfile(', route)
        self.assertIn('IdleProfileWindow(engine_profile)', route)


if __name__ == '__main__':
    unittest.main()
