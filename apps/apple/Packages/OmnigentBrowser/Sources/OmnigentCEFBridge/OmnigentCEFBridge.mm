#import "OmnigentCEFBridge.h"

#if TARGET_OS_OSX

#if !__has_feature(objc_arc)
#error "OmnigentCEFBridge requires ARC"
#endif

#include <crt_externs.h>
#include <dlfcn.h>

#include <map>
#include <string>

NSErrorDomain const OMCEFErrorDomain = @"ai.omnigent.browser.cef";

static NSError *OMCEFError(OMCEFErrorCode code, NSString *message) {
  return [NSError errorWithDomain:OMCEFErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

static BOOL OMCEFFail(NSError **out, OMCEFErrorCode code, NSString *message) {
  if (out) {
    *out = OMCEFError(code, message);
  }
  return NO;
}

static NSString *const OMCEFFrameworkName = @"Chromium Embedded Framework";

static NSArray<NSString *> *OMCEFHelperNames(NSString *base) {
  return @[
    base,
    [base stringByAppendingString:@" (GPU)"],
    [base stringByAppendingString:@" (Renderer)"],
    [base stringByAppendingString:@" (Plugin)"],
    [base stringByAppendingString:@" (Alerts)"],
  ];
}

static NSString *OMCEFHelperExecutablePath(NSString *frameworksPath, NSString *name) {
  return [frameworksPath
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.app/Contents/MacOS/%@", name,
                                                                name]];
}

@implementation OMCEFConfiguration

- (instancetype)initWithHelperName:(NSString *)helperName rootCacheURL:(NSURL *)rootCacheURL {
  if ((self = [super init])) {
    _helperName = [helperName copy];
    _rootCacheURL = [rootCacheURL copy];
  }
  return self;
}

@end

[[maybe_unused]] static BOOL OMCEFValidateBundle(OMCEFConfiguration *configuration, NSError **error) {
  NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
  if (frameworksPath == nil) {
    return OMCEFFail(error, OMCEFErrorFrameworkMissing,
                     @"The main bundle has no Frameworks directory.");
  }
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *framework = [frameworksPath
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework/%@",
                                                                OMCEFFrameworkName,
                                                                OMCEFFrameworkName]];
  if (![fm isExecutableFileAtPath:framework]) {
    return OMCEFFail(error, OMCEFErrorFrameworkMissing,
                     [NSString stringWithFormat:@"%@.framework is not embedded at %@.",
                                                OMCEFFrameworkName, frameworksPath]);
  }
  for (NSString *name in OMCEFHelperNames(configuration.helperName)) {
    NSString *path = OMCEFHelperExecutablePath(frameworksPath, name);
    if (![fm isExecutableFileAtPath:path]) {
      return OMCEFFail(error, OMCEFErrorHelperMissing,
                       [NSString stringWithFormat:@"CEF helper \"%@.app\" is missing (%@).", name,
                                                  path]);
    }
  }
  return YES;
}

#if OMNIGENT_CEF_LINKED

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

#include <objc/message.h>
#include <objc/runtime.h>

static const char *OMCEFDlerror() {
  const char *message = dlerror();
  return message != nullptr ? message : "unknown dlopen error";
}

@interface OMCEFBrowserView ()
- (void)cef_didCreateBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)cef_willCloseBrowser;
- (void)cef_didCloseBrowser;
- (void)cef_devToolsResult:(int)messageID success:(BOOL)success json:(nullable NSString *)json;
- (void)cef_createBrowserIfReady;
- (void)cef_releaseCefReferences;
@end

// Termination is deferred until every browser has closed, as in cefclient: terminate: closes
// the browsers and returns; the last OnBeforeClose re-issues terminate:.
static BOOL OMCEFShouldDeferTerminate();

#pragma mark - NSApplication

@interface OMCEFApplication () <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation OMCEFApplication

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  if (OMCEFShouldDeferTerminate()) {
    return;
  }
  [super terminate:sender];
}

@end

#pragma mark - CefAppProtocol for an existing NSApp

