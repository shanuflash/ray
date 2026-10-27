#import <AppKit/AppKit.h>

#import "ArdiaCore.h"

#include <string>
#include <vector>

static NSDictionary<NSString *, NSString *> *Env() { return NSProcessInfo.processInfo.environment; }

static BOOL Background() { return [Env()[@"LUMEN_BACKGROUND"] isEqualToString:@"1"]; }

static NSString *DataDirectory() {
  NSString *base = Env()[@"LUMEN_DATA_DIR"];
  if (!base.length)
    base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Lumen"];
  return [base stringByAppendingPathComponent:@"Chromium"];
}

@interface LumenEngineDelegate : NSObject <ArdiaCoreEngineDelegate, ArdiaCoreWindowDelegate, ArdiaCoreTabDelegate>
@property(nonatomic) ArdiaCoreWindow *window;
@property(nonatomic) ArdiaCoreTab *tab;
@end

@implementation LumenEngineDelegate

- (void)engineDidStart {
  ArdiaCoreEngine *engine = ArdiaCoreEngine.sharedEngine;
  NSLog(@"[lumen] engine started (Chromium %@)", engine.chromiumVersion);
  ArdiaCoreProfile *profile = engine.defaultProfile;

  self.window = [[ArdiaCoreWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 800)];
  self.window.delegate = self;
  self.window.activeProfile = profile;
  self.window.window.title = @"Lumen";

  NSString *url = Env()[@"LUMEN_START_URL"] ?: @"https://example.com";
  [self show:[self.window openTab:url profile:profile foreground:YES]];

  [self.window.window center];
  if (Background())
    [self.window showInactive];
  else
    [self.window.window makeKeyAndOrderFront:nil];
}

- (void)show:(ArdiaCoreTab *)tab {
  [self.tab.view removeFromSuperview];
  self.tab = tab;
  tab.delegate = self;
  NSView *host = self.window.hostView;
  tab.view.frame = host.bounds;
  tab.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [host addSubview:tab.view];
  [self.window activateTab:tab];
}

- (void)window:(ArdiaCoreWindow *)window
    didInsertTab:(ArdiaCoreTab *)tab
          opener:(ArdiaCoreTab *)opener
     disposition:(NSString *)disposition {
  NSLog(@"[lumen] tab inserted %d (%@)", tab.tabId, disposition);
  if (![disposition isEqualToString:@"background_tab"]) [self show:tab];
}

- (void)tabDidChangeTitle:(ArdiaCoreTab *)tab {
  if (tab == self.tab) self.window.window.title = tab.title.length ? tab.title : @"Lumen";
}

- (void)tabDidChangeLoading:(ArdiaCoreTab *)tab {
  NSLog(@"[lumen] tab %d %@ %@", tab.tabId, tab.loading ? @"loading" : @"loaded", tab.url);
}

- (void)tab:(ArdiaCoreTab *)tab didFailLoad:(NSString *)url code:(int)code description:(NSString *)text {
  NSLog(@"[lumen] tab %d failed %@ (%d %@)", tab.tabId, url, code, text);
}

- (BOOL)windowShouldClose:(ArdiaCoreWindow *)window {
  [ArdiaCoreEngine.sharedEngine quit];
  return YES;
}

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    NSString *dataDir = DataDirectory();
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dataDir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&error]) {
      fprintf(stderr, "[lumen] can't use data dir %s: %s\n", dataDir.fileSystemRepresentation,
              error.localizedDescription.UTF8String);
      return 1;
    }

    std::vector<std::string> extra = {
        std::string("--user-data-dir=") + dataDir.UTF8String,
        "--profile-directory=Default",
        "--disable-stack-profiler",
        "--disable-features=MacAppCodeSignClone,DevToolsAcceptDebuggingConnections,AutofillAiWalletPrivatePasses",
        "--enable-features=WebContentsDiscard,ImprovedStartupBestEffortDelay:StartupDelayStopOnLoadingTimedOut/true,"
        "CPUMeasurementInFreezingPolicy:freezing_visible_protection_time/0s,"
        "InfiniteTabsFreezing:ardia_unconnected_unfreeze_interval/600s,"
        "ThrottleMainFrameTo60Hz,UrgentMainFrameForInput",
    };
    if (NSString *port = Env()[@"LUMEN_REMOTE_DEBUGGING_PORT"]) {
      extra.push_back(std::string("--remote-debugging-port=") + port.UTF8String);
      extra.push_back("--remote-allow-origins=*");
    }
    if (Background()) {
      extra.push_back("--use-mock-keychain");
      extra.push_back("--mute-audio");
    }

    std::vector<const char *> args = {argc > 0 ? argv[0] : "Lumen"};
    for (const std::string &arg : extra) args.push_back(arg.c_str());

    static LumenEngineDelegate *delegate = [LumenEngineDelegate new];
    return [ArdiaCoreEngine runWithArgc:(int)args.size() argv:args.data() delegate:delegate];
  }
}
