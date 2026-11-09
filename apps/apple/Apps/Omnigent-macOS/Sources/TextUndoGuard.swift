import AppKit

/// A text view keeps its typing undo when its text is replaced from code, which SwiftUI's
/// `TextEditor` does whenever its binding changes (a sent draft, another session's draft). Undoing
/// then reads a range the text no longer has, and AppKit's throw quits the app. The guard drops a
/// text's undo when its characters change other than by editing in its text view.
@MainActor
enum TextUndoGuard {
  private static var isInstalled = false
  /// Texts changed in this run of the main queue that no text view has reported as edited.
  private static var changedFromCode: [ObjectIdentifier: NSTextStorage] = [:]
  /// Each text's length when its text view last reported an edit. SwiftUI sets a `TextEditor`'s
  /// own text back on it after typing, and that leaves the undo valid.
  private static var editedLength: [ObjectIdentifier: Int] = [:]
  /// Set while an undo manager runs an undo or redo, which needn't report an edit.
  private static var isUndoing = false

  /// Guards every text view from now on.
  static func install() {
    guard !isInstalled else { return }
    isInstalled = true
    let center = NotificationCenter.default
    // Delivered as posted: the edited mask is only set during the notification.
    center.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: nil,
      using: textChanged)
    center.addObserver(
      forName: NSText.didChangeNotification, object: nil, queue: nil, using: textEdited)
    let undoStates: [(Notification.Name, Bool)] = [
      (.NSUndoManagerWillUndoChange, true),
      (.NSUndoManagerWillRedoChange, true),
      (.NSUndoManagerDidUndoChange, false),
      (.NSUndoManagerDidRedoChange, false),
    ]
    for (name, undoing) in undoStates {
      center.addObserver(forName: name, object: nil, queue: nil) { _ in
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { isUndoing = undoing }
      }
    }
  }

  nonisolated private static func textChanged(_ notification: Notification) {
    // Only the main thread's texts belong to text views.
    guard Thread.isMainThread, let storage = notification.object as? NSTextStorage,
      storage.editedMask.contains(.editedCharacters)
    else { return }
    nonisolated(unsafe) let changed = storage
    MainActor.assumeIsolated { unsafe noteChange(changed) }
  }

  nonisolated private static func textEdited(_ notification: Notification) {
    guard Thread.isMainThread, let textView = notification.object as? NSTextView,
      let storage = unsafe textView.textStorage
    else { return }
    let identifier = ObjectIdentifier(storage)
    let length = storage.length
    MainActor.assumeIsolated {
      changedFromCode[identifier] = nil
      editedLength[identifier] = length
    }
  }

  private static func noteChange(_ storage: NSTextStorage) {
    if isUndoing {
      editedLength[ObjectIdentifier(storage)] = storage.length
      return
    }
    if changedFromCode.isEmpty {
      DispatchQueue.main.async { MainActor.assumeIsolated { dropUndoOfChangedTexts() } }
    }
    changedFromCode[ObjectIdentifier(storage)] = storage
  }

  private static func dropUndoOfChangedTexts() {
    let storages = changedFromCode.values
    changedFromCode = [:]
    for storage in storages where editedLength[ObjectIdentifier(storage)] != storage.length {
      editedLength[ObjectIdentifier(storage)] = storage.length
      for window in NSApp.windows {
        window.undoManager?.removeAllActions(withTarget: storage)
        // The next typing would otherwise join the undo just dropped, and have none.
        if let textView = window.firstResponder as? NSTextView,
          unsafe textView.textStorage === storage
        {
          textView.breakUndoCoalescing()
        }
      }
    }
  }
}
