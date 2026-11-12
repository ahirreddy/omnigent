internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// One step of the soak: a page to load, a stretch of input, or a stretch without input while
/// the window or its web view is left alone, taken away, changed, or joined by other pages.
struct SoakStep: Equatable {
  enum Kind: String {
    case page, active, idle, cover, minimize, hide, detach, flap, resize, history
    /// A second page that draws in no window, as an agent's does, next to the one on screen.
    case offscreen
    /// Input on the page on screen while six more pages draw in no window.
    case crowd
  }

  let kind: Kind
  /// How long the step lasts; loading a page takes about two seconds.
  let seconds: Double
  /// The page to load, for `page`.
  var page = ""

  static func page(_ name: String) -> Self { Self(kind: .page, seconds: 2, page: name) }

  static func timed(_ kind: Kind, _ seconds: Double) -> Self {
    Self(kind: kind, seconds: seconds)
  }

  /// `page:<name>`, or `<kind>:<seconds>`.
  static func parse(_ text: Substring) -> Self? {
    let parts = text.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
    if kind == .page { return page(String(parts[1])) }
    guard let seconds = Double(parts[1]), seconds > 0 else { return nil }
    return timed(kind, seconds)
  }

  var text: String {
    kind == .page ? "page:\(page)" : "\(kind.rawValue):\(Int(seconds))"
  }

  /// Rounds of load, input, a stretch without input and input again, over every page and kind
  /// of stretch, for about `minutes`. A soak of twelve minutes or more idles once for five.
  static func plan(minutes: Double) -> [Self] {
    let stretches: [Self] = [
      .timed(.idle, 10), .timed(.cover, 8), .timed(.minimize, 8), .timed(.hide, 8),
      .timed(.idle, 60), .timed(.detach, 8), .timed(.offscreen, 10), .timed(.flap, 6),
      .timed(.resize, 6), .timed(.history, 3), .timed(.idle, 30), .timed(.crowd, 8),
    ]
    var steps: [Self] = []
    var budget = minutes * 60
    var round = 0
    while budget > 0 {
      let page = SoakPage.all[round % SoakPage.all.count]
      let stretch =
        round == 2 && minutes >= 12 ? .timed(.idle, 300) : stretches[round % stretches.count]
      let added: [Self] = [.page(page.name), .timed(.active, 10), stretch, .timed(.active, 6)]
      steps += added
      budget -= added.reduce(0) { $0 + $1.seconds }
      round += 1
    }
    return steps
  }
}

/// The soak proof: realistic pages under scripted input for minutes, across idle gaps,
/// occlusion and foreground changes. It fails when a page stops drawing or answering.
///
/// `--soak-minutes <n>` (default 3) sets the length of the default plan, `--soak-plan
/// page:timers,active:10,idle:60,...` replaces it, `--soak-gap-ms <n>` (default 1000) is how
/// late a frame may be.
extension Proofs {
  func soak() async throws {
    let options = model.options
    let plan: [SoakStep]
    if let text = options.soakPlan {
      plan = try text.split(separator: ",").map { part in
        guard let step = SoakStep.parse(part) else {
          throw ProofFailure("Bad soak step '\(part)'.")
        }
        return step
      }
    } else {
      plan = SoakStep.plan(minutes: options.soakMinutes)
    }
    guard let window else { throw ProofFailure("No window to soak in.") }
    try await model.session.waitUntilReady()
    try await waitUntil("view live", timeout: 30) { self.webView.status == .live }
    let monitor = SoakMonitor(
      webView: webView, session: model.session, gapLimit: options.soakGapMilliseconds)
    let run = SoakRun(proofs: self, monitor: monitor, window: window)
    Clock.log("soak plan (\(plan.count) steps): \(plan.map(\.text).joined(separator: ","))")
    monitor.start()
    for (index, step) in plan.enumerated() {
      await run.perform(step, index: index)
    }
    monitor.stop()
    try await soakReport(monitor)
  }

  /// Prints the summary and fails the proof when anything stood still.
  private func soakReport(_ monitor: SoakMonitor) async throws {
    // The unified log takes a moment to show the host's last lines.
    try await settle(1.5)
    let seconds = Date().timeIntervalSince(monitor.started)
    let host = try await SoakHostLog.lines(since: monitor.started, pids: monitor.hostPIDs)
    let hostFailing = host.filter { line in
      SoakMonitor.failingMarks.contains(where: line.contains)
    }
    let health = host.filter { $0.contains("kind=view-health") }
    let rates = health.compactMap { SoakHostLog.largest(" fps=", in: [$0]) }
    let latencies = monitor.inputLatencies
    let summary = [
      "seconds=\(Int(seconds))", "frames=\(monitor.frames)",
      "drops=app:\(monitor.drops),host:\(SoakHostLog.largest(" dropped=", in: host) ?? 0)",
      "longest_owed_gap_ms=\(Int(monitor.longestGap))",
      "inputs=\(latencies.count)",
      "input_to_frame_ms=p50:\(percentile(latencies, 0.5)),"
        + "p95:\(percentile(latencies, 0.95)),max:\(Int(latencies.max() ?? 0))",
      "shown_to_frame_ms=n:\(monitor.resumeLatencies.count),"
        + "max:\(Int(monitor.resumeLatencies.max() ?? 0))",
      "stale_frames=late:\(monitor.lateFrames),latest_ms:\(Int(monitor.latestFrame))",
      "host_fps=lines:\(rates.count),min:\(rates.min() ?? 0),max:\(rates.max() ?? 0)",
      "ring=slots:\(SoakHostLog.largest(" ring_slots=", in: host) ?? 0),"
        + "busy_peak:\(SoakHostLog.largest(" ring_busy_peak=", in: host) ?? 0)",
      "naps=\(host.filter { $0.contains("kind=host-suppressed active=1") }.count)",
      "freeze_lines=app:\(monitor.freezeLines.count),host_log:\(host.count),"
        + "host_failing:\(hostFailing.count)",
      "sampler_delay_max_ms=\(Int(monitor.longestSamplerDelay))",
      "failures=\(monitor.failures.count)",
    ].joined(separator: " ")
    Clock.log("soak summary: \(summary)")
    for line in monitor.freezeLines { Clock.log("soak app line: \(line)") }
    for line in host where !line.contains("kind=view-health") {
      Clock.log("soak host line: \(line)")
    }
    if let last = health.last { Clock.log("soak host line: \(last)") }
    let report = (["soak summary: \(summary)"] + monitor.failures).joined(separator: "\n") + "\n"
    try report.write(
      to: outputDirectory.appending(path: "soak-summary.txt"), atomically: true, encoding: .utf8)
    guard monitor.failures.isEmpty, hostFailing.isEmpty else {
      let first = monitor.failures.first ?? hostFailing.first ?? ""
      throw ProofFailure(
        "\(monitor.failures.count) failure(s), \(hostFailing.count) host line(s); first: \(first)")
    }
  }
}
