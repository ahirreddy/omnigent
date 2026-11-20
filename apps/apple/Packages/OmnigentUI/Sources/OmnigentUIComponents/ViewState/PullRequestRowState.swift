import Foundation

/// An account the provider's CLI is signed in as on the host, to pick from.
nonisolated public struct PullRequestAccountChoice: Hashable, Sendable, Identifiable {
  /// The login.
  public var login: String
  /// The CLI's active account for the host.
  public var active: Bool
  /// The host reads and writes the PR as this account.
  public var selected: Bool

  /// Stable id.
  public var id: String { login }
  /// "ann (active)", as the web's picker names it.
  public var title: String { active ? "\(login) (active)" : login }

  /// Creates a choice.
  /// - Parameters:
  ///   - login: The login.
  ///   - active: The CLI's active account.
  ///   - selected: The account in use.
  public init(login: String, active: Bool, selected: Bool = false) {
    self.login = login
    self.active = active
    self.selected = selected
  }
}

/// Why a listed PR's live state can't be read: its host is offline or its sandbox asleep.
nonisolated public struct PullRequestOfflineNote: Hashable, Sendable {
  /// "Host offline", "Sandbox asleep" or "Sandbox starting".
  public var title: String
  /// When it last synced and what loads it.
  public var hint: String

  /// Creates a note.
  /// - Parameters:
  ///   - title: The badge.
  ///   - hint: Its help text.
  public init(title: String, hint: String) {
    self.title = title
    self.hint = hint
  }
}

/// A listed PR's live extras: its failing and running checks, or why it can't be read now.
nonisolated public struct PullRequestRowExtras: Hashable, Sendable {
  /// Failing checks.
  public var failing = 0
  /// Running checks.
  public var pending = 0
  /// The signed-in account can't read the checks.
  public var checksUnavailable = false
  /// The host can't read it now.
  public var offline: PullRequestOfflineNote?

  /// Creates extras with nothing to show.
  public init() {}

  /// Whether the row has anything to show.
  public var isEmpty: Bool { failing == 0 && pending == 0 && !checksUnavailable && offline == nil }
}

/// What the session's git provider calls things, as the web's `gitProviderCopy`.
nonisolated public struct PullRequestProviderWording: Hashable, Sendable {
  /// The provider's name.
  public var name: String
  /// "pull request", or the provider's own ("merge request").
  public var requestName: String
  /// The example address in the link field.
  public var linkPlaceholder: String

  /// GitHub's wording.
  public init() {
    self.init(name: "GitHub", requestName: "pull request")
  }

  /// A provider's wording; only GitHub gets an example address.
  /// - Parameters:
  ///   - name: The provider's name.
  ///   - requestName: What it calls a PR.
  public init(name: String, requestName: String) {
    self.name = name
    self.requestName = requestName
    linkPlaceholder =
      name == "GitHub"
      ? "https://github.com/owner/repo/pull/123"
      : "\(requestName.prefix(1).uppercased())\(requestName.dropFirst()) URL"
  }

  /// "Link a pull request", "Link a merge request".
  public var linkTitle: String { "Link a \(requestName)" }
}
