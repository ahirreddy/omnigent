#if DEBUG && os(macOS)
  import AppKit
  import Foundation
  import MetricKit
  import Testing

  @testable import OmnigentPlatform

  /// A payload the test scripts, since the system is the only source of real ones.
  private final class ScriptedMetricPayload: MXMetricPayload {
    var reads = 0
    let json: Data

    init(json: Data) {
      self.json = json
      super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func jsonRepresentation() -> Data {
      reads += 1
      return json
    }
  }

  /// A diagnostic payload the test scripts, for the same reason.
  private final class ScriptedDiagnosticPayload: MXDiagnosticPayload {
    var reads = 0

    override func jsonRepresentation() -> Data {
      reads += 1
      return Data([0xFF])
    }
  }

  @MainActor
  @Suite("Frame monitor seams")
  struct FrameMonitorSeamTests {
    @Test("A Mac with no screen starts nothing, and no link is held")
    func noScreen() {
      let monitor = FrameMonitor()
      monitor.start(with: nil)
      #expect(monitor.link == nil)
    }

    @Test("A display link's tick reads its frame times, whether or not a screen is awake")
    func displayLinkTick() {
      let monitor = FrameMonitor()
      let link = NSView().displayLink(target: monitor, selector: #selector(FrameMonitor.tick(_:)))
      monitor.tick(link)
      monitor.tick(link)
      #expect(monitor.second.frames == 0)
      link.invalidate()
    }

    @Test("The first frame only sets the baseline, later ones count, and a full second resets")
    func framesRollOverAfterASecond() {
      let monitor = FrameMonitor()
      let frame = 1.0 / 60
      monitor.recordFrame(timestamp: 100, expected: frame)
      #expect(monitor.second.duration == 0)
      monitor.recordFrame(timestamp: 100 + frame, expected: frame)
      #expect(monitor.second.duration > 0)
      monitor.recordFrame(timestamp: 100 + frame + 0.5, expected: frame)
      #expect(monitor.second.duration > 0.5)
      monitor.recordFrame(timestamp: 100 + frame + 1.5, expected: frame)
      #expect(monitor.second.duration == 0)
    }

    @Test("A UTF-8 payload logs its kind and JSON; any other bytes log no line")
    func metricKitLines() {
      #expect(MetricKitLog.logLine("metrics", Data("{\"a\":1}".utf8)) == "metrics {\"a\":1}")
      #expect(MetricKitLog.logLine("metrics", Data()) == "metrics ")
      #expect(MetricKitLog.logLine("diagnostics", Data([0xFF, 0xFE])) == nil)
    }

    @Test("Every delivered payload has its JSON read, valid or not")
    func metricKitPayloads() {
      let log = MetricKitLog()
      let metrics = [
        ScriptedMetricPayload(json: Data("{}".utf8)), ScriptedMetricPayload(json: Data([0xFF])),
      ]
      let diagnostics = [ScriptedDiagnosticPayload()]
      log.didReceive(metrics as [MXMetricPayload])
      log.didReceive(diagnostics as [MXDiagnosticPayload])
      #expect(metrics.map(\.reads) == [1, 1])
      #expect(diagnostics[0].reads == 1)
    }

    @Test("A command file's date reads back, and a missing file has none")
    func commandFileDate() throws {
      let file = FileManager.default.temporaryDirectory
        .appending(path: "FrameMonitorSeamTests-\(UUID().uuidString)")
      #expect(PerfCommandFile.modified(file) == nil)
      try Data("1 begin\n".utf8).write(to: file)
      defer {
        #expect(throws: Never.self) { try FileManager.default.removeItem(at: file) }
      }
      let date = try #require(PerfCommandFile.modified(file))
      #expect(abs(date.timeIntervalSinceNow) < 60)
    }
  }
#endif
