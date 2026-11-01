internal import Foundation
internal import os

/// The controller answers everything an agent page asks for, without UI, and reports it.
extension AgentBrowserController: BrowserTabDelegate {
  /// Answers the prompt at once (see `autoAnswer(_:)`) and records it.
  public func tab(_ tab: any BrowserTab, didRequest prompt: BrowserPrompt) {
    var event = Self.autoAnswer(prompt)
    event["kind"] = .string(prompt.kindName)
    record(event, from: tab)
  }

  /// Records that the engine withdrew a prompt.
  public func tab(_ tab: any BrowserTab, didCancel prompt: BrowserPrompt) {
    record(["kind": .string(prompt.kindName), "response": .string("withdrawn")], from: tab)
  }

  /// Keeps the popup as the conversation's newest, active page.
  public func tab(_ tab: any BrowserTab, didOpen popup: BrowserPopup) {
    guard let session = session(containing: tab) else {
      logger.error("A popup opened from a tab this controller does not own; closing it.")
      popup.tab.close()
      return
    }
    session.pages.append(adopt(popup.tab))
    record(
      ["kind": .string("popup"), "url": .string(popup.targetURL?.absoluteString ?? "")], from: tab)
  }

  /// Records a popup the policy stopped.
  public func tab(_ tab: any BrowserTab, didBlock popup: BrowserBlockedPopup) {
    record(
      [
        "kind": .string("popup_blocked"), "url": .string(popup.url?.absoluteString ?? ""),
        "reason": .string(popup.reason),
      ], from: tab)
  }

  /// Cancels the download and records it.
  public func tab(_ tab: any BrowserTab, didStart download: BrowserDownload) {
    // Download prompts are cancelled, so this only runs if an engine starts one regardless.
    var event: [String: AgentJSONValue] = [
      "kind": .string("download"), "url": .string(download.url?.absoluteString ?? ""),
    ]
    do throws(BrowserError) {
      try download.cancel()
      event["response"] = .string("cancelled")
    } catch {
      logger.error(
        "Cancelling an agent download failed: \(error.localizedDescription, privacy: .public)")
      event["response"] = .string("cancel failed: \(error.localizedDescription)")
    }
    record(event, from: tab)
  }

  private func record(_ event: [String: AgentJSONValue], from tab: any BrowserTab) {
    guard let session = session(containing: tab) else {
      logger.error("A prompt arrived from a tab this controller does not own.")
      return
    }
    session.events.append(.object(event))
  }

  /// Answers `prompt` and describes it. Alerts are acknowledged; everything else is declined.
  static func autoAnswer(_ prompt: BrowserPrompt) -> [String: AgentJSONValue] {
    switch prompt {
    case .dialog(let dialog):
      if dialog.kind == .alert { dialog.accept() } else { dialog.cancel() }
      return [
        "type": .string(dialog.kind.rawValue), "message": .string(dialog.message),
        "response": .string(dialog.kind == .alert ? "accepted" : "dismissed"),
      ]
    case .permission(let permission):
      permission.deny()
      return [
        "origin": .string(permission.origin),
        "permissions": .array(permission.permissions.names.map(AgentJSONValue.string)),
        "response": .string("denied"),
      ]
    case .fileChooser(let chooser):
      chooser.cancel()
      return ["response": .string("cancelled")]
    case .download(let download):
      download.cancel()
      return ["url": .string(download.url?.absoluteString ?? ""), "response": .string("cancelled")]
    case .authentication(let auth):
      auth.cancel()
      return ["host": .string(auth.space.host), "response": .string("cancelled")]
    case .certificateError(let certificate):
      certificate.cancel()
      return [
        "url": .string(certificate.url?.absoluteString ?? ""),
        "message": .string(certificate.message), "response": .string("cancelled"),
      ]
    case .color(let color):
      color.cancel()
      return ["response": .string("cancelled")]
    }
  }
}
