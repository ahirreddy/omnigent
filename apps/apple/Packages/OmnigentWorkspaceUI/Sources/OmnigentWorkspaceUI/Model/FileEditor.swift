import Foundation
public import Observation

/// An edit of one text file, as the web's file editor: edits save on their own after a short
/// pause (or at once with Save), a save first checks that nobody else changed the file, and a
/// change made elsewhere under unsaved edits raises a conflict to resolve (keep mine or load
/// the latest). The text is edited with `\n` line breaks; a CRLF file is saved with CRLF again.
///
/// Typing only marks the edit (``textEdited(_:)``): the text is read from the text view when
/// needed (a save, a selection), so a keystroke in a long file never copies or compares it, and
/// the observable state views draw (``isDirty``, ``status``) is written only when it changes.
@Observable
public final class FileEditor {
  /// Where the edit stands, for the toolbar's status.
  nonisolated public enum Status: Hashable, Sendable {
    /// Nothing to save.
    case clean
    /// Edits wait to be saved.
    case unsaved
    /// A save is in flight.
    case saving
    /// Just saved.
    case saved
    /// The last save failed.
    case failed(String)
  }

  /// A change made elsewhere while this edit was unsaved.
  nonisolated public struct Conflict: Hashable, Sendable {
    /// The file's text now; `nil` when it was deleted or is no longer text.
    public var latest: String?
  }

  /// The file.
  public let path: String
  /// The text being edited. Text views read it once and again only when ``textRevision``
  /// changes, so typing never observes it.
  public var text: String {
    get {
      if let typed = typedText {
        typedText = nil
        storedText = typed()
      }
      return storedText
    }
    set {
      typedText = nil
      guard newValue != storedText else { return }
      storedText = newValue
      edited(dirty: newValue != base)
    }
  }
  @ObservationIgnored private var storedText: String
  /// Reads the text view's text after typing, until ``text`` reads it.
  @ObservationIgnored private var typedText: (() -> String)?
  /// Bumped when ``text`` is replaced other than by typing (revert, load latest, a clean edit
  /// following the file), so a text view showing it reloads.
  public private(set) var textRevision = 0
  /// The saved text this edit started from.
  public private(set) var base: String
  /// Whether there are edits not yet saved.
  public private(set) var isDirty = false
  /// Where the edit stands.
  public private(set) var status = Status.clean
  /// Set while a change made elsewhere waits to be resolved; saving waits too.
  public private(set) var conflict: Conflict?
  /// The pause after the last keystroke before saving; `nil` saves only on request.
  @ObservationIgnored public var autosaveDelay: Duration? = .milliseconds(1_500)

  private let crlf: Bool
  private let write: (String, String?) async throws(WorkspaceFailure) -> FileSaveResult
  /// The file's text on the server as last read or written, with its own line breaks.
  @ObservationIgnored private var serverText: String
  /// The server text behind `conflict`.
  @ObservationIgnored private var conflictServerText: String?
  @ObservationIgnored private var pendingSave: Task<Void, Never>?
  @ObservationIgnored private var clearSaved: Task<Void, Never>?
  @ObservationIgnored private var isSaving = false

  /// An editor over `text` as read from the server.
  /// - Parameters:
  ///   - path: The file.
  ///   - text: Its text as read.
  ///   - lineEnding: Its line breaks.
  ///   - write: Saves `(text, base)` as `WorkspaceDataSource.save` does.
  public init(
    path: String, text: String, lineEnding: LineEnding,
    write: @escaping (String, String?) async throws(WorkspaceFailure) -> FileSaveResult
  ) {
    self.path = path
    crlf = lineEnding == .crlf
    serverText = text
    let editable = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    storedText = editable
    base = editable
    self.write = write
  }

  /// The file has CRLF line breaks, which the editor shows as `\n`.
  public var usesCRLF: Bool { crlf }

  /// The text view changed the text: the edit counts as unsaved and autosave restarts, without
  /// reading the text, which `current` returns when it is needed.
  /// - Parameter current: The text view's text now.
  public func textEdited(_ current: @escaping () -> String) {
    typedText = current
    edited(dirty: true)
  }

  /// Saves now. `force` overwrites a change made elsewhere ("Keep mine").
  /// - Parameter force: Skip the check for changes made elsewhere.
  public func save(force: Bool = false) async {
    pendingSave?.cancel()
    pendingSave = nil
    guard !isSaving, isDirty || force, conflict == nil || force else { return }
    let content = text
    guard content != base || force else {
      // Typed back to the saved text.
      updateDirty()
      setStatus(.clean)
      return
    }
    isSaving = true
    setStatus(.saving)
    let raw = crlf ? content.replacingOccurrences(of: "\n", with: "\r\n") : content
    do {
      switch try await write(raw, force ? nil : serverText) {
      case .saved:
        serverText = raw
        base = content
        conflict = nil
        updateDirty()
        setStatus(isDirty ? .unsaved : .saved)
      case .conflict(let latest):
        raiseConflict(latest)
        setStatus(.unsaved)
      }
    } catch {
      setStatus(.failed(error.message))
    }
    isSaving = false
    if status == .saved {
      showSavedBriefly()
    } else if status == .unsaved, conflict == nil {
      scheduleSave()
    }
  }

  /// Resolves a conflict by taking the file's text now and discarding the edits. When the file
  /// is gone the edits are discarded for the last saved text.
  public func loadLatest() {
    pendingSave?.cancel()
    if let raw = conflictServerText {
      serverText = raw
      base = editable(raw)
    }
    conflict = nil
    conflictServerText = nil
    replaceText(base)
    setStatus(.clean)
  }

  /// Discards the edits, keeping the last saved text; under a conflict, takes the latest.
  public func revert() {
    guard conflict == nil else {
      loadLatest()
      return
    }
    pendingSave?.cancel()
    replaceText(base)
    setStatus(.clean)
  }

  /// The file was read again (for example after the agent changed it): clean edits take the new
  /// text, unsaved ones raise a conflict.
  /// - Parameter raw: The text as read.
  public func serverChanged(_ raw: String) {
    guard raw != serverText else { return }
    if isDirty {
      pendingSave?.cancel()
      raiseConflict(raw)
    } else {
      serverText = raw
      base = editable(raw)
      replaceText(base)
    }
  }

  // MARK: Private

  private func replaceText(_ new: String) {
    text = new
    textRevision += 1
  }

  private func raiseConflict(_ raw: String?) {
    conflictServerText = raw
    conflict = Conflict(latest: raw.map(editable))
  }

  private func editable(_ raw: String) -> String {
    crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
  }

  private func updateDirty() {
    let dirty = text != base
    if dirty != isDirty { isDirty = dirty }
  }

  private func setStatus(_ new: Status) {
    if new != status { status = new }
  }

  private func edited(dirty: Bool) {
    if dirty != isDirty { isDirty = dirty }
    guard !isSaving else { return }
    setStatus(isDirty ? .unsaved : .clean)
    if isDirty, conflict == nil { scheduleSave() }
  }

  private func scheduleSave() {
    pendingSave?.cancel()
    guard let autosaveDelay else { return }
    pendingSave = Task { [weak self] in
      do {
        try await Task.sleep(for: autosaveDelay)
      } catch {
        return  // Cancelled by a newer edit or a manual save.
      }
      await self?.save()
    }
  }

  private func showSavedBriefly() {
    clearSaved?.cancel()
    clearSaved = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return  // Cancelled by the next save.
      }
      guard let self, self.status == .saved else { return }
      self.status = .clean
    }
  }
}
