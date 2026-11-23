import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dispatch", ROOT / "gen_engine_dispatch.py")
DISPATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISPATCH)


def sources(platform):
    gn = (ROOT / "BUILD.gn").read_text()
    common = re.search(r"ray_sources = \[(.*?)\n\]", gn, re.S).group(1)
    taken = {f"is_{platform}", "!is_win"}
    blocks = re.findall(r"^if \((!?is_\w+)\) \{\n  ray_sources \+= \[(.*?)\n  \]\n", gn, re.S | re.M)
    specific = "".join(listed for condition, listed in blocks if condition in taken)
    return [ROOT / name for name in re.findall(r'"([^\"]+)"', common + specific)]


def service_sources(platform):
    return [path for path in sources(platform) if path.suffix in (".cc", ".mm")]


def linux_core_headers():
    apply = ROOT.parents[4] / "raycore-linux/apply.sh"
    listed = subprocess.run(["bash", str(apply), "--paths"], capture_output=True, text=True, check=True, timeout=20)
    return set(listed.stdout.split())


def write(root, path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise AssertionError(f"{command}: {result.stdout}{result.stderr}")
    return result


class RegistryTests(unittest.TestCase):
    def test_windows_excluded_sources_reach_mac_and_linux(self):
        for platform in ("mac", "linux"):
            names = {path.name for path in sources(platform)}
            self.assertIn("ac_local_storage.cc", names)
            self.assertIn("ac_passwords_page.cc", names)
            self.assertIn("ac_extension_mirror.cc", names)
        self.assertIn("ac_registrable_domains", DISPATCH.service_names(service_sources("linux")))

    def test_dispatch_registry_reads_the_sources_listed_before_it(self):
        gn = (ROOT / "BUILD.gn").read_text()
        self.assertLess(gn.index("if (!is_win) {\n  ray_sources += ["), gn.index('action("engine_dispatch_registry")'))

    def test_platforms_have_same_services(self):
        linux = DISPATCH.service_names(service_sources("linux"))
        mac = DISPATCH.service_names(service_sources("mac"))
        self.assertEqual(linux, mac)
        self.assertGreaterEqual(len(linux), 66)
        self.assertIn("ac_passwords_reveal", linux)
        self.assertIn("ac_downloads_settings", linux)
        self.assertIn("ac_tabs_last_tab_policy", linux)
        self.assertIn("ac_downloads_command", linux)
        self.assertIn(ROOT / "ac_engine_dispatch.cc", sources("linux"))
        self.assertNotIn(ROOT / "ac_engine_dispatch.cc", sources("mac"))

    def test_registry_keeps_every_declared_service(self):
        declared = set()
        for path in service_sources("linux"):
            declared.update(re.findall(r"^AC_(?:ENGINE|PROFILE|ARGS)_CALL\(\s*(\w+)", path.read_text(), re.M))
        self.assertEqual(set(DISPATCH.service_names(service_sources("linux"))), declared)

    def test_registry_reads_mixed_case_and_multiline_services(self):
        with tempfile.TemporaryDirectory() as folder:
            path = pathlib.Path(folder) / "calls.cc"
            path.write_text(
                "AC_PROFILE_CALL(ac_demo_getAll, ray::OffTheRecord::kAllow) {\n}\n"
                "AC_PROFILE_CALL(ac_demo_save,\n                ray::Sensitive{ray::kMax}) {\n}\n"
                "AC_ARGS_CALL(ac_demo_plain) {\n}\n"
            )
            self.assertEqual(DISPATCH.service_names([path]), ["ac_demo_getAll", "ac_demo_plain", "ac_demo_save"])

    def test_registry_is_deterministic_and_rejects_duplicates(self):
        paths = service_sources("linux")
        self.assertEqual(DISPATCH.service_names(paths), DISPATCH.service_names(paths[::-1]))
        with self.assertRaisesRegex(ValueError, "duplicate service"):
            DISPATCH.service_names([ROOT / "ac_external_apps.mm", ROOT / "ac_external_apps_linux.cc"])
        with self.assertRaisesRegex(ValueError, "no engine services"):
            DISPATCH.service_names([ROOT / "ac_engine_dispatch.cc"])

    def test_linux_excludes_apple_and_mac_host(self):
        linux = sources("linux")
        self.assertFalse(any(path.suffix == ".mm" for path in linux))
        self.assertNotIn(ROOT / "ac_reauth.cc", linux)
        for shared in ("ac_cli_control.cc", "ac_cli_token_policy.cc", "ac_cli_token_policy_web_targets.cc"):
            self.assertIn(ROOT / shared, linux)
            self.assertIn(ROOT / shared, sources("mac"))
        self.assertFalse((ROOT / "ac_cli_control_linux.cc").exists())
        provided = linux_core_headers()
        self.assertIn("ray/core/ac_launch_switches.h", provided)
        self.assertIn("ray/core/ac_windowless_page.h", provided)
        self.assertIn(ROOT / "ac_windowless_page_linux.cc", linux)
        self.assertNotIn(ROOT / "ac_windowless_page_linux.cc", sources("mac"))
        for path in service_sources("linux"):
            text = path.read_text()
            self.assertNotRegex(text, r'#(?:include|import) [<"](?:AppKit|Cocoa|Security|QuartzCore|base/apple)/')
            for header in re.findall(r'#(?:include|import) [<"](ray/core/[^>"]+)[>"]', text):
                self.assertIn(header, provided, f"{path.name} includes {header}, which the Linux engine does not provide")
        contexts = []
        for line in (ROOT / "BUILD.gn").read_text().splitlines():
            if "{" in line:
                contexts.append(line.strip())
            if "frameworks" in line or "ldflags" in line:
                self.assertIn("if (is_mac) {", contexts)
            if "}" in line:
                contexts.pop()
        self.assertFalse(contexts)


@unittest.skipUnless(shutil.which("clang++"), "clang++ is required")
class CompiledFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ray-services-fixture-")
        self.root = pathlib.Path(self.temp.name)
        write(self.root, "base/check.h", "#pragma once\n#include <cstdlib>\n#define CHECK(value) ((value) ? (void)0 : std::abort())\n")
        write(self.root, "content/public/browser/browser_thread.h", "#pragma once\nnamespace content {\nstruct BrowserThread {\n  enum ID { UI };\n  static inline bool on_ui = true;\n  static bool CurrentlyOn(ID) { return on_ui; }\n};\n}\n")

    def tearDown(self):
        self.temp.cleanup()

    def compile(self, source, main):
        executable = self.root / "fixture"
        checked([
            "clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
            "-I", str(self.root), "-I", str(ROOT.parents[2]),
            str(source), str(main), "-o", str(executable),
        ])
        return executable

    def test_real_dispatcher_routes_only_registry_and_preserves_callbacks(self):
        names = DISPATCH.service_names(service_sources("linux"))
        write(self.root, "chrome/browser/ray/ac_engine_dispatch.inc", DISPATCH.registry(names))
        definitions = []
        for name in names:
            definitions.append(
                f'extern "C" void {name}(const char* profile, const char* args, '
                'ac_engine_reply_t reply, void* context) {\n'
                '  assert(profile == expected_profile);\n'
                '  assert(args == expected_args);\n'
                f'  called = "{name}";\n'
                '  if (defer) { pending = reply; pending_context = context; }\n'
                '  else { reply(context, "{\\"ok\\":true}"); }\n}\n'
            )
        invocations = "\n".join(
            f'  called = ""; replies = 0; ac_engine_call("{name}", expected_profile, expected_args, Receive, &replies); '
            f'assert(called == "{name}"); assert(replies == 1);'
            for name in names
        )
        main = self.root / "main.cc"
        main.write_text('''#include "chrome/browser/ray/public/ac_engine.h"
#include "content/public/browser/browser_thread.h"
#include <cassert>
#include <string>
#include <string_view>
const char* expected_profile = "/scratch/Profile";
const char* expected_args = "{\\"offTheRecord\\":true}";
std::string_view called;
std::string payload;
int replies = 0;
bool defer = false;
ac_engine_reply_t pending = nullptr;
void* pending_context = nullptr;
void Receive(void* context, const char* json) {
  assert(context == &replies);
  ++*static_cast<int*>(context);
  payload = json;
}
''' + "\n".join(definitions) + '''
int main(int argc, char**) {
  if (argc > 1) {
    content::BrowserThread::on_ui = false;
    ac_engine_call("ac_passwords_reveal", expected_profile, expected_args, Receive, &replies);
    return 0;
  }
''' + invocations + '''
  for (const char* name : {"", "unknown", "ac_engine_set_event_sink", "ac_passwords_reveal;system", "__proto__"}) {
    called = "";
    replies = 0;
    ac_engine_call(name, expected_profile, expected_args, Receive, &replies);
    assert(called.empty());
    assert(replies == 1);
    assert(payload == "{\\"error\\":\\"unknown engine service\\"}");
  }
  replies = 0;
  ac_engine_call(nullptr, nullptr, nullptr, Receive, &replies);
  assert(replies == 1);
  called = "";
  ac_engine_call("ac_passwords_reveal", expected_profile, expected_args, nullptr, &replies);
  assert(called.empty());
  replies = 0;
  defer = true;
  ac_engine_call("ac_passwords_reveal", expected_profile, expected_args, Receive, &replies);
  assert(replies == 0);
  assert(pending);
  pending(pending_context, "{\\"ok\\":true}");
  assert(replies == 1);
}
''')
        executable = self.compile(ROOT / "ac_engine_dispatch.cc", main)
        checked([str(executable)])
        wrong_thread = subprocess.run([str(executable), "wrong-thread"], capture_output=True)
        self.assertLess(wrong_thread.returncode, 0)
        header = self.root / "abi.c"
        header.write_text('#include "chrome/browser/ray/public/ac_engine.h"\nac_engine_dispatch_t dispatch = ac_engine_call;\nac_engine_set_event_sink_t sink = ac_engine_set_event_sink;\n')
        checked(["clang", "-std=c11", "-Werror", "-fsyntax-only", "-I", str(ROOT.parents[2]), str(header)])


if __name__ == "__main__":
    unittest.main()
