public import SwiftUI

/// The terminals a session's agent declares, as the new-tab page offers them.
nonisolated public enum NewTabTerminals: Hashable, Sendable {
  /// Not known yet: Terminal starts the default shell.
  case unknown
  /// The declared names; empty when the agent declares none.
  case declared([String])
}

/// What the new-tab page offers. Everything opens in the page's session.
nonisolated public struct NewTabPageState: Hashable, Sendable {
  /// The session the page's tabs open in.
  public var sessionTitle: String?
  /// Whether this build can open a browser tab.
  public var canOpenBrowser: Bool
  /// The terminals the session's agent declares.
  public var terminals: NewTabTerminals
  /// The remote browser profiles on the agent's machine; empty offers the default profile.
  public var remoteBrowserProfiles: [String]

  /// Creates the state.
  /// - Parameters:
  ///   - sessionTitle: The page's session.
  ///   - canOpenBrowser: Browser tabs are available.
  ///   - terminals: The session's declared terminals.
  ///   - remoteBrowserProfiles: Remote browser profiles.
  public init(
    sessionTitle: String? = nil, canOpenBrowser: Bool = false,
    terminals: NewTabTerminals = .unknown, remoteBrowserProfiles: [String] = []
  ) {
    self.sessionTitle = sessionTitle
    self.canOpenBrowser = canOpenBrowser
    self.terminals = terminals
    self.remoteBrowserProfiles = remoteBrowserProfiles
  }
}

/// What the new-tab page does. Each action replaces the new tab with what it opens in the
/// page's session.
public struct NewTabPageActions {
  /// Start a side chat of the session; `nil` hides it.
  public var newSideChat: (@MainActor () -> Void)?
  /// Open a new terminal: a declared terminal name, or `nil` for the default shell when the
  /// declared names are not known.
  public var newTerminal: (@MainActor (String?) -> Void)?
  /// Open a browser tab.
  public var openBrowser: (@MainActor () -> Void)?
  /// Open a remote browser tab in a profile; `nil` hides it.
  public var openRemoteBrowser: (@MainActor (String) -> Void)?

  /// Creates the actions.
  /// - Parameters:
  ///   - newSideChat: Side chat; `nil` hides it.
  ///   - newTerminal: New terminal; `nil` hides Terminal.
  ///   - openBrowser: Browser; `nil` hides it.
  ///   - openRemoteBrowser: Remote browser; `nil` hides it.
  public init(
    newSideChat: (@MainActor () -> Void)? = nil,
    newTerminal: (@MainActor (String?) -> Void)? = nil,
    openBrowser: (@MainActor () -> Void)? = nil,
    openRemoteBrowser: (@MainActor (String) -> Void)? = nil
  ) {
    self.newSideChat = newSideChat
    self.newTerminal = newTerminal
    self.openBrowser = openBrowser
    self.openRemoteBrowser = openRemoteBrowser
  }
}

/// The new-tab page (Command-T): a side chat, terminal, browser or remote browser in the
/// session.
public struct NewTabPage: View {
  private let state: NewTabPageState
  private let actions: NewTabPageActions
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  /// - Parameters:
  ///   - state: The session and what is available.
  ///   - actions: What it opens.
  public init(state: NewTabPageState, actions: NewTabPageActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.section) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("New Tab")
            .font(Theme.Typography.title)
            .accessibilityAddTraits(.isHeader)
          if let sessionTitle = state.sessionTitle {
            Text("Opens in \(sessionTitle)")
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        if hasLaunchers {
          launchers
        } else {
          Text("Nothing in this session opens in a tab.")
            .foregroundStyle(.secondary)
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

  private var hasLaunchers: Bool {
    actions.newSideChat != nil || actions.newTerminal != nil
      || (state.canOpenBrowser && actions.openBrowser != nil) || actions.openRemoteBrowser != nil
  }

  private var launchers: some View {
    let columns = [GridItem(.adaptive(minimum: 170), spacing: Theme.Spacing.medium)]
    return LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.medium) {
      if let newSideChat = actions.newSideChat {
        launcher(
          "Side Chat", detail: "Ask about this session without interrupting it",
          systemImage: TabKind.sideChat.systemImage, identifier: "newtab-side-chat",
          action: newSideChat)
      }
      if let newTerminal = actions.newTerminal {
        terminal(newTerminal)
      }
      if state.canOpenBrowser, let openBrowser = actions.openBrowser {
        launcher(
          "Browser", detail: "Open this server's web app", systemImage: "globe",
          identifier: "newtab-browser", action: openBrowser)
      }
      if let openRemoteBrowser = actions.openRemoteBrowser {
        remoteBrowser(openRemoteBrowser)
      }
    }
  }

  /// The session's terminals: the default shell while its declared names are unknown, a
  /// disabled note when it declares none, its one terminal, or a menu of them.
  @ViewBuilder
  private func terminal(_ newTerminal: @escaping @MainActor (String?) -> Void) -> some View {
    switch state.terminals {
    case .unknown:
      launcher(
        "Terminal", detail: "A shell in this session's sandbox", systemImage: "terminal",
        identifier: "newtab-terminal", action: { newTerminal(nil) })
    case .declared(let names) where names.isEmpty:
      launcher(
        "Terminal", detail: "This session's agent declares no terminals",
        systemImage: "terminal", identifier: "newtab-terminal", action: {}
      )
      .disabled(true)
    case .declared(let names) where names.count == 1:
      launcher(
        "Terminal", detail: names[0], systemImage: "terminal", identifier: "newtab-terminal",
        action: { newTerminal(names[0]) })
    case .declared(let names):
      launcherMenu(
        LauncherLabel(
          title: "Terminal", detail: "\(names.count) terminals", systemImage: "terminal"),
        identifier: "newtab-terminal", choices: names, choose: newTerminal)
    }
  }

  /// A remote browser in the default profile, the machine's one profile, or a menu of them.
  @ViewBuilder
  private func remoteBrowser(_ open: @escaping @MainActor (String) -> Void) -> some View {
    let profiles = state.remoteBrowserProfiles.isEmpty ? ["default"] : state.remoteBrowserProfiles
    let detail = "A browser on the agent's machine"
    if profiles.count == 1 {
      launcher(
        "Remote Browser", detail: detail, systemImage: TabKind.remoteBrowser.systemImage,
        identifier: "newtab-remote-browser", action: { open(profiles[0]) })
    } else {
      launcherMenu(
        LauncherLabel(
          title: "Remote Browser", detail: detail,
          systemImage: TabKind.remoteBrowser.systemImage),
        identifier: "newtab-remote-browser", choices: profiles, choose: open)
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

  private func launcherMenu(
    _ label: LauncherLabel, identifier: String, choices: [String],
    choose: @escaping @MainActor (String) -> Void
  ) -> some View {
    Menu {
      ForEach(choices, id: \.self) { choice in
        Button(choice) { choose(choice) }
          .accessibilityIdentifier("\(identifier)-\(choice)")
      }
    } label: {
      label
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityIdentifier(identifier)
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
