// Part of TerminalSurfaceController; see TerminalSurfaceController.swift for attribution.

import OmnigentGhosttyKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// User commands: clipboard, search, typing and keys.
extension TerminalSurfaceController {

  /// Runs a Ghostty binding action such as `copy_to_clipboard`. Returns whether it ran.
  @discardableResult
  public func perform(_ action: String) -> Bool {
    guard let surface = unsafe surface else { return false }
    return action.withCString { pointer in
      unsafe ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
    }
  }

  /// Copies the selection to the system clipboard.
  public func copy() { perform("copy_to_clipboard") }
  /// Pastes the system clipboard into the program (bracketed when it asked for it).
  public func paste() { perform("paste_from_clipboard") }
  /// Pastes `text` as the program expects a paste: bracketed when it enabled bracketed paste,
  /// with Ghostty's unsafe-paste checks.
  public func paste(_ text: String) {
    guard let surface = unsafe surface, !text.isEmpty else { return }
    text.withCString { pointer in
      unsafe ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
    }
  }

  /// Selects the whole screen and scrollback.
  public func selectAll() { perform("select_all") }
  /// Whether text is selected.
  public var hasSelection: Bool {
    guard let surface = unsafe surface else { return false }
    return unsafe ghostty_surface_has_selection(surface)
  }

  /// Opens the find bar.
  public func startSearch() {
    if search == nil { search = TerminalSearch(needle: "") }
    perform("start_search")
  }

  /// Searches for `needle` (empty cancels the search but keeps the bar).
  public func updateSearch(_ needle: String) {
    // A find bar that reappears sets its field to the current needle; Ghostty wouldn't recount.
    guard search?.needle != needle else { return }
    search = TerminalSearch(needle: needle)
    perform("search:\(needle)")
  }

  /// Moves to the next (or previous) match.
  public func searchNext(backwards: Bool = false) {
    perform(backwards ? "navigate_search:previous" : "navigate_search:next")
  }

  /// Closes the find bar.
  public func endSearch() {
    perform("end_search")
    search = nil
  }

  /// Sends committed text as if typed (accessory keys, dictation).
  public func type(_ text: String) {
    guard let surface = unsafe surface, !text.isEmpty else { return }
    text.withCString { pointer in
      unsafe ghostty_surface_text_input(surface, pointer, UInt(text.utf8.count))
    }
  }

  /// Sends one key through Ghostty's encoder, so the program's keyboard modes (application
  /// cursor keys, kitty keyboard flags, modifyOtherKeys) apply.
  @discardableResult
  public func press(_ key: TerminalKey, modifiers: TerminalModifiers = []) -> Bool {
    guard let surface = unsafe surface else { return false }
    var event = unsafe ghostty_input_key_s()
    unsafe event.keycode = key.macKeyCode
    unsafe event.mods = modifiers.ghostty
    unsafe event.consumed_mods = GHOSTTY_MODS_NONE
    unsafe event.unshifted_codepoint = key.unshiftedCodepoint
    unsafe event.composing = false
    unsafe event.text = nil
    unsafe event.action = GHOSTTY_ACTION_PRESS
    let handled = unsafe ghostty_surface_key(surface, event)
    unsafe event.action = GHOSTTY_ACTION_RELEASE
    unsafe ghostty_surface_key(surface, event)
    return handled
  }

  /// Gives the terminal keyboard focus (on iOS this shows the keyboard and accessory row).
  public func focus() {
    #if os(macOS)
      unsafe view.window?.makeFirstResponder(view)
    #else
      _ = view.becomeFirstResponder()
    #endif
  }

  /// Accepts the pending remote clipboard write.
  public func acceptPendingClipboard() {
    guard let pending = pendingClipboard else { return }
    TerminalPasteboard.write(pending.text)
    pendingClipboard = nil
  }

  /// Declines the pending remote clipboard write.
  public func declinePendingClipboard() {
    pendingClipboard = nil
  }

  /// Clears ``lastError`` after the user saw it.
  public func clearError() { lastError = nil }
}
