import SwiftUI

/// The whole chat takes dropped files as composer attachments, as on the web, with a "Drop files
/// here" outline while a drag hovers over it.
struct ChatDropTarget: ViewModifier {
  /// Attachments are accepted now.
  let isEnabled: Bool
  let add: (@MainActor ([ComposerAttachmentInput]) -> Void)?
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .dropDestination(for: URL.self, isEnabled: isEnabled && add != nil) { urls, _ in
        isTargeted = false
        guard !urls.isEmpty else { return }
        add?(urls.map { .file(url: $0) })
      }
      .modifier(DropTargetTracking(isTargeted: $isTargeted))
      .overlay {
        if isTargeted, isEnabled {
          RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.tint)
            .background(.tint.opacity(0.06), in: .rect(cornerRadius: Theme.Radius.large))
            .overlay {
              Label("Drop files here", systemImage: "arrow.down.doc")
                .font(.headline)
                .foregroundStyle(.tint)
            }
            .padding(Theme.Spacing.medium)
            .allowsHitTesting(false)
            .accessibilityIdentifier("chat-drop-target")
        }
      }
  }
}

extension View {
  /// Accepts files dropped anywhere on the chat as attachments.
  func chatDropTarget(
    isEnabled: Bool, add: (@MainActor ([ComposerAttachmentInput]) -> Void)?
  ) -> some View {
    modifier(ChatDropTarget(isEnabled: isEnabled, add: add))
  }
}
