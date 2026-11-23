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
#include <string>
#include <string_view>
#include "ray/linux/ac_linux_secret_text.h"
using namespace ray::linux_password;

static bool Zero(const char16_t* units, size_t from, size_t to) {
  for (size_t i = from; i < to; ++i) {
    if (units[i] != 0) return false;
  }
  return true;
}

int main() {
  SecretText text(512);
  assert(text.ok() && text.empty() && text.CodePoints() == 0);
  assert(text.Insert(u"abc"));
  assert(text.view() == u"abc" && text.cursor() == 3);
  text.MoveLeft();
  assert(text.cursor() == 2);
  assert(text.Insert(u"X"));
  assert(text.view() == u"abXc" && text.cursor() == 3);
  text.Backspace();
  assert(text.view() == u"abc" && text.cursor() == 2);
  text.DeleteForward();
  assert(text.view() == u"ab" && text.cursor() == 2);
  text.MoveHome();
  assert(text.Insert(u"0"));
  assert(text.view() == u"0ab" && text.cursor() == 1);
  text.MoveEnd();
  assert(text.cursor() == 3);
  text.BackspaceToStart();
  assert(text.empty() && text.cursor() == 0);

  assert(text.Insert(u"secret"));
  const char16_t* units = text.view().data();
  text.Backspace();
  text.Backspace();
  text.Backspace();
  assert(text.view() == u"sec" && Zero(units, 3, 6));
  text.MoveHome();
  text.DeleteForward();
  assert(text.view() == u"ec" && Zero(units, 2, 6));
  text.Clear();
  assert(text.empty() && Zero(units, 0, 512));

  assert(text.Insert(u"replace me"));
  text.SelectAll();
  assert(text.all_selected());
  assert(text.Insert(u"z"));
  assert(text.view() == u"z" && !text.all_selected() && Zero(units, 1, 10));
  text.SelectAll();
  text.Backspace();
  assert(text.empty() && Zero(units, 0, 10));
  assert(text.Insert(u"left"));
  text.SelectAll();
  text.MoveLeft();
  assert(!text.all_selected() && text.cursor() == 0 && text.view() == u"left");
  text.SelectAll();
  text.MoveRight();
  assert(!text.all_selected() && text.cursor() == 4);
  text.Clear();

  assert(text.Insert(std::u16string_view(u"a\nb\tc\x7f\u0085d\0ef", 11)));
  assert(text.view() == u"abcdef");
  assert(text.Insert(u"\n"));
  assert(text.view() == u"abcdef");
  text.Clear();

  assert(text.Insert(u"a\U0001F600b"));
  assert(text.size() == 4 && text.CodePoints() == 3);
  text.MoveLeft();
  assert(text.cursor() == 3 && text.CodePointsBeforeCursor() == 2);
  text.MoveLeft();
  assert(text.cursor() == 1 && text.CodePointsBeforeCursor() == 1);
  text.MoveRight();
  assert(text.cursor() == 3);
  text.Backspace();
  assert(text.view() == u"ab" && text.cursor() == 1);
  text.Clear();

  assert(text.Insert(std::u16string_view(u"\xD83D", 1)));
  assert(text.Insert(std::u16string_view(u"\xDE00", 1)));
  assert(text.CodePoints() == 1);
  text.Clear();

  assert(text.Insert(u"xé\U0001F600"));
  std::unique_ptr<SecretBytes> utf8 = text.Utf8();
  assert(utf8 && utf8->view() == "x\xC3\xA9\xF0\x9F\x98\x80");
  const char* bytes = utf8->view().data();
  utf8->Clear();
  assert(utf8->view().empty());
  for (int i = 0; i < 7; ++i) assert(bytes[i] == 0);
  text.Clear();

  assert(text.Insert(std::u16string_view(u"a\xDC00", 2)));
  utf8 = text.Utf8();
  assert(utf8 && utf8->view() == "a\xEF\xBF\xBD");
  text.Clear();

  assert(text.Insert(u"abcdef"));
  text.MoveLeft();
  text.MoveLeft();
  text.DeleteSurrounding(1, 1);
  assert(text.view() == u"abcf" && text.cursor() == 3);
  text.DeleteSurrounding(100, 100);
  assert(text.empty() && Zero(units, 0, 6));

  SecretText small(4);
  assert(small.Insert(u"abcd"));
  assert(!small.Insert(u"e"));
  assert(small.view() == u"abcd");
  assert(!small.Insert(u"\U0001F600"));
  small.SelectAll();
  assert(small.Insert(u"wxyz"));
  assert(small.view() == u"wxyz");
  std::unique_ptr<SecretBytes> full = small.Utf8();
  assert(full && full->view() == "wxyz");

  SecretBytes tight(3);
  assert(tight.Append("abc"));
  assert(!tight.Append("d"));
  assert(tight.view() == "abc");

  {
    SecretText sized(512);
    std::u16string many(512, u'一');
    assert(sized.Insert(many));
    std::unique_ptr<SecretBytes> wide = sized.Utf8();
    assert(wide && wide->view().size() == 512 * 3);
  }
  std::puts("secret text scenarios passed");
}
'''


class PasswordFieldTests(unittest.TestCase):
    def test_typed_secrets_live_in_wiped_pages_and_encode_to_utf8_without_copies(self):
        compiler = shutil.which('clang++') or shutil.which('c++')
        if compiler is None:
            self.skipTest('C++ compiler is unavailable')
        with tempfile.TemporaryDirectory(prefix='ray-secret-text-') as scratch:
            scratch = pathlib.Path(scratch)
            (scratch / 'scenarios.cc').write_text(SCENARIOS)
            binary = scratch / 'scenarios'
            compiled = subprocess.run([compiler, '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g', '-fsanitize=address,undefined',
                                       '-I', str(SOURCE), str(scratch / 'scenarios.cc'), str(LINUX / 'ac_linux_secret_text.cc'),
                                       '-o', str(binary)], capture_output=True, text=True, timeout=180)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('secret text scenarios passed', result.stdout)

    def test_secret_pages_are_kept_out_of_core_dumps_swap_and_forks(self):
        secret = (LINUX / 'ac_linux_secret_text.cc').read_text()
        for needle in ['MAP_PRIVATE | MAP_ANONYMOUS', 'MADV_DONTDUMP', 'MADV_WIPEONFORK', 'mlock(', 'WipeBytes(data_, mapped_);',
                       'munmap(data_, mapped_);', 'volatile unsigned char*']:
            self.assertIn(needle, secret)

    def test_the_field_never_hands_its_text_to_views_text_models_or_the_ime(self):
        field = (LINUX / 'ac_linux_password_field.cc').read_text()
        header = (LINUX / 'ac_linux_password_field.h').read_text()
        for source in (field, header):
            for needle in ['views::Textfield', 'textfield/textfield.h', 'TextfieldModel', 'RenderText::Create',
                           'Clipboard', 'std::u16string text_', 'LOG(']:
                self.assertFalse(needle in source, needle)
        self.assertEqual(field.count('SetValue('), 1)
        blur = field[field.index('void PasswordField::OnBlur() {'):]
        blur = blur[:blur.index('\n}\n')]
        self.assertNotIn('DropComposition()', blur)
        self.assertIn('Accept(text_.Insert(composition_.view()));', blur)
        for needle in ['SecretText text_;', 'SecretText composition_;']:
            self.assertTrue(needle in header, needle)
        for needle in ['ui::TEXT_INPUT_TYPE_PASSWORD', 'SetIsProtected(true)', 'Bullets(total)', 'accessibility.SetValue(Bullets(total));',
                       'SetTextSelStart(static_cast<int32_t>(selected ? 0 : caret));',
                       'SetTextSelEnd(static_cast<int32_t>(selected ? total : caret));',
                       '!overflowed_ && text_.Insert(composition_.view())', 'Accept(text_.Insert(std::u16string_view(&unit, 1)));',
                       'Accept(text_.Insert(text));', 'Accept(composition_.Insert(composition.text));',
                       'bool PasswordField::GetTextFromRange(const gfx::Range& range, std::u16string* text) const {\n  return false;\n}',
                       'bool PasswordField::GetTextRange(gfx::Range* range) const {\n  return false;\n}',
                       'case ui::VKEY_V:']:
            self.assertTrue(needle in field, needle)


if __name__ == '__main__':
    unittest.main()
