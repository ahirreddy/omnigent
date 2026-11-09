#if DEBUG
  import Foundation
  import MetricKit
  import OSLog

  /// Logs MetricKit's payloads (hitch-time ratios, launch and resume times, hangs) under
  /// ``FrameMonitor/subsystem`` while the frame monitor runs. The system delivers them about once
  /// a day on a device, and on demand from Xcode's Debug > Simulate MetricKit Payloads; the
  /// simulator never sends them on its own.
  final class MetricKitLog: NSObject, MXMetricManagerSubscriber {
    private static let logger = Logger(subsystem: FrameMonitor.subsystem, category: "metrickit")

    func didReceive(_ payloads: [MXMetricPayload]) {
      for payload in payloads { Self.log("metrics", payload.jsonRepresentation()) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
      for payload in payloads { Self.log("diagnostics", payload.jsonRepresentation()) }
    }

    private static func log(_ kind: String, _ json: Data) {
      guard let line = logLine(kind, json) else {
        logger.error("\(kind, privacy: .public): a payload that is not UTF-8 JSON")
        return
      }
      logger.notice("\(line, privacy: .public)")
    }

    /// What one payload logs, or `nil` when its JSON isn't UTF-8.
    static func logLine(_ kind: String, _ json: Data) -> String? {
      String(bytes: json, encoding: .utf8).map { "\(kind) \($0)" }
    }
  }
#endif
