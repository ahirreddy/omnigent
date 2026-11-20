import Foundation
public import Observation
public import OmnigentCoreFFI

/// The server's installed extensions (the web's `ExtensionProvider`): read once per connection,
/// they add sidebar entries and pages. A failed read leaves none, as on the web, and is kept for
/// the log.
@Observable
public final class ExtensionsStore {
  /// The enabled extensions; empty until read, or when the read failed.
  public private(set) var extensions: [Extension] = []
  /// The first read for this server and account is in flight, so a page link can't be resolved
  /// yet.
  public private(set) var isLoading = false
  /// Why the last read failed, until one succeeds.
  public private(set) var loadError: CoreError?

  private let core: ClientCore
  @ObservationIgnored private var owner: String?
  @ObservationIgnored private var generation = 0

  init(core: ClientCore) {
    self.core = core
  }

  /// The sidebar entries, by order then id, each with the page it opens.
  public var navigationEntries: [ExtensionNavigationEntry] {
    extensionNavigationEntries(extensions: extensions)
  }

  /// Extension `extensionID`'s page at `route`.
  /// - Parameters:
  ///   - extensionID: The extension.
  ///   - route: The page's path segment.
  /// - Returns: The extension and its page, when both exist.
  public func page(extensionID: String, route: String) -> (Extension, ExtensionPage)? {
    guard let extensionItem = extensions.first(where: { $0.id == extensionID }),
      let page = extensionItem.pages.first(where: { $0.route == route })
    else { return nil }
    return (extensionItem, page)
  }

  /// Forgets the extensions of another server or account; their read follows at once, so a
  /// link to a page waits for it rather than reading as not found.
  func belong(to owner: String) {
    guard owner != self.owner else { return }
    self.owner = owner
    generation += 1
    extensions = []
    loadError = nil
    isLoading = true
  }

  /// Reads the catalog; the extensions last read stay until it answers.
  /// - Returns: The extensions now known.
  @discardableResult
  public func reload() async -> [Extension] {
    let generation = generation
    if extensions.isEmpty { isLoading = true }
    defer { if generation == self.generation { isLoading = false } }
    do {
      let read = try await core.extensions()
      guard generation == self.generation else { return extensions }
      extensions = read
      loadError = nil
    } catch {
      guard generation == self.generation else { return extensions }
      loadError = coreError(error)
    }
    return extensions
  }
}
