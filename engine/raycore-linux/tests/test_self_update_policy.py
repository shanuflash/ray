import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray' / 'linux'

POLICY_TEST = r'''#include <cassert>
#include <string>
#include "ray/linux/ac_linux_self_update_policy.h"
using namespace ray::linux_self_update_policy;

const std::string kSha(64, 'a');

std::string Manifest(const std::string& version, const std::string& lines) {
  return "ray-linux-update 1\nversion " + version + "\n" + lines;
}

std::string Line(const std::string& kind, const std::string& name, const std::string& size) {
  return kind + " " + name + " " + kSha + " " + size + "\n";
}

int main() {
  assert(ValidVersion("0.2.48"));
  assert(ValidVersion("10.20.30"));
  assert(ValidVersion("0.2.47-nightly.9"));
  assert(!ValidVersion(""));
  assert(!ValidVersion("0.2"));
  assert(!ValidVersion("0.2.48."));
  assert(!ValidVersion("v0.2.48"));
  assert(!ValidVersion("0.2.48-beta.1"));
  assert(!ValidVersion("0.2.48-nightly."));
  assert(!ValidVersion("0.2.48-nightly.1a"));
  assert(!ValidVersion("0.2.48/../x"));
  assert(!ValidVersion("0..48"));
  assert(!ValidVersion(" 0.2.48"));
  assert(!ValidVersion(std::string(40, '1') + "." + std::string(40, '2') + ".3"));

  assert(InstallableKind("deb") == Kind::kDeb);
  assert(InstallableKind("tarball") == Kind::kTarball);
  assert(InstallableKind("appimage") == Kind::kAppImage);
  assert(!InstallableKind("managed"));
  assert(!InstallableKind("unsupported noPkexec"));
  assert(ThroughPkexec(Kind::kDeb) && ThroughPkexec(Kind::kTarball) && !ThroughPkexec(Kind::kAppImage));

  assert(ValidKindLine("deb") && ValidKindLine("tarball") && ValidKindLine("appimage") && ValidKindLine("managed"));
  assert(ValidKindLine("unsupported noVersion") && ValidKindLine("unsupported noOpenssl"));
  assert(!ValidKindLine("unsupported ") && !ValidKindLine("unsupported no key") && !ValidKindLine("rpm"));
  assert(!ValidKindLine("") && !ValidKindLine("deb\n") && !ValidKindLine("unsupported " + std::string(80, 'x')));

  assert(LastLine("installed 0.2.48\n") == "installed 0.2.48");
  assert(LastLine("copying\nfailed checksum\n\n") == "failed checksum");
  assert(LastLine("one\r\ntwo\r\n") == "two");
  assert(LastLine("") == "");

  assert(ManifestName("0.2.48") == "Ray-0.2.48-linux-update.txt");
  assert(SignatureName("0.2.48") == "Ray-0.2.48-linux-update.txt.sig");
  assert(PackageName("0.2.48", Kind::kDeb) == "Ray-0.2.48-linux-x64.deb");
  assert(PackageName("0.2.48", Kind::kTarball) == "Ray-0.2.48-linux-x64.tar.xz");
  assert(PackageName("0.2.48-nightly.3", Kind::kAppImage) == "Ray-0.2.48-nightly.3-linux-x64.AppImage");
  assert(ValidPackageName("Ray-0.2.48-linux-x64.deb", "0.2.48", Kind::kDeb));
  assert(!ValidPackageName("Ray-0.2.48-linux-x64.deb", "0.2.48", Kind::kTarball));
  assert(!ValidPackageName("../Ray-0.2.48-linux-x64.deb", "0.2.48", Kind::kDeb));
  assert(!ValidPackageName("Ray-0.2.49-linux-x64.deb", "0.2.48", Kind::kDeb));
  assert(!ValidPackageName("Ray-0.2.48-linux-arm64.deb", "0.2.48", Kind::kDeb));

  const std::string v = "0.2.48";
  const std::string full = Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "123") +
                                           Line("tarball", "Ray-0.2.48-linux-x64.tar.xz", "456") +
                                           Line("appimage", "Ray-0.2.48-linux-x64.AppImage", "789"));
  ManifestRead read = PackageInManifest(full, v, Kind::kTarball);
  assert(read.package && read.package->name == "Ray-0.2.48-linux-x64.tar.xz" && read.package->size == 456);
  read = PackageInManifest(full, v, Kind::kDeb);
  assert(read.package && read.package->size == 123);
  read = PackageInManifest(full, v, Kind::kAppImage);
  assert(read.package && read.package->name == "Ray-0.2.48-linux-x64.AppImage" && read.package->size == 789);

  const std::string no_deb = Manifest(v, Line("tarball", "Ray-0.2.48-linux-x64.tar.xz", "456") +
                                             Line("appimage", "Ray-0.2.48-linux-x64.AppImage", "789"));
  assert(PackageInManifest(no_deb, v, Kind::kDeb).reason == "kind");
  assert(PackageInManifest(no_deb, v, Kind::kTarball).package);
  assert(PackageInManifest(Manifest(v, ""), v, Kind::kDeb).reason == "kind");

  assert(PackageInManifest(full, "0.2.49", Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(full.substr(0, full.size() - 1), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest("ray-linux-update 2\n" + full.substr(21), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("tarball", "Ray-0.2.48-linux-x64.tar.xz", "1") +
                                           Line("deb", "Ray-0.2.48-linux-x64.deb", "1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "1") +
                                           Line("deb", "Ray-0.2.48-linux-x64.deb", "1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "../../etc/passwd", "1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.tar.xz", "1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("rpm", "Ray-0.2.48-linux-x64.rpm", "1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "0")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "012")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "-1")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "99999999999999999999")), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, "deb Ray-0.2.48-linux-x64.deb " + std::string(64, 'A') + " 1\n"), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, "deb Ray-0.2.48-linux-x64.deb " + kSha + " 1 extra\n"), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, "deb Ray-0.2.48-linux-x64.deb  " + kSha + " 1\n"), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, "deb Ray-0.2.48-linux-x64.deb " + kSha + " 1\r\n"), v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "1")) + "\n", v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "536870912")), v, Kind::kDeb).package);
  assert(PackageInManifest(Manifest(v, Line("deb", "Ray-0.2.48-linux-x64.deb", "536870913")), v, Kind::kDeb).reason == "tooLarge");
  assert(PackageInManifest(full + std::string(4096, 'x'), v, Kind::kDeb).reason == "tooLarge");
  assert(PackageInManifest("", v, Kind::kDeb).reason == "manifest");
  assert(PackageInManifest(full, "0.2", Kind::kDeb).reason == "manifest");

  const auto feed = FeedOverride("http://127.0.0.1:8765/");
  assert(feed && feed->port == 8765 && feed->base == "http://127.0.0.1:8765/");
  assert(ReleasesUrl(*feed) == "http://127.0.0.1:8765/releases.json");
  assert(FeedOverride("http://127.0.0.1:1/") && FeedOverride("http://127.0.0.1:65535/"));
  for (const char* bad : {"", "http://127.0.0.1/", "http://127.0.0.1:0/", "http://127.0.0.1:65536/", "http://127.0.0.1:08765/",
                          "http://127.0.0.1:8765", "http://127.0.0.1:8765/feed/", "https://127.0.0.1:8765/",
                          "http://localhost:8765/", "http://127.0.0.2:8765/", "http://127.0.0.1:8765@evil.example/",
                          "http://127.0.0.1:87a5/", "http://127.0.0.1:123456/"}) {
    assert(!FeedOverride(bad));
  }

  assert(DownloadUrl(v, "Ray-0.2.48-linux-update.txt", std::nullopt) ==
         "https://github.com/ray-browser/ray/releases/download/v0.2.48/Ray-0.2.48-linux-update.txt");
  assert(DownloadUrl(v, "Ray-0.2.48-linux-x64.deb", feed) == "http://127.0.0.1:8765/v0.2.48/Ray-0.2.48-linux-x64.deb");

  assert(AllowedRedirect("https", "github.com", 443, std::nullopt));
  assert(AllowedRedirect("https", "objects.githubusercontent.com", 443, std::nullopt));
  assert(AllowedRedirect("https", "release-assets.githubusercontent.com", 443, std::nullopt));
  assert(!AllowedRedirect("http", "github.com", 80, std::nullopt));
  assert(!AllowedRedirect("https", "github.com", 8443, std::nullopt));
  assert(!AllowedRedirect("https", "evil.example", 443, std::nullopt));
  assert(!AllowedRedirect("https", "github.com.evil.example", 443, std::nullopt));
  assert(!AllowedRedirect("https", "api.github.com", 443, std::nullopt));
  assert(!AllowedRedirect("https", "raw.githubusercontent.com", 443, std::nullopt));
  assert(!AllowedRedirect("ftp", "github.com", 443, std::nullopt));
  assert(!AllowedRedirect("http", "127.0.0.1", 8765, std::nullopt));
  assert(AllowedRedirect("http", "127.0.0.1", 8765, feed));
  assert(!AllowedRedirect("http", "127.0.0.1", 8766, feed));
  assert(!AllowedRedirect("http", "evil.example", 8765, feed));
  assert(AllowedRedirect("https", "github.com", 443, feed));

  InstallOutcome outcome = InstallOutcomeFor(v, false, 0, "installed 0.2.48", true);
  assert(outcome.ok && outcome.detail == "0.2.48");
  assert(InstallOutcomeFor(v, false, 0, "installed 0.2.49", true).detail == "install");
  assert(!InstallOutcomeFor(v, false, 1, "installed 0.2.48", true).ok);
  for (const char* reason : {"usage", "missing", "manifest", "signature", "notNewer", "kind", "checksum", "install", "busy", "timeout"}) {
    const InstallOutcome failed = InstallOutcomeFor(v, false, 1, std::string("failed ") + reason, true);
    assert(!failed.ok && failed.detail == reason);
  }
  assert(InstallOutcomeFor(v, false, 1, "failed somethingElse", true).detail == "install");
  assert(InstallOutcomeFor(v, false, 126, "", true).detail == "polkit");
  assert(InstallOutcomeFor(v, false, 127, "", true).detail == "polkit");
  assert(InstallOutcomeFor(v, false, 127, "", false).detail == "install");
  assert(InstallOutcomeFor(v, false, 127, "failed busy", true).detail == "busy");
  assert(InstallOutcomeFor(v, true, 0, "installed 0.2.48", true).detail == "timeout");
  assert(InstallOutcomeFor(v, false, -1, "", true).detail == "install");

  assert(kMaxManifestBytes == 4096 && kSignatureBytes == 64 && kMaxPackageBytes == 512ull * 1024 * 1024);
  assert(kInstallDeadlineSeconds == 600);
  assert(InstallOutcomeFor(v, false, 1, "failed timeout", true).detail == "timeout");
  for (const char* reason : {"signature", "checksum", "manifest", "notNewer"}) assert(DiscardsDownload(reason));
  for (const char* reason : {"polkit", "timeout", "busy", "install", "kind", "missing", "usage", "network", ""}) assert(!DiscardsDownload(reason));

  assert(CompareVersions("0.2.48", "0.2.48") == 0);
  assert(CompareVersions("0.2.47-nightly.9", "0.2.47") == -1);
  assert(CompareVersions("0.2.47", "0.2.48-nightly.1") == -1);
  assert(CompareVersions("0.2.48-nightly.10", "0.2.48-nightly.9") == 1);
  assert(CompareVersions("0.10.0", "0.9.99") == 1);
  assert(CompareVersions("1.0.0", "0.99.99") == 1);
  assert(CompareVersions("0.2.048", "0.2.48") == 0);
  assert(CompareVersions("0.2.48", "../0.2.48") == std::nullopt);

  UpdateState state;
  assert(state.phase == Phase::kIdle && state.run == 0 && !Busy(state));
  assert(!ClaimOutcome(state, 0) && !ClaimOutcome(state, 1));
  assert(BeginRun(state, "0.2.48"));
  assert(state.phase == Phase::kDownloading && state.run == 1 && state.version == "0.2.48" && Busy(state));
  assert(!BeginRun(state, "0.2.49") && state.run == 1 && state.version == "0.2.48");
  assert(!BeginRun(state, "bad") && state.run == 1 && state.phase == Phase::kDownloading);
  assert(!ClaimOutcome(state, 1));
  Downloaded(state, 1);
  assert(state.phase == Phase::kInstalling);
  Finished(state, 7, false, "network");
  assert(state.phase == Phase::kInstalling);
  Finished(state, 1, false, "signature");
  assert(state.phase == Phase::kFailed && state.reason == "signature");
  assert(!ClaimOutcome(state, 2) && ClaimOutcome(state, 1) && !ClaimOutcome(state, 1));
  assert(BeginRun(state, "0.2.48") && state.run == 2 && state.reason.empty() && !state.claimed);
  Downloaded(state, 2);
  Finished(state, 2, true, "");
  assert(state.phase == Phase::kReady && state.version == "0.2.48");
  assert(!BeginRun(state, "0.2.48") && !BeginRun(state, "0.2.47") && !BeginRun(state, "0.2.49") && state.run == 2 && state.phase == Phase::kReady);
  assert(!BeginRun(state, "x") && state.phase == Phase::kReady && state.run == 2 && state.version == "0.2.48");
  assert(ClaimOutcome(state, 2) && !ClaimOutcome(state, 2));
  UpdateState failing;
  assert(BeginRun(failing, "0.2.49") && failing.run == 1 && failing.phase == Phase::kDownloading);
  Finished(failing, 1, false, "kind");
  assert(!BeginRun(failing, "../x") && failing.phase == Phase::kFailed && failing.reason == "version" && failing.run == 2 && failing.version.empty());
  assert(ClaimOutcome(failing, 2) && !ClaimOutcome(failing, 1));
  assert(PhaseName(Phase::kIdle) == "idle" && PhaseName(Phase::kDownloading) == "downloading" && PhaseName(Phase::kInstalling) == "installing" &&
         PhaseName(Phase::kReady) == "ready" && PhaseName(Phase::kFailed) == "failed");

  assert(std::string(kSelfUpdateCapabilities[0]) == "RayUpdates.installKind");
  assert(std::string(kSelfUpdateCapabilities[1]) == "RayUpdates.update");
  assert(std::string(kSelfUpdateCapabilities[2]) == "RayUpdates.status");
  assert(std::string(kSelfUpdateCapabilities[3]) == "RayUpdates.claimOutcome");
  assert(std::string(kSelfUpdateCapabilities[4]) == "RayUpdates.restart");
  assert(sizeof(kSelfUpdateCapabilities) / sizeof(kSelfUpdateCapabilities[0]) == 5);
}
'''


