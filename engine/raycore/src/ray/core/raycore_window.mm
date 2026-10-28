#import "ray/core/public/RayCore.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/base64.h"
#include "base/pickle.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_tabrestore.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/sessions/core/serialized_navigation_entry.h"
#include "components/sessions/core/serialized_user_agent_override.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/window_open_disposition.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "url/gurl.h"
#include "ray/core/ac_browser.h"
#include "ray/core/ac_contents_background.h"
#include "ray/core/ac_extension_view.h"
#import "ray/core/raycore_internal.h"

@implementation RayCoreWindow {
  std::unique_ptr<raycore::WindowHost> _host;
}

@synthesize delegate = _delegate;

- (instancetype)initWithContentRect:(NSRect)rect {
  if ((self = [super init])) {
    _host = std::make_unique<raycore::WindowHost>(self,
                                                 gfx::ScreenRectFromNSRect(rect));
  }
  return self;
}

- (raycore::WindowHost*)host {
  return _host.get();
}

- (NSWindow*)window {
  return _host->ns_window();
}

- (NSView*)hostView {
  return _host->host_view();
}

- (RayCoreTab*)openTab:(NSString*)url
              profile:(RayCoreProfile*)profile
           foreground:(BOOL)foreground {
  Browser* browser = _host->BrowserFor(profile.chromeProfile);
  if (!browser) {
    return nil;
  }
  const bool ahead = !url.length;
  NavigateParams params(browser, GURL(ahead ? "about:blank" : base::SysNSStringToUTF8(url)),
                        ui::PAGE_TRANSITION_TYPED);
  params.disposition = foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                                  : WindowOpenDisposition::NEW_BACKGROUND_TAB;
  params.window_action = NavigateParams::WindowAction::kNoAction;
  base::AutoReset<raycore::WindowHost::PendingOpen> pending(
      &_host->pending_open(), raycore::WindowHost::PendingOpen{params.disposition, nullptr});
  Navigate(&params);
  content::WebContents* contents = params.navigated_or_inserted_contents;
  if (!contents) {
    return nil;
  }
  raycore::TabBridge* bridge = raycore::TabBridge::GetOrCreate(contents);
  if (ahead) {
    bridge->set_made_ahead();
    raycore::MarkAheadBlank(contents);
  }
  return bridge->tab();
}

- (RayCoreTab*)openExtensionView:(NSString*)url
                        profile:(RayCoreProfile*)profile
                           kind:(NSString*)kind {
  content::WebContents* contents = raycore::OpenExtensionView(
      _host->BrowserFor(profile.chromeProfile), GURL(base::SysNSStringToUTF8(url)),
      [kind isEqualToString:@"sidePanel"] ? raycore::ExtensionViewKind::kSidePanel
                                          : raycore::ExtensionViewKind::kPopup);
  return contents ? raycore::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (RayCoreProfile*)activeProfile {
  Profile* profile = _host->active_profile();
  return profile ? [RayCoreProfile wrapperFor:profile] : nil;
}

- (void)setActiveProfile:(RayCoreProfile*)profile {
  if (profile.chromeProfile) {
    _host->BrowserFor(profile.chromeProfile);
    _host->SetActiveProfile(profile.chromeProfile);
  }
}

- (void)activateTab:(RayCoreTab*)tab {
  if (raycore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self activateTab:tab];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser) {
    return;
  }
  auto focusing = raycore::TabBridge::GetOrCreate(contents)->HostFocuses();
  _host->NoteHostActivated(static_cast<Browser*>(browser));
  TabStripModel* model = browser->GetTabStripModel();
  int index = model->GetIndexOfWebContents(contents);
  if (index != TabStripModel::kNoTab && index != model->active_index()) {
    model->ActivateTabAt(index);
  }
}

- (NSArray<RayCoreTab*>*)tabsForProfile:(RayCoreProfile*)profile {
  NSMutableArray* tabs = [NSMutableArray array];
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  if (!browser) {
    return tabs;
  }
  TabStripModel* model = browser->GetTabStripModel();
  for (int i = 0; i < model->count(); ++i) {
    [tabs addObject:raycore::TabBridge::GetOrCreate(model->GetWebContentsAt(i))
                        ->tab()];
  }
  return tabs;
}

- (int)chromeWindowIdForProfile:(RayCoreProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser ? browser->GetSessionID().id() : -1;
}

- (BOOL)executeChromeCommand:(int)commandId profile:(RayCoreProfile*)profile {
  Browser* browser = _host->ExistingBrowserFor(profile.chromeProfile);
  return browser && chrome::ExecuteCommand(browser, commandId);
}

- (BOOL)internal {
  return _host->internal();
}

- (void)setInternal:(BOOL)internal {
  _host->set_internal(internal);
}

- (void)showInactive {
  _host->ShowInactive();
}

- (BOOL)actedFullScreen {
  return _host->acted_fullscreen();
}

- (void)setActedFullScreen:(BOOL)acted {
  _host->set_acted_fullscreen(acted);
}

