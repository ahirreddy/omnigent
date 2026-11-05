// In-process driver and frame logger for profiling: inject with DYLD_INSERT_LIBRARIES next to the
// hitch monitor.
//
// Frames: a display link on the main run loop appends "<unix ms> <interval ms>" to
// OMNIGENT_FRAME_LOG for every frame interval of 1.5 periods or more, and
// "# frames <unix ms> <count> <period ms>" every 250 ms, so perf.py can report frames per second,
// long frames and hitch time for a time window. A frame the main thread misses is one it was too
// busy to start; the render server's own misses are not seen here.
//
// Input: on SIGUSR2 it runs the steps in OMNIGENT_DRIVE_FILE, one per line, on the main queue:
//   key <character> [modifiers]     a key press (`esc` Escape, `del` Delete); modifiers: c command,
//                                   o option, t control, s shift
//   scroll <x> <y> <dy> <steps>     scroll-wheel steps of dy points, one per frame, over the point
//                                   at fractions x and y of the window (y from the top)
//   resize <dw> <dh> <steps>        grows the window by dw and dh points over steps frames
//   wait <ms>                       pauses
// Events go to the app's own queue or views, so no Accessibility permission is needed.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

static FILE *frame_log;
static CFTimeInterval last_frame;
static int frame_count;
static double frame_period;
static double last_report;

static double wall_ms(void) { return [NSDate date].timeIntervalSince1970 * 1000.0; }

@interface OmnigentFrameLogger : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation OmnigentFrameLogger
- (void)tick:(CADisplayLink *)link {
  CFTimeInterval now = link.timestamp;
  double period = (link.targetTimestamp - link.timestamp) * 1000.0;
  if (period > 0) frame_period = period;
  if (last_frame > 0) {
    double interval = (now - last_frame) * 1000.0;
    frame_count++;
    if (interval >= 1.5 * frame_period) fprintf(frame_log, "%.0f %.1f\n", wall_ms(), interval);
  }
  last_frame = now;
  double wall = wall_ms();
  if (wall - last_report >= 250) {
    fprintf(frame_log, "# frames %.0f %d %.2f\n", wall, frame_count, frame_period);
    fflush(frame_log);
    frame_count = 0;
    last_report = wall;
  }
}
@end

static NSWindow *drive_window(void) {
  if (NSApp.keyWindow != nil) return NSApp.keyWindow;
  for (NSWindow *window in NSApp.orderedWindows) {
    if (window.isVisible && window.canBecomeKeyWindow) return window;
  }
  return nil;
}

static void press(NSString *character, unsigned short code, NSString *modifiers) {
  NSEventModifierFlags flags = 0;
  if ([modifiers containsString:@"c"]) flags |= NSEventModifierFlagCommand;
  if ([modifiers containsString:@"o"]) flags |= NSEventModifierFlagOption;
  if ([modifiers containsString:@"t"]) flags |= NSEventModifierFlagControl;
  if ([modifiers containsString:@"s"]) flags |= NSEventModifierFlagShift;
  NSWindow *window = drive_window();
  NSEventType types[2] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
  for (int index = 0; index < 2; index++) {
    NSEvent *event = [NSEvent keyEventWithType:types[index]
                                      location:NSZeroPoint
                                 modifierFlags:flags
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.windowNumber
                                       context:nil
                                    characters:character
                   charactersIgnoringModifiers:character
                                     isARepeat:NO
                                       keyCode:code];
    [NSApp postEvent:event atStart:NO];
  }
}

/// The scroll view under a point of the window, given as fractions of its content (y from top).
static NSScrollView *scroll_view_at(NSWindow *window, double x, double y) {
  NSView *content = window.contentView;
  NSPoint point = NSMakePoint(NSWidth(content.bounds) * x, NSHeight(content.bounds) * (1 - y));
  NSView *hit = [content.superview hitTest:[content convertPoint:point toView:content.superview]];
  for (NSView *view = hit; view != nil; view = view.superview) {
    if ([view isKindOfClass:NSScrollView.class]) return (NSScrollView *)view;
  }
  return hit.enclosingScrollView;
}

