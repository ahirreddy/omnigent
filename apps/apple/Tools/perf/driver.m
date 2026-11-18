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
//   swipe <x> <y> <dy> <steps>      a trackpad flick: a gesture of steps frames of dy points, then
//                                   a tail decaying as AppKit's momentum (0.967 a 60 Hz frame),
//                                   sent as gesture events: a scroll view called directly drops
//                                   synthesized momentum-phase events
//   resize <dw> <dh> <steps>        grows the window by dw and dh points over steps frames
//   wait <ms>                       pauses
//   views <x> <y>                   writes "# views <unix ms> <count> <class>=<count>..." to the
//                                   frame log: the AppKit views in that scroll view's document
//   offset <x> <y>                  writes "# offset <unix ms> <y> <document height> <viewport
//                                   height>" for that scroll view: where the reader is
// Events go to the app's own queue or views, so no Accessibility permission is needed. After a
// scroll or swipe, "# scrolled <unix ms> <from y> <to y> <document height>" goes to the frame log.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

static FILE *frame_log;
static FILE *busy_log;
static double busy_since;
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

/// The scroll view under a point of the window, given as fractions of its content (y from top):
/// of those around the point, the one with the tallest document, so a code block's own
/// horizontal scroll view under the point is passed over for the transcript's.
static NSScrollView *scroll_view_at(NSWindow *window, double x, double y) {
  NSView *content = window.contentView;
  NSPoint point = NSMakePoint(NSWidth(content.bounds) * x, NSHeight(content.bounds) * (1 - y));
  NSView *hit = [content.superview hitTest:[content convertPoint:point toView:content.superview]];
  NSScrollView *tallest = nil;
  for (NSView *view = hit; view != nil; view = view.superview) {
    if (![view isKindOfClass:NSScrollView.class]) continue;
    NSScrollView *scroll_view = (NSScrollView *)view;
    if (tallest == nil ||
        NSHeight(scroll_view.documentView.frame) > NSHeight(tallest.documentView.frame)) {
      tallest = scroll_view;
    }
  }
  return tallest ?: hit.enclosingScrollView;
}

/// One continuous scroll event of dy points; phase and momentum as CGEvent's scroll-phase fields
/// (0 for a plain wheel step).
static void scroll_event(NSScrollView *scroll_view, double dy, int64_t phase, int64_t momentum) {
  CGEventRef wheel = CGEventCreateScrollWheelEvent2(NULL, kCGScrollEventUnitPixel, 1, (int32_t)lround(dy), 0, 0);
  CGEventSetIntegerValueField(wheel, kCGScrollWheelEventIsContinuous, 1);
  CGEventSetIntegerValueField(wheel, kCGScrollWheelEventScrollPhase, phase);
  CGEventSetIntegerValueField(wheel, kCGScrollWheelEventMomentumPhase, momentum);
  NSEvent *event = [NSEvent eventWithCGEvent:wheel];
  CFRelease(wheel);
  [scroll_view scrollWheel:event];
}

static void scroll_step(NSScrollView *scroll_view, double dy) { scroll_event(scroll_view, dy, 0, 0); }

/// A flick's events: the gesture's steps, its momentum-shaped tail until it is under half a
/// point, then its end.
static NSArray<NSArray<NSNumber *> *> *swipe_events(double dy, int steps) {
  NSMutableArray *events = [NSMutableArray array];
  for (int step = 0; step < steps; step++) {
    [events addObject:@[ @(dy), @(step == 0 ? kCGScrollPhaseBegan : kCGScrollPhaseChanged), @0 ]];
  }
  for (double velocity = dy; fabs(velocity) >= 0.5; velocity *= 0.967) {
    [events addObject:@[ @(velocity), @(kCGScrollPhaseChanged), @0 ]];
  }
  [events addObject:@[ @0, @(kCGScrollPhaseEnded), @0 ]];
  return events;
}

static void report_scroll(NSScrollView *scroll_view, double from) {
  if (frame_log == NULL || scroll_view == nil) return;
  fprintf(frame_log, "# scrolled %.0f %.0f %.0f %.0f\n", wall_ms(), from,
          scroll_view.contentView.bounds.origin.y, NSHeight(scroll_view.documentView.frame));
  fflush(frame_log);
}

/// Counts `view` and the views under it by class.
static void count_views(NSView *view, NSCountedSet *classes) {
  [classes addObject:NSStringFromClass(view.class)];
  for (NSView *subview in view.subviews) count_views(subview, classes);
}

