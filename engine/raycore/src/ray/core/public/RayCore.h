#import <AppKit/AppKit.h>

#define RAYCORE_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

@class RayCoreEngine;
@class RayCoreProfile;
@class RayCoreTab;
@class RayCoreWindow;

@protocol RayCoreEngineDelegate <NSObject>
- (void)engineDidStart;
@optional
- (void)engineWillShutDown;
- (void)engineQuitCancelled;
- (nullable RayCoreWindow*)engineWindowForNewBrowserOfProfile:(RayCoreProfile*)profile
                                                        type:(NSString*)type;
- (void)engine:(RayCoreEngine*)engine
    permissionRequest:(NSDictionary<NSString*, id>*)request
                  tab:(RayCoreTab*)tab;
- (void)engine:(RayCoreEngine*)engine permissionRequestDismissed:(NSString*)requestId;
- (void)engine:(RayCoreEngine*)engine
    extensionSidePanel:(NSDictionary<NSString*, id>*)panel
                   tab:(RayCoreTab*)tab;
- (BOOL)engine:(RayCoreEngine*)engine
    extensionActionPopup:(NSDictionary<NSString*, id>*)popup
                     tab:(RayCoreTab*)tab;
- (BOOL)engine:(RayCoreEngine*)engine
    extensionActionShortcut:(NSDictionary<NSString*, id>*)shortcut
                        tab:(RayCoreTab*)tab;
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event;
- (BOOL)engineIsReservedKey:(NSString*)key
               unshiftedKey:(NSString*)unshiftedKey
                  modifiers:(NSEventModifierFlags)modifiers;
- (void)engine:(RayCoreEngine*)engine
    extensionInstallPrompt:(NSDictionary<NSString*, id>*)prompt
                       tab:(nullable RayCoreTab*)tab;
- (void)engine:(RayCoreEngine*)engine
    deviceChooser:(NSDictionary<NSString*, id>*)chooser
              tab:(RayCoreTab*)tab;
- (void)engine:(RayCoreEngine*)engine
    castDialog:(NSDictionary<NSString*, id>*)dialog
           tab:(RayCoreTab*)tab;
- (void)engine:(RayCoreEngine*)engine
    castRoutes:(NSArray<NSDictionary<NSString*, NSString*>*>*)routes
       profile:(RayCoreProfile*)profile;
@end

RAYCORE_EXPORT
@interface RayCoreEngine : NSObject
+ (int)runWithArgc:(int)argc
              argv:(const char* _Nonnull* _Nonnull)argv
          delegate:(id<RayCoreEngineDelegate>)delegate;
@property(class, readonly, nullable) RayCoreEngine* sharedEngine;

@property(readonly) RayCoreProfile* defaultProfile;
- (void)loadProfile:(NSString*)directoryName
         completion:(void (^)(RayCoreProfile* _Nullable profile))completion;
- (void)quit;
@property(nonatomic, copy, nullable) NSString* pageScript;
+ (void)resolvePermission:(NSString*)requestId
                   result:(NSString*)result
                 remember:(BOOL)remember;
+ (void)resolveExtensionInstallPrompt:(NSString*)requestId accepted:(BOOL)accepted;
+ (void)startCasting:(int)dialogId sink:(NSString*)sinkId mode:(int)castMode;
+ (void)stopCasting:(int)dialogId route:(NSString*)routeId;
+ (void)closeCastDialog:(int)dialogId;
+ (void)terminateCastRoute:(NSString*)routeId;
+ (void)setAutoPictureInPicture:(BOOL)enabled;
+ (void)setVideoUpscaling:(BOOL)enabled;
+ (void)setVideoUpscalingTestConditions:(NSDictionary<NSString*, NSNumber*>*)conditions;
@property(class, readonly) NSDictionary<NSString*, id>* videoUpscalingState;
+ (void)reservedShortcutsChanged;
+ (BOOL)isReservedGlobalShortcut:(NSString*)shortcut;
+ (void)selectDevice:(int)chooserId index:(int)index;
+ (void)cancelDeviceChooser:(int)chooserId;
+ (void)refreshDeviceChooser:(int)chooserId;
+ (void)openDeviceChooserSettings:(int)chooserId;
- (void)deleteProfile:(RayCoreProfile*)profile
           completion:(nullable void (^)(BOOL deleted))completion;
