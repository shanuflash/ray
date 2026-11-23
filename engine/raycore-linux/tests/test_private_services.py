import pathlib
import unittest

from support import compile_and_run

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PrivateServiceHelperTests(unittest.TestCase):
    def test_routing_and_engine_failures(self):
        output = compile_and_run(self, 'private-services', [ROOT / 'tests/fixtures/private_services_scenarios.cc'])
        self.assertIn('private services scenarios passed', output)

    def test_a_private_window_releases_only_its_own_profile_and_never_changes_cli_control(self):
        host = (ROOT / 'src/ray/linux/ac_linux_host.cc').read_text()
        request = host[host.index('  void Request(const base::ListValue& arguments) {'):]
        request = request[:request.index('if (name == "profiles.deleteData") {')]
        private_check = request.index('if (host_->private_window() && !window_profile) {')
        cli = request.index('return CliControlCall(id, name, args.Find("args"));')
        release = request.index('raycore::ReleaseLinuxProfile(profile);')
        self.assertLess(private_check, cli)
        self.assertLess(private_check, release)
        self.assertLess(request.index('RouteCliControlChange(private_page)'), cli)
        self.assertLess(request.index('RouteProfileRelease(\n            private_page, host_->HostsProfile(profile), live_elsewhere);'), release)


if __name__ == '__main__':
    unittest.main()
