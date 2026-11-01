import SwiftUI

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
        .keyboardShortcut("v", modifiers: [.command, .option])
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
      .keyboardShortcut("e", modifiers: [.command, .shift])
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
