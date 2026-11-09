import SwiftUI

/// The strip's + button: a menu of what opens in the session's new tab (``TabActions/newTabMenu``),
/// or the New Tab page when the window has no such menu.
struct NewTabButton: View {
  let actions: TabActions

  var body: some View {
    // Read here, so what the menu offers updates this button rather than the strip.
    if let options = actions.newTabMenu?(), options.actions.offersLaunchers(in: options.state) {
      Menu {
        NewTabMenu(options: options)
      } label: {
        label
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .modifier(NewTabButtonStyle(help: "Open a side chat, terminal or browser in a new tab"))
    } else {
      Button(action: actions.newTab) { label }
        .buttonStyle(.plain)
        .modifier(NewTabButtonStyle(help: "New tab (Command-T)"))
    }
  }

  private var label: some View {
    Image(systemName: "plus")
      .accessibilityLabel("New tab")
      .font(.system(size: 13, weight: .medium))
      .frame(width: 26, height: 26)
      .contentShape(Rectangle())
      .touchTarget(width: 26, height: 26)
  }
}

private struct NewTabButtonStyle: ViewModifier {
  let help: String

  func body(content: Content) -> some View {
    content
      .foregroundStyle(.secondary)
      .hoverHighlight()
      .help(help)
      .accessibilityLabel("New tab")
      .accessibilityIdentifier("tab-new")
  }
}

/// The + button's menu: what the New Tab page offers, each opening in a new tab of the session.
/// Terminal opens the remembered terminal (``PreferredTerminal``); another one chosen here
/// becomes the remembered one, as on the web.
struct NewTabMenu: View {
  let options: NewTabOptions
  @AppStorage(PreferredTerminal.key) private var preferredTerminal: String?

  var body: some View {
    let actions = options.actions
    if let newSideChat = actions.newSideChat {
      Button("Side Chat", systemImage: TabKind.sideChat.systemImage, action: newSideChat)
        .accessibilityIdentifier("tab-new-side-chat")
    }
    if let newTerminal = actions.newTerminal {
      terminal(newTerminal)
    }
    if let openBrowser = actions.browser(in: options.state) {
      Button("Browser", systemImage: "globe", action: openBrowser)
        .accessibilityIdentifier("tab-new-browser")
    }
    if let openRemoteBrowser = actions.openRemoteBrowser {
      remoteBrowser(openRemoteBrowser)
    }
  }

  /// Terminal, disabled when the agent declares none; with several, it names the one it opens
  /// and the others follow in a submenu.
  @ViewBuilder
  private func terminal(_ newTerminal: @escaping @MainActor (String?) -> Void) -> some View {
    switch options.state.terminals {
    case .unknown:
      terminalItem("Terminal") { newTerminal(nil) }
    case .declared(let names) where names.isEmpty:
      terminalItem("Terminal") {}
        .disabled(true)
    case .declared(let names) where names.count == 1:
      terminalItem("Terminal") { newTerminal(names[0]) }
    case .declared(let names):
      let chosen = PreferredTerminal.resolve(names, preferred: preferredTerminal) ?? names[0]
      terminalItem("Terminal (\(chosen))") { newTerminal(chosen) }
      Menu("Other Terminals", systemImage: "terminal") {
        ForEach(names.filter { $0 != chosen }, id: \.self) { name in
          Button(name) {
            preferredTerminal = name
            newTerminal(name)
          }
          .accessibilityIdentifier("tab-new-terminal-\(name)")
        }
      }
      .accessibilityIdentifier("tab-new-other-terminals")
    }
  }

  private func terminalItem(_ title: String, action: @escaping @MainActor () -> Void)
    -> some View
  {
    Button(title, systemImage: "terminal", action: action)
      .accessibilityIdentifier("tab-new-terminal")
  }

  /// Remote Browser in the machine's one profile, or a submenu of its profiles.
  @ViewBuilder
  private func remoteBrowser(_ open: @escaping @MainActor (String) -> Void) -> some View {
    let profiles = options.state.remoteBrowserChoices
    if profiles.count == 1 {
      Button("Remote Browser", systemImage: TabKind.remoteBrowser.systemImage) {
        open(profiles[0])
      }
      .accessibilityIdentifier("tab-new-remote-browser")
    } else {
      Menu("Remote Browser", systemImage: TabKind.remoteBrowser.systemImage) {
        ForEach(profiles, id: \.self) { profile in
          Button(profile) { open(profile) }
            .accessibilityIdentifier("tab-new-remote-browser-\(profile)")
        }
      }
      .accessibilityIdentifier("tab-new-remote-browser")
    }
  }
}
