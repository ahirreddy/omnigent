public import Observation
public import OmnigentCoreFFI

/// What a new sandbox can launch with on one server: each provider's profiles, the caller's
/// GitHub repositories and their branches, and a sandbox fork's starting repositories. Reads
/// only; a newer request for the same thing supersedes an older one's result.
@Observable
public final class SandboxStore {
  /// Profiles by provider.
  public private(set) var profiles: [String: CreationLoad<SandboxProfilePage>] = [:]
  /// The caller's GitHub repositories.
  public private(set) var githubRepos: CreationLoad<GithubRepoList> = .idle
  /// Branches by `owner/name`.
  public private(set) var branches: [String: CreationLoad<[String]>] = [:]
  /// A fork's starting repositories and profile, by source session.
  public private(set) var forkDefaults: [String: CreationLoad<ForkSandboxDefaults>] = [:]

  private let core: ClientCore

  init(core: ClientCore) {
    self.core = core
  }

  /// Loads `provider`'s profiles once (again after a failure).
  public func loadProfiles(_ provider: String) async {
    switch profiles[provider] {
    case .loading, .loaded: return
    case .idle, .failed, nil: break
    }
    profiles[provider] = .loading
    profiles[provider] = await Self.read {
      try await self.core.sandboxProfiles(provider: provider, search: "", profileId: nil)
    }
  }

  /// `provider`'s profiles matching `text`, for the picker's search field.
  /// - Returns: The matches, or why they could not be read.
  public func searchProfiles(
    _ provider: String, text: String
  ) async -> Result<SandboxProfilePage, CoreError> {
    do {
      return .success(
        try await core.sandboxProfiles(provider: provider, search: text, profileId: nil))
    } catch {
      return .failure(coreError(error))
    }
  }

  /// Loads the caller's GitHub repositories once (again after a failure).
  public func loadGithubRepos() async {
    switch githubRepos {
    case .loading, .loaded: return
    case .idle, .failed: break
    }
    githubRepos = .loading
    githubRepos = await Self.read { try await self.core.githubRepos() }
  }

  /// Loads the branches of `fullName` (`owner/name`) once.
  public func loadBranches(_ fullName: String) async {
    switch branches[fullName] {
    case .loading, .loaded: return
    case .idle, .failed, nil: break
    }
    branches[fullName] = .loading
    branches[fullName] = await Self.read { try await self.core.githubBranches(fullName: fullName) }
  }

  /// Loads what a fork of `sourceID` onto a new sandbox starts from.
  public func loadForkDefaults(_ sourceID: String) async {
    if case .loaded = forkDefaults[sourceID] { return }
    forkDefaults[sourceID] = .loading
    forkDefaults[sourceID] = await Self.read {
      try await self.core.forkSandboxDefaults(sourceId: sourceID)
    }
  }

  private static func read<Value: Sendable & Equatable>(
    _ operation: () async throws -> Value
  ) async -> CreationLoad<Value> {
    do {
      return .loaded(try await operation())
    } catch {
      return .failed(coreError(error))
    }
  }
}

extension ConnectionStore {
  /// The sandbox reads for this server.
  /// - Returns: The store, or `nil` when the core did not start.
  public func sandboxes() -> SandboxStore? {
    guard let core else { return nil }
    return SandboxStore(core: core)
  }
}
