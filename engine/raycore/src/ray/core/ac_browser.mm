#include "ray/core/ac_browser.h"

#import <AppKit/AppKit.h>

#include "base/auto_reset.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_delegate.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "ray/core/ac_browser_internal.h"
#include "ray/core/ac_contents_background.h"
#import "ray/core/raycore_internal.h"

namespace raycore {

const char* DispositionName(WindowOpenDisposition disposition) {
  switch (disposition) {
    case WindowOpenDisposition::kCurrentTab:
      return "current_tab";
    case WindowOpenDisposition::kSingletonTab:
      return "singleton_tab";
    case WindowOpenDisposition::kNewForegroundTab:
      return "foreground_tab";
    case WindowOpenDisposition::kNewBackgroundTab:
      return "background_tab";
    case WindowOpenDisposition::kNewPopup:
      return "popup";
    case WindowOpenDisposition::kNewWindow:
      return "window";
    case WindowOpenDisposition::kNewPictureInPicture:
      return "picture_in_picture";
    case WindowOpenDisposition::kOffTheRecord:
      return "off_the_record";
    case WindowOpenDisposition::kNewSplitView:
      return "split_view";
    default:
      return "other";
  }
}

namespace {

int g_tab_strip_notifying = 0;
int g_navigation_notifying = 0;

int& CounterOf(ScopedNotifying::Kind kind) {
  return kind == ScopedNotifying::Kind::kTabStrip ? g_tab_strip_notifying
                                                  : g_navigation_notifying;
}

bool Defer(bool notifying, dispatch_block_t retry) {
  if (notifying) {
    dispatch_async(dispatch_get_main_queue(), retry);
  }
  return notifying;
}

}

ScopedNotifying::ScopedNotifying(Kind kind) : kind_(kind) {
  ++CounterOf(kind_);
}

ScopedNotifying::~ScopedNotifying() {
  --CounterOf(kind_);
}

bool IsNotifyingTabStrip() {
  return g_tab_strip_notifying > 0;
}

bool DeferWhileTabStripNotifies(dispatch_block_t retry) {
  return Defer(IsNotifyingTabStrip(), retry);
}

bool IsNotifyingAny() {
  return IsNotifyingTabStrip() || g_navigation_notifying > 0;
}

bool DeferWhileAnyNotifies(dispatch_block_t retry) {
  return Defer(IsNotifyingAny(), retry);
}

void InitialMainDocumentAccessed(content::WebContents* contents) {
  if (contents) {
    EndAheadBlank(contents);
  }
  TabBridge* bridge = contents ? TabBridge::FromWebContents(contents) : nullptr;
  if (!bridge) {
    return;
  }
  RayCoreTab* tab = bridge->tab();
  ScopedNotifying notifying(ScopedNotifying::Kind::kNavigation);
  [tab notify:@selector(tabDidChangeURL:)];
  [tab notify:@selector(tabDidChangeNavigationState:)];
}

bool OnlyShowedBlank(content::WebContents* contents) {
  TabBridge* bridge = TabBridge::FromWebContents(contents);
  if (!bridge || !bridge->made_ahead()) {
    return false;
  }
  content::NavigationController& controller = contents->GetController();
  content::NavigationEntry* committed = controller.GetLastCommittedEntry();
  return controller.GetEntryCount() == 1 && committed && !committed->IsInitialEntry() &&
         committed->GetURL().IsAboutBlank();
}

void CloseBlankTabsBeforeWindowCloses(Browser* browser) {
  TabStripModel* model = browser->GetTabStripModel();
  if (IsNotifyingTabStrip() || !model) {
    return;
  }
  for (int i = model->count() - 1; i >= 0; --i) {
    if (OnlyShowedBlank(model->GetWebContentsAt(i))) {
      model->DetachAndDeleteWebContentsAt(i);
    }
  }
}

void DeleteTabClosedByHost(content::WebContents* contents, ClosedTabRecord record) {
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser) {
    return;
  }
  TabStripModel* model = browser->GetTabStripModel();
  const int index = model->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab) {
    return;
  }
  content::NavigationEntry* committed =
      contents->GetController().GetLastCommittedEntry();
  if (record == ClosedTabRecord::kRecentlyClosed &&
      !Profile::FromBrowserContext(contents->GetBrowserContext())
           ->IsOffTheRecord() &&
      committed && !committed->IsInitialEntry() && !OnlyShowedBlank(contents)) {
    model->delegate()->CreateHistoricalTab(contents);
  }
  model->DetachAndDeleteWebContentsAt(index);
}

}
