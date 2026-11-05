import Foundation

/// One repository a new sandbox clones.
nonisolated public struct SandboxRepoChoice: Hashable, Sendable, Identifiable {
  /// Clone URL.
  public var url: String
  /// Branch; empty for the repository's default.
  public var branch: String

  /// The URL.
  public var id: String { url }

  /// Creates a choice.
  public init(url: String, branch: String = "") {
    self.url = url
    self.branch = branch
  }
}

/// A repository the caller's GitHub connection sees.
nonisolated public struct GithubRepoOption: Hashable, Sendable, Identifiable {
  /// `owner/name`.
  public var fullName: String
  /// Clone URL.
  public var cloneURL: String
  /// Default branch.
  public var defaultBranch: String?
  /// Private.
  public var isPrivate: Bool

  /// The full name.
  public var id: String { fullName }

  /// Creates an option.
  public init(fullName: String, cloneURL: String, defaultBranch: String?, isPrivate: Bool) {
    self.fullName = fullName
    self.cloneURL = cloneURL
    self.defaultBranch = defaultBranch
    self.isPrivate = isPrivate
  }
}

/// The sandbox repository picker (the web's `SandboxRepositoryPicker`): the chosen
/// repositories with their branches, the caller's GitHub repositories to add, and a URL field.
nonisolated public struct SandboxRepositoriesState: Hashable, Sendable {
  /// The chosen repositories, in clone order.
  public var repos: [SandboxRepoChoice]
  /// How many the provider clones.
  public var maxRepos: Int
  /// GitHub repositories to add; empty when GitHub is not connected.
  public var githubRepos: [GithubRepoOption]
  /// More GitHub repositories exist than are listed.
  public var githubTruncated: Bool
  /// Why the GitHub repositories could not be read.
  public var githubError: String?
  /// Branch names by GitHub `owner/name`, once read.
  public var branches: [String: [String]]
  /// Notes about a repository's branch, by URL (a fork's unpushed branch).
  public var notes: [String: String]
  /// Why the repositories cannot start a sandbox.
  public var problem: String?

  /// Creates state.
  public init(
    repos: [SandboxRepoChoice] = [], maxRepos: Int = 1, githubRepos: [GithubRepoOption] = [],
    githubTruncated: Bool = false, githubError: String? = nil, branches: [String: [String]] = [:],
    notes: [String: String] = [:], problem: String? = nil
  ) {
    self.repos = repos
    self.maxRepos = maxRepos
    self.githubRepos = githubRepos
    self.githubTruncated = githubTruncated
    self.githubError = githubError
    self.branches = branches
    self.notes = notes
    self.problem = problem
  }

  /// The chip's label: none, the one repository's name, or a count.
  public func label(name: (String) -> String) -> String {
    switch repos.count {
    case 0: "No repository"
    case 1: name(repos[0].url)
    default: "\(repos.count) repositories"
    }
  }
}

/// The repository picker's actions.
public struct SandboxRepositoriesActions {
  /// Replace the chosen repositories.
  public var setRepos: @MainActor ([SandboxRepoChoice]) -> Void
  /// Why a typed URL cannot be added to the chosen ones.
  public var urlProblem: @MainActor (String, [SandboxRepoChoice]) -> String?
  /// Why a branch of a repository cannot be used.
  public var branchProblem: @MainActor (_ url: String, _ branch: String) -> String?
  /// A repository's display name.
  public var repoName: @MainActor (String) -> String
  /// Whether two URLs name the same repository.
  public var isSameRepo: @MainActor (String, String) -> Bool
  /// Read a GitHub repository's branches.
  public var loadBranches: (@MainActor (String) -> Void)?

  /// Creates actions.
  public init(
    setRepos: @escaping @MainActor ([SandboxRepoChoice]) -> Void,
    urlProblem: @escaping @MainActor (String, [SandboxRepoChoice]) -> String?,
    branchProblem: @escaping @MainActor (String, String) -> String?,
    repoName: @escaping @MainActor (String) -> String,
    isSameRepo: @escaping @MainActor (String, String) -> Bool,
    loadBranches: (@MainActor (String) -> Void)? = nil
  ) {
    self.setRepos = setRepos
    self.urlProblem = urlProblem
    self.branchProblem = branchProblem
    self.repoName = repoName
    self.isSameRepo = isSameRepo
    self.loadBranches = loadBranches
  }
}

/// A server-defined sandbox profile.
nonisolated public struct SandboxProfileOption: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// Name.
  public var name: String
  /// Description; may be empty.
  public var description: String
  /// The revision a launch pins.
  public var revision: String

  /// Creates an option.
  public init(id: String, name: String, description: String = "", revision: String) {
    self.id = id
    self.name = name
    self.description = description
    self.revision = revision
  }
}

/// The sandbox profile picker (the web's `SandboxProfilePicker`), shown when the provider's
/// sandboxes launch with a profile.
nonisolated public struct SandboxProfilesState: Hashable, Sendable {
  /// The provider's first profiles.
  public var profiles: [SandboxProfileOption]
  /// The chosen profile.
  public var selected: SandboxProfileOption?
  /// The list is loading.
  public var isLoading: Bool
  /// Why the list could not be read.
  public var error: String?
  /// More match than are listed.
  public var hasMore: Bool

  /// Creates state.
  public init(
    profiles: [SandboxProfileOption] = [], selected: SandboxProfileOption? = nil,
    isLoading: Bool = false, error: String? = nil, hasMore: Bool = false
  ) {
    self.profiles = profiles
    self.selected = selected
    self.isLoading = isLoading
    self.error = error
    self.hasMore = hasMore
  }

  /// The chip's label.
  public var label: String {
    if let selected { return selected.name }
    if isLoading { return "Loading profiles\u{2026}" }
    if error != nil { return "Profiles unavailable" }
    return profiles.isEmpty ? "No profiles available" : "Choose profile"
  }
}

/// The profile picker's actions.
public struct SandboxProfilesActions {
  /// Choose a profile.
  public var select: @MainActor (SandboxProfileOption) -> Void
  /// Profiles matching a search.
  public var search:
    (@MainActor (String) async -> Result<[SandboxProfileOption], FolderBrowseError>)?
  /// Read the list again after a failure.
  public var retry: (@MainActor () -> Void)?

  /// Creates actions.
  public init(
    select: @escaping @MainActor (SandboxProfileOption) -> Void,
    search: (@MainActor (String) async -> Result<[SandboxProfileOption], FolderBrowseError>)? =
      nil,
    retry: (@MainActor () -> Void)? = nil
  ) {
    self.select = select
    self.search = search
    self.retry = retry
  }
}
