// Freeze diagnostics shared by the web host and the client: when a view counts as stalled, how
// often a stall is logged, and how a health record reads as a line. Pure functions, so both
// sides apply the same rules and the client's tests cover them. See DESIGN.md.
#pragma once

#include <CoreFoundation/CFAvailability.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "owl_protocol.h"

/// Seconds without a frame, after input or steady frames, before a view counts as stalled.
#define OWL_STALL_VIEW_SECONDS 2.0
/// Seconds a loading page may go without a frame: a slow server is not a freeze.
#define OWL_STALL_LOADING_SECONDS 5.0
/// Seconds the host's main thread may leave a ping unanswered.
#define OWL_STALL_HOST_SECONDS 1.0
/// Nanoseconds between the first lines of two stalls of the same subject.
#define OWL_STALL_QUIET_NANOS UINT64_C(5000000000)
/// Frames this close together count as one steady run.
#define OWL_STEADY_FRAME_GAP_NANOS UINT64_C(250000000)
/// A steady run this long that stops without input is reported.
#define OWL_STEADY_RUN_NANOS UINT64_C(3000000000)

/// How many lines a stall that has lasted `stalled_seconds` is due: one at `first_seconds`,
/// then at 10 s, 30 s, and every minute from 60 s.
static inline uint32_t owl_stall_lines_due(double stalled_seconds, double first_seconds) {
  if (!(stalled_seconds >= first_seconds)) {
    return 0;
  }
  if (stalled_seconds < 10) {
    return 1;
  }
  if (stalled_seconds < 30) {
    return 2;
  }
  if (stalled_seconds < 60) {
    return 3;
  }
  const double minutes = stalled_seconds / 60;
  return minutes >= 1000000 ? 1000003u : 3u + (uint32_t)minutes;
}

/// What a watcher remembers about one subject (a view, the host's main thread, the channel)
/// between ticks. Zero-initialized means nothing is being followed.
typedef struct owl_stall_episode {
  /// When the stall being followed began, in uptime nanoseconds; 0 when there is none.
  uint64_t since_nanos;
  /// Lines written for it so far.
  uint32_t lines;
  /// When the first line of the latest reported stall was written.
  uint64_t first_line_nanos;
  /// The caller's activity counter when the last line was written.
  uint64_t activity;
} owl_stall_episode;

/// What to write after a tick.
typedef CF_ENUM(uint32_t, OWLStallAction) {
  OWLStallActionNone = 0,
  /// Write a stall line.
  OWLStallActionReport = 1,
  /// The stall that was reported is over: write how long it lasted.
  OWLStallActionEnded = 2,
};

typedef struct owl_stall_step {
  owl_stall_episode episode;
  OWLStallAction action;
  /// Report: which line of the schedule this is, from 1. Otherwise 0.
  uint32_t line;
  /// Report and Ended: when the stall began.
  uint64_t since_nanos;
} owl_stall_step;

/// Advances one subject by one tick; `stalled_since_nanos` is 0 when it is not stalled. A first
/// line waits OWL_STALL_QUIET_NANOS after the previous stall's. With `repeat_needs_activity` a
/// later line is skipped unless `activity` changed: nobody waits on a page left untouched.
static inline owl_stall_step owl_stall_advance(owl_stall_episode episode, uint64_t now_nanos,
                                               uint64_t stalled_since_nanos, double first_seconds,
                                               uint64_t activity, bool repeat_needs_activity) {
  owl_stall_step step;
  step.action = OWLStallActionNone;
  step.line = 0;
  step.since_nanos = 0;
  if (episode.since_nanos != 0 && stalled_since_nanos != episode.since_nanos) {
    const bool reported = episode.lines > 0;
    step.since_nanos = episode.since_nanos;
    episode.since_nanos = 0;
    episode.lines = 0;
    if (reported) {
      // A stall that began in the same tick is picked up by the next one.
      step.episode = episode;
      step.action = OWLStallActionEnded;
      return step;
    }
    step.since_nanos = 0;
  }
  step.episode = episode;
  if (stalled_since_nanos == 0 || now_nanos < stalled_since_nanos) {
    return step;
  }
  episode.since_nanos = stalled_since_nanos;
  step.episode = episode;
  const double stalled_seconds = (double)(now_nanos - stalled_since_nanos) / 1e9;
  const uint32_t due = owl_stall_lines_due(stalled_seconds, first_seconds);
  if (due <= episode.lines) {
    return step;
  }
  if (episode.lines == 0) {
    if (episode.first_line_nanos != 0 &&
        now_nanos - episode.first_line_nanos < OWL_STALL_QUIET_NANOS) {
      return step;
    }
    episode.first_line_nanos = now_nanos;
  } else if (repeat_needs_activity && activity == episode.activity) {
    episode.lines = due;
    step.episode = episode;
    return step;
  }
  episode.lines = due;
  episode.activity = activity;
  step.episode = episode;
  step.action = OWLStallActionReport;
  step.line = due;
  step.since_nanos = stalled_since_nanos;
  return step;
}

