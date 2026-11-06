public import Foundation

/// What a compact address pill shows while it is not being edited: the domain only, as Safari
/// does, with whether the page is secure.
nonisolated public struct BrowserAddressDisplay: Hashable, Sendable {
  /// The domain without `www.`, or the whole address when it has no host; empty for no page.
  public var domain: String
  /// Whether the page was loaded over HTTPS.
  public var isSecure: Bool

  /// Whether there is no page, so the pill offers "Search or enter website".
  public var isEmpty: Bool { domain.isEmpty }

  /// The display for a page address.
  /// - Parameter url: The page's URL as text.
  public init(url: String) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "about:blank" else {
      domain = ""
      isSecure = false
      return
    }
    let parsed = URL(string: trimmed)
    isSecure = parsed?.scheme?.lowercased() == "https"
    guard let host = parsed?.host(percentEncoded: false), !host.isEmpty else {
      domain = trimmed
      return
    }
    let lowered = host.lowercased()
    domain = lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
  }

  /// The display for a page URL; `nil` is no page.
  /// - Parameter url: The page's URL.
  public init(url: URL?) {
    self.init(url: url?.absoluteString ?? "")
  }
}