- (void)releaseProfile:(RayCoreProfile*)profile;
+ (void)resolveExternalApp:(NSString*)requestId open:(BOOL)open remember:(BOOL)remember;
@property(class, readonly) NSArray<NSDictionary*>* testExternalLaunches;
@property(class, readonly) NSArray<NSDictionary*>* testChooserEvents;
+ (void)allowDesktopCapture:(NSString*)sourceId
                        tab:(RayCoreTab*)tab
                      frame:(nullable NSString*)frameId
                     origin:(nullable NSString*)origin
                      audio:(nullable NSString*)audio;
@property(class, readonly) NSDictionary<NSString*, NSNumber*>* desktopCaptureAudio;
- (void)offTheRecordProfileFor:(RayCoreProfile*)profile
                    completion:(void (^)(RayCoreProfile* _Nullable offTheRecord,
                                         NSString* _Nullable error))completion;
@property(readonly) NSString* chromiumVersion;
@property(readonly) NSString* keepAliveState;
@end

@interface RayCoreEngine (Tracing)
+ (void)beginTracing:(void (^)(BOOL started))completion;
+ (void)endTracing:(BOOL)keep completion:(void (^)(NSString* _Nullable path))completion;
@property(class, readonly) BOOL isTracing;
@end

RAYCORE_EXPORT
@interface RayCoreProfile : NSObject
@property(readonly) NSString* name;
@property(readonly) NSString* path;
@property(readonly) BOOL offTheRecord;
@property(readonly) BOOL destroyed;
- (nullable NSString*)loadComponentExtension:(NSString*)path;
- (void)unloadComponentExtension:(NSString*)extensionId;
- (void)warmSpareRenderer;
- (void)holdNavigationsUntilRulesetsOf:(NSString*)extensionId;
- (void)releaseNavigationHold:(NSString*)reason;
- (void)releaseNavigationHoldReady;
- (void)watchCastRoutes;
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* extensions;
- (nullable NSNumber*)boolPreference:(NSString*)name;
- (void)setBoolPreference:(NSString*)name value:(BOOL)value;
- (void)clearBrowsingData:(NSArray<NSString*>*)types
                    since:(nullable NSDate*)since
               completion:(nullable void (^)(void))completion;
@end

@interface RayCoreProfile (Icons)
- (void)fetchIcon:(NSString*)url
         maxBytes:(NSUInteger)maxBytes
       completion:(void (^)(NSData* _Nullable body))completion;
@end

@protocol RayCoreWindowDelegate <NSObject>
@optional
- (void)window:(RayCoreWindow*)window
    didInsertTab:(RayCoreTab*)tab
          opener:(nullable RayCoreTab*)opener
     disposition:(NSString*)disposition;
- (void)window:(RayCoreWindow*)window didRemoveTab:(RayCoreTab*)tab;
- (void)window:(RayCoreWindow*)window didActivateTab:(RayCoreTab*)tab;
- (void)window:(RayCoreWindow*)window
    devToolsDidChangeForTab:(RayCoreTab*)tab
                       view:(nullable NSView*)devToolsView;
- (void)window:(RayCoreWindow*)window
                    tab:(RayCoreTab*)tab
    didChangeFullscreen:(BOOL)fullscreen;
- (void)window:(RayCoreWindow*)window
    passwordPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(RayCoreTab*)tab;
- (void)window:(RayCoreWindow*)window
    autofillPrompt:(NSDictionary<NSString*, id>*)prompt
            forTab:(RayCoreTab*)tab;
