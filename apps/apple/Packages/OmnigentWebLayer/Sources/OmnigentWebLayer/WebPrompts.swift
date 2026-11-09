public import Foundation
internal import OWLProtocol
internal import os

/// Receives the browser UI a page asks for (protocol 1.1). See DESIGN.md, "Browser UI over the
/// channel".
///
/// Without a delegate every prompt is denied, popups are closed, and each is reported as
/// `WebViewEvent.featureBlocked`, as in protocol 1.0.
public protocol WebViewUIDelegate: AnyObject {
  /// The page needs an answer. Answer the prompt now or later; it stays in
  /// `WebView.pendingPrompts` until then.
  func webView(_ webView: WebView, didRequest prompt: WebPrompt)
  /// The host withdrew a prompt (navigation, view closed). Dismiss its UI.
  func webView(_ webView: WebView, didCancel prompt: WebPrompt, reason: String)
  /// The page opened a new view with an opener. Embed it, or close it.
  func webView(_ webView: WebView, didOpen popup: WebPopup)
  /// The popup policy stopped a new window.
  func webView(_ webView: WebView, didBlock popup: WebBlockedPopup)
  /// The page navigated to a scheme Chromium does not handle, such as Okta Verify's
  /// `com-okta-authenticator:` (protocol 1.3). Ask the user before opening it with the OS. The
  /// default reports it as `WebViewEvent.featureBlocked`.
  func webView(_ webView: WebView, wantsToOpenExternally request: WebExternalURLRequest)
}

extension WebViewUIDelegate {
  /// Reports the request as blocked.
  public func webView(_ webView: WebView, wantsToOpenExternally request: WebExternalURLRequest) {
    webView.reportUnhandledExternalURL(request)
  }
}

/// A page request that needs an answer.
public enum WebPrompt: Identifiable {
  /// `alert`, `confirm`, `prompt` or `beforeunload`.
  case dialog(WebDialogRequest)
  /// Camera, microphone, geolocation, notifications, clipboard and similar.
  case permission(WebPermissionRequest)
  /// `<input type=file>` and the File System Access pickers.
  case fileChooser(WebFileChooserRequest)
  /// Where to save a download, or whether to download at all.
  case download(WebDownloadRequest)
  /// HTTP or proxy authentication.
  case authentication(WebAuthRequest)
  /// A certificate error on a main-frame load.
  case certificateError(WebCertificateErrorRequest)
  /// A context menu, built from the host's menu model.
  case contextMenu(WebContextMenu)
  /// `<input type=color>`.
  case color(WebColorRequest)

  /// The underlying request.
  public var request: WebPromptRequest {
    switch self {
    case .dialog(let request): request
    case .permission(let request): request
    case .fileChooser(let request): request
    case .download(let request): request
    case .authentication(let request): request
    case .certificateError(let request): request
    case .contextMenu(let request): request
    case .color(let request): request
    }
  }

  /// The host's prompt ID, unique within the view.
  public var id: UInt64 { request.id }
}

/// What every prompt shares: identity, the view that asked, and whether it is finished.
public class WebPromptRequest {
  /// Host-assigned ID, unique within the view.
  public let id: UInt64
  /// The view that asked.
  public private(set) weak var webView: WebView?
  /// Whether the prompt was answered or withdrawn.
  public private(set) var isFinished = false
  /// Why the host withdrew the prompt, if it did.
  public private(set) var cancellationReason: String?

  init(id: UInt64, webView: WebView) {
    self.id = id
    self.webView = webView
  }

  /// Sends the answer once. A second answer, or one after the host withdrew the prompt, is
  /// reported as `WebLayerError.promptFinished` on the view.
  func reply(_ kind: OWLMessageKind, _ fields: WireEncoder = WireEncoder()) {
    guard let webView else { return }
    guard !isFinished else {
      Logger.view.error("Prompt \(self.id) was answered after it finished.")
      webView.lastError = .promptFinished("prompt \(id)")
      webView.changed()
      return
    }
    isFinished = true
    webView.send(kind, fields.u64(.promptID, id))
    webView.promptFinished(self)
  }

  /// Finishes a prompt that needs no message (for example a non-overridable certificate error).
  func finishLocally() {
    guard !isFinished else { return }
    isFinished = true
    webView?.promptFinished(self)
  }

