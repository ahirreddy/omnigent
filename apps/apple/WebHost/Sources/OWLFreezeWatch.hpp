// The host's freeze watch: a health record per view kept by the CEF UI thread, and a one-second
// timer on its own queue that writes a line to the unified log and the client when a view, the
// UI thread or the channel stalls. Header-only. See DESIGN.md, "Freeze diagnostics".
#pragma once

#include <cxxabi.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/log.h>
#include <pthread.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "OWLPresenter.hpp"
#include "OWLWire.hpp"
#include "include/base/cef_callback.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_closure_task.h"
#include "owl_channel.h"
#include "owl_freeze.h"
#include "owl_protocol.h"

namespace owl {

/// The kernel's App Nap state of a task. The flavor and layout are in XNU's task_policy.h but
/// not in the SDK; when the kernel refuses the call the watch says so once and moves on.
struct TaskSuppressionPolicy {
  integer_t active;
  integer_t lowpri_cpu;
  integer_t timer_throttle;
  integer_t disk_throttle;
  integer_t cpu_limit;
  integer_t suspend;
  integer_t throughput_qos;
  integer_t suppressed_cpu;
  integer_t background_sockets;
  integer_t reserved[7];
};
constexpr task_policy_flavor_t kTaskSuppressionPolicy = 3;

/// One view's health. The CEF UI thread writes it; the watch reads it from its own queue.
struct ViewHealth {
  explicit ViewHealth(uint64_t id) : view_id(id) {}

  const uint64_t view_id;
  std::atomic<bool> has_browser{false};
  std::atomic<bool> visible{false};
  std::atomic<bool> focused{false};
  std::atomic<bool> loading{false};
  std::atomic<bool> popup_open{false};
  std::atomic<bool> unresponsive{false};
  std::atomic<double> width{0};
  std::atomic<double> height{0};
  std::atomic<double> scale{0};
  std::atomic<uint64_t> paints{0};
  std::atomic<uint64_t> frames{0};
  std::atomic<uint64_t> dropped{0};
  std::atomic<uint64_t> present_errors{0};
  std::atomic<uint64_t> last_paint{0};
  std::atomic<uint64_t> last_frame{0};
  std::atomic<uint64_t> last_drop{0};
  std::atomic<uint64_t> steady_since{0};
  std::atomic<uint64_t> loading_since{0};
  std::atomic<uint64_t> inputs{0};
  std::atomic<uint64_t> input_failures{0};
  std::atomic<uint64_t> last_input{0};
  std::atomic<uint64_t> unanswered_input{0};
  /// Inputs that expect a frame, ever: more of them means somebody is still trying.
  std::atomic<uint64_t> expectant_inputs{0};
  std::atomic<uint64_t> keys_returned{0};
  std::atomic<uint32_t> unanswered_total{0};
  std::atomic<uint32_t> unanswered[OWL_INPUT_CLASS_COUNT] = {};

  // MARK: Written on the CEF UI thread

  void NotePaint(uint64_t now) {
    paints.fetch_add(1, std::memory_order_relaxed);
    last_paint.store(now, std::memory_order_relaxed);
  }

  void NoteFrame(uint64_t now) {
    const uint64_t previous = last_frame.load(std::memory_order_relaxed);
    if (previous == 0 || now - previous > OWL_STEADY_FRAME_GAP_NANOS ||
        steady_since.load(std::memory_order_relaxed) == 0) {
      steady_since.store(now, std::memory_order_relaxed);
    }
    last_frame.store(now, std::memory_order_relaxed);
    frames.fetch_add(1, std::memory_order_relaxed);
    if (unanswered_total.load(std::memory_order_relaxed) == 0) {
      return;
    }
    unanswered_input.store(0, std::memory_order_relaxed);
    unanswered_total.store(0, std::memory_order_relaxed);
    for (auto& count : unanswered) {
      count.store(0, std::memory_order_relaxed);
    }
  }

  void NoteDrop(uint64_t now) {
    dropped.fetch_add(1, std::memory_order_relaxed);
    last_drop.store(now, std::memory_order_relaxed);
  }

