public import SwiftUI

/// Grouped keyboard help for the native client, built from ``AppShortcuts`` so it lists what the
/// keys do; send keys follow the composer's send preference.
public struct KeyboardShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var submitWithCommandReturn = ComposerPreferences.commandReturnSends
  private let nestedAgents: Bool
  private let terminalSplit: Bool
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Creates shortcut help.
  /// - Parameters:
  ///   - nestedAgents: The server can add nested agents, so their shortcut is listed.
  ///   - terminalSplit: The server splits Terminal views, so their shortcuts are listed where
  ///     the split shows (not at compact width).
  public init(nestedAgents: Bool = false, terminalSplit: Bool = false) {
    self.nestedAgents = nestedAgents
    self.terminalSplit = terminalSplit
  }

  private var groups: [ShortcutGroup] {
    #if os(macOS)
      ShortcutGuide.groups(
        submitWithCommandReturn: submitWithCommandReturn, isMac: true, nestedAgents: nestedAgents,
        terminalSplit: terminalSplit)
    #else
      ShortcutGuide.groups(
        submitWithCommandReturn: submitWithCommandReturn, isMac: false, nestedAgents: nestedAgents,
        terminalSplit: terminalSplit && sizeClass == .regular)
    #endif
  }

  /// The shortcut reference.
  public var body: some View {
    NavigationStack {
      List {
        ForEach(groups) { group in
          Section {
            ForEach(group.rows) { shortcut($0) }
          } header: {
            if let note = group.note {
              Text("\(group.title) · \(note)")
            } else {
              Text(group.title)
            }
          }
        }
        #if !os(macOS)
          Text("With a touch keyboard, Return inserts a new line.")
            .font(.caption).foregroundStyle(.secondary)
        #endif
      }
      .navigationTitle("Keyboard shortcuts")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("shortcuts-done")
        }
      }
    }
    .frame(idealWidth: 540, idealHeight: 620)
    .accessibilityIdentifier("keyboard-shortcuts")
    .commandReturnPreference($submitWithCommandReturn)
  }

  private func shortcut(_ row: ShortcutRow) -> some View {
    HStack {
      Text(row.title)
      Spacer(minLength: Theme.Spacing.large)
      Text(row.keys).font(.callout.monospaced()).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
