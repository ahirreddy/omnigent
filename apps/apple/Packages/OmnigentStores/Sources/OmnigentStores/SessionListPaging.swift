public import Observation
public import OmnigentCoreFFI

/// Which pages of sessions are loaded beyond the list's first: the sidebar's and the Inbox's
/// "Load more" (the core's list window, reported by `SessionListPagingChanged`), and each
/// project folder's own pages (`?project=`), as the web's folders read them. Loaded sessions
/// reach ``SessionListStore`` as list upserts.
@Observable
public final class SessionListPaging {
  /// One project folder's pages.
  public struct ProjectPages: Equatable, Sendable {
    /// The folder's first page was read.
    public var isLoaded = false
    /// The cursor of its next page; `nil` once every member is loaded.
    public var nextCursor: String?
    /// A page is loading.
    public var isLoading = false

    /// More members exist on the server.
    public var hasMore: Bool { !isLoaded || nextCursor != nil }
  }

  /// More sessions exist after the loaded ones.
  public private(set) var hasMore = false
  /// A page of them is loading.
  public private(set) var isLoading = false
  /// Project folders' pages, by folder id.
  public private(set) var projects: [String: ProjectPages] = [:]

  /// The core pages load through; set by the owning ``ConnectionStore``.
  @ObservationIgnored var core: ClientCore?
  /// Reports a failed folder read where list edit failures show.
  @ObservationIgnored var reportFailure: (CoreError) -> Void = { _ in }

  /// Creates paging with nothing loaded beyond the first page.
  public init() {}

  /// Loads the page of sessions after the loaded ones, unless none remain or one is loading.
  /// ``isLoading`` follows the core's report, which a second request before it arrives cannot
  /// double (the core reads one page at a time).
  public func loadMore() {
    guard hasMore, !isLoading, let core else { return }
    core.loadMoreSessions()
  }

  /// Loads a folder's first page, or its next one once that was read. Nothing happens while a
  /// page is loading or once every member is loaded.
  /// - Parameters:
  ///   - project: The folder's project.
  ///   - id: The folder id.
  public func loadProject(_ project: ProjectSummary, id: String) async {
    var pages = projects[id] ?? ProjectPages()
    guard pages.hasMore, !pages.isLoading, let core else { return }
    pages.isLoading = true
    projects[id] = pages
    do {
      let page = try await core.projectSessions(
        project: project, after: pages.isLoaded ? pages.nextCursor : nil)
      pages.isLoaded = true
      pages.nextCursor = page.nextCursor
    } catch {
      reportFailure(coreError(error))
    }
    pages.isLoading = false
    // A list reload while reading dropped the folder's pages; they start again.
    if projects[id] != nil { projects[id] = pages }
  }

  func pagingChanged(hasMore: Bool, isLoading: Bool) {
    if hasMore != self.hasMore { self.hasMore = hasMore }
    if isLoading != self.isLoading { self.isLoading = isLoading }
  }

  /// The list reloaded only its own pages: folders read theirs again.
  func listReset() {
    if !projects.isEmpty { projects = [:] }
  }

  func clear() {
    pagingChanged(hasMore: false, isLoading: false)
    listReset()
  }
}
