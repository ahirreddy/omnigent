internal import Darwin
internal import Foundation
internal import OWLProtocol
internal import os

/// What the session keeps for freeze diagnostics between ticks.
nonisolated struct SessionFreezeState: Sendable {
  var lastTickNanos: UInt64 = 0
  /// The host's CPU time at the previous tick, while a view waited for a frame.
  var hostCPU: (cpuNanos: UInt64, atNanos: UInt64)?
  /// The share of one core the host used over the last tick, in percent; nil when not sampled.
  var hostCPUPercent: Int?
  /// The last report about the host itself (its main thread, the channel).
  var lastHostReport: HostHealthReport?
  /// Messages the channel refused to take from this side.
  var sendFailures: UInt64 = 0
}

/// The client half of the freeze diagnostics: a coarse timer that notices input going
/// unanswered, and the place every freeze line is written. See DESIGN.md, "Freeze diagnostics".
extension Session {
  /// How many diagnostic lines `freezeLines` keeps.
  static let freezeLineLimit = 128
  /// A tick this late means the app was not running its timers, so frames may sit unread.
  private static let lateTickNanos: UInt64 = 2_500_000_000

  /// Writes a freeze diagnostic to the unified log and keeps it in `freezeLines`.
  func logFreeze(_ line: String) {
    Logger.freeze.notice("freeze \(line, privacy: .public)")
    freezeLines.append(line)
    if freezeLines.count > Self.freezeLineLimit {
      freezeLines.removeFirst(freezeLines.count - Self.freezeLineLimit)
    }
  }

  /// Runs about once a second while the host is up. Costs a few comparisons per view unless a
  /// view has input waiting for a frame.
  func freezeTick() {
    let now = uptimeNanos()
    let previous = freeze.lastTickNanos
    freeze.lastTickNanos = now
    let waiting = views.values.contains { $0.freeze.isWaiting }
    sampleHostCPU(now: now, wanted: waiting)
    if previous != 0, now - previous > Self.lateTickNanos {
      if waiting {
        logFreeze(
          "kind=client-timer-late late_ms=\((now - previous) / 1_000_000) "
            + freezeStateText(now: now))
      }
      return  // Let the frames that queued up meanwhile be read before judging anything.
    }
    for view in views.values.sorted(by: { $0.id < $1.id }) {
      view.freezeTick(now: now)
    }
  }

  /// A report from the host's freeze watch: about `view`, or about the host itself.
  func noteHostReport(_ fields: WireDecoder, view: WebView?) {
    guard let text = fields.string(.text), !text.isEmpty else {
      Logger.freeze.error("A host health report carried no text.")
      lastProtocolError = .channelFailed("A host health report carried no text.")
      return
    }
    let report = HostHealthReport(
      kind: fields.u64(.healthKind) ?? 0, milliseconds: fields.u64(.elapsedMilliseconds) ?? 0,
      receivedNanos: uptimeNanos())
    if let view {
      view.lastHostReport = report
    } else {
      freeze.lastHostReport = report
    }
    logFreeze("from=host \(text.prefix(1000))")
  }

  /// The host and the channel as the app sees them, as `key=value` pairs.
  func freezeStateText(now: UInt64) -> String {
    let ping = outstandingPing.map { (ContinuousClock.now - $0.sent).milliseconds } ?? 0
    let report = freeze.lastHostReport.map {
      "\($0.kindName),age_ms:\(WebView.ageMilliseconds(now, $0.receivedNanos))"
    }
    let cpu = freeze.hostCPUPercent.map(String.init) ?? "unknown"
    return [
      "host=pid:\(process?.pid ?? 0),running:\(process?.isRunning == true ? 1 : 0),cpu_pct:\(cpu)",
      "ping_ms=\(ping)", "recv_queue=\(channel?.receiveBacklog ?? -1)",
      "send_failures=\(freeze.sendFailures)", "host_report=\(report ?? "none")",
    ].joined(separator: " ")
  }

  /// Samples the host's CPU time while a view waits, so a stall line can say whether the host
  /// was spinning or idle.
  private func sampleHostCPU(now: UInt64, wanted: Bool) {
    guard wanted, let process, let cpu = hostCPUNanos(process.pid) else {
      freeze.hostCPU = nil
      freeze.hostCPUPercent = nil
      return
    }
    if let last = freeze.hostCPU, now > last.atNanos, cpu >= last.cpuNanos {
      freeze.hostCPUPercent = Int((cpu - last.cpuNanos) * 100 / (now - last.atNanos))
    }
    freeze.hostCPU = (cpu, now)
  }

  /// User plus system CPU time `pid` has used, in nanoseconds; nil when the kernel will not say.
  nonisolated static func processCPUNanos(_ pid: pid_t) -> UInt64? {
    var info = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      unsafe pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        unsafe proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
      }
    }
    var timebase = mach_timebase_info_data_t()
    guard result == 0, unsafe mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0
    else { return nil }
    return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer)
      / UInt64(timebase.denom)
  }
}

extension Duration {
  /// Whole milliseconds, for log lines.
  fileprivate var milliseconds: Int64 {
    components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
  }
}