class SelfUpdatePolicyTests(unittest.TestCase):
    def test_versions_manifests_feeds_redirects_and_install_reasons(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-self-update-policy-test-') as scratch:
            scratch = pathlib.Path(scratch)
            cpp = scratch / 'self_update.cc'
            cpp.write_text(POLICY_TEST, encoding='utf-8')
            binary = scratch / 'self_update'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Werror', '-fsanitize=address,undefined', '-I', str(SOURCE), str(cpp), '-o', str(binary)], capture_output=True, text=True)
            if compiled.returncode != 0:
                raise AssertionError(compiled.stderr)
            subprocess.run([str(binary)], check=True)

    def test_the_download_is_cookieless_capped_and_checks_every_redirect(self):
        source = (LINUX / 'ac_linux_self_update.cc').read_text()
        for needle in ['CredentialsMode::kOmit', 'SetOnRedirectCallback(', 'policy::AllowedRedirect(target.scheme(), target.host(), target.EffectiveIntPort()',
                       'loader_.reset();\n    Fail(policy::kNetworkReason);', 'DownloadToFile(', 'static_cast<int64_t>(max_bytes)',
                       'policy::kMaxManifestBytes', 'policy::kSignatureBytes', 'checked.package->size', 'net::ERR_INSUFFICIENT_RESOURCES ? policy::kTooLargeReason',
                       'cookies_allowed: NO', '"ray_linux_update_download"', 'system_network_context_manager()', 'SetTimeoutDuration(',
                       'policy::DownloadUrl(version_, name, linux_updates::UpdateFeed())', 'chrome::DIR_USER_DATA', 'policy::kUpdatesFolder',
                       'if (name != version && policy::ValidVersion(name)) base::DeletePathRecursively(entry);',
                       'if (updates.empty() || !EnsureRealDirectory(updates))', 'lstat(path.value().c_str(), &info) == 0 && S_ISDIR(info.st_mode)',
                       'if (outcome.ok || policy::DiscardsDownload(outcome.detail)) base::DeletePathRecursively(directory);']:
            self.assertIn(needle, source)
        for absent in ['GetDefaultStoragePartition', 'Profile', 'Authorization', 'CredentialsMode::kInclude']:
            self.assertNotIn(absent, source)

    def test_the_helper_runs_off_the_ui_thread_with_a_clean_environment_and_a_deadline(self):
        source = (LINUX / 'ac_linux_self_update.cc').read_text()
        for needle in ['base::ThreadPool::PostTaskAndReplyWithResult', 'base::MayBlock()', 'options.clear_environment = true',
                       'options.new_process_group = true', 'kill(-group, SIGTERM)', 'kill(-group, SIGKILL)',
                       'base::Seconds(policy::kInstallDeadlineSeconds)', 'base::Seconds(policy::kKindDeadlineSeconds)',
                       'environment["PATH"] = Text(policy::kHelperSearchPath)', 'environment["APPIMAGE"] = *appimage',
                       'HelperEnvironment(through_pkexec ? std::nullopt : appimage)', 'policy::kPkexecPaths',
                       'arguments.push_back("install")', 'arguments.push_back("--disable-internal-agent")', 'raycore::LinuxPackage().directory.Append(Text(policy::kHelperName))',
                       'base::BindOnce(&chrome::AttemptRestart)', 'DCHECK_CURRENTLY_ON(content::BrowserThread::UI)',
                       'options.allow_new_privs = lets_pkexec_gain_root;', 'base::Seconds(policy::kInstallDeadlineSeconds), through_pkexec);']:
            self.assertIn(needle, source)

    def test_the_test_feed_needs_an_isolated_instance_and_also_serves_the_release_list(self):
        updates = (LINUX / 'ac_linux_updates.cc').read_text()
        for needle in ['HasSwitch(switches::kUserDataDir)', 'GetVar("RAY_DATA_DIR")', 'GetVar("RAY_UPDATE_FEED")',
                       'if (!isolated) return std::optional<linux_self_update_policy::Feed>();',
                       'linux_self_update_policy::FeedOverride(', 'linux_self_update_policy::ReleasesUrl(*UpdateFeed())']:
            self.assertIn(needle, updates)

    def test_the_engine_owns_the_run_and_windows_only_start_observe_and_claim_it(self):
        source = (LINUX / 'ac_linux_self_update.cc').read_text()
        for needle in ['if (policy::BeginRun(state_, version))', 'policy::Downloaded(state_, run);', 'policy::Finished(state_, run, outcome.ok, outcome.detail);',
                       'return policy::ClaimOutcome(state_, run);', '.Set("phase", Text(policy::PhaseName(state_.phase)))', '.Set("run", state_.run)',
                       'method == "RayUpdates.status"', 'method == "RayUpdates.update"', 'method == "RayUpdates.claimOutcome"']:
            self.assertIn(needle, source)
        for gone in ['"RayUpdates.download"', '"RayUpdates.install"']:
            self.assertNotIn(gone, source)
            self.assertNotIn(gone, (LINUX / 'ac_linux_self_update_policy.h').read_text())

    def test_the_host_advertises_and_routes_the_update_calls(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        bootstrap = host[host.index('base::DictValue ShellHostView::Bootstrap() const {'):host.index('void ShellHostView::LayoutOverlay()')]
        self.assertIn('for (const char* capability : ray::linux_self_update_policy::kSelfUpdateCapabilities) capabilities.Append(capability);', bootstrap)
        self.assertIn('if (ray::linux_self_update::Invokes(method)) {\n    return ray::linux_self_update::Invoke(method, values, std::move(done));', host)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ['"ac_linux_self_update.cc"', '"ac_linux_self_update.h"', '"ac_linux_self_update_policy.h"']:
            self.assertIn(name, build)


if __name__ == '__main__':
    unittest.main()
