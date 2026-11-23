import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src'
LINUX = SOURCE / 'ray/linux'
REPO = ROOT.parents[1]


class NotificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='ray-notifications-')
        cls.binary = Path(cls.directory.name) / 'notifications-core'
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-Wall', '-Wextra', '-Werror', '-g',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-I', str(SOURCE),
                        str(ROOT / 'tests/notifications_core_test.cc'), '-o', str(cls.binary)],
                       check=True, text=True, timeout=180)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, scenario):
        result = subprocess.run([str(self.binary), scenario], text=True, timeout=60, capture_output=True,
                                env={**os.environ, 'UBSAN_OPTIONS': 'halt_on_error=1'})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, 'ok\n')

    def test_ids_references_and_text_are_bounded_and_clipped_on_character_boundaries(self):
        self.run_case('text')

    def test_a_click_always_answers_and_a_close_answers_only_for_a_dismissible_one_the_user_closed(self):
        self.run_case('responses')

    def test_the_oldest_notification_gives_way_at_the_limit(self):
        self.run_case('limit')

    def test_the_reply_and_event_shapes_are_the_macs(self):
        shared = (REPO / 'packages/shell/src/notifications.ts').read_text()
        for field in ('id: string;', 'action: "click" | "close";', 'tabId: string | null;', 'windowId: string | null;', 'data: unknown;'):
            self.assertIn(field, shared)
        self.assertIn('addListener(name: "onNotificationResponse"', shared)
        glue = (LINUX / 'ac_linux_notifications.cc').read_text()
        report = glue[glue.index('void Report('):glue.index('class Handler')]
        for key in ('"id"', '"action"', '"tabId"', '"windowId"', '"data"'):
            self.assertIn(f'.Set({key},', report)
        post = glue[glue.index('void PostNotification('):glue.index('void RemoveNotifications(')]
        for key in ('"id"', '"title"', '"body"', '"subtitle"', '"silent"', '"dismissible"', '"tabId"', '"windowId"', '"data"'):
            self.assertIn(key, post)
        self.assertIn('std::move(done).Run(true, base::Value(std::move(id)));', post)
        self.assertIn('kResponseEvent[] = "onNotificationResponse"', (LINUX / 'ac_linux_notifications_core.h').read_text())

    def test_notifications_go_through_chromiums_system_bridge_and_come_back_through_rays_handler(self):
        glue = (LINUX / 'ac_linux_notifications.cc').read_text()
        self.assertIn('constexpr NotificationHandler::Type kRayType = NotificationHandler::Type::NEARBY_SHARE;', glue)
        self.assertNotIn('Type::TRANSIENT', glue)
        service = glue[glue.index('NotificationDisplayServiceImpl* Service('):glue.index('std::optional<std::string> Text(')]
        self.assertIn('profile->GetOriginalProfile()', service)
        self.assertLess(service.index('!service->GetNotificationHandler(kRayType)'),
                        service.index('service->AddNotificationHandler(kRayType, std::make_unique<Handler>());'))
        handler = glue[glue.index('class Handler'):glue.index('NotificationDisplayServiceImpl* Service(')]
        self.assertEqual(handler.count('std::move(completed_closure).Run();'), 2)
        self.assertIn('Posted().Closed(*id, by_user)', handler)
        self.assertIn('Posted().Clicked(*id)', handler)
        self.assertIn('service->Close(kRayType, notification_id);', handler)
        post = glue[glue.index('void PostNotification('):glue.index('void RemoveNotifications(')]
        self.assertIn('service->Display(kRayType, notification, nullptr);', post)
        self.assertLess(post.index('if (BackgroundInstance())'), post.index('Service(profile)'))
        self.assertLess(post.index('notifications::ValidId(post.id)'), post.index('if (BackgroundInstance())'))
        remove = glue[glue.index('void RemoveNotifications('):glue.index('void InitLinuxNotifications(')]
        self.assertIn('BackgroundInstance() ? nullptr : Service(profile)', remove)
        self.assertNotIn('getenv', glue)
        build = (LINUX / 'BUILD.gn').read_text()
        for name in ('ac_linux_notifications.cc', 'ac_linux_notifications.h', 'ac_linux_notifications_core.cc',
                     'ac_linux_notifications_core.h', '//chrome/browser/notifications', '//ui/message_center/public/cpp'):
            self.assertIn(f'"{name}"', build)

    def test_the_host_routes_the_calls_and_sends_the_response_to_the_window_that_posted(self):
        host = (LINUX / 'ac_linux_host.cc').read_text()
        self.assertIn('if (raycore::LinuxNotificationsInvokes(method)) {\n    return raycore::LinuxNotificationsInvoke(method, values, profile(), id_, std::move(done));', host)
        self.assertIn('for (const char* capability : ray::linux_notifications::kNotificationCapabilities) capabilities.Append(capability);', host)
        self.assertIn('raycore::InitLinuxNotifications(base::BindRepeating(&ReportNotificationResponse));', host)
        report = host[host.index('void ReportNotificationResponse('):host.index('void BroadcastProfileLoaded(')]
        self.assertLess(report.index('posted->second->ShellLive()'), report.index('host->TakesOpenUrls()'))
        self.assertLess(report.index('if (!chosen) return;'), report.index('if (clicked) chosen->FocusWindow();'))
        self.assertIn('chosen->Event("RayApp", ray::linux_notifications::kResponseEvent, std::move(response));', report)
        core = (LINUX / 'ac_linux_notifications_core.h').read_text()
        fallbacks = (REPO / 'apps/linux/src/appModuleFallbacks.ts').read_text()
        for name in ('notificationPermission', 'requestNotificationPermission', 'postNotification', 'removeNotifications'):
            self.assertIn(f'"RayApp.{name}"', core)
            self.assertIn(f'  {name}: ', fallbacks)
        self.assertIn('if (hostSupports(`${name}.${method}`, host)) return undefined;', fallbacks)
        shim = (REPO / 'apps/linux/src/shims/expo-modules-core.ts').read_text()
        self.assertIn('const APP_PARTS = ["RayUpdater", "RayNotifications", "RayScripting", "RayDev"];', shim)


if __name__ == '__main__':
    unittest.main()
