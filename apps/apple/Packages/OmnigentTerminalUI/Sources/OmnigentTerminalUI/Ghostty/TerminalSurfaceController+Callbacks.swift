// Part of TerminalSurfaceController; see TerminalSurfaceController.swift for attribution.

import Foundation
import OmnigentGhosttyKit

/// Callbacks from ``GhosttyRuntime`` and diagnostics.
extension TerminalSurfaceController {

  func handle(action: ghostty_action_s) -> Bool {
    switch unsafe action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
      if let pointer = unsafe action.action.set_title.title {
        title = unsafe lossyUTF8(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
      }
      return true
    case GHOSTTY_ACTION_START_SEARCH, GHOSTTY_ACTION_END_SEARCH, GHOSTTY_ACTION_SEARCH_TOTAL,
      GHOSTTY_ACTION_SEARCH_SELECTED:
      unsafe handleSearch(action)
      return true
    case GHOSTTY_ACTION_OPEN_URL:
      return unsafe openURL(action.action.open_url)
    case GHOSTTY_ACTION_MOUSE_SHAPE:
      view.setPointerShape(unsafe action.action.mouse_shape)
      return true
    case GHOSTTY_ACTION_RENDER:
      // iOS drives frames from the view's display link (the fork's external render mode);
      // macOS renders on Ghostty's own renderer thread and never asks.
      return view.requestRender()
    case GHOSTTY_ACTION_RING_BELL:
      view.ringBell()
      return true
    default:
      return false
    }
  }

  private func handleSearch(_ action: ghostty_action_s) {
    switch unsafe action.tag {
    case GHOSTTY_ACTION_START_SEARCH:
      let needle = unsafe action.action.start_search.needle.map { unsafe String(cString: $0) }
      search = TerminalSearch(needle: needle ?? search?.needle ?? "")
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      let total = unsafe action.action.search_total.total
      search?.total = total >= 0 ? total : nil
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      let selected = unsafe action.action.search_selected.selected
      search?.selected = selected >= 0 ? selected : nil
    default:
      search = nil
    }
  }

  private func openURL(_ open: ghostty_action_open_url_s) -> Bool {
    guard let pointer = unsafe open.url else { return false }
    let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: Int(open.len))
    guard let text = unsafe String(bytes: bytes, encoding: .utf8) else {
      report("The terminal reported a link that is not valid UTF-8; it was not opened.")
      return false
    }
    return TerminalLinks.open(text)
  }

  /// Ghostty asks for the clipboard to paste. `state` identifies the request.
  func completePaste(state: UnsafeMutableRawPointer?) {
    guard let surface = unsafe surface else { return }
    let text = TerminalPasteboard.read() ?? ""
    text.withCString { pointer in
      unsafe ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
    }
  }

  /// Ghostty asks to confirm a clipboard access. A paste that Ghostty flags as unsafe (for
  /// example multi-line text into a program without bracketed paste) is confirmed by the user's
  /// own paste action; remote OSC 52 reads are refused.
  func confirmClipboard(
    content: String, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e
  ) {
    guard let surface = unsafe surface else { return }
    switch request {
    case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
      content.withCString { pointer in
        unsafe ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
      }
    default:
      lastError = "The terminal program asked to read the clipboard; the request was refused."
      // libghostty needs a string, and asks again until confirmed: refuse with an empty answer.
      "".withCString { pointer in
        unsafe ghostty_surface_complete_clipboard_request(surface, pointer, state, true)
      }
    }
  }

  /// Ghostty copied text (a user copy, or an OSC 52 write when `requiresConfirmation`).
  func copied(text: String, requiresConfirmation: Bool) {
    if requiresConfirmation {
      remoteCopied(text)
    } else {
      TerminalPasteboard.write(text)
    }
  }

  /// A terminal program copied `text`: copy, ask or refuse, as Settings > Terminal says.
  func remoteCopied(_ text: String, policy: TerminalClipboardPolicy = .current()) {
    switch policy {
    case .ask: pendingClipboard = PendingClipboardWrite(id: UUID(), text: text)
    case .allow: TerminalPasteboard.write(text)
    case .block:
      lastError =
        "A terminal program tried to copy text. Copying is blocked in Settings > Terminal."
    }
  }

  // MARK: Testing and diagnostics

  /// The visible screen as plain text, one line per row with trailing spaces trimmed.
  public func visibleText() -> String {
    guard let surface = unsafe surface else { return "" }
    var selection = ghostty_selection_s()
    selection.top_left = ghostty_point_s(
      tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
    selection.bottom_right = ghostty_point_s(
      tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
    selection.rectangle = false
    var text = unsafe ghostty_text_s()
    guard unsafe ghostty_surface_read_text(surface, selection, &text) else { return "" }
    defer { unsafe ghostty_surface_free_text(surface, &text) }
    guard let pointer = unsafe text.text else { return "" }
    let bytes = unsafe UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len))
    return unsafe lossyUTF8(bytes)
  }

  /// Records a renderer error for the view.
  func report(_ message: String) {
    lastError = message
    GhosttyRuntime.log(message)
  }
}