/// Why a view owes a frame.
typedef CF_ENUM(uint64_t, OWLStallReason) {
  OWLStallReasonNone = 0,
  /// Input other than pointer movement was replayed into the page and no frame followed.
  OWLStallReasonInput = 1,
  /// The page is loading and no frame was presented.
  OWLStallReasonLoading = 2,
  /// Frames were steady with nobody driving them (a video, an animation) and stopped, and the
  /// renderer's animation frames stopped with them.
  OWLStallReasonFramesStopped = 3,
  /// Input was replayed into a view Chromium was told is hidden, which draws nothing.
  OWLStallReasonInputWhileHidden = 4,
};

/// The times a view's stall is judged from, in uptime nanoseconds; 0 means never.
typedef struct owl_view_activity {
  bool visible;
  bool loading;
  uint64_t loading_since_nanos;
  /// The last frame presented, and since when frames had been arriving without a gap.
  uint64_t last_frame_nanos;
  uint64_t steady_since_nanos;
  /// The first input, other than pointer movement, replayed since the last frame.
  uint64_t unanswered_input_nanos;
  /// The last input of any kind.
  uint64_t last_input_nanos;
  /// The last frame before which a probe found the page's animation frames not running; 0 when
  /// none did.
  uint64_t frames_stopped_after_nanos;
} owl_view_activity;

typedef struct owl_view_stall {
  OWLStallReason reason;
  /// When the wait for a frame began; 0 with OWLStallReasonNone.
  uint64_t since_nanos;
} owl_view_stall;

/// Seconds a stall for `reason` lasts before its first line.
static inline double owl_stall_first_seconds(OWLStallReason reason) {
  return reason == OWLStallReasonLoading ? OWL_STALL_LOADING_SECONDS : OWL_STALL_VIEW_SECONDS;
}

/// Whether the last frame ended a steady run that nobody was driving (a video, an animation).
static inline bool owl_view_frames_ran_by_themselves(owl_view_activity activity) {
  const uint64_t frame = activity.last_frame_nanos;
  const bool steady = frame != 0 && activity.steady_since_nanos != 0 &&
                      frame >= activity.steady_since_nanos &&
                      frame - activity.steady_since_nanos >= OWL_STEADY_RUN_NANOS;
  // Frames that input was driving (a scroll) stop when the input does.
  const bool driven = activity.last_input_nanos != 0 &&
                      activity.last_input_nanos + UINT64_C(1000000000) >= frame;
  return steady && !driven;
}

/// Whether to ask the renderer if the page's animation frames still run: frames that ran by
/// themselves stopped OWL_STALL_VIEW_SECONDS ago. A page that went static still runs them and
/// is not stalled; only a probe that finds them stopped makes it OWLStallReasonFramesStopped.
static inline bool owl_view_wants_frames_probe(owl_view_activity activity, uint64_t now_nanos) {
  const uint64_t frame = activity.last_frame_nanos;
  return activity.visible && activity.unanswered_input_nanos == 0 &&
         owl_view_frames_ran_by_themselves(activity) &&
         activity.frames_stopped_after_nanos != frame && now_nanos >= frame &&
         (double)(now_nanos - frame) / 1e9 >= OWL_STALL_VIEW_SECONDS;
}

/// Whether a view owes a frame, and since when. How long that may last before it is written
/// down is owl_stall_first_seconds; this only says what the view is waiting for.
static inline owl_view_stall owl_view_stall_since(owl_view_activity activity) {
  owl_view_stall stall;
  stall.reason = OWLStallReasonNone;
  stall.since_nanos = 0;
  if (activity.unanswered_input_nanos != 0) {
    stall.reason = activity.visible ? OWLStallReasonInput : OWLStallReasonInputWhileHidden;
    stall.since_nanos = activity.unanswered_input_nanos;
    return stall;
  }
  if (!activity.visible) {
    return stall;
  }
  const uint64_t frame = activity.last_frame_nanos;
  if (owl_view_frames_ran_by_themselves(activity) && activity.frames_stopped_after_nanos == frame) {
    stall.reason = OWLStallReasonFramesStopped;
    stall.since_nanos = frame;
    return stall;
  }
  if (activity.loading && activity.loading_since_nanos != 0) {
    stall.reason = OWLStallReasonLoading;
    stall.since_nanos =
        frame > activity.loading_since_nanos ? frame : activity.loading_since_nanos;
  }
  return stall;
}