- (void)adoptTab:(RayCoreTab*)tab {
  if (raycore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self adoptTab:tab];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* from =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  Browser* to = _host->BrowserFor(
      Profile::FromBrowserContext(contents->GetBrowserContext()));
  if (!from || !to || from == to) {
    return;
  }
  TabStripModel* source = from->GetTabStripModel();
  const int index = source->GetIndexOfWebContents(contents);
  if (index == TabStripModel::kNoTab) {
    return;
  }
  std::unique_ptr<tabs::TabModel> moved = source->DetachTabAtForInsertion(index);
  if (!moved) {
    return;
  }
  TabStripModel* target = to->GetTabStripModel();
  target->InsertDetachedTabAt(target->count(), std::move(moved),
                              AddTabTypes::ADD_NONE);
}

- (void)placeTab:(RayCoreTab*)tab index:(int)index pinned:(BOOL)pinned {
  if (raycore::IsNotifyingTabStrip()) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self placeTab:tab index:index pinned:pinned];
    });
    return;
  }
  content::WebContents* contents = tab.contents;
  if (!contents) {
    return;
  }
  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
  if (!browser || raycore::WindowHost::ForBrowser(browser) != _host.get()) {
    return;
  }
  TabStripModel* model = browser->GetTabStripModel();
  int at = model->GetIndexOfWebContents(contents);
  if (at == TabStripModel::kNoTab) {
    return;
  }
  if (model->IsTabPinned(at) != static_cast<bool>(pinned)) {
    at = model->SetTabPinned(at, pinned);
  }
  const int pinned_count = model->IndexOfFirstNonPinnedTab();
  int to = std::clamp(index, 0, model->count() - 1);
  to = pinned ? std::min(to, pinned_count - 1) : std::max(to, pinned_count);
  if (to != at) {
    model->MoveWebContentsAt(at, to, false);
  }
}

- (RayCoreTab*)restoreTab:(NSString*)state
                 profile:(RayCoreProfile*)profile
              foreground:(BOOL)foreground {
  if (raycore::IsNotifyingTabStrip()) {
    return nil;
  }
  std::optional<std::vector<uint8_t>> bytes =
      state ? base::Base64Decode(base::SysNSStringToUTF8(state)) : std::nullopt;
  Browser* browser = profile.chromeProfile ? _host->BrowserFor(profile.chromeProfile) : nullptr;
  if (!bytes || bytes->empty() || !browser) {
    return nil;
  }
  base::Pickle pickle = base::Pickle::WithUnownedBuffer(*bytes);
  base::PickleIterator it(pickle);
  int version = 0, selected = 0, count = 0;
  if (!it.ReadInt(&version) || version != 1 || !it.ReadInt(&selected) ||
      !it.ReadInt(&count) || count <= 0 || count > 1000) {
    return nil;
  }
  std::vector<sessions::SerializedNavigationEntry> navigations;
  for (int i = 0; i < count; ++i) {
    sessions::SerializedNavigationEntry entry;
    if (!entry.ReadFromPickle(&it)) {
      return nil;
    }
    navigations.push_back(std::move(entry));
  }
  selected = std::clamp(selected, 0, count - 1);
  base::AutoReset<raycore::WindowHost::PendingOpen> pending(
      &_host->pending_open(),
      raycore::WindowHost::PendingOpen{
          foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                     : WindowOpenDisposition::NEW_BACKGROUND_TAB,
          nullptr});
  content::WebContents* contents = chrome::AddRestoredTab(
      browser, navigations, browser->GetTabStripModel()->count(), selected,
      std::string(), std::nullopt, foreground,
      false, base::TimeTicks::Now(), base::Time::Now(),
      nullptr, sessions::SerializedUserAgentOverride(),
      {}, false,
      std::nullopt);
  return contents ? raycore::TabBridge::GetOrCreate(contents)->tab() : nil;
}

- (RayCoreTab*)duplicateTab:(RayCoreTab*)source
                   profile:(RayCoreProfile*)profile
                foreground:(BOOL)foreground {
  if (raycore::IsNotifyingTabStrip()) {
    return nil;
  }
  content::WebContents* contents = source.contents;
  Profile* chrome_profile = profile.chromeProfile;
  if (!contents || !chrome_profile ||
      Profile::FromBrowserContext(contents->GetBrowserContext()) != chrome_profile) {
    return nil;
  }
  Browser* browser = _host->BrowserFor(chrome_profile);
  if (!browser) {
    return nil;
  }
  std::unique_ptr<content::WebContents> copy = contents->Clone();
  content::WebContents* raw = copy.get();
  base::AutoReset<raycore::WindowHost::PendingOpen> pending(
      &_host->pending_open(),
      raycore::WindowHost::PendingOpen{
          foreground ? WindowOpenDisposition::NEW_FOREGROUND_TAB
                     : WindowOpenDisposition::NEW_BACKGROUND_TAB,
          contents->GetWeakPtr()});
  TabStripModel* model = browser->GetTabStripModel();
  model->InsertWebContentsAt(model->count(), std::move(copy),
                             foreground ? AddTabTypes::ADD_ACTIVE : AddTabTypes::ADD_NONE);
  return raycore::TabBridge::GetOrCreate(raw)->tab();
}

- (void)prepareProfile:(RayCoreProfile*)profile {
  if (profile.chromeProfile) {
    _host->BrowserFor(profile.chromeProfile);
  }
}

- (void)close {
  _host->Close();
}

@end
