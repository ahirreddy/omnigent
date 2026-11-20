import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Nests picker's server search for one session (the web's `NestPickerMenu`): sessions the
/// viewer owns whose title matches, a page at a time, read once typing pauses.
@MainActor
@Observable
final class NestPickerFlow: Identifiable {
  /// Reads a page of title matches after a cursor.
  typealias Search = @MainActor (String, String?) async throws(CoreError) -> SessionSearchPage

  /// The session that moves.
  let session: OmnigentUIComponents.SessionSummary
  /// The typed text; the server is asked once it rests for the debounce.
  var query = "" {
    didSet { if query != oldValue { schedule() } }
  }
  /// What the server found.
  private(set) var results = NestSearchResults()
  @ObservationIgnored private var cursor: String?
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var reading: Task<Void, Never>?
  @ObservationIgnored private let search: Search
  @ObservationIgnored private let isOwned: @MainActor (OmnigentCoreFFI.SessionSummary) -> Bool
  @ObservationIgnored private let debounce: Duration

  nonisolated var id: String { session.id }

  /// Creates the search.
  /// - Parameters:
  ///   - session: The session that moves.
  ///   - debounce: How long typing rests before the server is asked.
  ///   - search: Reads a page of title matches.
  ///   - isOwned: Whether the viewer owns a match; only their own nests are offered.
  init(
    session: OmnigentUIComponents.SessionSummary, debounce: Duration = .milliseconds(300),
    search: @escaping Search, isOwned: @escaping @MainActor (OmnigentCoreFFI.SessionSummary) -> Bool
  ) {
    self.session = session
    self.debounce = debounce
    self.search = search
    self.isOwned = isOwned
  }

  /// Reads the next page of matches, or the page that failed again.
  func more() {
    guard !results.isSearching, results.hasMore || results.failed, !results.query.isEmpty
    else { return }
    read(results.query)
  }

  /// Stops any read; the picker closed.
  func close() {
    pending?.cancel()
    reading?.cancel()
  }

  private func schedule() {
    pending?.cancel()
    let text = query.trimmingCharacters(in: .whitespaces)
    guard text != results.query else { return }
    let debounce = debounce
    pending = Task { [weak self] in
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      self?.start(text)
    }
  }

  private func start(_ text: String) {
    reading?.cancel()
    cursor = nil
    results = NestSearchResults(query: text)
    if !text.isEmpty { read(text) }
  }

  private func read(_ text: String) {
    let after = cursor
    results.isSearching = true
    results.failed = false
    reading = Task { [weak self] in
      guard let self else { return }
      let outcome: Result<SessionSearchPage, CoreError>
      do throws(CoreError) {
        outcome = .success(try await search(text, after))
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, results.query == text else { return }
      results.isSearching = false
      switch outcome {
      case .success(let page):
        results.found += page.sessions.filter(isOwned).map(OmnigentUIComponents.SessionSummary.init)
        cursor = page.nextCursor
        results.hasMore = page.nextCursor != nil
      case .failure:
        results.failed = true
      }
    }
  }
}
