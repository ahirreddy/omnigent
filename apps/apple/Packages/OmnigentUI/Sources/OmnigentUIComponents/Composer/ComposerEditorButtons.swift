import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The Mac's own dictation (Edit › Start Dictation), for a host without its own dictate action.
enum SystemDictation {
  /// Starts dictation into the focused text view.
  /// - Returns: Whether a responder took the request.
  @MainActor static func start() -> Bool {
    #if os(macOS)
      NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    #else
      false
    #endif
  }
}

/// Shift-Command-E without a visible button, for the Mac's pill, which has no Expand button.
struct ComposerExpandShortcut: View {
  @Binding var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(isExpanded ? "Collapse Editor" : "Expand Editor") {
      withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
    }
    .keyboardShortcut(AppShortcuts.expandEditor)
    .buttonStyle(.plain)
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

/// Dictate and Expand in the composer's action row: symbols with tooltips, accessibility labels
/// and hints, and keyboard shortcuts (Option-Command-V, Shift-Command-E).
struct ComposerEditorButtons: View {
  let dictate: (@MainActor () -> Void)?
  let isEditable: Bool
  /// Expand is for wide layouts; compact widths keep the editor's usual height.
  let showsExpand: Bool
  @Binding var isExpanded: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if let dictate {
      Button("Dictate", systemImage: "mic", action: dictate)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .composerChip()
        .keyboardShortcut(AppShortcuts.dictate)
        .help("Dictate (Option-Command-V)")
        .accessibilityHint("Types what you say into the message")
        .disabled(!isEditable)
        .accessibilityIdentifier("composer-mic")
    }
    if showsExpand {
      Button {
        withAnimation(reduceMotion ? nil : .snappy) { isExpanded.toggle() }
      } label: {
        Label(
          isExpanded ? "Collapse Editor" : "Expand Editor",
          systemImage: isExpanded
            ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .composerChip()
      .keyboardShortcut(AppShortcuts.expandEditor)
      .help(
        isExpanded
          ? "Collapse the editor (Shift-Command-E)" : "Expand the editor (Shift-Command-E)"
      )
      .accessibilityHint(
        isExpanded ? "Returns the editor to its usual height" : "Gives the editor more room"
      )
      .accessibilityIdentifier("composer-expand")
    }
  }
}