static void scroll_step(NSScrollView *scroll_view, double dy) {
  CGEventRef wheel = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 1, (int32_t)dy, 0, 0);
  CGEventSetIntegerValueField(wheel, kCGScrollWheelEventIsContinuous, 1);
  NSEvent *event = [NSEvent eventWithCGEvent:wheel];
  CFRelease(wheel);
  [scroll_view scrollWheel:event];
}

static void run_steps(NSArray<NSString *> *lines) {
  double at = 0;
  const double frame = 1000.0 / 60.0;
  for (NSString *line in lines) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    void (^after)(double, dispatch_block_t) = ^(double ms, dispatch_block_t block) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                     dispatch_get_main_queue(), block);
    };
    if ([verb isEqualToString:@"wait"] && parts.count >= 2) {
      at += parts[1].doubleValue;
    } else if ([verb isEqualToString:@"key"] && parts.count >= 2) {
      NSString *character = parts[1];
      unsigned short code = 0;
      if ([character isEqualToString:@"esc"]) character = @"\x1b", code = 53;
      if ([character isEqualToString:@"del"]) character = @"\x7f", code = 51;
      NSString *modifiers = parts.count >= 3 ? parts[2] : @"";
      after(at, ^{ press(character, code, modifiers); });
      at += 50;
    } else if ([verb isEqualToString:@"scroll"] && parts.count >= 5) {
      double x = parts[1].doubleValue, y = parts[2].doubleValue, dy = parts[3].doubleValue;
      int steps = parts[4].intValue;
      __block NSScrollView *target = nil;
      after(at, ^{ target = scroll_view_at(drive_window(), x, y); });
      for (int step = 0; step < steps; step++) {
        after(at + frame * (step + 1), ^{ if (target) scroll_step(target, dy); });
      }
      at += frame * (steps + 1);
    } else if ([verb isEqualToString:@"resize"] && parts.count >= 4) {
      double dw = parts[1].doubleValue, dh = parts[2].doubleValue;
      int steps = parts[3].intValue;
      for (int step = 0; step < steps; step++) {
        after(at + frame * step, ^{
          NSWindow *window = drive_window();
          NSRect rect = window.frame;
          rect.size.width += dw / steps;
          rect.size.height += dh / steps;
          rect.origin.y -= dh / steps;
          [window setFrame:rect display:YES];
        });
      }
      at += frame * steps;
    } else if (verb.length > 0) {
      NSLog(@"driver: unknown step %@", line);
    }
  }
}

static void start_frames(void) {
  const char *path = getenv("OMNIGENT_FRAME_LOG");
  if (path == NULL) return;
  frame_log = fopen(path, "a");
  if (frame_log == NULL) return;
  fprintf(frame_log, "# start %.0f\n", wall_ms());
  fflush(frame_log);
  static OmnigentFrameLogger *logger;
  logger = [OmnigentFrameLogger new];
  NSScreen *screen = NSScreen.mainScreen;
  CADisplayLink *link = [screen displayLinkWithTarget:logger selector:@selector(tick:)];
  [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

__attribute__((constructor)) static void start_driver(void) {
  [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *note) {
                                                (void)note;
                                                start_frames();
                                              }];
  signal(SIGUSR2, SIG_IGN);
  dispatch_source_t source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(source, ^{
    const char *path = getenv("OMNIGENT_DRIVE_FILE");
    NSString *text = path ? [NSString stringWithContentsOfFile:@(path)
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil]
                          : nil;
    if (text == nil) {
      NSLog(@"driver: no OMNIGENT_DRIVE_FILE to run");
      return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [drive_window() makeKeyAndOrderFront:nil];
    run_steps([text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]);
  });
  dispatch_resume(source);
  // Kept for the life of the process.
  CFBridgingRetain(source);
}
