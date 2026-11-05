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
  /// hitches, not the render server's; simulator numbers are not a device's.
  @MainActor
  public final class FrameMonitor: NSObject {
    /// The launch argument (a `UserDefaults` key) that starts the monitor.
    public static let launchArgument = "OmnigentFrameMonitor"
    /// The log subsystem.
    nonisolated public static let subsystem = "ai.omnigent.perf"

    private static var shared: FrameMonitor?
    private static let logger = Logger(subsystem: subsystem, category: "frames")

    private var link: CADisplayLink?
    private var previous: (timestamp: CFTimeInterval, expected: CFTimeInterval)?
    private var second = FrameStats()
    private var secondCounts: [String: Int] = [:]
    private struct Interval {
      let name: String
      var stats = FrameStats()
      var counts: [String: Int] = [:]
      /// The main thread's CPU time when the interval began.
      let startCPU = FrameMonitor.mainThreadCPU()
    }

    private var interval: Interval?
    private var observers: [Int32] = []
    private var activation: (any NSObjectProtocol)?
    private let metrics = MetricKitLog()
    private let commands = PerfCommandFile()

    /// Starts the monitor when the launch argument asks for it.
    /// - Parameter defaults: Where launch arguments land; `standard` by default.
    public static func startIfRequested(defaults: UserDefaults = .standard) {
      guard shared == nil, defaults.bool(forKey: launchArgument) else { return }
      let monitor = FrameMonitor()
      shared = monitor
      monitor.start()
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
        "interval \(interval.name, privacy: .public): \(interval.stats.summary, privacy: .public) cpu=\(cpu)ms\(Self.describe(interval.counts), privacy: .public)"
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

    private func start() {
      #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      #elseif os(macOS)
        guard let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        else {
          Self.logger.error("No screen to measure frames on")
          return
        }
      #endif
      link.add(to: .main, forMode: .common)
      self.link = link
      observers = [
        DarwinNotifications.observe("ai.omnigent.perf.begin") { Self.begin("marked") },
        DarwinNotifications.observe("ai.omnigent.perf.end") { Self.end() },
      ]
      commands.start()
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

    @objc private func tick(_ link: CADisplayLink) {
      let expected = link.targetTimestamp - link.timestamp
      defer { previous = (link.timestamp, expected) }
      guard let previous else { return }
      let elapsed = link.timestamp - previous.timestamp
      second.record(interval: elapsed, expected: previous.expected)
      interval?.stats.record(interval: elapsed, expected: previous.expected)
      guard second.duration >= 1 else { return }
      Self.logger.notice(
        "second: \(self.second.summary, privacy: .public)\(Self.describe(self.secondCounts), privacy: .public)"
      )
      second = FrameStats()
      secondCounts = [:]
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
