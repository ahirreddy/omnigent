import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The fork sheet's new sandbox, as the web's ForkSessionDialog offers it: one row per
/// provider, the original's repositories moved to their current pushed branches, and the
/// profile (the original's when it launched with one).
extension ForkFlow {
  /// A provider was chosen: read its profiles, the caller's GitHub repositories, and once the
  /// original's repositories on their current branches.
  func sandboxSelected(_ provider: String?) async {
    guard let context, let store else { return }
    if sandbox.provider != provider { sandbox.profile = nil }
    sandbox.provider = provider
    async let offers: Void = sandbox.load(store.catalog.value, sandboxes: store.sandboxes)
    async let repos: Void = seedRepos(store, sourceID: context.source.id)
    _ = await (offers, repos)
  }

  private func seedRepos(_ store: ForkStore, sourceID: String) async {
    await store.sandboxes.loadForkDefaults(sourceID)
    guard !isSandboxSeeded, let defaults = store.sandboxes.forkDefaults[sourceID] else { return }
    switch defaults {
    case .loaded(let value):
      sandbox.repos = value.repos.map { SandboxRepoChoice(url: $0.url, branch: $0.branch) }
      if sandbox.profile == nil, let profile = value.profile {
        sandbox.profile = SandboxChoices.profileOption(profile)
      }
      isSandboxSeeded = true
    case .failed:
      // The original could not be read: the copy inherits its repositories unchanged.
      isSandboxSeeded = true
    case .idle, .loading: break
    }
  }

  /// Fills the sheet's sandbox rows, repositories and profile.
  func applySandboxOptions(to options: inout ForkOptions, store: ForkStore, sourceID: String) {
    let catalog = store.catalog.value
    options.sandboxes = (catalog.map { sandboxProviderOptions(catalog: $0) } ?? []).map {
      ForkSandboxOption(provider: $0.provider, label: $0.label)
    }
    var repositories = sandbox.repositoriesState(catalog, sandboxes: store.sandboxes)
    switch store.sandboxes.forkDefaults[sourceID] {
    case .loaded(let defaults):
      repositories.notes = Dictionary(
        defaults.notes.map { ($0.url, $0.note) }, uniquingKeysWith: { first, _ in first })
    case .failed(let error):
      repositories.githubError = "The original's repositories could not be read: \(error.message)"
    case .idle, .loading, nil: break
    }
    options.repositories = repositories
    options.isCheckingBranches = !isSandboxSeeded
    options.profiles = sandbox.profilesState(catalog, sandboxes: store.sandboxes)
    options.sandboxProblem = sandbox.problem(catalog, sandboxes: store.sandboxes)
  }

  /// The sandbox part of the request: the chosen provider, the repositories (the original's
  /// unchanged when they could not be read) and the profile.
  func sandboxRequest(_ choices: ForkChoices, store: ForkStore) -> ForkSandbox {
    let catalog = store.catalog.value
    let readOriginal = store.sandboxes.forkDefaults[context?.source.id ?? ""]?.value != nil
    return ForkSandbox(
      provider: choices.sandboxProvider,
      workspaces: readOriginal
        ? composeSandboxWorkspaces(repos: sandbox.repos.map(SandboxChoices.repo)) : nil,
      profile: sandbox.chosenProfile(catalog))
  }

  /// `actions` with the sandbox pickers' and the folder browser's, editing this sheet.
  func withSandboxActions(_ actions: ForkActions) -> ForkActions {
    var actions = actions
    sandboxActions(into: &actions)
    return actions
  }

  /// The sandbox pickers' actions, editing this sheet's choices.
  func sandboxActions(into actions: inout ForkActions) {
    guard let store else { return }
    actions.repositories = SandboxChoices.repositoryActions(store.sandboxes) { [self] in
      sandbox.repos = $0
    }
    actions.profiles = SandboxChoices.profileActions(
      sandbox.profileProvider(store.catalog.value), sandboxes: store.sandboxes
    ) { [self] in sandbox.profile = $0 }
    actions.sandboxSelected = { [self] provider in Task { await sandboxSelected(provider) } }
    actions.browse = { [self] hostID, path in
      guard let hostID = hostID ?? context.flatMap({ store.plan(for: $0.source).hostId }) else {
        return .failure(FolderBrowseError(message: "Choose a host first."))
      }
      return await store.directory(hostID: hostID, path: path)
        .map(NewSessionAdapter.listing)
        .mapError { FolderBrowseError(message: $0.message) }
    }
  }
}
