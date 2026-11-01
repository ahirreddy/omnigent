import OmnigentCoreFFI

/// Lets a conversation's stores tell the session list what status an action leads to, before
/// the server's row says so (see ``SessionListStore/expect(_:for:)``).
struct ListStatusExpectation {
  /// An expectation that can be taken back when its action fails.
  struct Pending {
    let withdraw: @MainActor () -> Void
  }

  private let record: (@MainActor (SessionListStatus) -> Pending)?

  /// One that records nothing, for stores without a list.
  init() {
    record = nil
  }

  /// One that records on `list` for `sessionID`.
  /// - Parameters:
  ///   - list: The session list; held weakly.
  ///   - sessionID: The session.
  init(list: SessionListStore, sessionID: String) {
    record = { [weak list] status in
      guard let list, let token = list.expect(status, for: sessionID) else {
        return Pending {}
      }
      return Pending { [weak list] in list?.withdrawExpectation(token, for: sessionID) }
    }
  }

  /// Shows `status` for the session until its next server row.
  /// - Parameter status: The expected status.
  /// - Returns: The way to take it back.
  func expect(_ status: SessionListStatus) -> Pending {
    record?(status) ?? Pending {}
  }
}
