#import "ray/core/public/RayCore.h"

#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/apps/platform_apps/shortcut_manager.h"
#include "chrome/browser/ray/ac_tab_restore.h"  // nogncheck
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/desktop_browser_window_capabilities.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/prefs/pref_service.h"
#include "components/version_info/version_info.h"
#include "content/public/browser/browser_thread.h"
#include "ray/core/ac_browser.h"
#include "ray/core/ac_browser_window.h"
#include "ray/core/ac_cast_dialog.h"
#include "ray/core/ac_content_hooks.h"
#include "ray/core/ac_desktop_capture.h"
#include "ray/core/ac_device_chooser.h"
#include "ray/core/ac_extension_shortcuts.h"
#include "ray/core/ac_extension_view.h"
#include "ray/core/ac_external_apps.h"
#include "ray/core/ac_hooks.h"
#include "ray/core/ac_host_visibility.h"
#include "ray/core/ac_installed_bubble.h"
#include "ray/core/ac_lifetime.h"
#include "ray/core/ac_main_delegate.h"
#include "ray/core/ac_page_channel.h"
#include "ray/core/ac_permissions.h"
#include "ray/core/ac_picture_in_picture.h"
#include "ray/core/ac_video_upscaling.h"
#import "ray/core/raycore_api_internal.h"
#import "ray/core/raycore_internal.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace raycore {

id<RayCoreEngineDelegate> __strong g_delegate;
RayCoreEngine* __strong g_engine;

NSString* NS(const std::string& s) {
  return base::SysUTF8ToNSString(s);
}

NSString* NS(const std::u16string& s) {
  return base::SysUTF16ToNSString(s);
}

}

using raycore::g_delegate;
using raycore::g_engine;
using raycore::NS;

namespace {

bool g_auto_picture_in_picture = true;

void ApplyAutoPictureInPicture(Profile* profile) {
  g_ray_auto_picture_in_picture_off = !g_auto_picture_in_picture;
  HostContentSettingsMapFactory::GetForProfile(profile)->SetDefaultContentSetting(
      ContentSettingsType::AUTO_PICTURE_IN_PICTURE,
      g_auto_picture_in_picture ? CONTENT_SETTING_ALLOW : CONTENT_SETTING_BLOCK);
}

void PrepareProfilePrefs(Profile* profile) {
  if (!profile || profile->IsOffTheRecord()) {
    return;
  }
  PrefService* prefs = profile->GetPrefs();
  if (prefs->FindPreference("session.restore_on_startup")) {
    prefs->SetInteger("session.restore_on_startup", 5);
  }
  if (prefs->FindPreference("download_bubble.partial_view_enabled")) {
    prefs->SetBoolean("download_bubble.partial_view_enabled", false);
  }
  ApplyAutoPictureInPicture(profile);
}

class ProfilePrefsApplier : public ProfileManagerObserver {
 public:
  explicit ProfilePrefsApplier(ProfileManager* manager) {
    observation_.Observe(manager);
  }
  void OnProfileAdded(Profile* profile) override { PrepareProfilePrefs(profile); }
  void OnProfileManagerDestroying() override { observation_.Reset(); }

 private:
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> observation_{this};
};

void StartApplyingProfilePrefs() {
  ProfileManager* manager = g_browser_process->profile_manager();
  for (Profile* profile : manager->GetLoadedProfiles()) {
    PrepareProfilePrefs(profile);
  }
  static base::NoDestructor<ProfilePrefsApplier> applier(manager);
}

const char* BrowserTypeName(BrowserWindowInterface::Type type) {
  switch (type) {
    case BrowserWindowInterface::TYPE_NORMAL:
      return "normal";
    case BrowserWindowInterface::TYPE_POPUP:
      return "popup";
    case BrowserWindowInterface::TYPE_DEVTOOLS:
      return "devtools";
    case BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE:
      return "picture_in_picture";
    default:
      return "app";
  }
}

BrowserWindow* WindowForChromeBrowser(Browser* browser) {
  if (raycore::ACBrowserWindow::IsOurs(browser) ||
      browser->GetType() == BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE ||
      ![g_delegate respondsToSelector:@selector
                   (engineWindowForNewBrowserOfProfile:type:)]) {
    return nullptr;
  }
  RayCoreWindow* window = [g_delegate
      engineWindowForNewBrowserOfProfile:[RayCoreProfile
                                             wrapperFor:browser->GetProfile()]
                                    type:@(BrowserTypeName(browser->GetType()))];
  raycore::WindowHost* host = window.host;
  return host ? host->HostChromeBrowser(browser) : nullptr;
}

}