// SwiftUI ignores NSPrincipalClass and instantiates its own NSApplication subclass, so the
// protocol is grafted onto whatever class NSApp has: a dynamic subclass adds CefAppProtocol and
// wraps sendEvent: with CefScopedSendingEvent, the same isa-swizzle KVO uses.
namespace {

BOOL g_dynamicHandlingSendEvent = NO;
Class g_originalApplicationClass = Nil;

BOOL OMCEFDynamicIsHandlingSendEvent(id, SEL) {
  return g_dynamicHandlingSendEvent;
}

void OMCEFDynamicSetHandlingSendEvent(id, SEL, BOOL handlingSendEvent) {
  g_dynamicHandlingSendEvent = handlingSendEvent;
}

void OMCEFDynamicSendEvent(id self, SEL command, NSEvent *event) {
  CefScopedSendingEvent sendingEventScoper;
  struct objc_super superclass = {self, g_originalApplicationClass};
  reinterpret_cast<void (*)(struct objc_super *, SEL, NSEvent *)>(objc_msgSendSuper)(
      &superclass, command, event);
}

void OMCEFDynamicTerminate(id self, SEL command, id sender) {
  if (OMCEFShouldDeferTerminate()) {
    return;
  }
  struct objc_super superclass = {self, g_originalApplicationClass};
  reinterpret_cast<void (*)(struct objc_super *, SEL, id)>(objc_msgSendSuper)(&superclass,
                                                                               command, sender);
}

BOOL OMCEFInstallApplicationProtocol(NSError **error) {
  if (NSApp == nil) {
    return OMCEFFail(error, OMCEFErrorApplicationClass,
                     @"NSApp does not exist yet; start Chromium after the app launches.");
  }
  if ([NSApp conformsToProtocol:@protocol(CefAppProtocol)]) {
    return YES;
  }
  Class original = object_getClass(NSApp);
  NSString *name = [@"OMCEF_" stringByAppendingString:NSStringFromClass(original)];
  Class subclass = objc_allocateClassPair(original, name.UTF8String, 0);
  if (subclass == Nil) {
    return OMCEFFail(error, OMCEFErrorApplicationClass,
                     [NSString stringWithFormat:@"Cannot subclass %@ to add CefAppProtocol.",
                                                NSStringFromClass(original)]);
  }
  BOOL added =
      class_addMethod(subclass, @selector(isHandlingSendEvent),
                      reinterpret_cast<IMP>(OMCEFDynamicIsHandlingSendEvent), "c@:") &&
      class_addMethod(subclass, @selector(setHandlingSendEvent:),
                      reinterpret_cast<IMP>(OMCEFDynamicSetHandlingSendEvent), "v@:c") &&
      class_addMethod(subclass, @selector(sendEvent:),
                      reinterpret_cast<IMP>(OMCEFDynamicSendEvent), "v@:@") &&
      class_addMethod(subclass, @selector(terminate:),
                      reinterpret_cast<IMP>(OMCEFDynamicTerminate), "v@:@") &&
      class_addProtocol(subclass, @protocol(CefAppProtocol));
  if (!added) {
    objc_disposeClassPair(subclass);
    return OMCEFFail(error, OMCEFErrorApplicationClass,
                     [NSString stringWithFormat:@"Cannot add CefAppProtocol to %@.",
                                                NSStringFromClass(original)]);
  }
  objc_registerClassPair(subclass);
  g_originalApplicationClass = original;
  object_setClass(NSApp, subclass);
  return YES;
}

}  // namespace

#pragma mark - Message pump

static const int64_t OMCEFMaxPumpDelayMs = 1000 / 30;
static const int64_t OMCEFPumpPlaceholder = INT64_MAX;

@interface OMCEFPump : NSObject
@end

@implementation OMCEFPump {
  NSTimer *_timer;
  BOOL _active;
  BOOL _reentrancyDetected;
  BOOL _stopped;
}

+ (instancetype)shared {
  static OMCEFPump *pump;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pump = [[OMCEFPump alloc] init];
  });
  return pump;
}

