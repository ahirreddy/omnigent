import SwiftUI

/// Where a comment goes, for the line beside its button (the web's `PullRequestCommentForm`).
nonisolated enum PullRequestCommentDestination: Hashable, Sendable {
  /// The provider, posted as the host's account; `nil` when the host doesn't name it.
  case provider(account: String?, providerName: String)
  /// A new review conversation on the provider.
  case newThread(account: String?, providerName: String)
  /// A local comment for the agent, which posts as no account.
  case agent

  /// "Comment as ann", "@ann" on a new conversation, or the host's account unnamed.
  var line: String? {
    switch self {
    case .provider(let account?, _): "Comment as \(account)"
    case .newThread(let account?, _): "@\(account)"
    case .provider(nil, let name), .newThread(nil, let name): "Host\u{2019}s \(name) account"
    case .agent: nil
    }
  }
}

/// A comment being written, as the web's form has it: Write and Preview, why it can't post, the
/// account it posts as, then Cancel and the post button.
struct PullRequestCommentField: View {
  let prompt: String
  let text: String
  let isBusy: Bool
  let problem: String?
  let destination: PullRequestCommentDestination
  let setText: @MainActor (String) -> Void
  let post: (@MainActor () -> Void)?
  let postTitle: String
  var cancel: (@MainActor () -> Void)?
  var lineLimit = 1...8
  /// The field's accessibility identifier.
  var identifier: String?
  /// Command-Return posts; one field per window may take it.
  var postsOnCommandReturn = false

  @State private var previewing = false

  private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Picker("Comment view", selection: $previewing) {
        Text("Write").tag(false)
        Text("Preview").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      if previewing {
        preview
      } else {
        TextField(prompt, text: Binding(get: { text }, set: { setText($0) }), axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(lineLimit)
          .disabled(isBusy)
          .accessibilityIdentifier(identifier ?? "")
      }
      if let problem {
        Text(problem).font(.caption).foregroundStyle(Theme.failure)
          .accessibilityIdentifier("pr-comment-problem")
      }
      HStack(spacing: Theme.Spacing.small) {
        if let line = destination.line {
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(line)
        } else {
          Spacer(minLength: 0)
        }
        if let cancel {
          Button("Cancel", action: cancel)
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
        if let post {
          postButton(post)
        }
      }
      .controlSize(.small)
    }
    .padding(Theme.Spacing.small)
  }

  @ViewBuilder private func postButton(_ post: @escaping @MainActor () -> Void) -> some View {
    let button = Button(postTitle, action: post)
      .primaryActionStyle()
      .disabled(isBusy || blank || problem != nil)
    if postsOnCommandReturn {
      button.keyboardShortcut(.return, modifiers: .command)
    } else {
      button
    }
  }

  private var preview: some View {
    Group {
      if blank {
        Text("Nothing to preview.").foregroundStyle(.secondary)
      } else {
        ScrollView {
          MarkdownView(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.small)
    .accessibilityIdentifier("pr-comment-preview")
  }
}
