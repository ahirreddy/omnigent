import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The composer's list of a session's Browser design tool requests, from the window's outbox.
enum DesignRequestAdapter {
  /// The session's requests not yet sent; none without an outbox.
  static func rows(_ outbox: DesignRequestOutbox?, in sessionID: String) -> [DesignRequestRow] {
    guard let outbox else { return [] }
    return outbox.requests(in: sessionID).map { request in
      DesignRequestRow(
        id: request.id, tool: request.tool == .annotate ? .annotate : .draw,
        label: request.label, state: state(request.status, isSlow: request.isSlow))
    }
  }

  /// Retry and Remove on the outbox; none without one.
  static func actions(_ outbox: DesignRequestOutbox?) -> DesignRequestActions? {
    guard let outbox else { return nil }
    return DesignRequestActions(retry: { outbox.retry($0) }, remove: { outbox.remove($0) })
  }

  static func state(_ status: DesignOutboxRequest.Status, isSlow: Bool = false)
    -> DesignRequestRow.State
  {
    switch status {
    case .waiting: .waiting
    case .sending: isSlow ? .slow : .sending
    case .failed(let message, let canRetry): .failed(message, canRetry: canRetry)
    }
  }
}

/// Brings back the window's unsent design requests from before the app last closed, once its
/// account is known, and again for each account signed in later.
struct DesignOutboxRestoring: ViewModifier {
  let session: ServerSession

  func body(content: Content) -> some View {
    content.onChange(of: session.connection.connectedServer?.accountId, initial: true) {
      session.designOutbox.restoreSaved()
    }
  }
}
