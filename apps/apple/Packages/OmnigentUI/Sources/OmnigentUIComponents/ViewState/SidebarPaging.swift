import Foundation

/// The sidebar's paging: the main list's "Load more" and each project folder's pages.
nonisolated public struct SidebarPaging: Hashable, Sendable {
  /// More sessions exist on the server after the loaded ones.
  public var hasMore: Bool
  /// A page of them is loading.
  public var isLoading: Bool
  /// Folders whose first page was read, by folder id.
  public var loadedProjects: Set<String>
  /// Folders with members left on the server, by folder id.
  public var projectsWithMore: Set<String>
  /// Folders reading a page, by folder id.
  public var loadingProjects: Set<String>

  /// Creates paging state.
  /// - Parameters:
  ///   - hasMore: More sessions exist.
  ///   - isLoading: A page is loading.
  ///   - loadedProjects: Folders whose first page was read.
  ///   - projectsWithMore: Folders with members left.
  ///   - loadingProjects: Folders reading a page.
  public init(
    hasMore: Bool = false, isLoading: Bool = false, loadedProjects: Set<String> = [],
    projectsWithMore: Set<String> = [], loadingProjects: Set<String> = []
  ) {
    self.hasMore = hasMore
    self.isLoading = isLoading
    self.loadedProjects = loadedProjects
    self.projectsWithMore = projectsWithMore
    self.loadingProjects = loadingProjects
  }
}

/// How many rows a folder shows per Show more, as the web's.
nonisolated enum ProjectFolderPaging {
  static let pageSize = 5

  /// The folder's rows: `shown` of its loaded sessions, rounded up to keep the open session
  /// visible (the web never leaves it hidden).
  /// - Parameters:
  ///   - count: Loaded members.
  ///   - shown: Rows Show more has revealed.
  ///   - selectedIndex: The open session's index among the members, if it is one.
  /// - Returns: How many rows to list.
  static func visibleCount(count: Int, shown: Int, selectedIndex: Int?) -> Int {
    var limit = max(shown, pageSize)
    if let selectedIndex, selectedIndex >= limit {
      limit += ((selectedIndex + 1 - limit + pageSize - 1) / pageSize) * pageSize
    }
    return min(count, limit)
  }
}
