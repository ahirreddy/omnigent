public import SwiftUI

/// Where an approval link's request stands, as the web's `/approve/<session>/<request>` page.
nonisolated public enum ApprovalLinkState: Hashable, Sendable {
  /// Being read.
  case loading
  /// Waiting for an answer, with where the answer stands.
  case pending(DecisionCard, DecisionPhase)
  /// No longer waiting: answered, timed out, cancelled, or unknown.
  case resolved
  /// Answered here: approved, or rejected.
  case submitted(approved: Bool)
  /// The request could not be read, with why.
  case failed(String)
}

/// One approval request opened from a link, answered on its own: the web's approve page drawn
/// as a sheet around the chat's own approval card.
public struct ApprovalLinkView: View {
  let state: ApprovalLinkState
  let respond: @MainActor (DecisionResponse) -> Void
  let openSession: (@MainActor () -> Void)?
  let done: @MainActor () -> Void

  /// Creates the view.
  /// - Parameters:
  ///   - state: Where the request stands.
  ///   - respond: Answers the request.
  ///   - openSession: Opens the request's session, where it shows in the chat.
  ///   - done: Closes the sheet.
  public init(
    state: ApprovalLinkState, respond: @escaping @MainActor (DecisionResponse) -> Void,
    openSession: (@MainActor () -> Void)?, done: @escaping @MainActor () -> Void
  ) {
    self.state = state
    self.respond = respond
    self.openSession = openSession
    self.done = done
  }

  /// The sheet: buttons along the bottom on the Mac, in the navigation bar on iPhone and iPad.
  public var body: some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
          if let openSession { openSessionButton(openSession) }
          Spacer()
          doneButton
        }
      }
      .padding(Theme.Spacing.large)
      .frame(width: 520)
      .accessibilityIdentifier("approval-link")
    #else
      NavigationStack {
        content
          .padding(Theme.Spacing.large)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .toolbar {
            if let openSession {
              ToolbarItem(placement: .topBarLeading) { openSessionButton(openSession) }
            }
            ToolbarItem(placement: .confirmationAction) { doneButton }
          }
      }
      .accessibilityIdentifier("approval-link")
    #endif
  }

  private func openSessionButton(_ openSession: @escaping @MainActor () -> Void) -> some View {
    Button("Open Session", action: openSession)
      .accessibilityIdentifier("approval-link-open-session")
  }

  private var doneButton: some View {
    Button("Done", action: done)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("approval-link-done")
  }

  @ViewBuilder private var content: some View {
    switch state {
    case .loading:
      ProgressView("Loading elicitation\u{2026}")
        .frame(maxWidth: .infinity, minHeight: 120)
    case .pending(let card, let phase):
      ScrollView {
        DecisionCardView(card: card, phase: phase, respond: { respond($0) })
      }
      #if os(macOS)
        .frame(maxHeight: 520)
      #endif
    case .resolved:
      ContentUnavailableView(
        "Elicitation resolved", systemImage: "checkmark.circle",
        description: Text(
          "This approval request is no longer pending. It may have been resolved, timed out, or cancelled."
        ))
    case .submitted(let approved):
      ContentUnavailableView {
        Label(
          approved ? "Approved" : "Rejected",
          systemImage: approved ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(approved ? Theme.success : Theme.failure)
      }
      .accessibilityIdentifier("approval-link-submitted")
    case .failed(let message):
      ContentUnavailableView(
        "Error", systemImage: "exclamationmark.triangle", description: Text(message))
    }
  }
}