- (void)scheduleWork:(int64_t)delayMs {
  if (_stopped) {
    return;
  }
  if (delayMs == OMCEFPumpPlaceholder && _timer != nil) {
    return;
  }
  [self killTimer];
  if (delayMs <= 0) {
    [self doWork];
  } else {
    [self setTimer:MIN(delayMs, OMCEFMaxPumpDelayMs)];
  }
}

- (void)doWork {
  if (_active) {
    _reentrancyDetected = YES;
    return;
  }
  _active = YES;
  CefDoMessageLoopWork();
  _active = NO;
  if (_reentrancyDetected) {
    _reentrancyDetected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self scheduleWork:0];
    });
  } else {
    [self scheduleWork:OMCEFPumpPlaceholder];
  }
}

- (void)setTimer:(int64_t)delayMs {
  __weak OMCEFPump *weakSelf = self;
  _timer = [NSTimer timerWithTimeInterval:(double)delayMs / 1000.0
                                  repeats:NO
                                    block:^(NSTimer *timer) {
                                      (void)timer;
                                      OMCEFPump *strongSelf = weakSelf;
                                      if (strongSelf == nil) {
                                        return;
                                      }
                                      strongSelf->_timer = nil;
                                      [strongSelf doWork];
                                    }];
  [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)killTimer {
  [_timer invalidate];
  _timer = nil;
}

- (void)stop {
  _stopped = YES;
  [self killTimer];
}

@end

#pragma mark - Process state

namespace {

enum class RuntimeState { kIdle, kRunning, kFailed, kShutDown };

RuntimeState g_state = RuntimeState::kIdle;
NSError *g_startError = nil;
NSURL *g_rootCacheURL = nil;
bool g_contextInitialized = false;
int g_liveBrowsers = 0;
NSHashTable<OMCEFBrowserView *> *g_views = nil;
std::map<std::string, CefRefPtr<CefRequestContext>> g_contexts;

NSHashTable<OMCEFBrowserView *> *Views() {
  if (g_views == nil) {
    g_views = [NSHashTable weakObjectsHashTable];
  }
  return g_views;
}

bool g_terminateRequested = false;
bool g_terminateApproved = false;
const NSTimeInterval kTerminateTimeout = 5.0;

void FinishTerminate() {
  if (!g_terminateRequested || g_terminateApproved) {
    return;
  }
  g_terminateApproved = true;
  if (g_liveBrowsers > 0) {
    NSLog(@"OmnigentCEF: terminating with %d browser(s) that did not close in %.0fs",
          g_liveBrowsers, kTerminateTimeout);
  }
  [NSApp terminate:nil];
}

class OMApp : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit OMApp(bool useMockKeychain) : use_mock_keychain_(useMockKeychain) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString &process_type,
                                     CefRefPtr<CefCommandLine> command_line) override {
    if (process_type.empty() && use_mock_keychain_) {
      command_line->AppendSwitch("use-mock-keychain");
    }
  }

  void OnContextInitialized() override {
    g_contextInitialized = true;
    for (OMCEFBrowserView *view in Views().allObjects) {
      [view cef_createBrowserIfReady];
    }
  }

  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[OMCEFPump shared] scheduleWork:delay_ms];
    });
  }

 private:
  bool use_mock_keychain_;
  IMPLEMENT_REFCOUNTING(OMApp);
};

class OMClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefDisplayHandler,
                 public CefLoadHandler,
                 public CefRequestHandler,
                 public CefDownloadHandler,
                 public CefFindHandler,
                 public CefDevToolsMessageObserver {
 public:
  explicit OMClient(OMCEFBrowserView *view) : view_(view) {}

  void Detach() { view_ = nil; }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  // Popups open in the same tab for now; window.open targets replace the current page.
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> /*frame*/,
                     int /*popup_id*/,
                     const CefString &target_url,
                     const CefString & /*target_frame_name*/,
                     WindowOpenDisposition /*target_disposition*/,
                     bool /*user_gesture*/,
                     const CefPopupFeatures & /*popupFeatures*/,
                     CefWindowInfo & /*windowInfo*/,
                     CefRefPtr<CefClient> & /*client*/,
                     CefBrowserSettings & /*settings*/,
                     CefRefPtr<CefDictionaryValue> & /*extra_info*/,
                     bool * /*no_javascript_access*/) override {
    if (!target_url.empty()) {
      browser->GetMainFrame()->LoadURL(target_url);
    }
    return true;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    [view_ cef_didCreateBrowser:browser];
  }

  // Returning false would send performClose: to the hosting window. Returning true means we
  // finish the close by tearing down CEF's view; its deallocation triggers OnBeforeClose.
  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    NSView *browserView = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
    [view_ cef_willCloseBrowser];
    [browserView removeFromSuperview];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> /*browser*/) override {
    g_liveBrowsers -= 1;
    [view_ cef_didCloseBrowser];
    if (g_terminateRequested && g_liveBrowsers == 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        FinishTerminate();
      });
    }
  }

  void OnAddressChange(CefRefPtr<CefBrowser> /*browser*/,
                       CefRefPtr<CefFrame> frame,
                       const CefString &url) override {
    if (frame->IsMain()) {
      [view_.delegate browserView:view_ didChangeURL:Str(url)];
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> /*browser*/, const CefString &title) override {
    [view_.delegate browserView:view_ didChangeTitle:Str(title)];
  }

  void OnLoadingProgressChange(CefRefPtr<CefBrowser> /*browser*/, double progress) override {
    [view_.delegate browserView:view_ didChangeProgress:progress];
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> /*browser*/,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    [view_.delegate browserView:view_
               didChangeLoading:isLoading
                      canGoBack:canGoBack
                   canGoForward:canGoForward];
  }

  void OnLoadError(CefRefPtr<CefBrowser> /*browser*/,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString &errorText,
                   const CefString &failedUrl) override {
    if (frame->IsMain()) {
      [view_.delegate browserView:view_
          didFailLoadWithErrorCode:errorCode
                              text:Str(errorText)
                               url:Str(failedUrl)];
    }
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> /*browser*/,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString &error_string) override {
    [view_.delegate browserView:view_
        renderProcessTerminatedWithStatus:status
                                errorCode:error_code
                                  message:Str(error_string)];
  }

  bool CanDownload(CefRefPtr<CefBrowser> /*browser*/,
                   const CefString &url,
                   const CefString & /*request_method*/) override {
    [view_.delegate browserView:view_ didBlockDownloadOfURL:Str(url)];
    return false;
  }

  bool OnBeforeDownload(CefRefPtr<CefBrowser> /*browser*/,
                        CefRefPtr<CefDownloadItem> /*download_item*/,
                        const CefString & /*suggested_name*/,
                        CefRefPtr<CefBeforeDownloadCallback> /*callback*/) override {
    return false;
  }

  void OnFindResult(CefRefPtr<CefBrowser> /*browser*/,
                    int /*identifier*/,
                    int count,
                    const CefRect & /*selectionRect*/,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    [view_.delegate browserView:view_
                 didFindMatches:count
                    activeMatch:activeMatchOrdinal
                    finalUpdate:finalUpdate];
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> /*browser*/,
                              int message_id,
                              bool success,
                              const void *result,
                              size_t result_size) override {
    NSString *json = [[NSString alloc] initWithBytes:result
                                              length:result_size
                                            encoding:NSUTF8StringEncoding];
    [view_ cef_devToolsResult:message_id success:success json:json];
  }

 private:
  static NSString *Str(const CefString &value) {
    // CefString is UTF-16 internally; ToString() always yields valid UTF-8.
    std::string utf8 = value.ToString();
    NSString *string = [[NSString alloc] initWithBytes:utf8.data()
                                                length:utf8.size()
                                              encoding:NSUTF8StringEncoding];
    return string != nil ? string : @"";
  }

  __weak OMCEFBrowserView *view_;
  IMPLEMENT_REFCOUNTING(OMClient);
};

CefRefPtr<CefRequestContext> ContextFor(NSString *profileKey, BOOL persistent) {
  std::string key = std::string(persistent ? "p:" : "e:") + profileKey.UTF8String;
  auto found = g_contexts.find(key);
  if (found != g_contexts.end()) {
    return found->second;
  }
  CefRequestContextSettings settings;
  if (persistent) {
    // Chrome-style profiles must be direct children of root_cache_path.
    NSURL *path = [g_rootCacheURL
        URLByAppendingPathComponent:[@"Profile-" stringByAppendingString:profileKey]
                        isDirectory:YES];
    CefString(&settings.cache_path) = path.path.UTF8String;
    settings.persist_session_cookies = true;
  }
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, nullptr);
  if (context) {
    g_contexts[key] = context;
  }
  return context;
}

}  // namespace

