internal import Foundation
internal import OmnigentWebLayer

/// What the soak proof measures while it runs: frames as the app sees them arrive, the gaps
/// between them while the page owes frames, how long each input waits for one, and the freeze
/// lines written meanwhile.
final class SoakMonitor {
  /// Freeze lines that mean a page stood still. `client-` lines are the app's own.
  static let failingMarks = [
    "kind=view-stall", "kind=client-stall", "kind=host-stall ", "kind=host-watch-late",
    "renderer=hung", "frames=stopped", "kind=channel-backlog", "kind=client-timer-late",
    "kind=client-frames-unseen", "kind=renderer-gone", "kind=client-input-late",
  ]

  private let webView: WebView
  private let session: Session
  /// Milliseconds a frame may be late, after input or past the page's own interval.
  let gapLimit: Double
  /// The step in progress, named in every failure.
  var step = "start"

  private(set) var failures: [String] = []
  private(set) var freezeLines: [String] = []
  private(set) var inputLatencies: [Double] = []
  private(set) var resumeLatencies: [Double] = []
  private(set) var longestGap = 0.0
  private(set) var longestSamplerDelay = 0.0
  /// Times the frame on screen was behind the page when looked at, and by how much at most.
  private(set) var lateFrames = 0
  private(set) var latestFrame = 0.0
  private(set) var hostPIDs: Set<Int32> = []
  let started = Date()

  private var lastFrames = 0
  private var lastFrameAt = ContinuousClock.now
  private var lastSampleAt = ContinuousClock.now
  /// Seconds between the frames the page owes with nobody touching it; nil when it owes none.
  private var owedInterval: Double?
  private var gapReported = false
  private var lineMark: String?
  private var sampler: Task<Void, Never>?

  init(webView: WebView, session: Session, gapLimit: Double) {
    self.webView = webView
    self.session = session
    self.gapLimit = gapLimit
  }

  var frames: Int { webView.statistics.framesPresented }
  var drops: UInt64 { webView.statistics.framesDropped }

  func start() {
    lineMark = session.freezeLines.last
    lastFrames = frames
    sampler = Task { [weak self] in
      var ticks = 0
      while !Task.isCancelled, let self {
        self.sample()
        if ticks.isMultiple(of: 50) { self.collectLines() }
        ticks += 1
        do {
          try await Task.sleep(for: .milliseconds(4))
        } catch {
          return  // Cancelled: the soak is over.
        }
      }
    }
  }

  func stop() {
    sampler?.cancel()
    sampler = nil
    collectLines()
  }

  func fail(_ what: String) {
    let failure = "[\(step)] \(what)"
    failures.append(failure)
    Clock.log("soak FAILURE \(failure)")
  }

  func noteLateFrame(milliseconds: Double) {
    lateFrames += 1
    latestFrame = max(latestFrame, milliseconds)
    Clock.log("soak note [\(step)]: the frame on screen was up to \(Int(milliseconds)) ms behind")
  }

  /// Says whether the page owes frames by itself from now on, and how often.
  func expectFrames(every interval: Double?) {
    owedInterval = interval
    lastFrameAt = .now
    gapReported = false
  }

  /// Sends one input and waits for the frame that answers it.
  func input(_ what: String, _ send: () throws -> Void) async throws {
    let before = frames
    let sent = ContinuousClock.now
    try send()
    while frames == before {
      let waited = Self.milliseconds(.now - sent)
      if waited > 15_000 {
        inputLatencies.append(waited)
        fail("no frame \(Int(waited)) ms after \(what); gave up waiting")
        return
      }
      try await Task.sleep(for: .milliseconds(2))
    }
    let latency = Self.milliseconds(.now - sent)
    inputLatencies.append(latency)
    if latency > gapLimit { fail("\(what) waited \(Int(latency)) ms for a frame") }
  }

  /// The view is on screen again: a page that draws by itself owes a frame now.
  func noteShown(every interval: Double?) async throws {
    let before = frames
    let shown = ContinuousClock.now
    expectFrames(every: interval)
    guard let interval else { return }
    let limit = interval * 1000 + gapLimit
    while frames == before, Self.milliseconds(.now - shown) < 15_000 {
      try await Task.sleep(for: .milliseconds(2))
    }
    let latency = Self.milliseconds(.now - shown)
    resumeLatencies.append(latency)
    if latency > limit { fail("frames resumed \(Int(latency)) ms after the view was shown") }
  }

  private func sample() {
    let now = ContinuousClock.now
    longestSamplerDelay = max(longestSamplerDelay, Self.milliseconds(now - lastSampleAt))
    lastSampleAt = now
    if let pid = session.hostInfo?.pid { hostPIDs.insert(pid) }
    let frames = frames
    if frames != lastFrames {
      if gapReported {
        Clock.log("soak frames resumed after \(Int(Self.milliseconds(now - lastFrameAt))) ms")
      }
      lastFrames = frames
      lastFrameAt = now
      gapReported = false
      return
    }
    guard let owedInterval else { return }
    let gap = Self.milliseconds(now - lastFrameAt)
    longestGap = max(longestGap, gap)
    if gap > owedInterval * 1000 + gapLimit, !gapReported {
      gapReported = true
      fail("no frame for \(Int(gap)) ms from a page that draws every \(owedInterval) s")
    }
  }

  /// Takes the lines the session wrote since the last look.
  private func collectLines() {
    let lines = session.freezeLines
    let start = lineMark.flatMap { lines.lastIndex(of: $0) }.map { $0 + 1 } ?? 0
    for line in lines[start...] {
      freezeLines.append(line)
      if Self.failingMarks.contains(where: line.contains) { fail("freeze line: \(line)") }
    }
    lineMark = lines.last ?? lineMark
  }

  static func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
  }
}

/// The host's freeze lines from the unified log: the ones it only writes there (a nap, the
/// once-a-minute health line) and the ones that could not be sent while the channel was full.
enum SoakHostLog {
  /// The `freeze` lines the hosts with `pids` wrote since `start`, oldest first.
  static func lines(since start: Date, pids: Set<Int32>) async throws -> [String] {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "show", "--start", format.string(from: start.addingTimeInterval(-1)), "--style", "compact",
      "--predicate", "subsystem == \"ai.omnigent.weblayer.host\"",
    ]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = try await Task.detached {
      try output.fileHandleForReading.readToEnd() ?? Data()
    }.value
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ProofFailure("log show ended with status \(process.terminationStatus).")
    }
    let text = String(bytes: data, encoding: .utf8) ?? ""
    return text.split(separator: "\n").compactMap { line in
      guard pids.contains(where: { line.contains("Omnigent Web Host[\($0):") }),
        let range = line.range(of: " freeze ")
      else { return nil }
      return String(line[range.upperBound...])
    }
  }

  /// The largest value of `key=<number>` (or `key:<number>`) in `lines`, if any carries it.
  static func largest(_ key: String, in lines: [String]) -> Int? {
    lines.compactMap { line -> Int? in
      guard let range = line.range(of: key) else { return nil }
      return Int(line[range.upperBound...].prefix { $0.isNumber })
    }.max()
  }
}