- (void)window:(RayCoreWindow*)window
    passwordSavePromptForTab:(RayCoreTab*)tab
                    username:(NSString*)username
                      origin:(NSString*)origin;
- (void)window:(RayCoreWindow*)window showRequestedActive:(BOOL)active;
- (BOOL)windowShouldClose:(RayCoreWindow*)window;
- (void)windowDidCancelClose:(RayCoreWindow*)window;
- (void)window:(RayCoreWindow*)window
    confirmCloseWithDownloads:(int)count
                   completion:(void (^)(BOOL closeAnyway))completion;
- (BOOL)window:(RayCoreWindow*)window preHandleKeyEvent:(NSEvent*)event;
- (BOOL)window:(RayCoreWindow*)window handleKeyEvent:(NSEvent*)event;
@end

RAYCORE_EXPORT
@interface RayCoreWindow : NSObject
- (instancetype)initWithContentRect:(NSRect)rect;
@property(readonly) NSWindow* window;
@property(readonly) NSView* hostView;
@property(weak, nullable) id<RayCoreWindowDelegate> delegate;

- (RayCoreTab*)openTab:(NSString*)url
              profile:(RayCoreProfile*)profile
           foreground:(BOOL)foreground;
- (nullable RayCoreTab*)openExtensionView:(NSString*)url
                                 profile:(RayCoreProfile*)profile
                                    kind:(NSString*)kind;
@property(nonatomic, nullable) RayCoreProfile* activeProfile;
- (void)activateTab:(RayCoreTab*)tab;
- (NSArray<RayCoreTab*>*)tabsForProfile:(RayCoreProfile*)profile;
- (int)chromeWindowIdForProfile:(RayCoreProfile*)profile;
- (BOOL)executeChromeCommand:(int)commandId profile:(RayCoreProfile*)profile;
- (void)showInactive;
@property(nonatomic) BOOL actedFullScreen;
- (void)close;

- (void)prepareProfile:(RayCoreProfile*)profile;
- (void)adoptTab:(RayCoreTab*)tab;
- (nullable RayCoreTab*)restoreTab:(nullable NSString*)state
                          profile:(RayCoreProfile*)profile
                       foreground:(BOOL)foreground;
- (nullable RayCoreTab*)duplicateTab:(RayCoreTab*)source
                            profile:(RayCoreProfile*)profile
                         foreground:(BOOL)foreground;
- (void)placeTab:(RayCoreTab*)tab index:(int)index pinned:(BOOL)pinned;
@property(nonatomic) BOOL internal;
@end

@protocol RayCoreTabDelegate <NSObject>
@optional
- (void)tabDidChangeTitle:(RayCoreTab*)tab;
- (void)tabDidChangeURL:(RayCoreTab*)tab;
- (void)tabDidChangeLoading:(RayCoreTab*)tab;
- (void)tabDidChangeProgress:(RayCoreTab*)tab;
- (void)tabDidChangeFavicon:(RayCoreTab*)tab;
- (void)tabDidChangeNavigationState:(RayCoreTab*)tab;
- (void)tab:(RayCoreTab*)tab didFindMatches:(int)count active:(int)active final:(BOOL)final;
- (void)tab:(RayCoreTab*)tab
    didReceivePageMessage:(NSString*)kind
                     json:(NSString*)json
                    frame:(NSString*)frameId
                     main:(BOOL)main
                   origin:(NSString*)origin;
