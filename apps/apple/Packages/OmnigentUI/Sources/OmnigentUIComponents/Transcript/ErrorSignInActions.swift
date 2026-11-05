import SwiftUI

/// What asking the session's host for its live sign-in found.
nonisolated public enum SignInOutcome: Hashable, Sendable {
  /// The sign-in page opened; `code` is the one-time code it asks for, when there is one.
  case opened(code: String?)
  /// The terminal no longer waits on a sign-in.
  case notPending
  /// The host could not be reached.
  case failed(String)
}

/// A pending sign-in's actions on its error card (the web's `error-remediation-actions`): open
/// the link the terminal shows now, fetched at click time because a saved one goes stale, then
/// copy its one-time code.
struct ErrorSignInActions: View {
  let rowID: String
  let openSignIn: @MainActor () async -> SignInOutcome
  @State private var isFetching = false
  @State private var code: String?
  @State private var note: String?

  /// Failure codes whose card offers the live sign-in link.
  static let pendingCodes: Set<String> = ["databricks_sign_in_pending"]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(spacing: Theme.Spacing.small) {
        Button {
          Task { await fetch() }
        } label: {
          Label(
            isFetching ? "Fetching Link\u{2026}" : "Open Sign-In Link",
            systemImage: "arrow.up.forward.square")
        }
        .buttonStyle(.bordered)
        .disabled(isFetching)
        .accessibilityIdentifier("error-sign-in-\(rowID)")
        if let code {
          CopyButton(
            text: code, label: "Copy Code \(code)", identifier: "error-sign-in-code-\(rowID)",
            showsLabel: true)
        }
      }
      if let note {
        Text(note)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("error-sign-in-note-\(rowID)")
      }
    }
  }

  private func fetch() async {
    guard !isFetching else { return }
    isFetching = true
    note = nil
    let outcome = await openSignIn()
    isFetching = false
    (code, note) = Self.display(outcome, previousCode: code)
  }

  /// The code to offer and the note to show for `outcome`.
  static func display(_ outcome: SignInOutcome, previousCode: String?) -> (String?, String?) {
    switch outcome {
    case .opened(let code):
      (code, nil)
    case .notPending:
      // A code fetched earlier belongs to a prompt that is gone.
      (nil, "No sign-in is pending in the terminal any more. Try sending your message again.")
    case .failed(let message):
      (previousCode, "Could not reach the host for a fresh link: \(message)")
    }
  }
}

/// The error card's sign-in link and fork, for the CLI transcript's error line, which shows
/// Retry on its own.
struct ErrorRecoveryLinks: View {
  let row: Row
  let activity: Activity
  @Environment(\.conversationActions) private var actions

  var body: some View {
    let code = activity.detail("code")
    if let openSignIn = actions.openSignIn, ErrorSignInActions.pendingCodes.contains(code ?? "") {
      ErrorSignInActions(rowID: row.id, openSignIn: openSignIn)
    }
    if let label = ErrorRowView.forkLabel(code: code), let fork = actions.forkToRecover {
      let elsewhere = ErrorRowView.isWorkspaceMissing(activity)
      Button(label, systemImage: elsewhere ? "folder" : "arrow.triangle.branch") {
        fork(elsewhere)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("error-fork-\(row.id)")
    }
  }
}
