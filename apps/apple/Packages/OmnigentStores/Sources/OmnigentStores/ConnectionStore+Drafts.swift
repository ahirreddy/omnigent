public import Foundation
import OmnigentCoreFFI

/// Device preferences the core applies to its requests, under the web's local-storage keys.
public enum SessionPreferences {
  /// "Automatically name new sessions" (on by default): the server titles a new session in the
  /// background after its first message.
  public static let backgroundTitlesKey = "omnigent:background-session-titles"

  /// The stored value of ``backgroundTitlesKey``.
  /// - Parameter defaults: Where the Settings window writes it.
  /// - Returns: Whether automatic titles are on.
  public static func backgroundTitles(in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: backgroundTitlesKey) as? Bool ?? true
  }
}

/// Drafts kept across launches, and the device preferences the core needs.
extension ConnectionStore {
  /// Marks the sessions with a saved draft in the sidebar, for this account.
  func markSavedDrafts() {
    guard let archive = draftArchive, let account = connectedServer?.accountId else { return }
    if let failure = archive.lastError {
      record(scope: .connection, .InvalidState(message: failure))
    }
    for sessionID in archive.sessions(account: account) {
      sessionList.setDraft(sessionID, true)
    }
  }

  /// Restores `store`'s saved draft into an empty composer and keeps its later changes.
  func keepDraft(of store: ConversationStore) {
    let sessionID = store.sessionID
    store.composer.draftStored = { [weak self] text in
      guard let self, let archive = draftArchive, let account = connectedServer?.accountId
      else { return }
      archive.record(text, account: account, session: sessionID) { [weak self] message in
        self?.record(scope: .session(sessionId: sessionID), .InvalidState(message: message))
      }
    }
    guard let core, let account = connectedServer?.accountId,
      let saved = draftArchive?.draft(account: account, session: sessionID)
    else { return }
    do {
      // Text the core already holds is newer than the file.
      if try core.composerText(sessionId: sessionID).isEmpty {
        try core.updateComposer(sessionId: sessionID, text: saved)
        store.composer.setText(fromCore: saved)
      }
    } catch {
      record(scope: .session(sessionId: sessionID), coreError(error))
    }
  }

  /// Applies the automatic-titles preference to `core` now and whenever it changes.
  static func watchBackgroundTitles(_ core: ClientCore) -> Task<Void, Never> {
    var applied = SessionPreferences.backgroundTitles()
    core.setBackgroundSessionTitles(enabled: applied)
    return Task { [weak core] in
      for await _ in NotificationCenter.default.notifications(
        named: UserDefaults.didChangeNotification)
      {
        let enabled = SessionPreferences.backgroundTitles()
        guard enabled != applied, let core else { continue }
        applied = enabled
        core.setBackgroundSessionTitles(enabled: enabled)
      }
    }
  }
}
