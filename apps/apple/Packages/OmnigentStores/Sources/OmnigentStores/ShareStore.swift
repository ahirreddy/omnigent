import Foundation
public import Observation
public import OmnigentCoreFFI

/// One session's sharing: its grants, and granting, changing and revoking access through the
/// core. Writes are never retried; a failure is kept for the sheet to show.
@Observable
public final class ShareStore {
  /// The session.
  public let sessionID: String
  /// The grants, the owner's included.
  public private(set) var grants: CreationLoad<[SessionGrant]> = .idle
  /// A change is in flight.
  public private(set) var isSaving = false
  /// The last change's failure.
  public private(set) var error: CoreError?

  private let core: ClientCore

  init(core: ClientCore, sessionID: String) {
    self.core = core
    self.sessionID = sessionID
  }

  /// Anyone with the link can read.
  public var isPublic: Bool {
    grants.value?.contains { $0.userId == publicGrantee() } ?? false
  }

  /// Reads the grants.
  public func load() async {
    grants = .loading
    do {
      grants = .loaded(try await core.sessionGrants(sessionId: sessionID))
    } catch {
      grants = .failed(coreError(error))
    }
  }

  /// Grants `userID` `level` (1 read, 2 edit, 3 manage), or changes it, then reloads.
  /// - Parameters:
  ///   - userID: The person.
  ///   - level: The level.
  public func grant(_ userID: String, level: UInt8) async {
    await change {
      _ = try await $0.grantSessionAccess(sessionId: sessionID, userId: userID, level: level)
    }
  }

  /// Removes `userID`'s access, then reloads.
  /// - Parameter userID: The person.
  public func revoke(_ userID: String) async {
    await change { try await $0.revokeSessionAccess(sessionId: sessionID, userId: userID) }
  }

  /// Lets anyone with the link read the session, or stops it.
  /// - Parameter isPublic: Whether the link opens it.
  public func setPublic(_ isPublic: Bool) async {
    if isPublic {
      await grant(publicGrantee(), level: 1)
    } else {
      await revoke(publicGrantee())
    }
  }

  private func change(_ write: (ClientCore) async throws -> Void) async {
    isSaving = true
    error = nil
    do {
      try await write(core)
    } catch {
      self.error = coreError(error)
    }
    isSaving = false
    await load()
  }
}
