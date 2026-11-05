public import SwiftUI

/// The web's sandbox repository picker: each chosen repository with its branch (a menu of the
/// GitHub branches, or a field) and a remove button, then the caller's GitHub repositories and
/// a URL field to add another, up to the provider's limit.
public struct SandboxRepositoriesEditor: View {
  let state: SandboxRepositoriesState
  let actions: SandboxRepositoriesActions

  @State private var url = ""

  /// Creates the editor.
  public init(state: SandboxRepositoriesState, actions: SandboxRepositoriesActions) {
    self.state = state
    self.actions = actions
  }

  /// The editor.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if state.repos.count > state.maxRepos, let problem = state.problem {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.warning)
      }
      ForEach(Array(state.repos.enumerated()), id: \.offset) { index, repo in
        row(index: index, repo: repo)
      }
      if state.repos.count < state.maxRepos {
        if !state.repos.isEmpty { Divider() }
        addControls
      }
      Text(
        state.maxRepos > 1
          ? "Cloned into the sandbox at startup, side by side; the agent starts in the folder "
            + "that holds them, or inside the one repository. Leave empty for a blank workspace."
          : "Cloned into the sandbox at startup as the working directory. Leave empty for a "
            + "blank workspace."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sandbox-repositories")
  }

  private func row(index: Int, repo: SandboxRepoChoice) -> some View {
    let github = state.githubRepos.first { actions.isSameRepo($0.cloneURL, repo.url) }
    let name = github?.fullName ?? actions.repoName(repo.url)
    let note = actions.branchProblem(repo.url, repo.branch) ?? state.notes[repo.url]
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: Theme.Spacing.small) {
        Text(name).lineLimit(1).truncationMode(.middle).help(repo.url)
        Spacer(minLength: Theme.Spacing.small)
        if let github {
          branchMenu(index: index, repo: repo, github: github)
        } else {
          TextField("Branch", text: branchBinding(index), prompt: Text("Default branch"))
            .frame(width: 150)
            .accessibilityLabel("Branch for \(name)")
        }
        Button("Remove \(name)", systemImage: "xmark") {
          var repos = state.repos
          repos.remove(at: index)
          actions.setRepos(repos)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
      }
      if let note {
        Text(note).font(.caption)
          .foregroundStyle(
            actions.branchProblem(repo.url, repo.branch) == nil ? .secondary : Theme.failure)
      }
    }
    .accessibilityIdentifier("sandbox-repository-row")
  }

  private func branchMenu(index: Int, repo: SandboxRepoChoice, github: GithubRepoOption)
    -> some View
  {
    let defaultLabel = github.defaultBranch.map { "Default (\($0))" } ?? "Default branch"
    let others = (state.branches[github.fullName] ?? []).filter { $0 != github.defaultBranch }
    return Menu {
      Button(defaultLabel) { setBranch(index, "") }
      if state.branches[github.fullName] == nil {
        Text("Loading branches\u{2026}")
      }
      ForEach(others, id: \.self) { branch in
        Button(branch) { setBranch(index, branch) }
          .disabled(actions.branchProblem(repo.url, branch) != nil)
      }
    } label: {
      Label(repo.branch.isEmpty ? defaultLabel : repo.branch, systemImage: "arrow.triangle.branch")
    }
    .fixedSize()
    .onAppear { actions.loadBranches?(github.fullName) }
    .accessibilityLabel("Branch for \(github.fullName)")
  }

  @ViewBuilder private var addControls: some View {
    let available = state.githubRepos.filter { option in
      !state.repos.contains { actions.isSameRepo($0.url, option.cloneURL) }
    }
    if !available.isEmpty {
      Menu("Choose a Repository\u{2026}") {
        ForEach(available) { option in
          Button {
            actions.setRepos(state.repos + [SandboxRepoChoice(url: option.cloneURL)])
          } label: {
            Label(option.fullName, systemImage: option.isPrivate ? "lock" : "book.closed")
          }
        }
      }
      .accessibilityIdentifier("sandbox-github-repos")
      if state.githubTruncated {
        Text("Showing your most recently pushed repositories. Paste a URL for another.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    if let error = state.githubError {
      Text("Couldn't load your GitHub repositories (\(error)). Paste a repository URL below.")
        .font(.caption).foregroundStyle(Theme.failure)
    }
    HStack {
      TextField("Repository URL", text: $url, prompt: Text("https://github.com/org/repo"))
        .onSubmit(add)
        .accessibilityIdentifier("sandbox-repository-url")
      Button("Add", systemImage: "plus", action: add)
        .disabled(!canAdd)
        .accessibilityIdentifier("sandbox-repository-add")
    }
    if let problem = actions.urlProblem(url, state.repos) {
      Text(problem).font(.caption).foregroundStyle(Theme.failure)
    }
  }

  private var canAdd: Bool {
    !url.trimmingCharacters(in: .whitespaces).isEmpty
      && actions.urlProblem(url, state.repos) == nil && state.repos.count < state.maxRepos
  }

  private func add() {
    guard canAdd else { return }
    actions.setRepos(
      state.repos + [SandboxRepoChoice(url: url.trimmingCharacters(in: .whitespaces))])
    url = ""
  }

  private func setBranch(_ index: Int, _ branch: String) {
    var repos = state.repos
    repos[index].branch = branch
    actions.setRepos(repos)
  }

  private func branchBinding(_ index: Int) -> Binding<String> {
    Binding(
      get: { state.repos.indices.contains(index) ? state.repos[index].branch : "" },
      set: { branch in
        guard state.repos.indices.contains(index), state.repos[index].branch != branch else {
          return
        }
        setBranch(index, branch)
      })
  }
}