extern "C" __attribute__((visibility("default"))) int RayCoreMain(
    int argc,
    const char** argv) {
  return ChromeMain(argc, argv);
}

@implementation RayCoreEngine

+ (int)runWithArgc:(int)argc
              argv:(const char**)argv
          delegate:(id<RayCoreEngineDelegate>)delegate {
  bool is_browser = true;
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--type=", 7) == 0) {
      is_browser = false;
    }
  }
  if (!is_browser) {
    return ChromeMain(argc, argv);
  }

  g_delegate = delegate;
  g_engine = [[RayCoreEngine alloc] init];
  g_ray_browser_window_factory = &WindowForChromeBrowser;
  raycore::InstallRuleMatchedHook();
  raycore::InstallExtensionInstalledHook();
  raycore::InstallActionPopupHook();
  g_ray_reserved_accelerator = [](const ui::Accelerator& accelerator) {
    NSEvent* event = NSApp.currentEvent;
    return event.type == NSEventTypeKeyDown &&
           raycore::ExtensionShortcuts::AcceleratorFor(event) == accelerator &&
           [g_delegate respondsToSelector:@selector(engineIsReservedKeyEvent:)] &&
           [g_delegate engineIsReservedKeyEvent:event];
  };
  g_ray_reserved_global_accelerator = &raycore::IsReservedGlobalAccelerator;
  g_ray_global_shortcuts_resumed = &raycore::GlobalShortcutsResumed;
  g_ray_history_eligible = [](content::WebContents* contents) {
    BrowserWindowInterface* browser =
        GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
    raycore::WindowHost* host = browser ? raycore::WindowHost::ForBrowser(browser) : nullptr;
    return !host || !host->internal();
  };
  AppShortcutManager::SuppressShortcutsForTesting();
  raycore::SetLifetimeCallbacks({
      .quit_cancelled = base::BindRepeating([] {
        if ([g_delegate respondsToSelector:@selector(engineQuitCancelled)]) {
          [g_delegate engineQuitCancelled];
        }
      }),
  });
  raycore::SetEngineCallbacks({
      .started = base::BindOnce([] {
        StartApplyingProfilePrefs();
        ray::StartTabHistoryCleaner();
        raycore::InstallPermissionPrompts();
        raycore::StartMediaCaptureObserver();
        raycore::InstallExternalAppPrompts();
        raycore::StartPictureInPictureObserver();
        raycore::StartHostVisibility();
        raycore::StartVideoUpscaling();
        [g_delegate engineDidStart];
      }),
      .shutting_down = base::BindOnce([] {
        raycore::CloseAllExtensionViews();
        if ([g_delegate respondsToSelector:@selector(engineWillShutDown)]) {
          [g_delegate engineWillShutDown];
        }
      }),
  });

  std::vector<const char*> args(argv, argv + argc);
  static std::string features = "--enable-features=WebContentsDiscard";
  bool merged = false;
  for (const char*& arg : args) {
    if (strncmp(arg, "--enable-features=", 18) == 0 && !merged) {
      features = std::string(arg) + ",WebContentsDiscard";
      arg = features.c_str();
      merged = true;
    }
  }
  if (!merged) {
    args.push_back(features.c_str());
  }
  int rv = ChromeMain(static_cast<int>(args.size()), args.data());
  g_delegate = nil;
  return rv;
}

+ (RayCoreEngine*)sharedEngine {
  return g_engine;
}

- (RayCoreProfile*)defaultProfile {
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  return profile ? [RayCoreProfile wrapperFor:profile] : nil;
}

- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(RayCoreProfile*))completion {
  ProfileManager* manager = g_browser_process->profile_manager();
  base::FilePath path =
      manager->user_data_dir().Append(base::SysNSStringToUTF8(directoryName));
  Profile* loaded = manager->GetProfileByPath(path);
  if (IsProfileDirectoryMarkedForDeletion(path) ||
      (loaded && raycore::IsProfileDeleting(loaded))) {
    completion(nil);
    return;
  }
  manager->CreateProfileAsync(
      path, base::BindOnce(
                [](void (^completion)(RayCoreProfile*), Profile* profile) {
                  completion(profile && !raycore::IsProfileDeleting(profile)
                                 ? [RayCoreProfile wrapperFor:profile]
                                 : nil);
                },
                completion));
}

- (void)quit {
  raycore::QuitEngine();
}

- (NSString*)pageScript {
  const std::string& script = raycore::GetPageScript();
  return script.empty() ? nil : NS(script);
}

- (void)setPageScript:(NSString*)pageScript {
  raycore::SetPageScript(pageScript ? base::SysNSStringToUTF8(pageScript)
                                   : std::string());
}

+ (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember {
  raycore::ResolvePermission(base::SysNSStringToUTF8(requestId),
                            base::SysNSStringToUTF8(result), remember);
}

+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode {
  raycore::StartCasting(dialogId, base::SysNSStringToUTF8(sinkId), castMode);
}

+ (void)stopCasting:(int)dialogId route:(NSString*)routeId {
  raycore::StopCasting(dialogId, base::SysNSStringToUTF8(routeId));
}

+ (void)reservedShortcutsChanged {
  raycore::ReservedShortcutsChanged();
}

+ (BOOL)isReservedGlobalShortcut:(NSString*)shortcut {
  return raycore::IsReservedGlobalShortcut(shortcut);
}

+ (void)setVideoUpscaling:(BOOL)enabled {
  raycore::SetVideoUpscalingEnabled(enabled);
}

+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions {
  NSNumber* low_power = conditions[@"lowPower"];
  NSNumber* thermal = conditions[@"thermalPressure"];
  raycore::SetVideoUpscalingTestConditions(
      low_power ? std::optional<bool>(low_power.boolValue) : std::nullopt,
      thermal ? std::optional<bool>(thermal.boolValue) : std::nullopt);
}

+ (NSDictionary<NSString*, id>*)videoUpscalingState {
  return raycore::VideoUpscalingState();
}

+ (void)setAutoPictureInPicture:(BOOL)enabled {
  g_auto_picture_in_picture = enabled;
  g_ray_auto_picture_in_picture_off = !enabled;
  for (Profile* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    if (!profile->IsOffTheRecord()) {
      ApplyAutoPictureInPicture(profile);
    }
  }
}

+ (void)terminateCastRoute:(NSString*)routeId {
  raycore::TerminateCastRoute(base::SysNSStringToUTF8(routeId));
}

+ (void)closeCastDialog:(int)dialogId {
  raycore::CloseCastDialog(dialogId);
}

+ (void)selectDevice:(int)chooserId index:(int)index {
  raycore::SelectDevice(chooserId, index);
}

+ (void)cancelDeviceChooser:(int)chooserId {
  raycore::CancelDeviceChooser(chooserId);
}

+ (void)refreshDeviceChooser:(int)chooserId {
  raycore::RefreshDeviceChooser(chooserId);
}

+ (void)openDeviceChooserSettings:(int)chooserId {
  raycore::OpenDeviceChooserSettings(chooserId);
}

+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted {
  raycore::ResolveExtensionInstallPrompt(base::SysNSStringToUTF8(requestId), accepted);
}

- (void)deleteProfile:(RayCoreProfile*)profile completion:(void (^)(BOOL deleted))completion {
  Profile* chrome_profile = profile.chromeProfile;
  ProfileManager* manager = g_browser_process->profile_manager();
  if (!chrome_profile || !chrome_profile->IsRegularProfile() ||
      chrome_profile->GetPath() ==
          manager->user_data_dir().Append(ProfileManager::GetInitialProfileDir())) {
    if (completion) {
      completion(NO);
    }
    return;
  }
  raycore::NoteProfileDeleting(chrome_profile);
  base::WeakPtr<Profile> weak = chrome_profile->GetWeakPtr();
  const base::FilePath path = chrome_profile->GetPath();
  manager->GetDeleteProfileHelper().MaybeScheduleProfileForDeletion(
      chrome_profile->GetPath(), base::DoNothing(),
      ProfileMetrics::DELETE_PROFILE_SETTINGS);
  if (weak) {
    manager->ClearFirstBrowserWindowKeepAlive(weak.get());
  }
  for (const base::TimeDelta delay : {base::Seconds(2), base::Seconds(10)}) {
    content::GetUIThreadTaskRunner({})->PostDelayedTask(
        FROM_HERE, base::BindOnce([](const base::FilePath& dir) {
          if (!IsProfileDirectoryMarkedForDeletion(dir) ||
              g_browser_process->profile_manager()->GetProfileByPath(dir)) {
            return;
          }
          base::ThreadPool::PostTask(
              FROM_HERE,
              {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
               base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
              base::BindOnce(base::IgnoreResult(&base::DeletePathRecursively), dir));
        }, path),
        delay);
  }
  if (completion) {
    completion(YES);
  }
}

- (void)releaseProfile:(RayCoreProfile*)profile {
  Profile* chrome_profile = profile.chromeProfile;
  if (!chrome_profile || !chrome_profile->IsOffTheRecord()) {
    return;
  }
  bool in_use = false;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
    in_use |= browser->GetProfile() == chrome_profile &&
              !browser->capabilities()->IsAttemptingToCloseBrowser();
    return !in_use;
  });
  if (!in_use) {
    ProfileDestroyer::DestroyOTRProfileWhenAppropriate(chrome_profile);
  }
}

