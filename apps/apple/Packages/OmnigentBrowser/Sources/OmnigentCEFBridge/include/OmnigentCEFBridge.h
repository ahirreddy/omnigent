// Swift-facing Objective-C surface over CEF. No CEF or C++ types appear here so Swift
// imports it as a plain Clang module. Everything is main-thread only.
#pragma once

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const OMCEFErrorDomain;

typedef NS_ERROR_ENUM(OMCEFErrorDomain, OMCEFErrorCode) {
  /// The bridge was compiled without CEF (scripts/fetch-cef.sh was not run).
  OMCEFErrorNotCompiledIn = 1,
  /// NSApp is missing or CefAppProtocol could not be added to its class.
  OMCEFErrorApplicationClass = 2,
  OMCEFErrorFrameworkMissing = 3,
  OMCEFErrorHelperMissing = 4,
  OMCEFErrorLibraryLoadFailed = 5,
  OMCEFErrorInitializeFailed = 6,
  OMCEFErrorNotRunning = 7,
  /// CEF cannot be re-initialized in a process after CefShutdown.
  OMCEFErrorAlreadyShutDown = 8,
  OMCEFErrorBrowserCreateFailed = 9,
  OMCEFErrorBrowserNotReady = 10,
  OMCEFErrorBrowserClosed = 11,
  OMCEFErrorDevToolsFailed = 12,
  OMCEFErrorInvalidArgument = 13,
};

/// NSApplication subclass implementing CefAppProtocol (CrAppProtocol / CrAppControlProtocol)
/// for AppKit-lifecycle apps (NSPrincipalClass). Optional: when NSApp does not conform, for
/// example under the SwiftUI App lifecycle, OMCEFRuntime adds the protocol to NSApp's class.
NS_SWIFT_UI_ACTOR
@interface OMCEFApplication : NSApplication
@end

NS_SWIFT_UI_ACTOR
@interface OMCEFConfiguration : NSObject
/// Base helper bundle name; CEF derives "(GPU)", "(Renderer)", "(Plugin)", "(Alerts)".
@property(nonatomic, copy) NSString *helperName;
/// Root directory for all persistent profiles. Must be app-private.
@property(nonatomic, copy) NSURL *rootCacheURL;
/// Chrome remote debugging port, 0 disables it.
@property(nonatomic) NSInteger remoteDebuggingPort;
/// Disables Chromium's seatbelt sandbox for helper processes. Never set in release builds.
@property(nonatomic) BOOL disableSandbox;
/// Use Chromium's mock keychain (no Keychain item for cookie encryption). Debug only.
@property(nonatomic) BOOL useMockKeychain;
@property(nonatomic, copy, nullable) NSString *keychainServiceName;
@property(nonatomic, copy, nullable) NSString *keychainAccountName;
@property(nonatomic, copy, nullable) NSURL *logFileURL;
@property(nonatomic, copy, nullable) NSString *locale;

- (instancetype)initWithHelperName:(NSString *)helperName rootCacheURL:(NSURL *)rootCacheURL;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_SWIFT_UI_ACTOR
@interface OMCEFRuntime : NSObject
@property(class, nonatomic, readonly) BOOL isCompiledIn;
@property(class, nonatomic, readonly) NSString *compiledVersion;
@property(class, nonatomic, readonly) BOOL isRunning;

/// Checks that the framework and helper bundles exist in the main bundle, without loading CEF.
+ (BOOL)validateBundleWithConfiguration:(OMCEFConfiguration *)configuration
                                  error:(NSError **)error;

/// Loads the framework and calls CefInitialize with an external message pump.
/// Idempotent while running. Failure is sticky for the process lifetime.
+ (BOOL)startWithConfiguration:(OMCEFConfiguration *)configuration error:(NSError **)error;

/// Force-closes browsers, drains the pump, and calls CefShutdown. Called automatically on
/// NSApplicationWillTerminateNotification.
+ (void)shutdown;

- (instancetype)init NS_UNAVAILABLE;
@end

@class OMCEFBrowserView;

NS_SWIFT_UI_ACTOR
@protocol OMCEFBrowserViewDelegate <NSObject>
- (void)browserViewDidCreateBrowser:(OMCEFBrowserView *)view;
- (void)browserView:(OMCEFBrowserView *)view didChangeURL:(NSString *)url;
- (void)browserView:(OMCEFBrowserView *)view didChangeTitle:(NSString *)title;
- (void)browserView:(OMCEFBrowserView *)view
    didChangeLoading:(BOOL)isLoading
           canGoBack:(BOOL)canGoBack
        canGoForward:(BOOL)canGoForward;
- (void)browserView:(OMCEFBrowserView *)view didChangeProgress:(double)progress;
- (void)browserView:(OMCEFBrowserView *)view
    didFailLoadWithErrorCode:(NSInteger)code
                        text:(NSString *)text
                         url:(NSString *)url;
- (void)browserView:(OMCEFBrowserView *)view
    renderProcessTerminatedWithStatus:(NSInteger)status
                            errorCode:(NSInteger)errorCode
                              message:(NSString *)message;
- (void)browserView:(OMCEFBrowserView *)view didBlockDownloadOfURL:(NSString *)url;
- (void)browserView:(OMCEFBrowserView *)view
    didFindMatches:(NSInteger)count
       activeMatch:(NSInteger)activeMatch
       finalUpdate:(BOOL)finalUpdate;
- (void)browserViewDidClose:(OMCEFBrowserView *)view;
@end

/// Hosts one CEF browser (Alloy style, native child view). The browser is created when the
/// view first joins a window; loads issued earlier are applied once it exists.
NS_SWIFT_UI_ACTOR
@interface OMCEFBrowserView : NSView

/// @param profileKey filesystem-safe key; persistent profiles live under rootCacheURL/Profiles/<key>.
- (nullable instancetype)initWithProfileKey:(NSString *)profileKey
                                 persistent:(BOOL)persistent
                                 initialURL:(NSString *)initialURL
                                      error:(NSError **)error;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<OMCEFBrowserViewDelegate> delegate;
@property(nonatomic, readonly) BOOL hasBrowser;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase;
- (void)stopFinding;
- (BOOL)showDevToolsWithError:(NSError **)error;

/// Runs a Chrome DevTools Protocol method in the browser process. The completion runs on the
/// main thread with the raw JSON result object, or an error.
- (void)executeDevToolsMethod:(NSString *)method
                   paramsJSON:(nullable NSString *)paramsJSON
                   completion:(void (^NS_SWIFT_UI_ACTOR)(NSString *_Nullable resultJSON,
                                                          NSError *_Nullable error))completion
    NS_SWIFT_DISABLE_ASYNC;

/// Closes the browser. Pending DevTools calls fail with OMCEFErrorBrowserClosed.
- (void)close;
@end

NS_ASSUME_NONNULL_END

#endif
