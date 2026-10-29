#include "ray/core/ac_modal_dialog_host.h"

#import <AppKit/AppKit.h>

#include <algorithm>

#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "ray/core/ac_browser.h"

namespace raycore {

namespace {

int g_dialog_host_observers = 0;
id g_frame_change_observer = nil;

}

gfx::Rect PageRectInHostView(NSView* host_view, content::WebContents* contents) {
  if (!host_view) {
    return gfx::Rect();
  }
  NSRect bounds = host_view.bounds;
  NSRect page = bounds;
  NSView* view = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  if (view && view.window == host_view.window && view.superview &&
      [view isDescendantOf:host_view.window.contentView]) {
    page = NSIntersectionRect([view convertRect:view.bounds toView:host_view],
                              bounds);
    if (NSIsEmptyRect(page)) {
      page = bounds;
    }
  }
  const CGFloat top = host_view.isFlipped ? NSMinY(page)
                                          : NSHeight(bounds) - NSMaxY(page);
  return gfx::Rect(NSMinX(page), top, NSWidth(page), NSHeight(page));
}

gfx::Point DialogPositionInHostView(NSView* host_view,
                                    const gfx::Rect& page,
                                    const gfx::Size& size) {
  const int host_width = host_view ? NSWidth(host_view.bounds) : page.right();
  int x = page.x() + (page.width() - size.width()) / 2;
  x = std::min(x, host_width - size.width());
  x = std::max(x, 0);
  // Ray: centred on the page both ways, as Arc and Dia show tab-modal dialogs,
  // rather than hanging from its top edge as Chrome's do.
  const int y = page.y() + std::max(0, (page.height() - size.height()) / 2);
  return gfx::Point(x, y);
}

bool WindowIsForeground(NSWindow* window) {
  if (!window || !NSApp.isActive) {
    return false;
  }
  if (NSApp.mainWindow == window) {
    return true;
  }
  for (NSWindow* key = NSApp.keyWindow; key;
       key = key.parentWindow ?: key.sheetParent) {
    if (key == window) {
      return true;
    }
  }
  return false;
}

void DialogHostObserverAdded() {
  if (++g_dialog_host_observers != 1 || g_frame_change_observer) {
    return;
  }
  g_frame_change_observer = [NSNotificationCenter.defaultCenter
      addObserverForName:NSViewFrameDidChangeNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification* notification) {
                NSView* view = notification.object;
                if (![view isKindOfClass:[NSView class]]) {
                  return;
                }
                if (WindowHost* host = WindowHost::ForNSWindow(view.window)) {
                  host->ScheduleDialogPositionUpdate();
                }
              }];
}

void DialogHostObserverRemoved() {
  if (g_dialog_host_observers == 0 || --g_dialog_host_observers != 0 ||
      !g_frame_change_observer) {
    return;
  }
  [NSNotificationCenter.defaultCenter removeObserver:g_frame_change_observer];
  g_frame_change_observer = nil;
}

ACTabDialogHost::ACTabDialogHost(content::WebContents* contents)
    : content::WebContentsUserData<ACTabDialogHost>(*contents) {}

ACTabDialogHost::~ACTabDialogHost() {
  for (auto& observer : observers_) {
    observer.OnHostDestroying();
  }
  for ([[maybe_unused]] auto& observer : observers_) {
    DialogHostObserverRemoved();
  }
}

WindowHost* ACTabDialogHost::window_host() const {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(
      const_cast<content::WebContents*>(&GetWebContents()));
  return tab ? WindowHost::ForBrowser(tab->GetBrowserWindowInterface())
             : nullptr;
}

gfx::NativeView ACTabDialogHost::GetHostView() const {
  WindowHost* host = window_host();
  return host ? gfx::NativeView(host->host_view()) : gfx::NativeView();
}

gfx::Point ACTabDialogHost::GetDialogPosition(const gfx::Size& size) {
  WindowHost* host = window_host();
  NSView* host_view = host ? host->host_view() : nil;
  return DialogPositionInHostView(
      host_view, PageRectInHostView(host_view, &GetWebContents()), size);
}

bool ACTabDialogHost::ShouldActivateDialog() const {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(
      const_cast<content::WebContents*>(&GetWebContents()));
  WindowHost* host = window_host();
  return tab && tab->GetBrowserWindowInterface() && host &&
         GetLastActiveBrowserWindowInterfaceWithAnyProfile() ==
             tab->GetBrowserWindowInterface() &&
         WindowIsForeground(host->ns_window());
}

gfx::Size ACTabDialogHost::GetMaximumDialogSize() {
  WindowHost* host = window_host();
  return PageRectInHostView(host ? host->host_view() : nil, &GetWebContents())
      .size();
}

void ACTabDialogHost::AddObserver(web_modal::ModalDialogHostObserver* observer) {
  if (observers_.HasObserver(observer)) {
    return;
  }
  observers_.AddObserver(observer);
  DialogHostObserverAdded();
}

void ACTabDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  if (!observers_.HasObserver(observer)) {
    return;
  }
  observers_.RemoveObserver(observer);
  DialogHostObserverRemoved();
}

void ACTabDialogHost::NotifyPositionRequiresUpdate() {
  observers_.Notify(
      &web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(ACTabDialogHost);

}