/// The start of the stall to keep following: the one already followed while no frame has come
/// (a click on a frozen page does not start a new stall), otherwise the current one.
static inline uint64_t owl_stall_followed_since(uint64_t followed_since_nanos, bool frame_arrived,
                                                owl_view_stall current) {
  if (followed_since_nanos != 0 && !frame_arrived && current.reason != OWLStallReasonNone) {
    return followed_since_nanos;
  }
  return current.since_nanos;
}

static inline const char *owl_stall_reason_name(OWLStallReason reason) {
  switch (reason) {
    case OWLStallReasonInput:
      return "input";
    case OWLStallReasonLoading:
      return "loading";
    case OWLStallReasonFramesStopped:
      return "frames-stopped";
    case OWLStallReasonInputWhileHidden:
      return "input-while-hidden";
    case OWLStallReasonNone:
      break;
  }
  return "none";
}

/// Input grouped by what a page usually answers with a frame. Pointer movement over a page
/// that has nothing to highlight draws nothing, so it never starts a stall.
typedef CF_ENUM(uint32_t, OWLInputClass) {
  OWLInputClassClick = 0,
  OWLInputClassWheel = 1,
  OWLInputClassKey = 2,
  OWLInputClassMove = 3,
  OWLInputClassText = 4,
  OWLInputClassDrag = 5,
  /// Key releases and modifier keys pressed by themselves, which change nothing on most pages.
  OWLInputClassKeyOther = 6,
};
#define OWL_INPUT_CLASS_COUNT 7

/// Whether input of this class makes a view owe a frame.
static inline bool owl_input_expects_frame(OWLInputClass input) {
  return input != OWLInputClassMove && input != OWLInputClassKeyOther;
}

/// The class of an input message from its kind and, for mouse and key messages, its MouseKind,
/// or its KeyKind and NativeKeyCode (macOS virtual key codes 54 to 63 are the modifier keys).
static inline OWLInputClass owl_input_class(uint16_t message_kind, uint64_t mouse_kind,
                                            uint64_t key_kind, uint64_t native_key_code) {
  if (message_kind == OWLMessageKindInputMouse) {
    if (mouse_kind == OWLMouseKindDown || mouse_kind == OWLMouseKindUp) {
      return OWLInputClassClick;
    }
    return mouse_kind == OWLMouseKindWheel ? OWLInputClassWheel : OWLInputClassMove;
  }
  if (message_kind == OWLMessageKindInputKey) {
    const bool modifier = native_key_code >= 54 && native_key_code <= 63;
    return key_kind == OWLKeyKindKeyUp || modifier ? OWLInputClassKeyOther : OWLInputClassKey;
  }
  if (message_kind >= OWLMessageKindImeSetComposition &&
      message_kind <= OWLMessageKindImeCancelComposition) {
    return OWLInputClassText;
  }
  return OWLInputClassDrag;
}

/// One view as the host's freeze watch sees it. Times are uptime nanoseconds, 0 for never.
typedef struct owl_view_health {
  uint64_t now_nanos;
  bool has_browser;
  bool visible;
  bool focused;
  bool loading;
  bool popup_open;
  /// Chromium's hang monitor says the renderer is not handling input.
  bool renderer_unresponsive;
  double width;
  double height;
  double scale;
  /// Paint callbacks from Chromium, frames put on screen, frames dropped because every buffer
  /// was busy, and frames lost to an error.
  uint64_t paints;
  uint64_t frames;
  uint64_t dropped;
  uint64_t present_errors;
  uint64_t last_paint_nanos;
  uint64_t last_frame_nanos;
  uint64_t last_drop_nanos;
  /// Frames presented during the watch's last full tick, about a second.
  uint64_t frames_last_second;
  /// Input messages replayed into the page, and those dropped because they got no time.
  uint64_t inputs;
  uint64_t input_failures;
  uint64_t last_input_nanos;
  /// Key events Chromium handed back as not consumed by the page: proof it processed them.
  uint64_t keys_returned;
  /// Input replayed since the last frame, by OWLInputClass.
  uint32_t unanswered[OWL_INPUT_CLASS_COUNT];
  /// The page's host name, or its scheme when it has none. Never a path or a query.
  char site[64];
} owl_view_health;