  func withdraw(reason: String) {
    cancellationReason = reason
    isFinished = true
  }
}

/// Which JavaScript dialog the page opened.
nonisolated public enum WebDialogKind: Sendable, Hashable {
  /// `alert()`.
  case alert
  /// `confirm()`.
  case confirm
  /// `prompt()`.
  case prompt
  /// The `beforeunload` "leave page?" confirmation.
  case beforeUnload

  init(wire value: UInt64) {
    switch OWLDialogKind(rawValue: value) {
    case .confirm: self = .confirm
    case .prompt: self = .prompt
    case .beforeUnload: self = .beforeUnload
    default: self = .alert
    }
  }
}

/// A JavaScript dialog. The page is paused until it is answered.
public final class WebDialogRequest: WebPromptRequest {
  /// The dialog type.
  public let kind: WebDialogKind
  /// The page origin that opened it.
  public let origin: URL?
  /// The message.
  public let message: String
  /// `prompt()` only: the initial text.
  public let defaultText: String
  /// `beforeunload` only: whether the page is reloading rather than leaving.
  public let isReload: Bool

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    kind = WebDialogKind(wire: fields.u64(.dialogKind) ?? 0)
    origin = fields.string(.origin).flatMap(URL.init(string:))
    message = fields.string(.message) ?? ""
    defaultText = fields.string(.defaultText) ?? ""
    isReload = fields.bool(.isReload)
    super.init(id: id, webView: webView)
  }

  /// Answers OK (alert, confirm, leave) or with `text` (prompt).
  public func accept(text: String? = nil) {
    var fields = WireEncoder().bool(.accepted, true)
    if let text { fields = fields.string(.text, text) }
    reply(.dialogReply, fields)
  }

  /// Answers Cancel (confirm and prompt return false and null; beforeunload stays).
  public func cancel() {
    reply(.dialogReply, WireEncoder().bool(.accepted, false))
  }
}

/// Permissions a page can ask for.
nonisolated public struct WebPermissions: OptionSet, Sendable, Hashable {
  /// Raw bits (the OWLPermission values).
  public let rawValue: UInt64
  /// Creates permissions from raw bits.
  public init(rawValue: UInt64) { self.rawValue = rawValue }

  /// Camera capture.
  public static let camera = Self(rawValue: OWLPermission.camera.rawValue)
  /// Microphone capture.
  public static let microphone = Self(rawValue: OWLPermission.microphone.rawValue)
  /// Location.
  public static let geolocation = Self(rawValue: OWLPermission.geolocation.rawValue)
  /// Web notifications.
  public static let notifications = Self(rawValue: OWLPermission.notifications.rawValue)
  /// Clipboard read.
  public static let clipboard = Self(rawValue: OWLPermission.clipboard.rawValue)
  /// Screen or tab capture.
  public static let screenCapture = Self(rawValue: OWLPermission.screenCapture.rawValue)
  /// MIDI system exclusive messages.
  public static let midi = Self(rawValue: OWLPermission.MIDI.rawValue)
  /// Requests to loopback or private-network addresses, such as Okta FastPass probing Okta
  /// Verify on 127.0.0.1 (protocol 1.3; older hosts report them as `other`).
  public static let localNetwork = Self(rawValue: OWLPermission.localNetwork.rawValue)
  /// A request type with no case of its own. Deny it.
  public static let other = Self(rawValue: OWLPermission.other.rawValue)
}

/// A permission request. The decision applies to every permission in it.
public final class WebPermissionRequest: WebPromptRequest {
  /// The requesting origin.
  public let origin: URL?
  /// What the page asked for.
  public let permissions: WebPermissions

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    origin = fields.string(.origin).flatMap(URL.init(string:))
    permissions = WebPermissions(rawValue: fields.u64(.permissions) ?? 0)
    super.init(id: id, webView: webView)
  }

  /// Grants the request.
  public func allow() { decide(.allow) }
  /// Denies the request.
  public func deny() { decide(.deny) }
  /// Closes the prompt without a decision; the page may ask again.
  public func dismiss() { decide(.dismiss) }

  private func decide(_ result: OWLPermissionResult) {
    reply(
      .permissionReply,
      WireEncoder()
        .u64(.permissionResult, result.rawValue)
        .u64(.permissions, result == .allow ? permissions.rawValue : 0))
  }
}