  void NoteInput(OWLInputClass input, uint64_t now) {
    inputs.fetch_add(1, std::memory_order_relaxed);
    last_input.store(now, std::memory_order_relaxed);
    unanswered[input].fetch_add(1, std::memory_order_relaxed);
    unanswered_total.fetch_add(1, std::memory_order_relaxed);
    if (!owl_input_expects_frame(input)) {
      return;
    }
    expectant_inputs.fetch_add(1, std::memory_order_relaxed);
    if (unanswered_input.load(std::memory_order_relaxed) == 0) {
      unanswered_input.store(now, std::memory_order_relaxed);
    }
  }

  void SetLoading(bool is_loading, uint64_t now) {
    if (is_loading && !loading.load(std::memory_order_relaxed)) {
      loading_since.store(now, std::memory_order_relaxed);
    }
    loading.store(is_loading, std::memory_order_relaxed);
  }

  /// The page changed: what the old one was drawing says nothing about the new one.
  void NoteNavigation() { steady_since.store(0, std::memory_order_relaxed); }

  /// `host_name` is the page's host, or its scheme when it has none; never more of the URL.
  void SetSite(const std::string& host_name) {
    std::lock_guard<std::mutex> lock(site_mutex_);
    owl_site_copy(site_, sizeof(site_), host_name.c_str());
  }

  // MARK: Read from any thread

  owl_view_activity Activity() const {
    owl_view_activity activity;
    activity.visible = visible.load(std::memory_order_relaxed);
    activity.loading = loading.load(std::memory_order_relaxed);
    activity.loading_since_nanos = loading_since.load(std::memory_order_relaxed);
    activity.last_frame_nanos = last_frame.load(std::memory_order_relaxed);
    activity.steady_since_nanos = steady_since.load(std::memory_order_relaxed);
    activity.unanswered_input_nanos = unanswered_input.load(std::memory_order_relaxed);
    activity.last_input_nanos = last_input.load(std::memory_order_relaxed);
    return activity;
  }

  owl_view_health Snapshot(uint64_t now, uint64_t frames_last_second) {
    owl_view_health health = {};
    health.now_nanos = now;
    health.has_browser = has_browser.load(std::memory_order_relaxed);
    health.visible = visible.load(std::memory_order_relaxed);
    health.focused = focused.load(std::memory_order_relaxed);
    health.loading = loading.load(std::memory_order_relaxed);
    health.popup_open = popup_open.load(std::memory_order_relaxed);
    health.renderer_unresponsive = unresponsive.load(std::memory_order_relaxed);
    health.width = width.load(std::memory_order_relaxed);
    health.height = height.load(std::memory_order_relaxed);
    health.scale = scale.load(std::memory_order_relaxed);
    health.paints = paints.load(std::memory_order_relaxed);
    health.frames = frames.load(std::memory_order_relaxed);
    health.dropped = dropped.load(std::memory_order_relaxed);
    health.present_errors = present_errors.load(std::memory_order_relaxed);
    health.last_paint_nanos = last_paint.load(std::memory_order_relaxed);
    health.last_frame_nanos = last_frame.load(std::memory_order_relaxed);
    health.last_drop_nanos = last_drop.load(std::memory_order_relaxed);
    health.frames_last_second = frames_last_second;
    health.inputs = inputs.load(std::memory_order_relaxed);
    health.input_failures = input_failures.load(std::memory_order_relaxed);
    health.last_input_nanos = last_input.load(std::memory_order_relaxed);
    health.keys_returned = keys_returned.load(std::memory_order_relaxed);
    for (size_t index = 0; index < OWL_INPUT_CLASS_COUNT; ++index) {
      health.unanswered[index] = unanswered[index].load(std::memory_order_relaxed);
    }
    std::lock_guard<std::mutex> lock(site_mutex_);
    std::memcpy(health.site, site_, sizeof(health.site));
    return health;
  }

  std::string Line(uint64_t now, uint64_t frames_last_second) {
    const owl_view_health health = Snapshot(now, frames_last_second);
    char buffer[640];
    const size_t length = owl_view_health_format(&health, buffer, sizeof(buffer));
    return std::string(buffer, length);
  }

  /// What the watch remembers between ticks. Touched on the watch's queue only.
  struct Watched {
    owl_stall_episode episode = {};
    OWLStallReason reason = OWLStallReasonNone;
    uint64_t frames_at_stall = 0;
    uint64_t frames_at_tick = 0;
    uint64_t frames_last_second = 0;
    uint64_t counters_at_heartbeat = 0;
    uint64_t liveness_asked_nanos = 0;
    uint64_t inputs_at_liveness = 0;
  };
  Watched watched;

