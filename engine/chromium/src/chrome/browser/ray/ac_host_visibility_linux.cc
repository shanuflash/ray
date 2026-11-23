// Copyright 2026 Ray. Apache-2.0.

#include "ray/core/ac_host_visibility.h"

#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_user_data.h"

bool (*g_ray_linux_automation_window)(const BrowserWindowInterface*) = nullptr;

namespace raycore {

namespace {

class ShownSlot : public content::WebContentsUserData<ShownSlot> {
 private:
  explicit ShownSlot(content::WebContents* contents)
      : content::WebContentsUserData<ShownSlot>(*contents) {}
  friend class content::WebContentsUserData<ShownSlot>;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(ShownSlot);

}

void NoteTabInShownSlot(content::WebContents* contents) {
  if (contents && !ShownSlot::FromWebContents(contents)) {
    ShownSlot::CreateForWebContents(contents);
  }
}

bool TabWasInShownSlot(content::WebContents* contents) {
  return contents && ShownSlot::FromWebContents(contents);
}

bool IsAutomationWindow(const BrowserWindowInterface* browser) {
  return g_ray_linux_automation_window && g_ray_linux_automation_window(browser);
}

bool InAutomationWindow(content::WebContents* contents) {
  BrowserWindowInterface* browser =
      contents ? GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents) : nullptr;
  return browser && IsAutomationWindow(browser);
}

}
