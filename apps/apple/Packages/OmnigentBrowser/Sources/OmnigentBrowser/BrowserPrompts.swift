public import Foundation
public import Observation

/// Browser UI a page asks for, the same for every engine. Engines create prompts; the app's
/// `BrowserTabDelegate` (normally `BrowserPromptPresenter`) answers them, or an agent does.
public enum BrowserPrompt: Identifiable {
  /// `alert`, `confirm`, `prompt` or `beforeunload`.
  case dialog(BrowserDialogPrompt)
  /// Camera, microphone, geolocation, notifications, clipboard and similar.
  case permission(BrowserPermissionPrompt)
  /// `<input type=file>` and similar pickers.
  case fileChooser(BrowserFileChooserPrompt)
  /// Where a download goes, or whether it happens.
  case download(BrowserDownloadPrompt)
  /// HTTP or proxy authentication.
  case authentication(BrowserAuthPrompt)
  /// A certificate error; shown as an interstitial.
  case certificateError(BrowserCertificatePrompt)
  /// `<input type=color>`.
  case color(BrowserColorPrompt)

  /// The prompt's shared state.
  public var base: BrowserPromptBase {
    switch self {
    case .dialog(let prompt): prompt
    case .permission(let prompt): prompt
    case .fileChooser(let prompt): prompt
    case .download(let prompt): prompt
    case .authentication(let prompt): prompt
    case .certificateError(let prompt): prompt
    case .color(let prompt): prompt
    }
  }

  /// Stable identity for SwiftUI.
  public var id: UUID { base.id }

  /// A short name for logs and agent results.
  public var kindName: String {
    switch self {
    case .dialog: "dialog"
    case .permission: "permission"
    case .fileChooser: "file_chooser"
    case .download: "download"
    case .authentication: "authentication"
    case .certificateError: "certificate_error"
    case .color: "color"
    }
  }
}

/// What every prompt shares.
@Observable
public class BrowserPromptBase {
  /// Identity.
  public let id = UUID()
  /// Whether it was answered or withdrawn.
  public private(set) var isFinished = false
  /// Why the engine withdrew it, if it did.
  public private(set) var cancellationReason: String?

  init() {}

  /// Marks the prompt answered. Returns false when it already was, so the engine is not told
  /// twice.
  func finish() -> Bool {
    guard !isFinished else { return false }
    isFinished = true
    return true
  }

  /// Called by engines when the page or engine withdrew the prompt.
  package func withdraw(reason: String) {
    cancellationReason = reason
    isFinished = true
  }
}

/// Which JavaScript dialog the page opened.
nonisolated public enum BrowserDialogKind: String, Sendable, Hashable {
  /// `alert()`.
  case alert
  /// `confirm()`.
  case confirm
  /// `prompt()`.
  case prompt
  /// The "leave page?" confirmation.
  case beforeUnload = "beforeunload"
}

/// A JavaScript dialog. The page waits for the answer.
public final class BrowserDialogPrompt: BrowserPromptBase {
  /// The dialog type.
  public let kind: BrowserDialogKind
  /// The page that opened it.
  public let origin: URL?
  /// The message.
  public let message: String
  /// `prompt()` only: the initial text.
  public let defaultText: String
  private let answer: (_ accepted: Bool, _ text: String?) -> Void

  /// Creates a prompt; `answer` runs once.
  package init(
    kind: BrowserDialogKind, origin: URL?, message: String, defaultText: String,
    answer: @escaping (_ accepted: Bool, _ text: String?) -> Void
  ) {
    self.kind = kind
    self.origin = origin
    self.message = message
    self.defaultText = defaultText
    self.answer = answer
  }

  /// OK, Leave, or the prompt text.
  public func accept(text: String? = nil) {
    if finish() { answer(true, text) }
  }

  /// Cancel, Stay.
  public func cancel() {
    if finish() { answer(false, nil) }
  }
}