 private:
  std::mutex site_mutex_;
  char site_[sizeof(owl_view_health::site)] = {};
};

class FreezeWatch {
 public:
  /// Asks a view's renderer whether it is alive. Called on the main thread. `quiet` is the
  /// routine question to a page in use, which is written down only when it goes unanswered.
  using ProbeFunction = std::function<void(uint64_t view_id, bool quiet)>;

  static FreezeWatch& Get() {
    static FreezeWatch* watch = new FreezeWatch();
    return *watch;
  }

  static os_log_t Log() {
    static os_log_t log = os_log_create("ai.omnigent.weblayer.host", "freeze");
    return log;
  }

  /// Starts the timer. Main thread, once Chromium runs its loop.
  void Start(owl_channel* channel, bool client_takes_reports, ProbeFunction probe) {
    if (queue_ != nullptr) {
      return;
    }
    channel_ = channel;
    client_takes_reports_ = client_takes_reports;
    probe_ = std::move(probe);
    main_thread_ = pthread_mach_thread_np(pthread_self());
    queue_ = dispatch_queue_create("ai.omnigent.weblayer.host.freeze-watch",
                                   dispatch_queue_attr_make_with_qos_class(
                                       DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    dispatch_source_set_timer(timer_, dispatch_time(DISPATCH_TIME_NOW, kTickNanos), kTickNanos,
                              kTickNanos / 10);
    dispatch_source_set_event_handler(timer_, ^{
      Tick();
    });
    running_.store(true);
    dispatch_activate(timer_);
  }

  /// Stops the timer and waits out a tick in flight. Main thread, before Chromium shuts down.
  void Stop() {
    if (queue_ == nullptr || !running_.exchange(false)) {
      return;
    }
    dispatch_sync(queue_, ^{
      dispatch_source_cancel(timer_);
    });
  }

  std::shared_ptr<ViewHealth> AddView(uint64_t view_id) {
    auto health = std::make_shared<ViewHealth>(view_id);
    std::lock_guard<std::mutex> lock(views_mutex_);
    views_.push_back(health);
    return health;
  }

  /// A message to the client was not taken within its timeout; the sender waited that long.
  void NoteSendFailure(uint64_t now, uint64_t blocked_nanos) {
    send_failures_.fetch_add(1, std::memory_order_relaxed);
    send_blocked_nanos_.fetch_add(blocked_nanos, std::memory_order_relaxed);
    uint64_t none = 0;
    backlog_since_.compare_exchange_strong(none, now, std::memory_order_relaxed);
  }

  /// Writes a line to the log only: a transition worth having next to the stalls.
  void Note(const std::string& line) { os_log(Log(), "freeze %{public}s", line.c_str()); }

  /// Writes a line to the log and sends it to the client. Any thread.
  void Report(OWLHealthKind kind, uint64_t view_id, uint64_t elapsed_milliseconds,
              const std::string& line) {
    os_log(Log(), "freeze %{public}s", line.c_str());
    if (!client_takes_reports_ || channel_ == nullptr || !running_.load()) {
      return;
    }
    Encoder fields;
    fields.U64(OWLFieldHealthKind, kind)
        .U64(OWLFieldElapsedMilliseconds, elapsed_milliseconds)
        .String(OWLFieldText, line);
    const auto& data = fields.data();
    const kern_return_t result =
        owl_channel_send(channel_, OWLMessageKindHealthReport, 0, view_id, data.data(),
                         data.size(), MACH_PORT_NULL, MACH_MSG_TYPE_COPY_SEND, kReportTimeoutMs);
    if (result != KERN_SUCCESS) {
      // The log has the line; the client's copy is lost, and the log says so.
      os_log_error(Log(), "freeze kind=report-undelivered error=%d reason=%{public}s", result,
                   owl_error_string(result));
    }
  }

  /// Whether the main thread answered its last ping in time, as far as the watch knows.
  bool MainThreadResponsive() const { return !host_stalled_.load(); }

 private:
  static constexpr uint64_t kTickNanos = NSEC_PER_SEC;
  static constexpr uint32_t kReportTimeoutMs = 20;
  static constexpr uint32_t kHeartbeatTicks = 60;
  static constexpr uint64_t kLivenessNanos = 5 * NSEC_PER_SEC;
  static constexpr size_t kMaxFrames = 20;

  FreezeWatch() = default;

  static uint64_t Milliseconds(uint64_t now, uint64_t since) {
    return now > since ? (now - since) / NSEC_PER_MSEC : 0;
  }

  void Tick() {
    if (!running_.load()) {
      return;
    }
    const uint64_t now = NowNanos();
    const uint64_t late = last_tick_ != 0 && now - last_tick_ > kTickNanos
                              ? (now - last_tick_ - kTickNanos) / NSEC_PER_MSEC
                              : 0;
    last_tick_ = now;
    tick_count_ += 1;
    if (late >= 2000 && now - late_logged_ >= OWL_STALL_QUIET_NANOS) {
      // The watch's own timer ran late: the whole process was stopped, napped or starved.
      late_logged_ = now;
      Report(OWLHealthKindHostStall, 0, late,
             "kind=host-watch-late late_ms=" + std::to_string(late));
    }
    CheckSuppression();
    CheckMainThread(now, late);
    CheckChannel(now);
    if (!host_stalled_.load()) {
      CheckViews(now);
    }
  }

  /// Whether macOS is holding the process back (App Nap), which starves timers and frames.
  void CheckSuppression() {
    TaskSuppressionPolicy policy = {};
    mach_msg_type_number_t count = sizeof(policy) / sizeof(integer_t);
    boolean_t get_default = FALSE;
    const kern_return_t result =
        task_policy_get(mach_task_self(), kTaskSuppressionPolicy,
                        reinterpret_cast<task_policy_t>(&policy), &count, &get_default);
    if (result != KERN_SUCCESS) {
      if (!suppression_unreadable_) {
        suppression_unreadable_ = true;
        os_log_error(Log(), "freeze kind=host-suppression-unreadable error=%d", result);
      }
      return;
    }
    if (policy.active == suppressed_) {
      return;
    }
    suppressed_ = policy.active;
    char line[160];
    std::snprintf(line, sizeof(line),
                  "kind=host-suppressed active=%d timer_throttle=%d lowpri_cpu=%d suspend=%d",
                  policy.active, policy.timer_throttle, policy.lowpri_cpu, policy.suspend);
    Note(line);
  }

  void CheckMainThread(uint64_t now, uint64_t watch_late_milliseconds) {
    const bool queue_waiting = queue_ping_ != 0 && queue_pong_.load() < queue_ping_;
    const bool task_waiting = task_ping_ != 0 && task_pong_.load() < task_ping_;
    uint64_t since = queue_waiting ? queue_ping_ : 0;
    if (task_waiting && (since == 0 || task_ping_ < since)) {
      since = task_ping_;
    }
    const owl_stall_step step =
        owl_stall_advance(host_episode_, now, since, OWL_STALL_HOST_SECONDS, 0, false);
    host_episode_ = step.episode;
    host_stalled_.store(since != 0 && now - since >= NSEC_PER_SEC);
    if (step.action == OWLStallActionReport) {
      const uint64_t queue_late = queue_waiting ? Milliseconds(now, queue_ping_) : 0;
      const uint64_t task_late = task_waiting ? Milliseconds(now, task_ping_) : 0;
      char line[320];
      std::snprintf(line, sizeof(line),
                    "kind=host-stall stalled_ms=%llu line=%u main_queue_late_ms=%llu "
                    "cef_task_late_ms=%llu watch_late_ms=%llu recv_queue=%lld send_failures=%llu",
                    static_cast<unsigned long long>(Milliseconds(now, step.since_nanos)), step.line,
                    static_cast<unsigned long long>(queue_late),
                    static_cast<unsigned long long>(task_late),
                    static_cast<unsigned long long>(watch_late_milliseconds),
                    static_cast<long long>(owl_channel_receive_backlog(channel_)),
                    static_cast<unsigned long long>(send_failures_.load()));
      Report(OWLHealthKindHostStall, 0, Milliseconds(now, step.since_nanos), line);
      Report(OWLHealthKindHostStall, 0, Milliseconds(now, step.since_nanos),
             "kind=host-stall-stack main_thread=" + MainThreadStack());
    } else if (step.action == OWLStallActionEnded) {
      const uint64_t lasted = Milliseconds(now, step.since_nanos);
      Report(OWLHealthKindHostRecovered, 0, lasted,
             "kind=host-recovered stalled_ms=" + std::to_string(lasted));
    }
    if (!queue_waiting) {
      queue_ping_ = now;
      dispatch_async(dispatch_get_main_queue(), ^{
        queue_pong_.store(NowNanos());
      });
    }
    if (!task_waiting) {
      // Chromium's own task queue on the same thread: it can starve while the run loop turns.
      const bool posted = CefPostTask(TID_UI, base::BindOnce([]() {
                                        FreezeWatch::Get().task_pong_.store(NowNanos());
                                      }));
      task_ping_ = posted ? now : 0;
    }
  }

  void CheckChannel(uint64_t now) {
    const uint64_t failures = send_failures_.load();
    if (failures == failures_at_tick_) {
      backlog_since_.store(0);
    }
    const uint64_t added = failures - failures_at_tick_;
    failures_at_tick_ = failures;
    const owl_stall_step step =
        owl_stall_advance(channel_episode_, now, backlog_since_.load(), 0, 0, false);
    channel_episode_ = step.episode;
    if (step.action == OWLStallActionReport) {
      char line[240];
      std::snprintf(line, sizeof(line),
                    "kind=channel-backlog stalled_ms=%llu line=%u send_failures=%llu added=%llu "
                    "blocked_ms=%llu",
                    static_cast<unsigned long long>(Milliseconds(now, step.since_nanos)), step.line,
                    static_cast<unsigned long long>(failures),
                    static_cast<unsigned long long>(added),
                    static_cast<unsigned long long>(send_blocked_nanos_.load() / NSEC_PER_MSEC));
      Report(OWLHealthKindChannelBacklog, 0, Milliseconds(now, step.since_nanos), line);
    } else if (step.action == OWLStallActionEnded) {
      const uint64_t lasted = Milliseconds(now, step.since_nanos);
      Report(OWLHealthKindChannelDrained, 0, lasted,
             "kind=channel-drained stalled_ms=" + std::to_string(lasted) +
                 " send_failures=" + std::to_string(failures));
    }
  }

  void CheckViews(uint64_t now) {
    std::vector<std::shared_ptr<ViewHealth>> views;
    {
      std::lock_guard<std::mutex> lock(views_mutex_);
      std::erase_if(views_, [](const std::weak_ptr<ViewHealth>& view) { return view.expired(); });
      for (const auto& view : views_) {
        if (auto health = view.lock()) {
          views.push_back(std::move(health));
        }
      }
    }
    for (const auto& health : views) {
      CheckView(*health, now);
    }
  }

  void CheckView(ViewHealth& health, uint64_t now) {
    ViewHealth::Watched& watched = health.watched;
    const uint64_t frames = health.frames.load(std::memory_order_relaxed);
    watched.frames_last_second = frames - watched.frames_at_tick;
    watched.frames_at_tick = frames;
    owl_view_stall current = owl_view_stall_since(health.Activity());
    if (!health.has_browser.load(std::memory_order_relaxed)) {
      current.reason = OWLStallReasonNone;
      current.since_nanos = 0;
    }
    const bool following = watched.episode.since_nanos != 0;
    const OWLStallReason followed_reason = watched.reason;
    const uint64_t frames_since = frames - watched.frames_at_stall;
    const uint64_t since = owl_stall_followed_since(watched.episode.since_nanos,
                                                    following && frames_since != 0, current);
    if (!following || since != watched.episode.since_nanos) {
      watched.reason = current.reason;
      watched.frames_at_stall = frames;
    }
    const OWLStallReason reason = watched.reason;
    const owl_stall_step step = owl_stall_advance(
        watched.episode, now, since, owl_stall_first_seconds(reason),
        health.expectant_inputs.load(std::memory_order_relaxed), reason != OWLStallReasonLoading);
    watched.episode = step.episode;
    const uint64_t view_id = health.view_id;
    if (step.action == OWLStallActionReport) {
      const uint64_t stalled = Milliseconds(now, step.since_nanos);
      Report(OWLHealthKindViewStall, view_id, stalled,
             "kind=view-stall view=" + std::to_string(view_id) + " reason=" +
                 owl_stall_reason_name(reason) + " stalled_ms=" + std::to_string(stalled) +
                 " line=" + std::to_string(step.line) + " " +
                 health.Line(now, watched.frames_last_second) + " recv_queue=" +
                 std::to_string(owl_channel_receive_backlog(channel_)));
      ProbeFunction probe = probe_;
      dispatch_async(dispatch_get_main_queue(), ^{
        probe(view_id, false);
      });
    } else if (step.action == OWLStallActionEnded) {
      // It ended with the frame that came, or, without one, when nothing was owed any more.
      const uint64_t end =
          frames_since != 0 ? health.last_frame.load(std::memory_order_relaxed) : now;
      const uint64_t lasted = Milliseconds(end, step.since_nanos);
      Report(OWLHealthKindViewRecovered, view_id, lasted,
             "kind=view-recovered view=" + std::to_string(view_id) + " reason=" +
                 owl_stall_reason_name(followed_reason) + " stalled_ms=" +
                 std::to_string(lasted) + " frames_since=" + std::to_string(frames_since) +
                 " visible=" + std::to_string(health.visible.load(std::memory_order_relaxed)));
    }
    CheckLiveness(health, now);
    Heartbeat(health, now);
  }

  /// A page that keeps drawing while its script is stuck (it scrolls, a video plays, clicks do
  /// nothing) shows no stall above. While it is being used, the renderer is asked the constant
  /// every few seconds; only a missing answer is written.
  void CheckLiveness(ViewHealth& health, uint64_t now) {
    ViewHealth::Watched& watched = health.watched;
    const uint64_t inputs = health.expectant_inputs.load(std::memory_order_relaxed);
    if (watched.episode.since_nanos != 0 || inputs == watched.inputs_at_liveness ||
        now - watched.liveness_asked_nanos < kLivenessNanos ||
        !health.visible.load(std::memory_order_relaxed) ||
        !health.has_browser.load(std::memory_order_relaxed)) {
      return;
    }
    watched.inputs_at_liveness = inputs;
    watched.liveness_asked_nanos = now;
    const uint64_t view_id = health.view_id;
    ProbeFunction probe = probe_;
    dispatch_async(dispatch_get_main_queue(), ^{
      probe(view_id, true);
    });
  }

  /// One line a minute for a visible view that drew or took input, so a freeze nothing above
  /// caught still has the minutes before it on record.
  void Heartbeat(ViewHealth& health, uint64_t now) {
    if (tick_count_ % kHeartbeatTicks != 0 || !health.visible.load(std::memory_order_relaxed)) {
      return;
    }
    const uint64_t counters = health.frames.load(std::memory_order_relaxed) +
                              health.inputs.load(std::memory_order_relaxed) +
                              health.paints.load(std::memory_order_relaxed);
    if (counters == health.watched.counters_at_heartbeat) {
      return;
    }
    health.watched.counters_at_heartbeat = counters;
    Note("kind=view-health view=" + std::to_string(health.view_id) + " " +
         health.Line(now, health.watched.frames_last_second));
  }

  /// Where the main thread is, innermost frame first: suspends it for a few microseconds, reads
  /// its frame pointers, and names the frames after it runs again.
  std::string MainThreadStack() const {
    uintptr_t frames[kMaxFrames];
    const size_t count = CaptureFrames(main_thread_, frames, kMaxFrames);
    if (count == 0) {
      return "unreadable";
    }
    std::string stack;
    std::string previous;
    for (size_t index = 0; index < count && stack.size() < 760; ++index) {
      const std::string name = FrameName(frames[index]);
      // The link register of a function that has its own frame names it again, and the
      // standard library's plumbing between a callback and its body says nothing.
      if (name == previous || name.empty() || name.find("std::__1::") != std::string::npos) {
        continue;
      }
      stack += stack.empty() ? name : "<" + name;
      previous = name;
    }
    return stack;
  }

  static uintptr_t StripPointer(uintptr_t address) {
#if defined(__arm64__)
    // Return addresses saved by system code are signed; the signature sits above bit 47.
    return address & UINT64_C(0x00007FFFFFFFFFFF);
#else
    return address;
#endif
  }

  /// Nothing between suspend and resume may take a lock the suspended thread could hold, so
  /// this only makes kernel calls.
  static size_t CaptureFrames(thread_act_t thread, uintptr_t* frames, size_t capacity) {
    if (thread == MACH_PORT_NULL || capacity < 2 || thread_suspend(thread) != KERN_SUCCESS) {
      return 0;
    }
    size_t count = 0;
    uintptr_t frame_pointer = 0;
    uintptr_t link = 0;
#if defined(__arm64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state),
                         &state_count) == KERN_SUCCESS) {
      frames[count++] = StripPointer(arm_thread_state64_get_pc(state));
      frame_pointer = arm_thread_state64_get_fp(state);
      link = StripPointer(arm_thread_state64_get_lr(state));
    }
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t state_count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, reinterpret_cast<thread_state_t>(&state),
                         &state_count) == KERN_SUCCESS) {
      frames[count++] = state.__rip;
      frame_pointer = state.__rbp;
    }
#endif
    while (count > 0 && count < capacity && frame_pointer != 0) {
      uintptr_t record[2] = {0, 0};
      vm_size_t read = 0;
      if (vm_read_overwrite(mach_task_self(), frame_pointer, sizeof(record),
                            reinterpret_cast<vm_address_t>(record), &read) != KERN_SUCCESS ||
          read != sizeof(record)) {
        break;
      }
      const uintptr_t return_address = StripPointer(record[1]);
      if (count == 1 && link != 0 && link != return_address && count + 1 < capacity) {
        frames[count++] = link;  // A leaf (a system call stub) keeps its caller here only.
      }
      if (return_address == 0) {
        break;
      }
      frames[count++] = return_address;
      if (record[0] <= frame_pointer) {
        break;
      }
      frame_pointer = record[0];
    }
    thread_resume(thread);
    return count;
  }

  static std::string FrameName(uintptr_t address) {
    Dl_info info = {};
    if (dladdr(reinterpret_cast<const void*>(address), &info) == 0 || info.dli_fname == nullptr) {
      return "?";
    }
    const char* slash = std::strrchr(info.dli_fname, '/');
    const std::string image = slash != nullptr ? slash + 1 : info.dli_fname;
    const uintptr_t offset = address - reinterpret_cast<uintptr_t>(info.dli_fbase);
    char place[96];
    // Chromium exports few names, so the nearest one misleads; an offset can be symbolized.
    if (info.dli_sname == nullptr || image.rfind("Chromium Embedded Framework", 0) == 0) {
      std::snprintf(place, sizeof(place), "%.40s+0x%lx",
                    image.rfind("Chromium", 0) == 0 ? "CEF" : image.c_str(),
                    static_cast<unsigned long>(offset));
      return place;
    }
    std::string name = info.dli_sname;
    int status = -1;
    char* demangled = abi::__cxa_demangle(info.dli_sname, nullptr, nullptr, &status);
    if (status == 0 && demangled != nullptr) {
      name = demangled;
    }
    std::free(demangled);
    static constexpr char kAnonymous[] = "(anonymous namespace)::";
    for (size_t at = name.find(kAnonymous); at != std::string::npos; at = name.find(kAnonymous)) {
      name.erase(at, sizeof(kAnonymous) - 1);
    }
    const size_t parameters = name.find('(');
    if (parameters != std::string::npos && name[0] != '-' && name[0] != '+') {
      name.resize(parameters);
    }
    return name.substr(0, 64);
  }

  // Set by Start, on the main thread, before the timer runs.
  owl_channel* channel_ = nullptr;
  bool client_takes_reports_ = false;
  ProbeFunction probe_;
  thread_act_t main_thread_ = MACH_PORT_NULL;
  dispatch_queue_t queue_ = nullptr;
  dispatch_source_t timer_ = nullptr;
  std::atomic<bool> running_{false};

  // Written by other threads.
  std::mutex views_mutex_;
  std::vector<std::weak_ptr<ViewHealth>> views_;
  std::atomic<uint64_t> queue_pong_{0};
  std::atomic<uint64_t> task_pong_{0};
  std::atomic<uint64_t> send_failures_{0};
  std::atomic<uint64_t> send_blocked_nanos_{0};
  std::atomic<uint64_t> backlog_since_{0};
  std::atomic<bool> host_stalled_{false};

  // The watch's queue only.
  uint64_t last_tick_ = 0;
  uint64_t tick_count_ = 0;
  uint64_t late_logged_ = 0;
  uint64_t queue_ping_ = 0;
  uint64_t task_ping_ = 0;
  uint64_t failures_at_tick_ = 0;
  owl_stall_episode host_episode_ = {};
  owl_stall_episode channel_episode_ = {};
  integer_t suppressed_ = 0;
  bool suppression_unreadable_ = false;
};

}  // namespace owl