/// HTTP or proxy authentication.
public final class WebAuthRequest: WebPromptRequest {
  /// The origin that triggered it.
  public let origin: URL?
  /// The server or proxy host.
  public let host: String
  /// The port.
  public let port: Int
  /// The realm, possibly empty.
  public let realm: String
  /// The scheme, for example "basic" or "digest".
  public let scheme: String
  /// Whether a proxy asked.
  public let isProxy: Bool

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    origin = fields.string(.origin).flatMap(URL.init(string:))
    host = fields.string(.host) ?? ""
    port = Int(clamping: fields.u64(.port) ?? 0)
    realm = fields.string(.realm) ?? ""
    scheme = fields.string(.scheme) ?? ""
    isProxy = fields.bool(.isProxy)
    super.init(id: id, webView: webView)
  }

  /// Answers with credentials. They cross to the host once and are not stored by the web layer.
  public func respond(username: String, password: String) {
    reply(
      .authReply,
      WireEncoder().bool(.accepted, true).string(.username, username).string(.password, password))
  }

  /// Cancels; the load fails with an authentication error.
  public func cancel() {
    reply(.authReply, WireEncoder().bool(.accepted, false))
  }
}

/// A certificate error on a load. Show an interstitial; proceed only when allowed.
public final class WebCertificateErrorRequest: WebPromptRequest {
  /// The URL that failed.
  public let url: URL?
  /// Chromium's net error code, for example -202 (authority invalid).
  public let errorCode: Int
  /// What is wrong, in plain words.
  public let message: String
  /// The certificate subject.
  public let subject: String
  /// The certificate issuer.
  public let issuer: String
  /// The certificate validity.
  public let validFrom: Date?
  /// The certificate expiry.
  public let validUntil: Date?
  /// Whether Chromium lets the user proceed (false for HSTS hosts, for example).
  public let isOverridable: Bool

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    url = fields.string(.URL).flatMap(URL.init(string:))
    errorCode = Int(fields.i64(.errorCode) ?? 0)
    message = fields.string(.message) ?? ""
    subject = fields.string(.certSubject) ?? ""
    issuer = fields.string(.certIssuer) ?? ""
    validFrom = fields.double(.certValidStart).flatMap {
      $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
    }
    validUntil = fields.double(.certValidExpiry).flatMap {
      $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
    }
    isOverridable = fields.bool(.overridable)
    super.init(id: id, webView: webView)
  }

  /// Proceeds despite the error. Not overridable errors stay blocked and report
  /// `invalidArgument` on the view.
  public func proceed() {
    guard isOverridable else {
      webView?.lastError = .invalidArgument("This certificate error cannot be overridden.")
      webView?.changed()
      cancel()
      return
    }
    reply(.certificateReply, WireEncoder().bool(.accepted, true))
  }

  /// Stops the load; the page shows Chromium's error.
  public func cancel() {
    if isOverridable {
      reply(.certificateReply, WireEncoder().bool(.accepted, false))
    } else {
      finishLocally()
    }
  }
}

/// `<input type=color>`. The host blocks Chromium's own color panel and asks here instead.
public final class WebColorRequest: WebPromptRequest {
  /// The input's current value, "#rrggbb".
  public let initialColor: String

  init(id: UInt64, webView: WebView, fields: WireDecoder) {
    initialColor = fields.string(.color) ?? "#000000"
    super.init(id: id, webView: webView)
  }

  /// Sets the input to `hex` ("#rrggbb") and fires input and change events.
  public func choose(_ hex: String) {
    guard hex.count == 7, hex.first == "#",
      hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
    else {
      webView?.lastError = .invalidArgument("A color must be #rrggbb, not \(hex).")
      webView?.changed()
      cancel()
      return
    }
    reply(.colorReply, WireEncoder().bool(.accepted, true).string(.color, hex))
  }

  /// Leaves the input unchanged.
  public func cancel() {
    reply(.colorReply, WireEncoder().bool(.accepted, false))
  }
}
