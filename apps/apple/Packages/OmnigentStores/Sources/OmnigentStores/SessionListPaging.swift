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
  /// Why a folder's last read failed, by folder id, until it reads again.
  public private(set) var folderFailures: [String: CoreError] = [:]
  /// The folders the sidebar shows open.
  @ObservationIgnored private var sidebarFolders: Set<String> = []
  /// The folders whose board is shown; they stay loaded as an open folder does.
  @ObservationIgnored private var boardFolders: [String: Int] = [:]

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
    let folderID = projectFolderId(project: project)
    let isLoaded = projects[folderID]?.isLoaded == true
    if folderFailures[folderID] != nil { folderFailures[folderID] = nil }
    core?.loadProjectFolder(project: project, next: isLoaded)
  }

  /// Tells the core which folders the sidebar shows open, so it reads their first pages as soon
  /// as the projects are known and keeps them through list reloads.
  /// - Parameter folderIDs: The open folders.
  public func setOpenFolders(_ folderIDs: Set<String>) {
    sidebarFolders = folderIDs
    reportOpenFolders()
  }

  /// A project's board shows (`true`) or leaves: while any board of it shows, the core keeps its
  /// folder's pages through list reloads, as it does an open folder's.
  /// - Parameters:
  ///   - folderID: The board's folder.
  ///   - isShown: Whether the board shows.
  public func setBoardShown(_ folderID: String, _ isShown: Bool) {
    let count = (boardFolders[folderID] ?? 0) + (isShown ? 1 : -1)
    boardFolders[folderID] = count > 0 ? count : nil
    reportOpenFolders()
  }

  /// The folders the core keeps read: open in the sidebar, or with a board shown.
  var openFolderIDs: Set<String> { sidebarFolders.union(boardFolders.keys) }

  private func reportOpenFolders() {
    core?.setOpenProjectFolders(folderIds: openFolderIDs.sorted())
  }

  func folderFailed(_ folderID: String, _ error: CoreError) {
    folderFailures[folderID] = error
    reportFailure(error)
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
    let read = folders.filter { $0.isLoaded || $0.isLoading }.map(\.folderId)
    for folderID in read where folderFailures[folderID] != nil { folderFailures[folderID] = nil }
  }

  func clear() {
    pagingChanged(hasMore: false, isLoading: false)
    if !projects.isEmpty { projects = [:] }
    if !folderFailures.isEmpty { folderFailures = [:] }
  }
}
