public import SwiftUI

/// Under the new-session heading while it runs or plans a saved workflow: whether the run starts
/// with the user reviewing the plan, and Cancel, which leaves the workflow.
public struct NewSessionWorkflowControls: View {
  private let reviewPlanFirst: Binding<Bool>?
  private let cancel: @MainActor () -> Void

  /// Creates the controls.
  /// - Parameters:
  ///   - reviewPlanFirst: A run's review choice; `nil` for a planning chat.
  ///   - cancel: Leaves the workflow for an ordinary new session.
  public init(reviewPlanFirst: Binding<Bool>?, cancel: @escaping @MainActor () -> Void) {
    self.reviewPlanFirst = reviewPlanFirst
    self.cancel = cancel
  }

  /// The controls.
  public var body: some View {
    VStack(spacing: Theme.Spacing.small) {
      if let reviewPlanFirst {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Toggle("Review the plan before work starts", isOn: reviewPlanFirst)
            #if os(macOS)
              .toggleStyle(.checkbox)
            #endif
            .accessibilityIdentifier("new-session-workflow-review")
          Text("The agent shows you its plan and waits for your approval.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      Button("Cancel", action: cancel)
        .buttonStyle(.borderless)
        .font(.callout)
        .accessibilityIdentifier("new-session-workflow-cancel")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-workflow")
  }
}