- (void)tabWillClose:(RayCoreTab*)tab;
- (void)tab:(RayCoreTab*)tab rendererGone:(NSString*)status code:(int)code;
- (void)tab:(RayCoreTab*)tab didFailLoad:(NSString*)url code:(int)code description:(NSString*)text;
- (void)tab:(RayCoreTab*)tab didChangeStatusText:(NSString*)text;
- (void)tab:(RayCoreTab*)tab didRequestAppURL:(NSString*)url userGesture:(BOOL)userGesture;
- (void)tabDidChangeThemeColor:(RayCoreTab*)tab;
- (void)tabDidCommitDocument:(RayCoreTab*)tab;
- (void)tabDidGainFocus:(RayCoreTab*)tab;
- (void)tabDidChangeAudio:(RayCoreTab*)tab;
- (void)tabDidChangeSecurity:(RayCoreTab*)tab;
- (void)tabDidChangeZoom:(RayCoreTab*)tab;
- (void)tab:(RayCoreTab*)tab didBlockPopup:(NSDictionary<NSString*, NSString*>*)popup;
- (void)tab:(RayCoreTab*)tab preferredSizeDidChange:(NSSize)size;
- (void)tab:(RayCoreTab*)tab externalAppRequest:(NSDictionary<NSString*, id>*)request;
- (void)tab:(RayCoreTab*)tab requestsActivation:(NSString*)reason;
- (void)tab:(RayCoreTab*)tab didChangePictureInPicture:(NSDictionary<NSString*, id>*)state;
- (void)tab:(RayCoreTab*)tab didShowAutofillSuggestions:(NSArray<NSDictionary<NSString*, NSString*>*>*)items;
- (void)tab:(RayCoreTab*)tab didBlockRequests:(int)count lastURL:(NSString*)url;
- (NSArray<NSDictionary<NSString*, NSString*>*>*)tab:(RayCoreTab*)tab
                         contextMenuItemsForSelection:(NSString*)text;
- (void)tab:(RayCoreTab*)tab
    contextMenuCommand:(NSString*)itemId
                  text:(NSString*)selection
             modifiers:(NSDictionary<NSString*, NSNumber*>*)modifiers;
- (void)tab:(RayCoreTab*)tab didShowContextMenu:(NSArray<NSDictionary*>*)items;
- (nullable NSDictionary<NSString*, id>*)tab:(RayCoreTab*)tab
                              runContextMenu:(NSDictionary<NSString*, id>*)menu;
- (void)tab:(RayCoreTab*)tab navigationBecameDownload:(NSString*)url;
- (void)tabDidChangeDiscarded:(RayCoreTab*)tab;
- (void)tabBecameUnresponsive:(RayCoreTab*)tab;
- (void)tabBecameResponsive:(RayCoreTab*)tab;
- (void)tab:(RayCoreTab*)tab didChangeMediaAccess:(NSDictionary<NSString*, NSNumber*>*)access;
@end

RAYCORE_EXPORT
@interface RayCoreTab : NSObject
@property(readonly) NSView* view;
@property(readonly, weak) RayCoreProfile* profile;
@property(readonly) int tabId;
@property(readonly) NSString* url;
@property(readonly) NSString* title;
@property(readonly) BOOL loading;
@property(readonly) double progress;
@property(readonly, nullable) NSImage* favicon;
@property(readonly) BOOL canGoBack;
@property(readonly) BOOL canGoForward;
@property(readonly) BOOL closed;
@property(weak, nullable) id<RayCoreTabDelegate> delegate;

- (void)focus;
- (void)find:(NSString*)text forward:(BOOL)forward;
- (void)stopFinding;
- (void)close;
@property(readonly, nullable) NSDictionary<NSString*, id>* passwordPrompt;
- (void)resolvePasswordPrompt:(NSString*)action
                     username:(nullable NSString*)username
                     password:(nullable NSString*)password;
@property(readonly, nullable) NSDictionary<NSString*, id>* autofillPrompt;
- (void)resolveAutofillPrompt:(NSInteger)promptId action:(NSString*)action;

