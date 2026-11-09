public import SwiftUI

/// What the new-tab page offers.
nonisolated public struct NewTabPageState: Hashable, Sendable {
  /// Recent sessions: quick links, and the targets for a new terminal.
  public var recentSessions: [SessionSummary]
  /// Whether this build can open a browser tab.
  public var canOpenBrowser: Bool
  /// The terminals each session's agent declares, by session id. A session that is missing is
  /// not known yet and offers the default shell; an empty list explains that the agent declares
  /// none.
  public var terminalNames: [String: [String]]
  /// The remote browser profiles on the agent's machine; empty offers the default profile.
  public var remoteBrowserProfiles: [String]

  /// Creates the state.
  /// - Parameters:
  ///   - recentSessions: Recent sessions, most recent first.
  ///   - canOpenBrowser: Browser tabs are available.
  ///   - terminalNames: Declared terminals by session id.
  ///   - remoteBrowserProfiles: Remote browser profiles.
  public init(
    recentSessions: [SessionSummary] = [], canOpenBrowser: Bool = false,
    terminalNames: [String: [String]] = [:], remoteBrowserProfiles: [String] = []
  ) {
    self.recentSessions = recentSessions
    self.canOpenBrowser = canOpenBrowser
    self.terminalNames = terminalNames
    self.remoteBrowserProfiles = remoteBrowserProfiles
  }
}

/// What the new-tab page does. Each action replaces the new tab with what it opens.
public struct NewTabPageActions {
  /// Start a session (the new-session form).
  public var newSession: @MainActor () -> Void
  /// Open a new terminal in a session: the session id and a declared terminal name, or `nil`
  /// for the default shell when the declared names are not known.
  public var newTerminal: (@MainActor (String, String?) -> Void)?
  /// Open a browser tab.
  public var openBrowser: (@MainActor () -> Void)?
  /// Open a session's conversation.
  public var openSession: @MainActor (String) -> Void
  /// Open a remote browser tab for a session in a profile; `nil` hides it.
  public var openRemoteBrowser: (@MainActor (String, String) -> Void)?

  /// Creates the actions.
  /// - Parameters:
  ///   - newSession: New session.
  ///   - newTerminal: New terminal in a session; `nil` hides Terminal.
  ///   - openBrowser: Browser; `nil` hides it.
  ///   - openSession: Open a session.
  public init(
    newSession: @escaping @MainActor () -> Void = {},
    newTerminal: (@MainActor (String, String?) -> Void)? = nil,
    openBrowser: (@MainActor () -> Void)? = nil,
    openSession: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.newSession = newSession
    self.newTerminal = newTerminal
    self.openBrowser = openBrowser
    self.openSession = openSession
  }
}

