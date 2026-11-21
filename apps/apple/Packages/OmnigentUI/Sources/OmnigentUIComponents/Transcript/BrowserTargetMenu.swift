public import SwiftUI

/// Which browser a session's agent drives through Chrome DevTools.
nonisolated public enum BrowserTargetChoice: String, CaseIterable, Hashable, Sendable {
  /// Omnigent picks, and asks once when both browsers would do.
  case auto
  /// The Mac app's browser, with the owner's logins.
  case local
  /// The browser on the agent's machine, which works while the Mac sleeps.
  case remote

  /// The menu's order: the two browsers, then letting Omnigent pick.
  public static let menuOrder: [Self] = [.local, .remote, .auto]

  /// The name the chip and the menu give it.
  public var title: String {
    switch self {
    case .auto: "Auto"
    case .local: "This Mac"
    case .remote: "Agent\u{2019}s machine"
    }
  }

  /// The SF Symbol beside the name.
  public var systemImage: String {
    switch self {
    case .auto: "wand.and.stars"
    case .local: "laptopcomputer"
    case .remote: "cloud"
    }
  }
}

/// The session's browser choice, for the Mac toolbar's chip and the iOS title menu.
nonisolated public struct BrowserTargetState: Hashable, Sendable {
  /// The current choice.
  public var choice: BrowserTargetChoice
  /// Why this Mac's browser can't be chosen; `nil` when it can.
  public var localUnavailableReason: String?

  /// Why a session others can see or write to can't use the owner's browser. The server's 403
  /// shows as this too.
  public static let ownerOnly =
    "Only the owner of an unshared session can use this Mac\u{2019}s browser."
  /// That each browser keeps its own logins.
  public static let separateLogins =
    "Logins and cookies don\u{2019}t carry over between this Mac and the agent\u{2019}s machine."

  /// Creates the state.
  /// - Parameters:
  ///   - choice: The current choice.
  ///   - localUnavailableReason: Why This Mac is disabled; `nil` enables it.
  public init(choice: BrowserTargetChoice, localUnavailableReason: String? = nil) {
    self.choice = choice
    self.localUnavailableReason = localUnavailableReason
  }

  /// Whether `option` can be picked: This Mac only where the session allows it.
  public func allows(_ option: BrowserTargetChoice) -> Bool {
    option != .local || localUnavailableReason == nil
  }

  /// What the chip says to VoiceOver and on hover.
  var summary: String { "Browser: \(choice.title)" }
}

/// The browser choices with a check on the current one, then why This Mac is off (when it is)
/// and that logins don't carry over.
struct BrowserTargetMenuItems: View {
  let state: BrowserTargetState
  let choose: @MainActor (BrowserTargetChoice) -> Void

  var body: some View {
    Picker(
      "Browser",
      selection: Binding(get: { state.choice }, set: { if $0 != state.choice { choose($0) } })
    ) {
      ForEach(BrowserTargetChoice.menuOrder, id: \.self) { option in
        Label(option.title, systemImage: option.systemImage)
          .tag(option)
          .disabled(!state.allows(option))
          .accessibilityIdentifier("browser-target-\(option.rawValue)")
      }
    }
    .pickerStyle(.inline)
    Section {
      if let reason = state.localUnavailableReason { Text(reason) }
      Text(BrowserTargetState.separateLogins)
    }
  }
}

#if os(macOS)
  /// The toolbar's browser chip: which browser the session's agent drives, with a menu to
  /// switch.
  struct BrowserTargetChip: View {
    let state: BrowserTargetState
    let choose: @MainActor (BrowserTargetChoice) -> Void

    /// The titlebar width the chip takes, in button widths: its symbol and name.
    static func width(_ choice: BrowserTargetChoice) -> Int {
      choice == .remote ? 4 : 3
    }

    var body: some View {
      Menu {
        BrowserTargetMenuItems(state: state, choose: choose)
      } label: {
        Label(state.choice.title, systemImage: state.choice.systemImage)
          .labelStyle(.titleAndIcon)
      }
      .fixedSize()
      .help(state.summary)
      .accessibilityLabel(state.summary)
      .accessibilityIdentifier("header-browser-target")
    }
  }
#endif

#if os(iOS)
  /// The title menu's Browser submenu.
  struct BrowserTargetSubmenu: View {
    let state: BrowserTargetState
    let choose: @MainActor (BrowserTargetChoice) -> Void

    var body: some View {
      Menu {
        BrowserTargetMenuItems(state: state, choose: choose)
      } label: {
        Label("Browser", systemImage: state.choice.systemImage)
        Text(state.choice.title)
      }
      .accessibilityIdentifier("header-browser-target")
    }
  }
#endif