@property(readonly, nullable) NSString* faviconURL;
@property(readonly, nullable) NSString* themeColor;
@property(readonly) BOOL audible;
@property(nonatomic) BOOL muted;
@property(readonly) int browserId;
@property(readonly, nullable) NSString* committedOrigin;
+ (nullable NSString*)originForURL:(NSString*)url;
@property(readonly) BOOL initialDocumentAccessed;
@property(readonly) BOOL committedInitial;
- (nullable id)suppressInput;
- (void)closeNow;
@property(nonatomic) BOOL temporary;
- (void)setTemporarySource:(nullable RayCoreTab*)source;
- (void)deliverHeldPageMessages;
@property(readonly) NSDictionary<NSString*, id>* securityInfo;
- (BOOL)discard;
@property(readonly) BOOL discarded;
@property(nonatomic) BOOL frozen;
- (void)resolveUnresponsive:(BOOL)terminate;
- (BOOL)showAutofillSuggestions:(BOOL)passwords;
@property(readonly, nullable) NSDictionary<NSString*, NSNumber*>* popupFeatures;
@property(readonly) NSSize preferredSize;
@end

@interface RayCoreTab (Navigation)
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stop;
- (void)loadURL:(NSString*)url userInitiated:(BOOL)userInitiated;
- (void)goToOffset:(int)offset;
- (void)reloadIgnoringCache;
- (void)loadIfNeeded;
@property(readonly) NSArray<NSDictionary<NSString*, id>*>* navigationEntries;
@end

@interface RayCoreTab (Page)
- (void)executeJavaScript:(NSString*)code frame:(nullable NSString*)frameId;
- (void)evaluate:(NSString*)code completion:(void (^)(NSString* _Nullable json))completion;
- (BOOL)hasLiveFrame:(NSString*)frameId;
- (void)callPage:(NSString*)kind json:(NSString*)json;
- (void)callFrame:(NSString*)frameId kind:(NSString*)kind json:(NSString*)json;
@property(nonatomic, nullable) NSColor* pageBackgroundColor;
@property(nonatomic, copy, nullable) NSString* pageColor;
@property(nonatomic, nullable) NSColor* contentsBackgroundColor;
@property(nonatomic) double zoomFactor;
- (void)zoomStep:(int)direction;
@property(readonly) double pinchScale;
@end

@interface RayCoreTab (Commands)
- (BOOL)executeChromeCommand:(int)command;
- (void)openBlockedPopup:(NSString*)popupId always:(BOOL)always;
- (void)showDevTools;
- (void)closeDevTools;
@property(readonly, nullable) NSView* devToolsView;
- (void)devToolsLayoutForSize:(NSSize)size
                     devTools:(NSRect*)devToolsFrame
                         page:(NSRect*)pageFrame;
- (void)devToolsCall:(NSString*)method
              params:(nullable NSDictionary*)params
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(NSDictionary* _Nullable result,
                               NSString* _Nullable error))completion;
@end

@interface RayCoreTab (Media)
@property(readonly, nullable) NSString* mediaCaptureSourceId;
- (void)copyPicture:(NSTimeInterval)timeout completion:(void (^)(CGImageRef _Nullable picture))completion;
- (BOOL)stopCapture;
@property(readonly) BOOL autoPictureInPictureIsChromes;
- (void)noteShownByHost:(BOOL)shown;
- (void)exitFullscreen;
- (void)exitExclusiveAccess;
- (void)tracePictureInPicture:(NSString*)line withInputs:(BOOL)withInputs;
- (void)exitPictureInPicture;
- (void)enterPictureInPictureForClickAt:(NSTimeInterval)clickTime
                             completion:(void (^)(NSString* route, BOOL opened))completion;
- (BOOL)canShareThisTabInsteadFor:(RayCoreTab*)capturer;
- (BOOL)shareThisTabInsteadFor:(RayCoreTab*)capturer;
- (BOOL)showCastDialog;
- (BOOL)devShowBluetoothChooser:(BOOL)unauthorized;
@end

@interface RayCoreTab (Extensions)
- (NSString*)executeExtensionAction:(NSString*)extensionId;
- (NSDictionary<NSString*, NSDictionary*>*)actionStatesForExtensions:(NSArray<NSString*>*)extensionIds;
- (nullable NSString*)sidePanelURLForExtension:(NSString*)extensionId;
@end

NS_ASSUME_NONNULL_END
