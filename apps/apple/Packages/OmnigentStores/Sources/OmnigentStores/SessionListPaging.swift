public import Observation
public import OmnigentCoreFFI

/// Which pages of sessions are loaded beyond the list's first: the sidebar's and the Inbox's
/// "Load more" (the core's list window, reported by `SessionListPagingChanged`), and each
/// project folder's own pages (`?project=`, as the web's folders read them), which the core
/// reads for the open folders and reports by `ProjectFoldersChanged`. Loaded sessions reach
/// ``SessionListStore`` as list upserts.
@Observable
public final class SessionListPaging {
  /// One project folder's pages.
  public struct ProjectPages: Equatable, Sendable {
    /// The folder's first page was read.
    public var isLoaded = false
    /// Members exist after the loaded pages.
    public var hasMoreAfter = false
    /// A page is loading.
    public var isLoading = false

    /// More members exist on the server.
    public var hasMore: Bool { !isLoaded || hasMoreAfter }
  }

  /// More sessions exist after the loaded ones.
  public private(set) var hasMore = false
  /// A page of them is loading.
  public private(set) var isLoading = false
  /// Project folders' pages, by folder id (the core's `projectFolderId`).
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

  /// Loads a folder's first page, or its next one once that was read. The core reads nothing
  /// while a page is loading, for a first page it read already, or once every member is loaded.
  /// - Parameter project: The folder's project.
  public func loadProject(_ project: ProjectSummary) {
    let isLoaded = projects[projectFolderId(project: project)]?.isLoaded == true
    core?.loadProjectFolder(project: project, next: isLoaded)
  }

  /// Tells the core which folders the sidebar shows open, so it reads their first pages as soon
  /// as the projects are known and keeps them through list reloads.
  /// - Parameter folderIDs: The open folders.
  public func setOpenFolders(_ folderIDs: Set<String>) {
    core?.setOpenProjectFolders(folderIds: folderIDs.sorted())
  }

  func pagingChanged(hasMore: Bool, isLoading: Bool) {
    if hasMore != self.hasMore { self.hasMore = hasMore }
    if isLoading != self.isLoading { self.isLoading = isLoading }
  }

  func foldersChanged(_ folders: [ProjectFolderPaging]) {
    let pages = Dictionary(
      folders.map { folder in
        (
          folder.folderId,
          ProjectPages(
            isLoaded: folder.isLoaded, hasMoreAfter: folder.hasMoreAfter,
            isLoading: folder.isLoading)
        )
      }, uniquingKeysWith: { _, last in last })
    if pages != projects { projects = pages }
  }

  func clear() {
    pagingChanged(hasMore: false, isLoading: false)
    if !projects.isEmpty { projects = [:] }
  }
}
