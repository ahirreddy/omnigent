public import Observation
public import OmnigentCoreFFI

/// The opening sentences of each board card's last reply (the core's `boardReplyPreview`), read
/// once per finished turn: a session that is working keeps showing its previous reply.
@Observable
public final class ProjectBoardPreviews {
  /// Each session's preview; `nil` when its newest items hold no reply.
  public private(set) var previews: [String: String] = [:]
  /// Why a session's last read failed, until it reads again. The card keeps the reply it had,
  /// as the web's does.
  public private(set) var errors: [String: CoreError] = [:]
  /// The `updatedAt` each session's preview was read for.
  @ObservationIgnored private var stamps: [String: Int64] = [:]
  @ObservationIgnored private let core: ClientCore?

  /// Creates the store.
  /// - Parameter core: The core the replies are read through.
  public init(core: ClientCore?) {
    self.core = core
  }

  /// Reads `sessionID`'s preview unless it is working or was read for this `updatedAt` already.
  /// - Parameters:
  ///   - sessionID: The card's head.
  ///   - updatedAt: Its last activity, Unix seconds.
  ///   - isWorking: A turn is in progress.
  public func load(_ sessionID: String, updatedAt: Int64, isWorking: Bool) async {
    guard !isWorking, stamps[sessionID] != updatedAt, let core else { return }
    stamps[sessionID] = updatedAt
    do {
      let preview = try await core.boardReplyPreview(sessionId: sessionID)
      if previews[sessionID] != preview { previews[sessionID] = preview }
      if errors[sessionID] != nil { errors[sessionID] = nil }
    } catch {
      errors[sessionID] = coreError(error)
      // Read again on the next look.
      stamps[sessionID] = nil
    }
  }
}
