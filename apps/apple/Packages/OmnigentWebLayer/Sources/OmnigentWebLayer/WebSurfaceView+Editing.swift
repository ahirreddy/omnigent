internal import AppKit

/// The Edit menu's actions, run in the page. Blink on macOS leaves ⌘Z, ⌘X, ⌘C, ⌘V and ⌘A to the
/// embedder's menu: the page sees the key first, and one it does not consume comes back through
/// `redispatch` to the menu item, whose action lands here. See DESIGN.md, "Editing commands".
extension WebSurfaceView: NSUserInterfaceValidations {
  /// The editing command an Edit menu action stands for, or nil for any other action.
  static func editingCommand(for action: Selector?) -> WebEditingCommand? {
    switch action {
    case #selector(undo(_:)): .undo
    case #selector(redo(_:)): .redo
    case #selector(cut(_:)): .cut
    case #selector(copy(_:)): .copy
    case #selector(paste(_:)): .paste
    case #selector(pasteAsPlainText(_:)): .pasteAndMatchStyle
    case #selector(delete(_:)): .delete
    case #selector(selectAll(_:)): .selectAll
    default: nil
    }
  }

  /// Whether the Edit menu acts on the page: this view has the keyboard, and the page is live
  /// on a host that runs editing commands.
  var editsPage: Bool {
    hostWindow?.firstResponder === self && webView.canPerformEditingCommands
  }

  /// Enables the Edit menu's items for the page. Like Chromium, it does not ask the page what
  /// is selected or undoable: a page may handle a command however it likes.
  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    Self.editingCommand(for: item.action) == nil || editsPage
  }

  /// Undoes in the page. Answering here keeps the window's own undo manager out of it.
  @objc func undo(_ sender: Any?) { webView.performEditingCommand(.undo) }
  /// Redoes in the page.
  @objc func redo(_ sender: Any?) { webView.performEditingCommand(.redo) }
  /// Cuts the page's selection to the pasteboard.
  @objc func cut(_ sender: Any?) { webView.performEditingCommand(.cut) }
  /// Copies the page's selection to the pasteboard.
  @objc func copy(_ sender: Any?) { webView.performEditingCommand(.copy) }
  /// Pastes the pasteboard into the page.
  @objc func paste(_ sender: Any?) { webView.performEditingCommand(.paste) }
  /// Paste and Match Style: pastes the pasteboard's text without its formatting.
  @objc func pasteAsPlainText(_ sender: Any?) {
    webView.performEditingCommand(.pasteAndMatchStyle)
  }
  /// Deletes the page's selection.
  @objc func delete(_ sender: Any?) { webView.performEditingCommand(.delete) }
  /// Selects everything in the page's focused frame or text field.
  override func selectAll(_ sender: Any?) { webView.performEditingCommand(.selectAll) }
}