/// Permissions a page can ask for.
nonisolated public struct BrowserPermissions: OptionSet, Sendable, Hashable {
  /// Raw bits.
  public let rawValue: UInt64
  /// Creates permissions from raw bits.
  public init(rawValue: UInt64) { self.rawValue = rawValue }

  /// Camera.
  public static let camera = Self(rawValue: 1 << 0)
  /// Microphone.
  public static let microphone = Self(rawValue: 1 << 1)
  /// Location.
  public static let geolocation = Self(rawValue: 1 << 2)
  /// Notifications.
  public static let notifications = Self(rawValue: 1 << 3)
  /// Clipboard read.
  public static let clipboard = Self(rawValue: 1 << 4)
  /// Screen capture.
  public static let screenCapture = Self(rawValue: 1 << 5)
  /// MIDI.
  public static let midi = Self(rawValue: 1 << 6)
  /// Loopback and private-network requests, such as Okta FastPass probing Okta Verify on
  /// 127.0.0.1 (Chromium's Local Network Access).
  public static let localNetwork = Self(rawValue: 1 << 7)
  /// Anything else; always denied.
  public static let other = Self(rawValue: 1 << 30)

  /// Single permissions in display order with their names.
  public static let named: [(Self, String)] = [
    (.camera, "camera"), (.microphone, "microphone"), (.geolocation, "location"),
    (.notifications, "notifications"), (.clipboard, "clipboard"),
    (.screenCapture, "screen capture"), (.midi, "MIDI devices"),
    (.localNetwork, "apps and devices on your computer and local network"),
    (.other, "other features"),
  ]

  /// The names of the permissions in this set.
  public var names: [String] {
    Self.named.filter { contains($0.0) }.map(\.1)
  }
}

/// The answer to a permission prompt.
nonisolated public enum BrowserPermissionAnswer: Sendable, Hashable {
  /// Granted.
  case allow
  /// Denied.
  case deny
  /// Closed without deciding; the page may ask again.
  case dismiss
}

/// A permission request. One decision covers every permission in it.
public final class BrowserPermissionPrompt: BrowserPromptBase {
  /// The requesting origin, `scheme://host[:port]`.
  public let origin: String
  /// What the page asked for.
  public let permissions: BrowserPermissions
  private let answer: (BrowserPermissionAnswer) -> Void

  /// Creates a prompt; `answer` runs once.
  package init(
    origin: String, permissions: BrowserPermissions,
    answer: @escaping (BrowserPermissionAnswer) -> Void
  ) {
    self.origin = origin
    self.permissions = permissions
    self.answer = answer
  }

  /// Grants the request.
  public func allow() {
    if finish() { answer(.allow) }
  }

  /// Denies the request.
  public func deny() {
    if finish() { answer(.deny) }
  }

  /// Closes without deciding.
  public func dismiss() {
    if finish() { answer(.dismiss) }
  }
}

/// What a file chooser may pick.
nonisolated public enum BrowserFileChooserMode: String, Sendable, Hashable {
  /// One file.
  case open
  /// One or more files.
  case openMultiple
  /// A folder.
  case openFolder
  /// A new file to save.
  case save
}

/// A file chooser.
public final class BrowserFileChooserPrompt: BrowserPromptBase {
  /// What may be picked.
  public let mode: BrowserFileChooserMode
  /// Allowed file name extensions without the dot; empty allows all.
  public let allowedExtensions: [String]
  /// Allowed MIME types or patterns such as "image/*"; empty allows all.
  public let allowedMIMETypes: [String]
  /// A suggested name for save mode.
  public let suggestedName: String
  private let answer: ([URL]) -> Void

  /// Creates a prompt; `answer` gets the chosen file URLs, empty when cancelled.
  package init(
    mode: BrowserFileChooserMode, allowedExtensions: [String], allowedMIMETypes: [String],
    suggestedName: String, answer: @escaping ([URL]) -> Void
  ) {
    self.mode = mode
    self.allowedExtensions = allowedExtensions
    self.allowedMIMETypes = allowedMIMETypes
    self.suggestedName = suggestedName
    self.answer = answer
  }

  /// Answers with file URLs.
  public func choose(_ urls: [URL]) {
    if finish() { answer(urls) }
  }

  /// Cancels.
  public func cancel() {
    if finish() { answer([]) }
  }
}

/// A download waiting for a destination.
public final class BrowserDownloadPrompt: BrowserPromptBase {
  /// What is downloaded.
  public let url: URL?
  /// The suggested file name.
  public let suggestedName: String
  /// The MIME type, possibly empty.
  public let mimeType: String
  /// The size, when known.
  public let totalBytes: Int64?
  private let answer: (URL?) -> Void

  /// Creates a prompt; `answer` gets the destination, or nil to cancel.
  package init(
    url: URL?, suggestedName: String, mimeType: String, totalBytes: Int64?,
    answer: @escaping (URL?) -> Void
  ) {
    self.url = url
    self.suggestedName = suggestedName
    self.mimeType = mimeType
    self.totalBytes = totalBytes
    self.answer = answer
  }

  /// Saves to `destination`. The engine then reports a `BrowserDownload`.
  public func save(to destination: URL) {
    if finish() { answer(destination) }
  }

  /// Cancels the download.
  public func cancel() {
    if finish() { answer(nil) }
  }
}
