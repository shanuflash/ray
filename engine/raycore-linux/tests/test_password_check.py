import os
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
#include <cstdlib>
#include <map>
#include <string>
#include "ray/linux/ac_linux_password_check.h"
#include "ray/linux/ac_linux_secret_text.h"
using namespace ray::linux_password;

int main(int, char** argv) {
  const std::string helper = argv[1];
  const std::string sleeper = argv[2];
  std::map<std::string, FileFacts> disk = {
      {"/", {false, true, 0, 040755}},
      {"/usr", {false, true, 0, 040755}},
      {"/usr/sbin", {false, true, 0, 040755}},
      {"/usr/sbin/unix_chkpwd", {true, false, 0, 0102755}},
      {"/home", {false, true, 0, 040755}},
      {"/home/me", {false, true, 1000, 040700}},
      {"/home/me/unix_chkpwd", {true, false, 0, 0100755}},
      {"/tmp", {false, true, 0, 041777}},
      {"/tmp/unix_chkpwd", {true, false, 0, 0100755}},
      {"/usr/sbin/writable", {true, false, 0, 0100777}},
      {"/usr/sbin/mine", {true, false, 1000, 0100755}},
      {"/usr/sbin/plain", {true, false, 0, 0100644}},
  };
  auto stat = [&disk](const std::string& path) -> std::optional<FileFacts> {
    auto found = disk.find(path);
    if (found == disk.end()) return std::nullopt;
    return found->second;
  };
  assert(TrustedHelperAt("/usr/sbin/unix_chkpwd", stat) == "/usr/sbin/unix_chkpwd");
  assert(!TrustedHelperAt("/home/me/unix_chkpwd", stat));
  assert(!TrustedHelperAt("/tmp/unix_chkpwd", stat));
  assert(!TrustedHelperAt("/usr/sbin/writable", stat));
  assert(!TrustedHelperAt("/usr/sbin/mine", stat));
  assert(!TrustedHelperAt("/usr/sbin/plain", stat));
  assert(!TrustedHelperAt("/usr/sbin/missing", stat));
  assert(!TrustedHelperAt("relative/unix_chkpwd", stat));
  assert(!TrustedHelperAt("", stat));

  assert(VerdictForExit(0) == Verdict::kMatch);
  assert(VerdictForExit(kWrongPasswordExit) == Verdict::kMismatch);
  assert(VerdictForExit(1) == Verdict::kFailed);
  assert(VerdictForExit(std::nullopt) == Verdict::kFailed);

  assert(UnusablePassword(""));
  assert(UnusablePassword(std::string(kMaxPasswordBytes + 1, 'a')));
  assert(UnusablePassword(std::string("a\0b", 3)));
  assert(!UnusablePassword(std::string(kMaxPasswordBytes, 'a')));
  assert(!UnusablePassword("correct horse"));

  Throttle throttle;
  assert(throttle.WaitMs(0) == 0);
  throttle.NoteWrong(1000);
  assert(throttle.WaitMs(1000) == 0);
  throttle.NoteWrong(1000);
  assert(throttle.WaitMs(1000) == 2000 && throttle.WaitMs(2500) == 500);
  throttle.NoteWrong(5000);
  assert(throttle.WaitMs(5000) == 5000);
  throttle.NoteWrong(10000);
  assert(throttle.WaitMs(10000) == 30000);
  for (int i = 0; i < 4; ++i) throttle.NoteWrong(50000);
  assert(throttle.WaitMs(50000) == 60000 && throttle.wrong() == 8);
  throttle.NoteRight();
  assert(throttle.WaitMs(50000) == 0 && throttle.wrong() == 0);

  SecretText typed(kMaxPasswordBytes);
  assert(typed.Insert(u"correct horse"));
  std::unique_ptr<SecretBytes> right = typed.Utf8();
  assert(right && right->view() == "correct horse");
  assert(RunHelper(helper, "me", right->view()) == Verdict::kMatch);
  assert(RunHelper(helper, "me", "wrong horse") == Verdict::kMismatch);
  assert(RunHelper(helper, "me", "correct") == Verdict::kMismatch);
  assert(RunHelper(helper, "someone", right->view()) == Verdict::kFailed);
  assert(RunHelper(sleeper, "me", right->view(), 300) == Verdict::kFailed);
  assert(RunHelper("/nonexistent/unix_chkpwd", "me", "x") == Verdict::kFailed);
  assert(CurrentUser() && !CurrentUser()->empty());
  std::puts("password check scenarios passed");
}
'''

FAKE_HELPER = '''#!/bin/bash
[ "$#" = 2 ] && [ "$2" = nonull ] || exit 3
[ -z "${HOME:-}${USER:-}${LD_PRELOAD:-}" ] || exit 4
[ "$1" = me ] || exit 9
IFS= read -r -d '' typed
[ "$typed" = "correct horse" ] && exit 0
exit 7
'''


class PasswordCheckTests(unittest.TestCase):
    def test_the_login_password_is_checked_by_a_trusted_root_helper_on_stdin_and_never_on_the_command_line(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-password-check-') as scratch:
            scratch = pathlib.Path(scratch)
            (scratch / 'scenarios.cc').write_text(SCENARIOS)
            helper = scratch / 'unix_chkpwd'
            helper.write_text(FAKE_HELPER)
            helper.chmod(0o755)
            sleeper = scratch / 'sleeper'
            sleeper.write_text('#!/bin/bash\nsleep 30\n')
            sleeper.chmod(0o755)
            binary = scratch / 'scenarios'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g', '-fsanitize=address,undefined',
                                       '-I', str(SOURCE), str(scratch / 'scenarios.cc'), str(LINUX / 'ac_linux_password_check.cc'),
                                       str(LINUX / 'ac_linux_secret_text.cc'), '-o', str(binary)], capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary), str(helper), str(sleeper)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('password check scenarios passed', result.stdout)

    def test_the_prompt_is_native_installed_at_startup_and_hands_reauth_its_answer(self):
        prompt = (LINUX / 'ac_linux_password_prompt.cc').read_text()
        for needle in ['PasswordField>(u"Login password")', 'ModalType::kWindow', 'ForEachCurrentBrowserWindowInterfaceOrderedByActivation(',
                       'ray::SetReauthFallback(', 'base::MayBlock()', 'field_->TakeUtf8()', 'std::unique_ptr<SecretBytes> password',
                       'TheThrottle().WaitMs(NowMs())']:
            self.assertIn(needle, prompt)
        for needle in ['LOG(', 'Textfield', 'SetPromptField', 'GetText(', 'UTF16ToUTF8(', 'std::string password']:
            self.assertNotIn(needle, prompt)
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('ray::linux_password::InstallReauthFallback();', host)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ['"ac_linux_password_check.cc"', '"ac_linux_password_field.cc"', '"ac_linux_password_prompt.cc"',
                     '"ac_linux_secret_text.cc"']:
            self.assertIn(name, build)


if __name__ == '__main__':
    unittest.main()
