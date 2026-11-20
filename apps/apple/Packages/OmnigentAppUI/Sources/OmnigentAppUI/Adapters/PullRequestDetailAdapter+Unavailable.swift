import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The provider accounts to pick from, and why there is no PR to show, in the web panel's
/// words.
extension PullRequestDetailAdapter {
  /// The accounts to pick from, the one in use selected.
  static func accountChoices(_ info: PullRequestInfo) -> [PullRequestAccountChoice] {
    info.accounts.map {
      PullRequestAccountChoice(
        login: $0.login, active: $0.active, selected: $0.login == info.selectedAccount)
    }
  }

  /// The accounts the upstream repository can be reached with, offered only while it can't
  /// (the web's `GithubAccountSelector`): once it resolves, the account is right.
  static func unresolvedAccountChoices(_ detail: CreationLoad<PullRequestInfo>)
    -> [PullRequestAccountChoice]
  {
    guard let info = detail.value, case .repositoryUnresolved = info.availability,
      info.capabilities.accountSwitching, info.accounts.count > 1
    else { return [] }
    return accountChoices(info)
  }

  static func unavailable(_ info: PullRequestInfo) -> PullRequestDetailContent {
    let provider = info.providerName ?? "the git provider"
    let github = info.provider == "github"
    switch info.availability {
    case .notAGitRepository:
      return .unavailable(
        title: "Not a git repository",
        message:
          "This workspace isn\u{2019}t a git checkout, so there\u{2019}s no branch or PR to show.",
        systemImage: "arrow.triangle.branch")
    case .hostOutdated:
      return .unavailable(
        title: "Update your host",
        message: "The Pull Requests tab needs the host running Omnigent 0.13.0 or later.",
        systemImage: "arrow.down.circle")
    case .unsupportedRemote(let host):
      return .unavailable(
        title: "No supported remote", message: unsupportedRemote(host), systemImage: "server.rack")
    case .noCli(let cli):
      let label = github ? "GitHub CLI" : "\(info.providerName ?? "Git provider") CLI"
      return .unavailable(
        title: "\(label) not found",
        message: "Install the \(label) (`\(cli)`) on the host to see this branch\u{2019}s pull "
          + "request and CI status.",
        systemImage: "terminal")
    case .repositoryUnresolved(let hint):
      return .unavailable(
        title: "Can\u{2019}t reach the upstream repo",
        message: github
          ? "Pick the account to use, or run `gh auth status` on the host to confirm the GitHub "
            + "CLI is signed in."
          : hint ?? "Sign in to \(provider) on the host.",
        systemImage: "key")
    case .noPullRequest:
      return .unavailable(
        title: "No open PR for \(info.branch ?? "this branch")",
        message:
          "Pull requests created in this session appear here. You can also link an existing PR.",
        systemImage: "arrow.triangle.pull")
    case .ready, .unavailable:
      return .unavailable(
        title: "Pull request unavailable",
        message: info.warnings.first
          ?? "The host couldn\u{2019}t read this pull request from \(provider).",
        systemImage: "exclamationmark.circle")
    }
  }

  /// The web's note for a remote no provider claims: how to sign in to GitLab or GitHub
  /// Enterprise on it, or mark a GitHub SSH alias.
  static func unsupportedRemote(_ host: String?) -> String {
    guard let host else {
      return "Omnigent couldn\u{2019}t identify this workspace\u{2019}s git provider."
    }
    return "Omnigent couldn\u{2019}t identify the git provider for `\(host)`.\n\n"
      + "On the execution host, run `glab auth login --hostname \(host)` for GitLab or "
      + "`gh auth login --hostname \(host)` for GitHub Enterprise. For a GitHub SSH alias, run "
      + "`git config --local omnigent.gitprovider github` in this checkout, then refresh for "
      + "installation or sign-in help."
  }
}
