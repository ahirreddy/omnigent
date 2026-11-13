internal import OWLProtocol

/// An Edit menu action the page runs in its focused frame (protocol 1.6). See DESIGN.md,
/// "Editing commands".
nonisolated enum WebEditingCommand: Sendable, Hashable, CaseIterable {
  case undo
  case redo
  case cut
  case copy
  case paste
  /// Pastes the pasteboard's text without its formatting.
  case pasteAndMatchStyle
  /// Deletes the selection and leaves the pasteboard alone.
  case delete
  case selectAll

  var wire: OWLEditCommand {
    switch self {
    case .undo: .undo
    case .redo: .redo
    case .cut: .cut
    case .copy: .copy
    case .paste: .paste
    case .pasteAndMatchStyle: .pasteAndMatchStyle
    case .delete: .delete
    case .selectAll: .selectAll
    }
  }
}

extension Session {
  /// Whether the running host runs editing commands (Undo, Redo, Cut, Copy, Paste, Paste and
  /// Match Style, Delete, Select All): protocol 1.6 or later. Older hosts are never sent one.
  public var supportsEditingCommands: Bool {
    isReady && hostMinor >= UInt64(OWL_PROTOCOL_MINOR_EDITING)
  }
}

/// Editing commands for 1.6 hosts. This is the user's path only: Cut, Copy and Paste use the
/// user's pasteboard, so agent input has no way to reach it. See DESIGN.md, "Agent input".
extension WebView {
  /// Whether the page can run an editing command now: it is live and its host is 1.6 or later.
  var canPerformEditingCommands: Bool {
    status == .live && session.supportsEditingCommands
  }

  /// Runs `command` in the page's focused frame. Dropped while the view is not live; an older
  /// host is not sent it, which `featureBlocked` reports.
  func performEditingCommand(_ command: WebEditingCommand) {
    guard status == .live else { return }
    guard session.supportsEditingCommands else {
      let feature = "Editing commands"
      lastError = .featureBlocked(
        feature: feature, detail: "The Chromium web host is older than protocol 1.6.")
      onEvent?(.featureBlocked(feature: feature, detail: "Host protocol before 1.6."))
      return
    }
    send(.editCommand, WireEncoder().u64(.editCommand, command.wire.rawValue))
  }
}
