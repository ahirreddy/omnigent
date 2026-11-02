// macOS entry point of omnigent-browser-host.app (a runner-side host with no UI). CEF needs an
// NSApplication that implements CefAppProtocol even when nothing is shown.
#import <AppKit/AppKit.h>

#include "host/browser_host.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"

@interface RBHostApplication : NSApplication <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation RBHostApplication

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sending_event_scoper;
  [super sendEvent:event];
}

- (void)terminate:(id)sender {
  (void)sender;
  rb::BrowserHost::Get().BeginShutdown("terminate: was sent to the host application");
}

@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    [RBHostApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInMain()) {
      fprintf(stderr, "omnigent-browser-host: cannot load Chromium Embedded Framework\n");
      return 70;
    }
    return rb::BrowserHost::Get().Run(argc, argv);
  }
}