static BOOL OMCEFShouldDeferTerminate() {
  if (g_state != RuntimeState::kRunning || g_terminateApproved || g_liveBrowsers == 0) {
    return NO;
  }
  if (!g_terminateRequested) {
    g_terminateRequested = true;
    for (OMCEFBrowserView *view in Views().allObjects) {
      [view close];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTerminateTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     FinishTerminate();
                   });
  }
  return YES;
}

#pragma mark - Runtime

@implementation OMCEFRuntime

+ (BOOL)isCompiledIn {
  return YES;
}

+ (NSString *)compiledVersion {
  return @CEF_VERSION;
}

+ (BOOL)isRunning {
  return g_state == RuntimeState::kRunning;
}

+ (BOOL)validateBundleWithConfiguration:(OMCEFConfiguration *)configuration
                                  error:(NSError **)error {
  return OMCEFValidateBundle(configuration, error);
}

+ (BOOL)startWithConfiguration:(OMCEFConfiguration *)configuration error:(NSError **)error {
  switch (g_state) {
    case RuntimeState::kRunning:
      return YES;
    case RuntimeState::kFailed:
      if (error) {
        *error = g_startError;
      }
      return NO;
    case RuntimeState::kShutDown:
      return OMCEFFail(error, OMCEFErrorAlreadyShutDown,
                       @"Chromium was shut down and cannot restart in this process.");
    case RuntimeState::kIdle:
      break;
  }

  NSError *failure = nil;
  if ([self startOnce:configuration error:&failure]) {
    g_state = RuntimeState::kRunning;
    return YES;
  }
  g_state = RuntimeState::kFailed;
  g_startError = failure;
  if (error) {
    *error = failure;
  }
  return NO;
}

+ (BOOL)startOnce:(OMCEFConfiguration *)configuration error:(NSError **)error {
  if (!OMCEFInstallApplicationProtocol(error)) {
    return NO;
  }
  if (!OMCEFValidateBundle(configuration, error)) {
    return NO;
  }
  NSString *frameworksPath = NSBundle.mainBundle.privateFrameworksPath;
  NSString *frameworkDir = [frameworksPath
      stringByAppendingPathComponent:[OMCEFFrameworkName stringByAppendingString:@".framework"]];
  NSString *frameworkBinary = [frameworkDir stringByAppendingPathComponent:OMCEFFrameworkName];

  NSError *dirError = nil;
  if (![NSFileManager.defaultManager createDirectoryAtURL:configuration.rootCacheURL
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError]) {
    return OMCEFFail(error, OMCEFErrorInitializeFailed,
                     [NSString stringWithFormat:@"Cannot create the Chromium profile directory: %@",
                                                dirError.localizedDescription]);
  }

  if (!cef_load_library(frameworkBinary.fileSystemRepresentation)) {
    return OMCEFFail(error, OMCEFErrorLibraryLoadFailed,
                     [NSString stringWithFormat:@"Failed to load %@ (%s).", frameworkBinary,
                                                OMCEFDlerror()]);
  }

  CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  settings.no_sandbox = configuration.disableSandbox;
  settings.external_message_pump = true;
  settings.command_line_args_disabled = true;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = (int)configuration.remoteDebuggingPort;
  settings.log_severity = LOGSEVERITY_WARNING;
  CefString(&settings.browser_subprocess_path) =
      OMCEFHelperExecutablePath(frameworksPath, configuration.helperName).UTF8String;
  CefString(&settings.framework_dir_path) = frameworkDir.UTF8String;
  CefString(&settings.main_bundle_path) = NSBundle.mainBundle.bundlePath.UTF8String;
  CefString(&settings.root_cache_path) = configuration.rootCacheURL.path.UTF8String;
  NSURL *logFile = configuration.logFileURL != nil
                       ? configuration.logFileURL
                       : [configuration.rootCacheURL URLByAppendingPathComponent:@"chromium.log"];
  CefString(&settings.log_file) = logFile.path.UTF8String;
  if (configuration.locale.length > 0) {
    CefString(&settings.locale) = configuration.locale.UTF8String;
  }
  if (configuration.keychainServiceName.length > 0) {
    CefString(&settings.keychain_service_name) = configuration.keychainServiceName.UTF8String;
  }
  if (configuration.keychainAccountName.length > 0) {
    CefString(&settings.keychain_account_name) = configuration.keychainAccountName.UTF8String;
  }

  g_rootCacheURL = [configuration.rootCacheURL copy];
  CefRefPtr<OMApp> app(new OMApp(configuration.useMockKeychain));
  if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) {
    int code = CefGetExitCode();
    cef_unload_library();
    return OMCEFFail(error, OMCEFErrorInitializeFailed,
                     [NSString stringWithFormat:@"CefInitialize failed (result code %d). Another "
                                                @"process may be using %@.",
                                                code, configuration.rootCacheURL.path]);
  }
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(applicationWillTerminate:)
                                             name:NSApplicationWillTerminateNotification
                                           object:nil];
  [[OMCEFPump shared] scheduleWork:0];
  return YES;
}

