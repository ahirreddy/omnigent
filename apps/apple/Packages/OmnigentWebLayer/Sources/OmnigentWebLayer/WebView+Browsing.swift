public import Foundation
internal import OWLProtocol
internal import os

/// One entry of a view's back/forward list.
nonisolated public struct WebNavigationEntry: Sendable, Hashable, Codable {
  /// The entry's URL.
  public let url: URL
  /// The entry's title, empty when unknown.
  public let title: String

  /// Creates an entry.
  public init(url: URL, title: String) {
    self.url = url
    self.title = title
  }
}

/// A view's back/forward list (protocol 1.2).
nonisolated public struct WebNavigationHistory: Sendable, Hashable, Codable {
  /// Every entry, oldest first.
  public let entries: [WebNavigationEntry]
  /// The current entry's index in `entries`.
  public let currentIndex: Int

  /// Creates a list; `currentIndex` is clamped to the entries.
  public init(entries: [WebNavigationEntry], currentIndex: Int) {
    self.entries = entries
    self.currentIndex = entries.isEmpty ? 0 : min(max(0, currentIndex), entries.count - 1)
  }

  /// Parses the NavigationHistory JSON (owl_protocol.h). Entries whose URL does not parse are
  /// dropped and the index adjusted.
  static func parse(json: String) throws(WebLayerError) -> Self {
    let wire: WireNavigationHistory
    do {
      wire = try JSONDecoder().decode(WireNavigationHistory.self, from: Data(json.utf8))
    } catch {
      throw .invalidArgument("NavigationHistory JSON is malformed: \(error.localizedDescription)")
    }
    var entries: [WebNavigationEntry] = []
    var current = 0
    for (index, entry) in wire.entries.enumerated() {
      guard let url = URL(string: entry.url) else { continue }
      if index <= wire.index { current = entries.count }
      entries.append(WebNavigationEntry(url: url, title: entry.title ?? ""))
    }
    return Self(entries: entries, currentIndex: current)
  }
}

/// The NavigationHistory JSON (owl_protocol.h).
nonisolated private struct WireNavigationHistory: Decodable {
  let index: Int
  let entries: [WireNavigationEntry]
}

nonisolated private struct WireNavigationEntry: Decodable {
  let url: String
  let title: String?
}

/// Browsing state from 1.2 hosts: favicons, history, audio.
extension WebView {
  /// Mutes or unmutes the view's audio. Remembered and applied once the view exists; ignored by
  /// hosts before 1.2, which `featureBlocked` reports.
  public func setAudioMuted(_ muted: Bool) {
    guard muted != isAudioMuted else { return }
    isAudioMuted = muted
    if status == .live { sendMuted() }
    changed()
  }

  func sendMuted() {
    guard session.supportsBrowsing else {
      lastError = .featureBlocked(
        feature: "Muting a tab", detail: "The Chromium web host is older than protocol 1.2.")
      onEvent?(.featureBlocked(feature: "Muting a tab", detail: "Host protocol before 1.2."))
      return
    }
    send(.setAudioMuted, WireEncoder().bool(.muted, isAudioMuted))
  }

  /// Handles 1.2 view events; false for anything else.
  func handleBrowsing(_ kind: OWLMessageKind, _ fields: WireDecoder) -> Bool {
    switch kind {
    case .faviconURLChanged:
      do {
        let strings = try JSONDecoder().decode(
          [String].self, from: Data((fields.string(.JSON) ?? "[]").utf8))
        faviconURLs = strings.compactMap(URL.init(string:))
      } catch {
        Logger.view.error("View \(self.id) got malformed favicon URLs.")
        lastError = .invalidArgument(
          "FaviconURLChanged JSON is malformed: \(error.localizedDescription)")
      }
    case .navigationHistory:
      do throws(WebLayerError) {
        navigationHistory = try WebNavigationHistory.parse(json: fields.string(.JSON) ?? "")
      } catch {
        Logger.view.error(
          "View \(self.id) got bad history: \(error.localizedDescription, privacy: .public)")
        lastError = error
      }
    case .audioStateChanged:
      isAudible = fields.bool(.audible)
      isAudioMuted = fields.bool(.muted)
    default:
      return false
    }
    return true
  }
}
