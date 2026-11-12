import SwiftUI

#if os(macOS)
  import AppKit

  /// The sidebar's search field, drawn by the sidebar itself so its header can sit above it: a
  /// `searchable` field is always the sidebar's first view.
  struct SidebarSearchBox: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
      let field = NSSearchField()
      field.placeholderString = "Search sessions"
      field.controlSize = .large
      field.delegate = context.coordinator
      return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
      context.coordinator.text = $text
      if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
      var text: Binding<String>

      init(text: Binding<String>) {
        self.text = text
      }

      func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        text.wrappedValue = field.stringValue
      }

      /// The field's clear button, which empties it without a text change.
      func searchFieldDidEndSearching(_ sender: NSSearchField) {
        text.wrappedValue = ""
      }
    }
  }

  /// What the sidebar itself is drawn on, behind the bars pinned over its list, so a row
  /// scrolling under a bar does not show through it.
  struct SidebarBarBackdrop: View {
    @Environment(\.omnigentTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isSidebarPeek) private var isPeek

    var body: some View {
      // A peeking sidebar is a rounded glass panel; its bars stay on that.
      if !isPeek {
        ZStack {
          SidebarMaterial()
          if let tint = theme.palette(for: colorScheme).sidebarTint { tint }
        }
      }
    }
  }

  /// The system's sidebar material, which shows the desktop and nothing of this window.
  private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
      let view = NSVisualEffectView()
      view.material = .sidebar
      view.blendingMode = .behindWindow
      // The window keeps its active look in the background, and so does this.
      view.state = .active
      return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
  }
#endif