+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(RayCoreTab*)tab
                      frame:(NSString*)frameId
                     origin:(NSString*)origin
                      audio:(NSString*)audio {
  raycore::AllowDesktopCapture(tab.contents, base::SysNSStringToUTF8(sourceId ?: @""),
                              base::SysNSStringToUTF8(frameId ?: @""),
                              base::SysNSStringToUTF8(origin ?: @""),
                              base::SysNSStringToUTF8(audio ?: @""));
}

+ (NSDictionary<NSString*, NSNumber*>*)desktopCaptureAudio {
  return @{
    @"system" : @(raycore::IsDesktopCaptureSystemAudioSupported()),
    @"application" : @(raycore::IsDesktopCaptureApplicationAudioSupported()),
  };
}

+ (NSArray<NSDictionary*>*)testExternalLaunches {
  return raycore::TestExternalLaunches();
}

+ (NSArray<NSDictionary*>*)testChooserEvents {
  return raycore::TestChooserEvents();
}

+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember {
  raycore::ResolveExternalApp(base::SysNSStringToUTF8(requestId), open, remember);
}

- (void)offTheRecordProfileFor:(RayCoreProfile*)profile
                    completion:(void (^)(RayCoreProfile*, NSString*))completion {
  Profile* original = profile.chromeProfile;
  if (!original || original->IsOffTheRecord()) {
    completion(nil, original ? @"not a regular profile" : @"the profile went");
    return;
  }
  Profile* current = original->GetPrimaryOTRProfile(false);
  if (current && raycore::IsProfileDying(current)) {
    raycore::WhenProfileGone(current, base::BindOnce(^{
                              [self offTheRecordProfileFor:profile completion:completion];
                            }));
    return;
  }
  RayCoreProfile* otr =
      [RayCoreProfile wrapperFor:original->GetPrimaryOTRProfile(true)];
  completion(otr, otr ? nil : @"Chrome is destroying it");
}

- (NSString*)keepAliveState {
  std::ostringstream out;
  out << *KeepAliveRegistry::GetInstance()
      << " trying_to_quit=" << browser_shutdown::IsTryingToQuit();
  return NS(out.str());
}

- (NSString*)chromiumVersion {
  return NS(std::string(version_info::GetVersionNumber()));
}

@end
