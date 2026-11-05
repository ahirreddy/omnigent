// In-process typist for profiling the composer: inject with DYLD_INSERT_LIBRARIES next to the
// hitch monitor. On SIGUSR1 it focuses the composer (Control-Shift-L) and types
// OMNIGENT_TYPE_COUNT characters (default 20), one every 80 ms, then deletes them. Events are
// posted to the app's own queue, so no Accessibility permission is needed.
#import <AppKit/AppKit.h>

static NSWindow *target_window(void) {
  if (NSApp.keyWindow != nil) return NSApp.keyWindow;
  for (NSWindow *window in NSApp.orderedWindows) {
    if (window.isVisible && window.canBecomeKeyWindow) return window;
  }
  return nil;
}

static void post_key(NSString *characters, unsigned short code, NSEventModifierFlags flags) {
  NSWindow *window = target_window();
  NSEventType types[2] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
  for (int index = 0; index < 2; index++) {
    NSEvent *event = [NSEvent keyEventWithType:types[index]
                                      location:NSZeroPoint
                                 modifierFlags:flags
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.windowNumber
                                       context:nil
                                    characters:characters
                   charactersIgnoringModifiers:characters.lowercaseString
                                     isARepeat:NO
                                       keyCode:code];
    [NSApp postEvent:event atStart:NO];
  }
}

/// The lowest editable text view in `view`: the composer sits at the bottom of the window.
static NSTextView *lowest_editor(NSView *view, NSTextView *best) {
  if ([view isKindOfClass:NSTextView.class] && ((NSTextView *)view).isEditable &&
      !((NSTextView *)view).isFieldEditor && view.window != nil && !view.isHiddenOrHasHiddenAncestor) {
    NSRect frame = [view convertRect:view.bounds toView:nil];
    NSRect current = best ? [best convertRect:best.bounds toView:nil] : NSZeroRect;
    if (best == nil || NSMinY(frame) < NSMinY(current)) best = (NSTextView *)view;
  }
  for (NSView *child in view.subviews) best = lowest_editor(child, best);
  return best;
}

static void type_burst(void) {
  const char *setting = getenv("OMNIGENT_TYPE_COUNT");
  int count = setting ? atoi(setting) : 20;
  [NSApp activateIgnoringOtherApps:YES];
  NSWindow *window = target_window();
  [window makeKeyAndOrderFront:nil];
  NSTextView *composer = lowest_editor(window.contentView.superview, nil);
  if (composer == nil) {
    NSLog(@"typist: no editable text view in the window");
    return;
  }
  [window makeFirstResponder:composer];
  for (int index = 0; index < 2 * count; index++) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 + 80 * index) * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     if (index < count) {
                       NSString *letter = [NSString stringWithFormat:@"%c", 'a' + index % 26];
                       post_key(letter, 0, 0);
                     } else {
                       post_key(@"\x7f", 51, 0);
                     }
                   });
  }
}

__attribute__((constructor)) static void start_typist(void) {
  signal(SIGUSR1, SIG_IGN);
  dispatch_source_t source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    type_burst();
  });
  dispatch_resume(source);
  // Kept for the life of the process.
  CFBridgingRetain(source);
}
