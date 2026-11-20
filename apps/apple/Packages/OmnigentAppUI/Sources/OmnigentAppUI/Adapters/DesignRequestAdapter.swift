import Foundation
import OmnigentStores
import OmnigentUIComponents

/// The composer's list of a session's Browser design tool requests, from the window's outbox.
enum DesignRequestAdapter {
  /// The session's requests not yet sent; none without an outbox.
  static func rows(_ outbox: DesignRequestOutbox?, in sessionID: String) -> [DesignRequestRow] {
    guard let outbox else { return [] }
    return outbox.requests(in: sessionID).map { request in
      DesignRequestRow(
        id: request.id, tool: request.tool == .annotate ? .annotate : .draw,
        label: request.label, state: state(request.status))
    }
  }

  /// Retry and Remove on the outbox; none without one.
  static func actions(_ outbox: DesignRequestOutbox?) -> DesignRequestActions? {
    guard let outbox else { return nil }
    return DesignRequestActions(retry: { outbox.retry($0) }, remove: { outbox.remove($0) })
  }

  static func state(_ status: DesignOutboxRequest.Status) -> DesignRequestRow.State {
    switch status {
    case .waiting: .waiting
    case .sending: .sending
    case .failed(let message, let canRetry): .failed(message, canRetry: canRetry)
    }
  }
}