+ (void)applicationWillTerminate:(NSNotification *)notification {
  [self shutdown];
}

+ (void)shutdown {
  if (g_state != RuntimeState::kRunning) {
    return;
  }
  for (OMCEFBrowserView *view in Views().allObjects) {
    [view close];
  }
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
  while (g_liveBrowsers > 0 && deadline.timeIntervalSinceNow > 0) {
    // Draining the pool releases detached CEF views, which completes their close.
    @autoreleasepool {
      CefDoMessageLoopWork();
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
  }
  if (g_liveBrowsers > 0) {
    NSLog(@"OmnigentCEF: shutting down with %d browser(s) still open", g_liveBrowsers);
  }
  [[OMCEFPump shared] stop];
  for (OMCEFBrowserView *view in Views().allObjects) {
    [view cef_releaseCefReferences];
  }
  g_contexts.clear();
  // CefShutdown requires released references and an idle pump; like cefclient's external pump,
  // drain pending work for a while first.
  for (int i = 0; i < 10; ++i) {
    @autoreleasepool {
      CefDoMessageLoopWork();
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
  }
  CefShutdown();
  cef_unload_library();
  g_state = RuntimeState::kShutDown;
}

@end

#pragma mark - Browser view

@implementation OMCEFBrowserView {
  CefRefPtr<OMClient> _client;
  CefRefPtr<CefBrowser> _browser;
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSString *_pendingURL;
  NSString *_lastFindText;
  NSMutableDictionary<NSNumber *, void (^)(NSString *, NSError *)> *_pendingDevTools;
  int _nextMessageID;
  BOOL _creating;
  BOOL _closing;
  BOOL _closed;
}

- (nullable instancetype)initWithProfileKey:(NSString *)profileKey
                                 persistent:(BOOL)persistent
                                 initialURL:(NSString *)initialURL
                                      error:(NSError **)error {
  if (g_state != RuntimeState::kRunning) {
    OMCEFFail(error, OMCEFErrorNotRunning, @"Chromium is not running.");
    return nil;
  }
  if (profileKey.length == 0 || [profileKey containsString:@"/"] ||
      [profileKey hasPrefix:@"."]) {
    OMCEFFail(error, OMCEFErrorInvalidArgument,
              [NSString stringWithFormat:@"Invalid profile key \"%@\".", profileKey]);
    return nil;
  }
  CefRefPtr<CefRequestContext> context = ContextFor(profileKey, persistent);
  if (!context) {
    OMCEFFail(error, OMCEFErrorBrowserCreateFailed,
              [NSString stringWithFormat:@"Cannot create the Chromium profile \"%@\".", profileKey]);
    return nil;
  }
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) {
    _context = context;
    _pendingURL = [initialURL copy];
    _pendingDevTools = [NSMutableDictionary dictionary];
    _client = new OMClient(self);
    [Views() addObject:self];
  }
  return self;
}

- (void)dealloc {
  if (_client) {
    _client->Detach();
  }
  if (_browser && !_closed) {
    _browser->GetHost()->CloseBrowser(true);
  }
}

- (BOOL)hasBrowser {
  return _browser != nullptr;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self cef_createBrowserIfReady];
}

