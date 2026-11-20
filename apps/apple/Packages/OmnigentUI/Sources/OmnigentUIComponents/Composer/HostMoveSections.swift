import SwiftUI

/// Switch Host's fields for a new sandbox, as the web's: the repository cloned as the working
/// directory and its branch, both optional, with the problem under the field it belongs to.
struct HostMoveSandboxSection: View {
  @Binding var repository: String
  @Binding var branch: String
  let problem: HostMoveRepoProblem?

  var body: some View {
    Section {
      TextField(
        "Repository (optional)", text: $repository, prompt: Text("https://github.com/org/repo")
      )
      .font(Theme.codeFont)
      .autocorrectionDisabled()
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
      #endif
      .accessibilityIdentifier("switch-host-sandbox-repo")
      if let problem, !problem.isBranch {
        problemLabel(problem)
      } else {
        Text(
          "Cloned into the sandbox as the session\u{2019}s working directory. Leave blank to "
            + "start in an empty sandbox."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      TextField("Branch (optional)", text: $branch, prompt: Text("main"))
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .accessibilityIdentifier("switch-host-sandbox-branch")
      if let problem, problem.isBranch {
        problemLabel(problem)
      }
    } header: {
      Label("Repository", systemImage: "arrow.triangle.branch")
    } footer: {
      Label(
        "Files don\u{2019}t move into the sandbox. Anything uncommitted stays on the old machine, "
          + "and the agent picks up in the new sandbox instead.",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(Theme.warning)
      .accessibilityIdentifier("switch-host-sandbox-warning")
    }
  }

  private func problemLabel(_ problem: HostMoveRepoProblem) -> some View {
    Label(problem.message, systemImage: "exclamationmark.circle")
      .font(.callout)
      .foregroundStyle(Theme.failure)
      .accessibilityIdentifier("switch-host-sandbox-problem")
  }
}

/// Resume on a Machine's optional worktree: a new branch, and its base once a branch is typed.
struct HostMoveWorktreeSection: View {
  @Binding var branch: String
  @Binding var baseBranch: String

  var body: some View {
    Section {
      TextField("Branch", text: $branch, prompt: Text("feature/my-branch"))
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        .accessibilityIdentifier("resume-dir-branch")
      if !branch.trimmingCharacters(in: .whitespaces).isEmpty {
        TextField(
          "Base branch", text: $baseBranch,
          prompt: Text("Base branch (defaults to the current branch)")
        )
        .font(Theme.codeFont)
        .autocorrectionDisabled()
        .accessibilityIdentifier("resume-dir-base-branch")
      }
    } header: {
      Label("Git worktree (optional)", systemImage: "arrow.triangle.branch")
    } footer: {
      Text(
        "Creates a git worktree for a new branch in an isolated directory. Leave blank to "
          + "start in the picked directory.")
    }
  }
}

/// Why a move failed. A move that left the old host and didn't start says the session may run
/// nowhere, in the web's words for a host launch and for a sandbox request.
struct HostMoveErrorSection: View {
  let error: String
  let stranded: Bool
  /// The sandbox request failed after the release, so whether it moved isn't known.
  let unconfirmed: Bool

  var body: some View {
    Section {
      if unconfirmed {
        Text(
          "The session left its old host, but we could not confirm the move completed. Check "
            + "its current host before retrying. Pick a host \u{2014} including the one it came "
            + "from \u{2014} and try again."
        )
        .foregroundStyle(Theme.failure)
        Text(error).font(.callout).foregroundStyle(.secondary)
      } else if stranded {
        Text(
          "The session left its old host but didn\u{2019}t start on the new one, so it isn\u{2019}t "
            + "running anywhere. Pick a host \u{2014} including the one it came from \u{2014} and "
            + "try again."
        )
        .foregroundStyle(Theme.failure)
        Text(error).font(.callout).foregroundStyle(.secondary)
      } else {
        Text(error).foregroundStyle(Theme.failure)
      }
    }
    .accessibilityIdentifier("host-move-error")
  }
}
