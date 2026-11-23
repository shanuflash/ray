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


class CrashDumpTests(unittest.TestCase):
    def test_ids_cursor_newest_and_version_rules(self):
        with tempfile.TemporaryDirectory(prefix='ray-crash-') as directory:
            binary = Path(directory) / 'crash-dumps'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/crash_dumps_core_test.cc'), str(LINUX / 'ac_linux_crash_dumps_core.cc'),
                            '-o', str(binary)], check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_dumps_come_from_chromiums_crashpad_database_off_the_ui_thread(self):
        source = (LINUX / 'ac_linux_crash_dumps.cc').read_text()
        self.assertIn('base::PathService::Get(chrome::DIR_CRASH_DUMPS, &folder)', source)
        self.assertIn('Database::InitializeWithoutCreating(folder)', source)
        listing = body(source, 'std::vector<crash::Dump> ListDumps(', 'std::optional<std::string> ReadDump(')
        self.assertIn('GetPendingReports(&reports)', listing)
        self.assertIn('GetCompletedReports(&reports)', listing)
        self.assertIn('crash::Newest(std::move(dumps), since)', listing)
        reading = body(source, 'std::optional<std::string> ReadDump(', 'bool LinuxCrashInvokes(')
        self.assertLess(reading.index('crash::IsReportId(id)'), reading.index('LookUpCrashReport(uuid, &report)'))
        self.assertIn('base::ReadFileToStringWithMaxSize(report.file_path, &bytes, crash::kReadMaxBytes)', reading)
        self.assertIn('base::Base64Encode(bytes)', reading)
        invoke = source[source.index('void LinuxCrashInvoke('):]
        self.assertEqual(invoke.count('base::ThreadPool::PostTaskAndReplyWithResult('), 2)
        self.assertIn('base::MayBlock()', invoke)
        self.assertNotIn('base::DeleteFile', source)

    def test_the_host_serves_regular_browser_windows_only_and_names_what_the_shell_calls(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        route = body(host, 'if (raycore::LinuxCrashInvokes(method)) {', 'if (raycore::LinuxReportInvokes(method)) {')
        self.assertIn('if (is_utility() || private_window() || !private_window_.empty()) {', route)
        self.assertLess(route.index('ERR_UNAVAILABLE'), route.index('raycore::LinuxCrashInvoke(method, values, std::move(done))'))
        self.assertIn('  if (!is_utility()) {\n    for (const char* capability : ray::linux_crash::kCrashCapabilities) capabilities.Append(capability);\n  }', host)
        start = body(host, 'void StartLinuxHost() {', 'g_ray_auto_picture_in_picture_off = true;')
        self.assertIn('raycore::AnnotateLinuxCrashVersion();', start)
        core = (LINUX / 'ac_linux_crash_dumps_core.h').read_text()
        shell = (REPO / 'apps/linux/src/hostCrashReports.ts').read_text()
        for constant, value in (('kCapability', 'crash.dumps'), ('kListCall', 'RayCrash.list'), ('kReadCall', 'RayCrash.read'), ('kVersionKey', 'ray-ver')):
            self.assertIn(f'inline constexpr char {constant}[] = "{value}";', core)
            self.assertIn(f'"{value}"', shell)
        self.assertIn('kListMost = 32', core)
        self.assertRegex(shell, r'READ_AT_MOST = 16;')
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_crash_dumps.cc', 'ac_linux_crash_dumps_core.cc', '//third_party/crashpad/crashpad/client', '//components/crash/core/common:crash_key'):
            self.assertIn(f'"{name}"', build)


if __name__ == '__main__':
    unittest.main()