- (void)layout {
  [super layout];
  for (NSView *subview in self.subviews) {
    subview.frame = self.bounds;
  }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  for (NSView *subview in self.subviews) {
    subview.frame = self.bounds;
  }
}

- (void)cef_createBrowserIfReady {
  if (_browser || _creating || _closing || self.window == nil || !g_contextInitialized ||
      g_state != RuntimeState::kRunning) {
    return;
  }
  NSRect bounds = self.bounds;
  CefWindowInfo windowInfo;
  windowInfo.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(self),
                        CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings browserSettings;
  NSString *url = _pendingURL != nil ? _pendingURL : @"about:blank";
  _pendingURL = nil;
  _creating = YES;
  if (!CefBrowserHost::CreateBrowser(windowInfo, _client.get(), url.UTF8String, browserSettings,
                                     nullptr, _context)) {
    _creating = NO;
    [self.delegate browserView:self
        didFailLoadWithErrorCode:OMCEFErrorBrowserCreateFailed
                            text:@"CefBrowserHost::CreateBrowser failed."
                             url:url];
    return;
  }
  g_liveBrowsers += 1;
}

- (void)cef_didCreateBrowser:(CefRefPtr<CefBrowser>)browser {
  _creating = NO;
  _browser = browser;
  _devToolsRegistration = browser->GetHost()->AddDevToolsMessageObserver(_client.get());
  if (_closing) {
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  for (NSView *subview in self.subviews) {
    subview.frame = self.bounds;
  }
  if (_pendingURL) {
    browser->GetMainFrame()->LoadURL(_pendingURL.UTF8String);
    _pendingURL = nil;
  }
  [self.delegate browserViewDidCreateBrowser:self];
}

- (void)cef_willCloseBrowser {
  _closing = YES;
}

- (void)cef_releaseCefReferences {
  _devToolsRegistration = nullptr;
  _browser = nullptr;
  _context = nullptr;
}

- (void)cef_didCloseBrowser {
  _closed = YES;
  [self cef_releaseCefReferences];
  [self failPendingDevTools:OMCEFError(OMCEFErrorBrowserClosed, @"The browser was closed.")];
  [self.delegate browserViewDidClose:self];
}

- (void)failPendingDevTools:(NSError *)error {
  NSDictionary *pending = [_pendingDevTools copy];
  [_pendingDevTools removeAllObjects];
  for (NSNumber *key in pending) {
    void (^completion)(NSString *, NSError *) = pending[key];
    completion(nil, error);
  }
}

- (void)loadURL:(NSString *)url {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.UTF8String);
  } else {
    _pendingURL = [url copy];
    [self cef_createBrowserIfReady];
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase {
  if (!_browser) {
    return;
  }
  BOOL findNext = [_lastFindText isEqualToString:text];
  _lastFindText = [text copy];
  _browser->GetHost()->Find(text.UTF8String, forward, matchCase, findNext);
}

- (void)stopFinding {
  _lastFindText = nil;
  if (_browser) {
    _browser->GetHost()->StopFinding(true);
  }
}

- (BOOL)showDevToolsWithError:(NSError **)error {
  if (!_browser) {
    return OMCEFFail(error, OMCEFErrorBrowserNotReady, @"The browser has not been created yet.");
  }
  CefWindowInfo windowInfo;
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
  return YES;
}

- (void)executeDevToolsMethod:(NSString *)method
                   paramsJSON:(NSString *)paramsJSON
                   completion:(void (^)(NSString *, NSError *))completion {
  if (!_browser) {
    completion(nil, OMCEFError(_closed ? OMCEFErrorBrowserClosed : OMCEFErrorBrowserNotReady,
                               @"The browser is not available."));
    return;
  }
  CefRefPtr<CefDictionaryValue> params;
  if (paramsJSON.length > 0) {
    CefRefPtr<CefValue> value = CefParseJSON(CefString(paramsJSON.UTF8String), JSON_PARSER_RFC);
    if (!value || value->GetType() != VTYPE_DICTIONARY) {
      completion(nil, OMCEFError(OMCEFErrorInvalidArgument,
                                 @"DevTools params must be a JSON object."));
      return;
    }
    params = value->GetDictionary();
  }
  int messageID = ++_nextMessageID;
  _pendingDevTools[@(messageID)] = [completion copy];
  if (_browser->GetHost()->ExecuteDevToolsMethod(messageID, method.UTF8String, params) == 0) {
    [_pendingDevTools removeObjectForKey:@(messageID)];
    completion(nil, OMCEFError(OMCEFErrorDevToolsFailed,
                               [NSString stringWithFormat:@"DevTools method %@ was rejected.",
                                                          method]));
  }
}

- (void)cef_devToolsResult:(int)messageID success:(BOOL)success json:(NSString *)json {
  void (^completion)(NSString *, NSError *) = _pendingDevTools[@(messageID)];
  if (completion == nil) {
    return;
  }
  [_pendingDevTools removeObjectForKey:@(messageID)];
  if (json == nil) {
    completion(nil, OMCEFError(OMCEFErrorDevToolsFailed, @"DevTools returned non-UTF-8 data."));
  } else if (success) {
    completion(json, nil);
  } else {
    completion(nil, OMCEFError(OMCEFErrorDevToolsFailed, json));
  }
}

- (void)close {
  if (_closing || _closed) {
    return;
  }
  _closing = YES;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
  } else if (!_creating) {
    _closed = YES;
    [self failPendingDevTools:OMCEFError(OMCEFErrorBrowserClosed, @"The browser was closed.")];
  }
}

