import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A new sandbox's choices on the new-session page and the fork sheet, as the web offers them:
/// the provider row chosen in the Host picker, the repositories it clones and the profile it
/// launches with. The rules (limits, validation, profile requirements) are the core's.
struct SandboxChoices: Equatable {
  /// The provider; `nil` takes the server's default.
  var provider: String?
  /// Repositories to clone.
  var repos: [SandboxRepoChoice] = []
  /// The profile to launch with.
  var profile: SandboxProfileOption?

  /// The chosen sandbox row, or the first when the chosen provider is no longer offered.
  func option(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> SandboxProviderOption? {
    guard let catalog else { return nil }
    let options = sandboxProviderOptions(catalog: catalog)
    return options.first { $0.provider == provider } ?? options.first
  }

  /// The provider whose profiles apply: the chosen one, else the server's default.
  func profileProvider(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> String? {
    guard let catalog, catalog.sandboxProfiles, catalog.managedSandboxes else { return nil }
    return option(catalog)?.provider ?? catalog.defaultSandboxProvider
  }

  /// Why the sandbox cannot start yet: repositories it would refuse, or a profile to choose.
  func problem(_ catalog: OmnigentCoreFFI.CreationCatalog?, sandboxes: SandboxStore?) -> String? {
    if let problem = sandboxReposProblem(
      repos: repos.map(Self.repo), max: option(catalog)?.maxRepos ?? 1)
    {
      return problem
    }
    guard let provider = profileProvider(catalog) else { return nil }
    switch sandboxes?.profiles[provider] {
    case .loaded(let page):
      return sandboxProfileProblem(
        page: page, provider: provider,
        selected: profile.map { Self.profile($0, provider: provider) })
    case .failed: return "Could not load sandbox profiles. Try again."
    case .idle, .loading, nil: return "Loading sandbox profiles\u{2026}"
    }
  }

  /// The sandbox a new session starts on.
  func target(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> SandboxTarget {
    SandboxTarget(
      provider: option(catalog)?.provider, profile: chosenProfile(catalog),
      workspaces: composeSandboxWorkspaces(repos: repos.map(Self.repo)))
  }

  /// The chosen profile for the core, when the provider uses profiles.
  func chosenProfile(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> SandboxProfile? {
    profileProvider(catalog).flatMap { provider in
      profile.map { Self.profile($0, provider: provider) }
    }
  }

  /// The repository picker's state.
  func repositoriesState(
    _ catalog: OmnigentCoreFFI.CreationCatalog?, sandboxes: SandboxStore?
  ) -> SandboxRepositoriesState {
    let github = catalog?.githubConnection == true ? sandboxes?.githubRepos : nil
    let list = github?.value
    let max = option(catalog)?.maxRepos ?? 1
    var githubError: String?
    if case .failed(let error) = github { githubError = error.message }
    return SandboxRepositoriesState(
      repos: repos, maxRepos: Int(max),
      githubRepos: list?.connected == true ? list?.repos.map(Self.githubOption) ?? [] : [],
      githubTruncated: list?.truncated ?? false, githubError: githubError,
      branches: (sandboxes?.branches ?? [:]).compactMapValues(\.value),
      problem: sandboxReposProblem(repos: repos.map(Self.repo), max: max))
  }

  /// The profile picker's state, when the provider launches with a profile.
  func profilesState(
    _ catalog: OmnigentCoreFFI.CreationCatalog?, sandboxes: SandboxStore?
  ) -> SandboxProfilesState? {
    guard let provider = profileProvider(catalog) else { return nil }
    let load = sandboxes?.profiles[provider]
    if let page = load?.value, !page.managedProviders.contains(provider) { return nil }
    var error: String?
    if case .failed(let failure) = load { error = failure.message }
    return SandboxProfilesState(
      profiles: load?.value?.profiles.map(Self.profileOption) ?? [], selected: profile,
      isLoading: load?.value == nil && error == nil, error: error,
      hasMore: load?.value?.hasMore ?? false)
  }

  /// Reads what the chosen sandbox offers: its profiles and the caller's GitHub repositories.
  func load(_ catalog: OmnigentCoreFFI.CreationCatalog?, sandboxes: SandboxStore) async {
    if catalog?.githubConnection == true { await sandboxes.loadGithubRepos() }
    if let provider = profileProvider(catalog) { await sandboxes.loadProfiles(provider) }
  }

  /// The repository picker's actions; `set` stores the new list.
  static func repositoryActions(
    _ sandboxes: SandboxStore?, set: @escaping @MainActor ([SandboxRepoChoice]) -> Void
  ) -> SandboxRepositoriesActions {
    SandboxRepositoriesActions(
      setRepos: set,
      urlProblem: { url, chosen in sandboxUrlProblem(url: url, selected: chosen.map(repo)) },
      branchProblem: { sandboxBranchProblem(url: $0, branch: $1) },
      repoName: { sandboxRepoName(url: $0) },
      isSameRepo: { isSameSandboxRepo(first: $0, second: $1) },
      loadBranches: { fullName in Task { await sandboxes?.loadBranches(fullName) } })
  }

  /// The profile picker's actions for `provider`; `select` stores the choice.
  static func profileActions(
    _ provider: String?, sandboxes: SandboxStore?,
    select: @escaping @MainActor (SandboxProfileOption) -> Void
  ) -> SandboxProfilesActions? {
    guard let provider, let sandboxes else { return nil }
    return SandboxProfilesActions(
      select: select,
      search: { text in
        await sandboxes.searchProfiles(provider, text: text)
          .map { $0.profiles.map(profileOption) }
          .mapError { FolderBrowseError(message: $0.message) }
      },
      retry: { Task { await sandboxes.loadProfiles(provider) } })
  }

  static func repo(_ choice: SandboxRepoChoice) -> SandboxRepo {
    SandboxRepo(url: choice.url, branch: choice.branch)
  }

  static func profile(_ option: SandboxProfileOption, provider: String) -> SandboxProfile {
    SandboxProfile(
      id: option.id, name: option.name, description: option.description, provider: provider,
      revision: option.revision)
  }

  static func profileOption(_ profile: SandboxProfile) -> SandboxProfileOption {
    SandboxProfileOption(
      id: profile.id, name: profile.name, description: profile.description,
      revision: profile.revision)
  }

  static func githubOption(_ repo: GithubRepo) -> GithubRepoOption {
    GithubRepoOption(
      fullName: repo.fullName, cloneURL: repo.cloneUrl, defaultBranch: repo.defaultBranch,
      isPrivate: repo.isPrivate)
  }
}
