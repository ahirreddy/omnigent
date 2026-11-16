#if DEBUG
  public import Foundation
  import MetricKit
  import OSLog
  import QuartzCore

  #if os(iOS)
    import UIKit
  #elseif os(macOS)
    import AppKit
  #endif

  /// Debug builds launched with `-OmnigentFrameMonitor YES` log the main thread's frame pacing
  /// (``FrameStats``) once a second, and over an interval that `ai.omnigent.perf.begin` and
  /// `ai.omnigent.perf.end` Darwin notifications mark (`notifyutil -p`, or
  /// `xcrun simctl spawn <udid> notifyutil -p` for a simulator). Read the lines with
  /// `log stream --predicate 'subsystem == "ai.omnigent.perf"'`.
  ///
  /// A display link measures when the main thread delivered each frame, so it sees main-thread
  /// hitches, not the render server's; simulator numbers are not a device's. Each line also has
  /// the main run loop's pass times (``RunLoopPassStats``), which show the work a faster display
  /// would miss.
  @MainActor
  public final class FrameMonitor: NSObject {
    /// The launch argument (a `UserDefaults` key) that starts the monitor.
    public static let launchArgument = "OmnigentFrameMonitor"
    /// The log subsystem.
    nonisolated public static let subsystem = "ai.omnigent.perf"

    private static var shared: FrameMonitor?
    private static let logger = Logger(subsystem: subsystem, category: "frames")

    private(set) var link: CADisplayLink?
    private var previous: (timestamp: CFTimeInterval, expected: CFTimeInterval)?
    private(set) var second = FrameStats()
    private var secondPasses = RunLoopPassStats()
    private var secondCounts: [String: Int] = [:]
    private struct Interval {
      let name: String
      var stats = FrameStats()
      var passes = RunLoopPassStats()
      var counts: [String: Int] = [:]
      /// The main thread's CPU time when the interval began.
      let startCPU: TimeInterval

      init(name: String) {
        self.name = name
        startCPU = FrameMonitor.mainThreadCPU()
      }
    }

    private var interval: Interval?
    private var observers: [Int32] = []
    private var runLoopObservers: [CFRunLoopObserver] = []
    /// When the main run loop woke for the pass under way.
    private var passStart: CFTimeInterval?
    private var activation: (any NSObjectProtocol)?
    private let metrics = MetricKitLog()
    private let commands = PerfCommandFile()

    /// Starts the monitor when the launch argument asks for it.
    /// - Parameter defaults: Where launch arguments land; `standard` by default.
    public static func startIfRequested(defaults: UserDefaults = .standard) {
      guard shared == nil, defaults.bool(forKey: launchArgument) else { return }
      let monitor = FrameMonitor()
      shared = monitor
      monitor.start(with: monitor.makeDisplayLink())
      MXMetricManager.shared.add(monitor.metrics)
    }

    /// Counts one render of `name` (a view body), reported beside the frames.
    /// - Parameter name: What rendered.
    public static func count(_ name: String) {
      guard let shared else { return }
      shared.secondCounts[name, default: 0] += 1
      shared.interval?.counts[name, default: 0] += 1
    }

    /// Starts a named interval, replacing one already open.
    /// - Parameter name: The interval's name, logged with its stats.
    public static func begin(_ name: String) {
      shared?.interval = Interval(name: name)
      logger.notice("begin \(name, privacy: .public)")
    }

    /// Ends the open interval and logs its stats.
    public static func end() {
      guard let shared, let interval = shared.interval else { return }
      shared.interval = nil
      let cpu = Int(((mainThreadCPU() - interval.startCPU) * 1000).rounded())
      logger.notice(
        "interval \(interval.name, privacy: .public): \(interval.stats.summary, privacy: .public) cpu=\(cpu)ms \(interval.passes.summary, privacy: .public)\(Self.describe(interval.counts), privacy: .public)"
      )
    }

    /// The CPU time the calling (main) thread has used, in seconds.
    nonisolated private static func mainThreadCPU() -> TimeInterval {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
      let thread = mach_thread_self()
      defer { unsafe mach_port_deallocate(mach_task_self_, thread) }
      let status = withUnsafeMutablePointer(to: &info) { pointer in
        unsafe pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          unsafe thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
      }
      guard status == KERN_SUCCESS else { return 0 }
      func seconds(_ value: time_value_t) -> TimeInterval {
        TimeInterval(value.seconds) + TimeInterval(value.microseconds) / 1e6
      }
      return seconds(info.user_time) + seconds(info.system_time)
    }

    private func makeDisplayLink() -> CADisplayLink? {
      #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return link
      #elseif os(macOS)
        return NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
      #endif
    }

    /// Starts measuring on `link`; a Mac with no screen has none, so nothing starts.
    func start(with link: CADisplayLink?) {
      guard let link else {
        Self.logger.error("No screen to measure frames on")
        return
      }
      link.add(to: .main, forMode: .common)
      self.link = link
      observers = [
        DarwinNotifications.observe("ai.omnigent.perf.begin") { Self.begin("marked") },
        DarwinNotifications.observe("ai.omnigent.perf.end") { Self.end() },
      ]
      commands.start()
      observeRunLoopPasses()
      // Frames stop while the app is in the background; that pause is not a hang.
      #if os(iOS)
        let activated = UIApplication.didBecomeActiveNotification
      #elseif os(macOS)
        let activated = NSApplication.didBecomeActiveNotification
      #endif
      activation = NotificationCenter.default.addObserver(
        forName: activated, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.previous = nil }
      }
      Self.logger.notice("frame monitor started")
    }

    @objc func tick(_ link: CADisplayLink) {
      recordFrame(timestamp: link.timestamp, expected: link.targetTimestamp - link.timestamp)
    }

    /// Adds one delivered frame to the open second and interval, and logs a finished second.
    func recordFrame(timestamp: CFTimeInterval, expected: CFTimeInterval) {
      defer { previous = (timestamp, expected) }
      guard let previous else { return }
      let elapsed = timestamp - previous.timestamp
      second.record(interval: elapsed, expected: previous.expected)
      interval?.stats.record(interval: elapsed, expected: previous.expected)
      guard second.duration >= 1 else { return }
      Self.logger.notice(
        "second: \(self.second.summary, privacy: .public) \(self.secondPasses.summary, privacy: .public)\(Self.describe(self.secondCounts), privacy: .public)"
      )
      second = FrameStats()
      secondPasses = RunLoopPassStats()
      secondCounts = [:]
    }

    /// Times each pass of the main run loop: first after it wakes, last before it waits again,
    /// after Core Animation's commit.
    private func observeRunLoopPasses() {
      let woke = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.passStart = CACurrentMediaTime() }
      }
      let waits = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
      ) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.passEnded(at: CACurrentMediaTime()) }
      }
      for observer in [woke, waits] {
        guard let observer else { continue }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        runLoopObservers.append(observer)
      }
    }

    /// The main run loop is about to wait: the pass since it woke is done.
    func passEnded(at now: CFTimeInterval) {
      guard let start = passStart else { return }
      passStart = nil
      secondPasses.record(now - start)
      interval?.passes.record(now - start)
    }

    private static func describe(_ counts: [String: Int]) -> String {
      counts.isEmpty
        ? ""
        : " renders="
          + counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
          .joined(separator: ",")
    }
  }
#endif
