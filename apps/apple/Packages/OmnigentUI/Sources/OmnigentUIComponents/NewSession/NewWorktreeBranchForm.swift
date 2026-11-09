import SwiftUI

/// Names a new worktree's branch and what it starts from.
struct NewWorktreeBranchForm: View {
  @Binding var branch: String
  @Binding var base: String
  let isValidBranch: (@MainActor (String) -> Bool)?
  let use: (NewSessionWorktreeChoice) -> Void
  let cancel: () -> Void

  private var isBranchValid: Bool {
    let name = branch.trimmingCharacters(in: .whitespaces)
    return isValidBranch?(name) ?? !name.isEmpty
  }

  var body: some View {
    Form {
      TextField("Branch", text: $branch, prompt: Text("feature/my-change"))
        .accessibilityIdentifier("new-session-branch")
      TextField("From", text: $base, prompt: Text("Default branch"))
        .accessibilityIdentifier("new-session-base-branch")
      HStack {
        Spacer()
        Button("Cancel", action: cancel)
        Button("Use Branch") {
          use(
            .new(
              branch: branch.trimmingCharacters(in: .whitespaces),
              base: base.trimmingCharacters(in: .whitespaces)))
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isBranchValid)
      }
    }
    .padding()
    .frame(width: 320)
  }
}