@end

#else  // OMNIGENT_CEF_LINKED

static NSString *const OMCEFNotCompiledMessage =
    @"This build does not include Chromium. Run apps/apple/scripts/fetch-cef.sh, then regenerate "
    @"the project.";

@implementation OMCEFApplication
@end

@implementation OMCEFRuntime

+ (BOOL)isCompiledIn {
  return NO;
}

+ (NSString *)compiledVersion {
  return @"";
}

+ (BOOL)isRunning {
  return NO;
}

+ (BOOL)validateBundleWithConfiguration:(OMCEFConfiguration *)configuration
                                  error:(NSError **)error {
  return OMCEFFail(error, OMCEFErrorNotCompiledIn, OMCEFNotCompiledMessage);
}

+ (BOOL)startWithConfiguration:(OMCEFConfiguration *)configuration error:(NSError **)error {
  return OMCEFFail(error, OMCEFErrorNotCompiledIn, OMCEFNotCompiledMessage);
}

+ (void)shutdown {
}

@end

@implementation OMCEFBrowserView

- (nullable instancetype)initWithProfileKey:(NSString *)profileKey
                                 persistent:(BOOL)persistent
                                 initialURL:(NSString *)initialURL
                                      error:(NSError **)error {
  OMCEFFail(error, OMCEFErrorNotCompiledIn, OMCEFNotCompiledMessage);
  return nil;
}

- (BOOL)hasBrowser {
  return NO;
}
- (void)loadURL:(NSString *)url {
}
- (void)goBack {
}
- (void)goForward {
}
- (void)reload {
}
- (void)stopLoading {
}
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase {
}
- (void)stopFinding {
}
- (BOOL)showDevToolsWithError:(NSError **)error {
  return OMCEFFail(error, OMCEFErrorNotCompiledIn, OMCEFNotCompiledMessage);
}
- (void)executeDevToolsMethod:(NSString *)method
                   paramsJSON:(NSString *)paramsJSON
                   completion:(void (^)(NSString *, NSError *))completion {
  completion(nil, OMCEFError(OMCEFErrorNotCompiledIn, OMCEFNotCompiledMessage));
}
- (void)close {
}

@end

#endif  // OMNIGENT_CEF_LINKED

#endif  // TARGET_OS_OSX
