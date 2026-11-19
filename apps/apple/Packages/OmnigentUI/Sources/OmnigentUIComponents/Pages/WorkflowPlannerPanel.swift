public import SwiftUI

/// The planning chat beside a workflow's page (web `WorkflowPlanningChat`): its title, Open
/// session, Expand (a Mac fills the page with it), Close, and the chat itself.
public struct WorkflowPlannerPanel<Content: View>: View {
  private let title: String
  @Binding private var expanded: Bool
  private let openSession: (@MainActor () -> Void)?
  private let close: @MainActor () -> Void
  private let content: Content

  /// Creates the panel.
  /// - Parameters:
  ///   - title: "Create plan" or "Edit plan".
  ///   - expanded: The panel covers the page.
  ///   - openSession: Opens the planning session's own chat; `nil` before it exists.
  ///   - close: Closes the panel.
  ///   - content: The chat, or a way to start one.
  public init(
    title: String, expanded: Binding<Bool>, openSession: (@MainActor () -> Void)?,
    close: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content
  ) {
    self.title = title
    _expanded = expanded
    self.openSession = openSession
    self.close = close
    self.content = content()
  }

  /// The panel.
  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        if let openSession {
          Button("Open planning session", systemImage: "arrow.up.forward.app", action: openSession)
            .help("Open session")
            .accessibilityIdentifier("workflow-planner-open-session")
        }
        #if os(macOS)
          Button(
            expanded ? "Collapse planning chat" : "Expand planning chat",
            systemImage: expanded
              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
          ) {
            withAnimation(Theme.Motion.disclosure) { expanded.toggle() }
          }
          .help(expanded ? "Collapse" : "Expand")
          .accessibilityIdentifier("workflow-planner-expand")
        #endif
        Button("Close planning chat", systemImage: "xmark", action: close)
          .help("Close")
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("workflow-planner-close")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .padding(.horizontal, Theme.Spacing.large)
      .padding(.vertical, Theme.Spacing.medium)
      Divider()
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
  }
}

/// The planning chat before it exists: what it is for, and Start planning, which picks where
/// the agent runs.
public struct WorkflowPlannerStart: View {
  private let start: @MainActor () -> Void

  /// Creates the prompt.
  /// - Parameter start: Opens the new-session page to start the planning chat.
  public init(start: @escaping @MainActor () -> Void) {
    self.start = start
  }

  /// The prompt.
  public var body: some View {
    ContentUnavailableView {
      Label("Plan with an agent", systemImage: "bubble.left.and.text.bubble.right")
    } description: {
      Text(
        "Describe what the workflow should do. The agent proposes its steps here, and Save plan keeps them."
      )
    } actions: {
      Button("Start planning", action: start)
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("workflow-planner-start")
    }
  }
}
