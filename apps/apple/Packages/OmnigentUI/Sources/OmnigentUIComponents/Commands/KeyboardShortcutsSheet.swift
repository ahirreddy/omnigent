public import SwiftUI

/// Grouped keyboard help for the native client, including focus-specific shortcuts.
public struct KeyboardShortcutsSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// Creates shortcut help.
  public init() {}

  /// The shortcut reference.
  public var body: some View {
    NavigationStack {
      List {
        Section("Navigation") {
          shortcut("Command palette", "⌘K")
          shortcut("Keyboard shortcuts", "⌘/")
          shortcut("New session", "⌘N")
          shortcut("Previous / next session", "⌘[ / ⌘]")
          shortcut("Right panel", "⌥⌘I / ⌥⌘]")
          shortcut("Chat / Terminal", "⌥⌘\\")
        }
        Section("Conversation") {
          shortcut("Rename session", "⌥⌘R")
          shortcut("Focus composer", "⌃⇧L")
          shortcut("Jump to latest", "⌘↓")
          shortcut("Send message", "Return / ⌘Return")
          shortcut("Insert a newline", "⇧Return / ⌥Return")
          shortcut("Stop agent", "Esc / ⌘.")
          shortcut("Paste as attachment", "⌥⌘V")
          shortcut("Approve focused request", "⌘Return")
          shortcut("Cycle approval mode", "⇧Tab")
        }
        Section("Inbox · when the list has focus") {
          shortcut("Next / previous item", "J / K or ↓ / ↑")
          shortcut("Open session", "Return")
          shortcut("Approve / mark read", "E")
          shortcut("Search", "/")
          Text("Marking read does not resolve a request. Questions and forms require an answer.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Tabs") {
          shortcut("New tab", "⌘T")
          shortcut("Close tab", "⌘W")
          shortcut("Reopen closed tab", "⇧⌘T")
          shortcut("Select tab 1–8 / last tab", "⌘1–⌘8 / ⌘9")
          shortcut("Next / previous tab", "⌃Tab / ⌃⇧Tab")
          shortcut("Show all tabs", "⇧⌘\\")
          shortcut("Session terminal / chat", "⌃`")
        }
        Section("Palette") {
          shortcut("Navigate results", "↓ / ↑")
          shortcut("Open selected result", "Return")
          shortcut("Close", "Esc")
        }
        #if os(macOS)
          Section("Mac windows and search") {
            shortcut("New window", "⇧⌘N")
            shortcut("Close window", "⇧⌘W")
            shortcut("Settings", "⌘,")
            shortcut("Reconnect", "⇧⌥⌘R")
            shortcut("Browser tab", "⌥⌘B")
            shortcut("Zoom in / out / actual size", "⌘+ / ⌘− / ⌘0")
            shortcut("Find", "⌘F")
            shortcut("Find next / previous", "⌘G / ⇧⌘G")
            shortcut("Use selection for Find", "⌘E")
          }
        #endif
        Section("Editing") {
          shortcut("Undo sidebar action", "⌘Z")
          Text(
            "Send keys follow composer preferences. On iPhone and iPad, Return inserts a newline."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
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
  }

  private func shortcut(_ title: String, _ keys: String) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: Theme.Spacing.large)
      Text(keys).font(.callout.monospaced()).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
