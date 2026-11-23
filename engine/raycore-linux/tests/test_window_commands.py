import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class WindowCommandsTests(unittest.TestCase):
    def test_edit_actions_parse_exactly_and_full_screen_reports_the_state_it_is_going_to(self):
        with tempfile.TemporaryDirectory(prefix='ray-window-commands-') as directory:
            binary = Path(directory) / 'window-commands'
            subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                            '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                            str(ROOT / 'tests/window_commands_test.cc'), '-o', str(binary)],
                           check=True, text=True, timeout=180)
            result = subprocess.run([str(binary)], text=True, timeout=60, capture_output=True,
                                    env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, 'ok\n')

    def test_the_edit_names_are_the_macs_standard_selectors(self):
        catalog = (REPO / 'apps/browser/src/state/commands/commandCatalog.ts').read_text()
        core = (LINUX / 'ac_linux_window_commands.h').read_text()
        for name in ('undo', 'redo', 'cut', 'copy', 'paste', 'pasteAndMatchStyle', 'selectAll'):
            self.assertIn(f'"std:{name}:"', catalog)
            self.assertIn(f'{{"{name}", EditAction::', core)
        self.assertIn('"std:toggleFullScreen:"', catalog)

    def test_an_edit_command_acts_on_the_claimed_tab_and_refuses_an_unknown_action(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        command = host[host.index('void ShellHostView::TabCommand('):]
        claimed = command.index('TabBinding* binding = ClaimedBinding(args);')
        edit = command.index('} else if (command == ray::linux_commands::kEditCommand) {')
        self.assertLess(claimed, edit)
        body = command[edit:command.index('} else if (command == "resolveUnresponsive") {')]
        self.assertLess(body.index('if (!action) return std::move(done).Run(false,'), body.index('switch (*action)'))
        for call in ('Undo', 'Redo', 'Cut', 'Copy', 'Paste', 'PasteAndMatchStyle', 'SelectAll'):
            self.assertEqual(body.count(f'contents->{call}();'), 1)
        self.assertNotIn('default:', body)

    def test_full_screen_toggles_a_browser_window_the_caller_reaches_and_answers_the_new_state(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        route = host[host.index('if (method == "RayShell.windowFrame" || method == "RayShell.closeWindow" ||'):]
        self.assertLess(route.index('method == ray::linux_commands::kToggleFullScreenCall ||'), route.index('ShellHostView* target = nullptr;'))
        self.assertLess(route.index(': Reaches(host))) target = host;'), route.index('} else if (method == ray::linux_commands::kToggleFullScreenCall) {'))
        body = route[route.index('} else if (method == ray::linux_commands::kToggleFullScreenCall) {'):]
        body = body[:body.index('} else if (method == "RayShell.focusWindow") {')]
        self.assertIn('target->is_utility() ? nullptr : ExclusiveAccessManager::From(target->browser())', body)
        self.assertLess(body.index('if (!widget || !access) return std::move(done).Run(false,'), body.index('ToggleBrowserFullscreenMode(true)'))
        self.assertLess(body.index('FullScreenAfterToggle(widget->IsFullscreen())'), body.index('ToggleBrowserFullscreenMode(true)'))
        self.assertIn('return std::move(done).Run(true, base::Value(full_screen));', body)

    def test_the_host_advertises_both(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('for (const char* capability : ray::linux_commands::kWindowCommandCapabilities) capabilities.Append(capability);', host)
        core = (LINUX / 'ac_linux_window_commands.h').read_text()
        self.assertIn('kToggleFullScreenCall[] = "RayShell.toggleFullScreen"', core)
        self.assertIn('kEditCapability[] = "tab.edit"', core)
        self.assertIn('kReadTextCall[] = "RayShell.readText"', core)
        self.assertIn('kWindowCommandCapabilities[] = {"RayShell.toggleFullScreen", "tab.edit",\n'
                      '                                                             "RayShell.readText"}', core)
        self.assertIn('"ac_linux_window_commands.h"', (LINUX / 'BUILD.gn').read_text())

    def test_read_text_answers_the_copy_paste_clipboard_as_plain_text_and_takes_no_arguments(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        body = host[host.index('if (method == ray::linux_commands::kReadTextCall) {'):]
        body = body[:body.index('if (method == "RayShell.copyText") {')]
        self.assertLess(body.index('takes no arguments'), body.index('ReadText('))
        self.assertIn('clipboard->ReadText(ui::ClipboardBuffer::kCopyPaste,', body)
        self.assertIn('base::Value(base::UTF16ToUTF8(text))', body)
        self.assertIn('if (!clipboard) return std::move(done).Run(true, base::Value(""));', body)


if __name__ == '__main__':
    unittest.main()
