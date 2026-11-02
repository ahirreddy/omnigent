#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The local pasteboard the remote page copies to and pastes from (the remote machine's
/// clipboard is never used; design doc section 16.5).
public protocol RemotePasteboard: AnyObject {
  /// Replaces the pasteboard's contents with text.
  /// - Parameter text: The text.
  func write(_ text: String)
  /// The pasteboard's text, if it has any. Read only in response to a user's Paste.
  func read() -> String?
}

/// The system's general pasteboard.
public final class SystemPasteboard: RemotePasteboard {
  /// Creates the wrapper.
  public init() {}

  /// Replaces the general pasteboard's contents.
  public func write(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }

  /// The general pasteboard's text.
  public func read() -> String? {
    #if os(macOS)
      NSPasteboard.general.string(forType: .string)
    #else
      UIPasteboard.general.string
    #endif
  }
}
