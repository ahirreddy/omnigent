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
  static let pageSize = 10
  /// Show all: every member, and every page read.
  static let all = Int.max

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

/// The projects whose open folder lists every session (the project menu's Show All Sessions),
/// kept across launches.
nonisolated enum ProjectShowAll {
  static let key = "omnigent:sidebar-show-all-projects"

  static func shows(_ projectID: String, in defaults: UserDefaults = .standard) -> Bool {
    ids(in: defaults).contains(projectID)
  }

  /// The rows a folder lists before any Show more: all of them, or one page.
  static func shown(_ projectID: String, in defaults: UserDefaults = .standard) -> Int {
    shows(projectID, in: defaults) ? ProjectFolderPaging.all : 0
  }

  static func set(_ projectID: String, _ isOn: Bool, in defaults: UserDefaults = .standard) {
    var ids = ids(in: defaults)
    if isOn { ids.insert(projectID) } else { ids.remove(projectID) }
    defaults.set(ids.sorted().joined(separator: "\n"), forKey: key)
  }

  private static func ids(in defaults: UserDefaults) -> Set<String> {
    Set((defaults.string(forKey: key) ?? "").split(separator: "\n").map(String.init))
  }
}
