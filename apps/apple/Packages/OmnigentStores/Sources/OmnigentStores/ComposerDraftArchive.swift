public import Foundation

/// Unsent composer text per account and session, kept in one JSON file so drafts survive
/// relaunches (the web keeps them in local storage). Writes are coalesced: typing changes the
/// in-memory copy at once and the file shortly after.
@MainActor
public final class ComposerDraftArchive {
  /// The archive under `Application Support/<bundle id>/composer-drafts.json`, or `nil` when
  /// Application Support cannot be located.
  public static let shared: ComposerDraftArchive? = {
    do {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let folder = support.appending(path: Bundle.main.bundleIdentifier ?? "Omnigent")
      return ComposerDraftArchive(fileURL: folder.appending(path: "composer-drafts.json"))
    } catch {
      NSLog("Composer drafts are not kept across launches: %@", error.localizedDescription)
      return nil
    }
  }()

  /// The last failure to read or write the file, until the next success.
  public private(set) var lastError: String?

  private let fileURL: URL
  private let saveDelay: Duration
  private var drafts: [String: [String: String]]
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
        [String: [String: String]].self, from: Data(contentsOf: fileURL))
    } catch {
      lastError = "Saved drafts could not be read: \(error.localizedDescription)"
    }
  }

  /// The saved draft of `sessionID` on `account`.
  /// - Parameters:
  ///   - account: The account scope (server plus user).
  ///   - sessionID: The session.
  /// - Returns: Its text, or `nil`.
  public func draft(account: String, session sessionID: String) -> String? {
    drafts[account]?[sessionID]
  }

  /// The sessions on `account` with a saved draft.
  /// - Parameter account: The account scope.
  /// - Returns: Their ids.
  public func sessions(account: String) -> Set<String> {
    Set(drafts[account].map { Array($0.keys) } ?? [])
  }

  /// Keeps `text` as `sessionID`'s draft; blank text forgets it.
  /// - Parameters:
  ///   - text: The composer text.
  ///   - account: The account scope.
  ///   - sessionID: The session.
  ///   - report: Shows a failure to write the file.
  public func record(
    _ text: String, account: String, session sessionID: String,
    report: (@MainActor (String) -> Void)? = nil
  ) {
    let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard drafts[account]?[sessionID] != (blank ? nil : text) else { return }
    if blank {
      drafts[account]?[sessionID] = nil
      if drafts[account]?.isEmpty == true { drafts[account] = nil }
    } else {
      drafts[account, default: [:]][sessionID] = text
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
