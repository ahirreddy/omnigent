public import Foundation

/// Unsent composer drafts (text, quote blocks and `@` paths) per account and session, kept in
/// one JSON file so drafts survive relaunches (the web keeps them in local storage). Writes are
/// coalesced: typing changes the in-memory copy at once and the file shortly after.
@MainActor
public final class ComposerDraftArchive {
  /// The archive under `Application Support/<bundle id>/composer-drafts.json`, or `nil` when
  /// Application Support cannot be located.
  public static let shared = locating(bundleIdentifier: Bundle.main.bundleIdentifier) {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
  }

  /// The archive of the app named `bundleIdentifier`, in the folder `applicationSupport` finds.
  /// - Parameters:
  ///   - bundleIdentifier: The app's identifier, when it has one.
  ///   - applicationSupport: Locates Application Support.
  /// - Returns: The archive, or `nil` after logging why when the folder can't be located.
  static func locating(
    bundleIdentifier: String?, applicationSupport: () throws -> URL
  ) -> ComposerDraftArchive? {
    do {
      let folder = try applicationSupport().appending(path: bundleIdentifier ?? "Omnigent")
      return ComposerDraftArchive(fileURL: folder.appending(path: "composer-drafts.json"))
    } catch {
      NSLog("Composer drafts are not kept across launches: %@", error.localizedDescription)
      return nil
    }
  }

  /// The last failure to read or write the file, until the next success.
  public private(set) var lastError: String?

  private let fileURL: URL
  private let saveDelay: Duration
  private var drafts: [String: [String: SavedDraft]]
  private var pendingSave: Task<Void, Never>?
  private var reportFailure: (@MainActor (String) -> Void)?

  /// An archive stored at `fileURL`, read now.
  /// - Parameters:
  ///   - fileURL: The JSON file.
  ///   - saveDelay: How long changes collect before the file is written.
  public init(fileURL: URL, saveDelay: Duration = .milliseconds(500)) {
    self.fileURL = fileURL
    self.saveDelay = saveDelay
    drafts = [:]
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      drafts = try JSONDecoder().decode(
        [String: [String: SavedDraft]].self, from: Data(contentsOf: fileURL))
    } catch {
      lastError = "Saved drafts could not be read: \(error.localizedDescription)"
    }
  }

  /// The saved draft of `sessionID` on `account`.
  /// - Parameters:
  ///   - account: The account scope (server plus user).
  ///   - sessionID: The session.
  /// - Returns: The draft, or `nil`.
  public func draft(account: String, session sessionID: String) -> SavedDraft? {
    drafts[account]?[sessionID]
  }

  /// The sessions on `account` with a saved draft.
  /// - Parameter account: The account scope.
  /// - Returns: Their ids.
  public func sessions(account: String) -> Set<String> {
    Set(drafts[account].map { Array($0.keys) } ?? [])
  }

  /// Keeps `draft` as `sessionID`'s draft; an empty draft forgets it.
  /// - Parameters:
  ///   - draft: The composer draft.
  ///   - account: The account scope.
  ///   - sessionID: The session.
  ///   - report: Shows a failure to write the file.
  public func record(
    _ draft: SavedDraft, account: String, session sessionID: String,
    report: (@MainActor (String) -> Void)? = nil
  ) {
    let kept = draft.isEmpty ? nil : draft
    guard drafts[account]?[sessionID] != kept else { return }
    if let kept {
      drafts[account, default: [:]][sessionID] = kept
    } else {
      drafts[account]?[sessionID] = nil
      if drafts[account]?.isEmpty == true { drafts[account] = nil }
    }
    if let report { reportFailure = report }
    scheduleSave()
  }

  /// Writes pending changes now.
  public func flush() {
    pendingSave?.cancel()
    pendingSave = nil
    save()
  }

  private func scheduleSave() {
    guard pendingSave == nil else { return }
    pendingSave = Task { [weak self, saveDelay] in
      do {
        try await Task.sleep(for: saveDelay)
      } catch {
        // Flushed meanwhile.
        return
      }
      self?.pendingSave = nil
      self?.save()
    }
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(drafts).write(to: fileURL, options: .atomic)
      lastError = nil
    } catch {
      let message = "Drafts could not be saved: \(error.localizedDescription)"
      lastError = message
      reportFailure?(message)
    }
  }
}