/// The new-tab page (Command-T): New session, Terminal (in a recent session) and Browser, then
/// the recent sessions.
public struct NewTabPage: View {
  private let state: NewTabPageState
  private let actions: NewTabPageActions
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  /// - Parameters:
  ///   - state: Recent sessions and what is available.
  ///   - actions: What it opens.
  public init(state: NewTabPageState, actions: NewTabPageActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.section) {
        Text("New Tab")
          .font(Theme.Typography.title)
          .accessibilityAddTraits(.isHeader)
        launchers
        if !state.recentSessions.isEmpty {
          recent
        }
      }
      .frame(maxWidth: 640, alignment: .leading)
      .padding(layoutWidth == .compact ? Theme.Spacing.large : Theme.Spacing.section)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle("New Tab")
    .accessibilityIdentifier("newtab-page")
  }

  private var launchers: some View {
    let columns = [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.medium)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.medium) {
      launcher(
        "New Session", detail: "Start an agent on a task", systemImage: "square.and.pencil",
        identifier: "newtab-session", action: actions.newSession)
      if let newTerminal = actions.newTerminal {
        Menu {
          if state.recentSessions.isEmpty {
            Text("Open a session first")
          }
          ForEach(state.recentSessions.prefix(12)) { session in
            terminalChoices(session, newTerminal: newTerminal)
          }
        } label: {
          LauncherLabel(
            title: "Terminal", detail: "A shell in a session's sandbox",
            systemImage: "terminal")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(state.recentSessions.isEmpty)
        .accessibilityIdentifier("newtab-terminal")
      }
      if state.canOpenBrowser, let openBrowser = actions.openBrowser {
        launcher(
          "Browser", detail: "Open this server's web app", systemImage: "globe",
          identifier: "newtab-browser", action: openBrowser)
      }
      if let openRemoteBrowser = actions.openRemoteBrowser {
        Menu {
          if state.recentSessions.isEmpty {
            Text("Open a session first")
          }
          ForEach(state.recentSessions.prefix(12)) { session in
            Menu(session.title) {
              let profiles =
                state.remoteBrowserProfiles.isEmpty ? ["default"] : state.remoteBrowserProfiles
              ForEach(profiles, id: \.self) { profile in
                Button(profile) { openRemoteBrowser(session.id, profile) }
                  .accessibilityIdentifier("newtab-remote-browser-\(session.id)-\(profile)")
              }
            }
            .accessibilityIdentifier("newtab-remote-browser-\(session.id)")
          }
        } label: {
          LauncherLabel(
            title: "Remote Browser", detail: "A browser on the agent's machine",
            systemImage: TabKind.remoteBrowser.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(state.recentSessions.isEmpty)
        .accessibilityIdentifier("newtab-remote-browser")
      }
    }
  }

  /// A session's terminals: its declared names, a disabled note when it declares none, or the
  /// default shell while the names are unknown.
  @ViewBuilder
  private func terminalChoices(
    _ session: SessionSummary, newTerminal: @escaping @MainActor (String, String?) -> Void
  ) -> some View {
    switch state.terminalNames[session.id] {
    case nil:
      Button(session.title) { newTerminal(session.id, nil) }
    case let names? where names.isEmpty:
      Button("\(session.title): no terminals declared") {}
        .disabled(true)
        .help("This session's agent declares no terminals.")
    case let names? where names.count == 1:
      Button("\(session.title) \u{2014} \(names[0])") { newTerminal(session.id, names[0]) }
    case let names?:
      Menu(session.title) {
        ForEach(names, id: \.self) { name in
          Button(name) { newTerminal(session.id, name) }
        }
      }
    }
  }

  private func launcher(
    _ title: String, detail: String, systemImage: String, identifier: String,
    action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(action: action) {
      LauncherLabel(title: title, detail: detail, systemImage: systemImage)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }

  private var recent: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Recent Sessions")
        .font(Theme.Typography.section)
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      VStack(spacing: 0) {
        ForEach(state.recentSessions.prefix(8)) { session in
          Button {
            actions.openSession(session.id)
          } label: {
            HStack(spacing: Theme.Spacing.medium) {
              Image(systemName: TabKind.chat.systemImage)
                .accessibilityHidden(true)
                .foregroundStyle(.secondary)
                .frame(width: Theme.Control.icon)
              VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                if !session.agentName.isEmpty {
                  Text(HarnessAppearance.agentName(session.agentName, harness: nil))
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 0)
              if session.attention == .needsYou {
                Circle().fill(Theme.attention).frame(width: 7, height: 7)
              }
            }
            .padding(.vertical, Theme.Spacing.small)
            .padding(.horizontal, Theme.Spacing.medium)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .hoverHighlight()
          .accessibilityIdentifier("newtab-recent-\(session.id)")
        }
      }
      .cardSurface(cornerRadius: Theme.Radius.medium)
    }
  }
}

private struct LauncherLabel: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Image(systemName: systemImage)
        .accessibilityHidden(true)
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(title).font(Theme.Typography.label)
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
    .padding(Theme.Spacing.large)
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .hoverHighlight(cornerRadius: Theme.Radius.medium)
    .contentShape(Rectangle())
  }
}

/// The + button's menu: New Tab, and a remote browser tab in a chosen profile.
struct NewTabMenu: View {
  let actions: TabActions

  var body: some View {
    Button("New Tab", systemImage: "plus", action: actions.newTab)
    if let newRemoteBrowser = actions.newRemoteBrowser {
      Menu("New Remote Browser Tab", systemImage: TabKind.remoteBrowser.systemImage) {
        if actions.remoteBrowserProfiles.isEmpty {
          Button("Default Profile") { newRemoteBrowser("default") }
        }
        ForEach(actions.remoteBrowserProfiles, id: \.self) { profile in
          Button(profile) { newRemoteBrowser(profile) }
        }
      }
      .accessibilityIdentifier("tab-new-remote-browser")
    }
  }
}