/// Milliseconds from `then` to `now`, or -1 when `then` is never.
static inline int64_t owl_age_milliseconds(uint64_t now_nanos, uint64_t then_nanos) {
  if (then_nanos == 0) {
    return -1;
  }
  return now_nanos > then_nanos ? (int64_t)((now_nanos - then_nanos) / 1000000) : 0;
}

/// Appends formatted text at `*length`, never past `capacity`, always terminated.
static inline void owl_line_append(char *buffer, size_t capacity, size_t *length,
                                   const char *format, ...)
    __attribute__((format(printf, 4, 5)));
static inline void owl_line_append(char *buffer, size_t capacity, size_t *length,
                                   const char *format, ...) {
  if (capacity == 0 || *length >= capacity - 1) {
    return;
  }
  va_list arguments;
  va_start(arguments, format);
  const int written = vsnprintf(buffer + *length, capacity - *length, format, arguments);
  va_end(arguments);
  if (written > 0) {
    const size_t room = capacity - 1 - *length;
    *length += (size_t)written < room ? (size_t)written : room;
  }
}

/// Copies a page's host name into `site`, stopping at the first character that is not a letter,
/// a digit or one of `.-:_[]`: whatever follows a host in a URL can never reach a log line.
static inline void owl_site_copy(char *site, size_t capacity, const char *host_name) {
  size_t length = 0;
  for (const char *cursor = host_name; *cursor != '\0' && length + 1 < capacity; ++cursor) {
    const char character = *cursor;
    const bool keep = (character >= 'a' && character <= 'z') ||
                      (character >= 'A' && character <= 'Z') ||
                      (character >= '0' && character <= '9') || character == '.' ||
                      character == '-' || character == ':' || character == '_' ||
                      character == '[' || character == ']';
    if (!keep) {
      break;
    }
    site[length++] = character;
  }
  if (capacity > 0) {
    site[length] = '\0';
  }
}

/// Writes `health` as `key=value` pairs separated by spaces. Returns the length written.
static inline size_t owl_view_health_format(const owl_view_health *health,
                                            char *buffer, size_t capacity) {
  size_t length = 0;
  const uint64_t now = health->now_nanos;
  if (capacity == 0) {
    return 0;
  }
  buffer[0] = '\0';
  owl_line_append(buffer, capacity, &length,
                  "browser=%d visible=%d focused=%d loading=%d popup=%d unresponsive=%d",
                  health->has_browser, health->visible, health->focused, health->loading,
                  health->popup_open, health->renderer_unresponsive);
  owl_line_append(buffer, capacity, &length, " size=%.0fx%.0f@%.2g site=%s", health->width,
                  health->height, health->scale, health->site[0] != '\0' ? health->site : "-");
  owl_line_append(buffer, capacity, &length,
                  " paints=%llu frames=%llu dropped=%llu errors=%llu fps=%llu",
                  (unsigned long long)health->paints, (unsigned long long)health->frames,
                  (unsigned long long)health->dropped, (unsigned long long)health->present_errors,
                  (unsigned long long)health->frames_last_second);
  owl_line_append(buffer, capacity, &length,
                  " paint_age_ms=%lld frame_age_ms=%lld drop_age_ms=%lld",
                  (long long)owl_age_milliseconds(now, health->last_paint_nanos),
                  (long long)owl_age_milliseconds(now, health->last_frame_nanos),
                  (long long)owl_age_milliseconds(now, health->last_drop_nanos));
  owl_line_append(buffer, capacity, &length,
                  " waiting=click:%u,wheel:%u,key:%u,move:%u,text:%u,drag:%u,keyup:%u",
                  health->unanswered[OWLInputClassClick], health->unanswered[OWLInputClassWheel],
                  health->unanswered[OWLInputClassKey], health->unanswered[OWLInputClassMove],
                  health->unanswered[OWLInputClassText], health->unanswered[OWLInputClassDrag],
                  health->unanswered[OWLInputClassKeyOther]);
  owl_line_append(buffer, capacity, &length,
                  " inputs=%llu input_failures=%llu input_age_ms=%lld keys_returned=%llu",
                  (unsigned long long)health->inputs, (unsigned long long)health->input_failures,
                  (long long)owl_age_milliseconds(now, health->last_input_nanos),
                  (unsigned long long)health->keys_returned);
  return length;
}
