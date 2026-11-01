internal import Foundation
internal import OWLProtocol
internal import os

/// Views the host creates on its own initiative (protocol 1.1).
extension Session {
  /// The host created a view for a page's window.open, target=_blank or modified link click.
  func adoptPopup(_ message: IncomingMessage) {
    let fields = message.fields
    guard let openerID = fields.u64(.openerID), let opener = views[openerID],
      opener.status != .closed, views[message.target] == nil
    else {
      Logger.session.error("Popup \(message.target) has no live opener; closing it.")
      do {
        try post(.viewClose, target: message.target)
      } catch {
        lastProtocolError = error
      }
      return
    }
    let url = fields.string(.URL).flatMap(URL.init(string:))
    let popup = WebView(profile: opener.profile, id: message.target, initialURL: url)
    popup.opener = opener
    popup.status = .creating
    popup.popupPolicy = opener.popupPolicy
    popup.navigationRules = opener.navigationRules
    var requested: CGSize?
    if let width = fields.double(.width), let height = fields.double(.height) {
      requested = CGSize(width: width, height: height)
      popup.size = CGSize(width: width, height: height)
    }
    views[popup.id] = popup
    opener.didOpen(
      WebPopup(
        webView: popup, opener: opener, targetURL: url,
        disposition: WebPopupDisposition(wire: fields.u64(.disposition) ?? 0),
        userGesture: fields.bool(.userGesture), frameName: fields.string(.frameName) ?? "",
        requestedSize: requested))
  }
}