static void report_views(NSScrollView *scroll_view) {
  if (frame_log == NULL || scroll_view.documentView == nil) return;
  NSCountedSet *classes = [NSCountedSet set];
  count_views(scroll_view.documentView, classes);
  NSArray *names = [classes.allObjects sortedArrayUsingComparator:^(id a, id b) {
    return [@([classes countForObject:b]) compare:@([classes countForObject:a])];
  }];
  NSUInteger total = 0;
  for (NSString *name in names) total += [classes countForObject:name];
  fprintf(frame_log, "# views %.0f %lu", wall_ms(), (unsigned long)total);
  for (NSString *name in names) {
    fprintf(frame_log, " %s=%lu", name.UTF8String, (unsigned long)[classes countForObject:name]);
  }
  fprintf(frame_log, "\n");
  fflush(frame_log);
}

static void report_offset(NSScrollView *scroll_view) {
  if (frame_log == NULL || scroll_view == nil) return;
  fprintf(frame_log, "# offset %.0f %.1f %.1f %.1f\n", wall_ms(),
          scroll_view.contentView.bounds.origin.y, NSHeight(scroll_view.documentView.frame),
          NSHeight(scroll_view.contentView.bounds));
  fflush(frame_log);
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
    } else if (([verb isEqualToString:@"scroll"] || [verb isEqualToString:@"swipe"]) &&
               parts.count >= 5) {
      double x = parts[1].doubleValue, y = parts[2].doubleValue, dy = parts[3].doubleValue;
      int steps = parts[4].intValue;
      NSArray<NSArray<NSNumber *> *> *events = [verb isEqualToString:@"swipe"]
                                                   ? swipe_events(dy, steps)
                                                   : nil;
      int count = events ? (int)events.count : steps;
      __block NSScrollView *target = nil;
      __block double from = 0;
      after(at, ^{
        target = scroll_view_at(drive_window(), x, y);
        from = target.contentView.bounds.origin.y;
      });
      for (int step = 0; step < count; step++) {
        NSArray<NSNumber *> *event = events ? events[step] : nil;
        after(at + frame * (step + 1), ^{
          if (target == nil) return;
          if (event) {
            scroll_event(target, event[0].doubleValue, event[1].longLongValue, event[2].longLongValue);
          } else {
            scroll_step(target, dy);
          }
        });
      }
      after(at + frame * (count + 1), ^{ report_scroll(target, from); });
      at += frame * (count + 1);
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
    } else if ([verb isEqualToString:@"views"] && parts.count >= 3) {
      double x = parts[1].doubleValue, y = parts[2].doubleValue;
      after(at, ^{ report_views(scroll_view_at(drive_window(), x, y)); });
      at += 50;
    } else if ([verb isEqualToString:@"offset"] && parts.count >= 3) {
      double x = parts[1].doubleValue, y = parts[2].doubleValue;
      after(at, ^{ report_offset(scroll_view_at(drive_window(), x, y)); });
      at += 50;
    } else if (verb.length > 0) {
      NSLog(@"driver: unknown step %@", line);
    }
  }
}

static void start_busy_log(void) {
  const char *path = getenv("OMNIGENT_BUSY_LOG");
  if (path == NULL) return;
  busy_log = fopen(path, "a");
  if (busy_log == NULL) return;
  fprintf(busy_log, "# start %.0f\n", wall_ms());
  fflush(busy_log);
  // The wake is seen first and the sleep last, after AppKit's layout and Core Animation's commit.
  CFRunLoopObserverRef woke = CFRunLoopObserverCreateWithHandler(
      NULL, kCFRunLoopAfterWaiting, true, LONG_MIN,
      ^(CFRunLoopObserverRef unused, CFRunLoopActivity activity) {
        (void)unused, (void)activity;
        busy_since = CACurrentMediaTime() * 1000.0;
      });
  CFRunLoopObserverRef sleeps = CFRunLoopObserverCreateWithHandler(
      NULL, kCFRunLoopBeforeWaiting, true, LONG_MAX,
      ^(CFRunLoopObserverRef unused, CFRunLoopActivity activity) {
        (void)unused, (void)activity;
        if (busy_since <= 0) return;
        double busy = CACurrentMediaTime() * 1000.0 - busy_since;
        if (busy >= 1.0) fprintf(busy_log, "%.1f %.2f\n", wall_ms() - busy, busy);
        busy_since = 0;
      });
  CFRunLoopAddObserver(CFRunLoopGetMain(), woke, kCFRunLoopCommonModes);
  CFRunLoopAddObserver(CFRunLoopGetMain(), sleeps, kCFRunLoopCommonModes);
  // Flushed four times a second rather than per line, to stay off the measured passes.
  dispatch_source_t flush = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(flush, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(flush, ^{ fflush(busy_log); });
  dispatch_resume(flush);
  CFBridgingRetain(flush);
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
                                                start_busy_log();
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
