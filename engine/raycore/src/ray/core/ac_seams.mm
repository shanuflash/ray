#include "ray/core/ac_seams.h"

#import <AppKit/AppKit.h>

#include <memory>

#include "base/functional/callback.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/desktop_browser_window_capabilities.h"
#include "components/permissions/chooser_controller.h"
#include "components/sessions/content/content_live_tab.h"
#include "components/sessions/core/live_tab.h"
#include "components/sessions/core/session_id.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_install_prompt_client.h"
#include "extensions/common/extension_id.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_browser.h"
#include "ray/core/ac_cast_dialog.h"
#include "ray/core/ac_browser_window.h"
#include "ray/core/ac_desktop_capture.h"
#include "ray/core/ac_device_chooser.h"
#include "ray/core/ac_extension_shortcuts.h"
#include "ray/core/ac_extension_view.h"
#include "ray/core/ac_host_visibility.h"
#include "ray/core/ac_installed_bubble.h"
#include "ray/core/ac_launch_switches.h"
#include "ray/core/ac_windowless_page.h"
#include "ui/base/cocoa/drag_permission.h"
#import "ray/core/raycore_api_internal.h"
#import "ray/core/raycore_internal.h"

namespace raycore {

namespace {

bool HandlePasswordBubble(content::WebContents* web_contents) {
  WindowHost* host = WindowHost::ForContents(web_contents);
  return host && host->OfferPasswordSave(web_contents);
}

bool HandleExtensionSidePanel(BrowserWindowInterface* browser_window,
                              content::WebContents* web_contents,
                              const extensions::ExtensionId& extension_id,
                              bool open) {
  content::WebContents* contents = web_contents;
  if (!contents && browser_window && browser_window->GetActiveTabInterface()) {
    contents = browser_window->GetActiveTabInterface()->GetContents();
  }
  if (!WindowHost::ForContents(contents)) {
    return false;
  }
  return HostExtensionSidePanel(contents, extension_id, open);
}

bool OmitsFromSessionService(const BrowserWindowInterface* browser) {
  return ACBrowserWindow::IsOurs(browser);
}

bool IsHiddenFromExtensions(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && host->internal();
}

bool KeepsWindowWithoutTabs(const BrowserWindowInterface* browser) {
  WindowHost* host = WindowHost::ForBrowser(browser);
  return host && !host->closing() && !browser_shutdown::IsTryingToQuit();
}

std::unique_ptr<BrowserWebContentsDelegate> CreateWebContentsDelegate(
    BrowserWindowInterface* browser,
    ExclusiveAccessManager& exclusive_access_manager,
    chrome::BrowserCommandController& command_controller,
    UnloadController& unload_controller,
    web_app::AppBrowserController* app_browser_controller,
    BrowserWindow& window,
    DesktopBrowserWindowCapabilities& capabilities,
    BrowserUiController& browser_ui_controller) {
  ACBrowserWindow* ours = ACBrowserWindow::FromWindow(&window);
  if (!ours) {
    return nullptr;
  }
  ours->Register(browser);
  return std::make_unique<ACWebContentsDelegate>(
      browser, exclusive_access_manager, command_controller, unload_controller,
      app_browser_controller, window, capabilities, browser_ui_controller,
      ours->host_weak());
}

const char* BrowserTypeName(const BrowserWindowInterface* browser) {
  if (DesktopBrowserWindowCapabilities::IsDocumentPictureInPicture(browser)) {
    return "picture_in_picture";
  }
  switch (browser->GetType()) {
    case BrowserWindowInterface::TYPE_NORMAL:
      return "normal";
    case BrowserWindowInterface::TYPE_POPUP:
      return "popup";
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      return "devtools";
    case BrowserWindowInterface::TYPE_FLOATING:
      return "floating";
    default:
      return "app";
  }
}

BrowserWindow* WindowForChromeBrowser(Browser* browser) {
  if (ACBrowserWindow::IsOurs(browser) ||
      DesktopBrowserWindowCapabilities::IsDocumentPictureInPicture(browser)) {
    return nullptr;
  }
  RayCoreWindow* window = [g_delegate
      engineWindowForNewBrowserOfProfile:[RayCoreProfile
                                             wrapperFor:browser->GetProfile()]
                                    type:@(BrowserTypeName(browser))];
  WindowHost* host = window.host;
  return host ? host->HostChromeBrowser(browser) : nullptr;
}

bool IsReservedAccelerator(const ui::Accelerator& accelerator) {
  NSEvent* event = NSApp.currentEvent;
  return event.type == NSEventTypeKeyDown &&
         ExtensionShortcuts::AcceleratorFor(event) == accelerator &&
         [g_delegate engineIsReservedKeyEvent:event];
}

bool IsHistoryEligible(content::WebContents* contents) {
  WindowHost* host = WindowHost::ForContents(contents);
  return !host || !host->internal();
}

void DevToolsDockChanged(BrowserWindowInterface* browser,
                         content::WebContents* inspected,
                         content::WebContents* devtools) {
  if (WindowHost* host = WindowHost::ForBrowser(browser)) {
    host->DevToolsDockChanged(inspected, devtools);
  }
}

}

void InstallChromeHooks() {
  g_ray_browser_window_factory = &WindowForChromeBrowser;
  g_ray_reserved_accelerator = &IsReservedAccelerator;
  g_ray_reserved_global_accelerator = &IsReservedGlobalAccelerator;
  g_ray_global_shortcuts_resumed = &GlobalShortcutsResumed;
  g_ray_history_eligible = &IsHistoryEligible;
  InstallRuleMatchedHook();
  InstallExtensionInstalledHook();
  InstallActionPopupHook();
  g_ray_password_bubble = &HandlePasswordBubble;
  g_ray_extension_install_prompt = &HostExtensionInstallPrompt;
  g_ray_device_chooser = &HandleDeviceChooser;
  g_ray_media_access_request = &AnswerNativeDisplayCapture;
  g_ray_wants_cast_dialog = &WantsCastDialog;
  g_ray_cast_dialog = &HandleCastDialog;
  g_ray_extension_side_panel = &HandleExtensionSidePanel;
  g_ray_hidden_from_extensions = &IsHiddenFromExtensions;
  g_ray_keeps_window_without_tabs = &KeepsWindowWithoutTabs;
  g_ray_devtools_dock_changed = &DevToolsDockChanged;
  g_ray_create_web_contents_delegate = &CreateWebContentsDelegate;
  g_ray_initial_main_document_accessed = &InitialMainDocumentAccessed;
  g_ray_omits_from_session_service = &OmitsFromSessionService;
  g_ray_viewless_browsers = true;
  InstallWindowlessPageGeometry();
  if (TestFlag("nativeDragRefused")) {
    ui::RayRefuseDragSessionInitiation();
  }
}

}
