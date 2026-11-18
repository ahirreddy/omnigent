public import Foundation
import OmnigentPlatform
public import SwiftUI

/// What a changed file's header offers, as the web's `PullRequestFileActions` and
/// `PullRequestViewedToggle`.
nonisolated public struct PullRequestFileActionsState: Hashable, Sendable {
  /// The current path.
  public var path: String
  /// The old path of a renamed file.
  public var previousPath: String?
  /// "Open in GitHub".
  public var openLabel: String
  /// The file on the provider at the revision shown; `nil` explains why in
  /// ``openUnavailable``.
  public var openURL: URL?
  /// Why the file can't be opened.
  public var openUnavailable: String
  /// The file has earlier (outdated) comments to show or hide.
  public var hasEarlierComments = false
  /// Whether its earlier comments show.
  public var earlierCommentsShown = false
  /// Review conversations on the file.
  public var conversations = 0
  /// The Viewed mark shows.
  public var offersViewed = false
  /// Whether the file is viewed.
  public var viewed = false
  /// The file changed since it was viewed.
  public var changedSinceViewed = false

  /// Creates the state.
  public init(
    path: String, previousPath: String?, openLabel: String, openURL: URL?,
    openUnavailable: String
  ) {
    self.path = path
    self.previousPath = previousPath
    self.openLabel = openLabel
    self.openURL = openURL
    self.openUnavailable = openUnavailable
  }
}

/// A changed file's header controls: its conversation count, Copy path, a menu (earlier
/// comments, Copy path on a phone, Copy previous path, Open in the provider) and Viewed.
public struct PullRequestFileActionsView: View {
  private let state: PullRequestFileActionsState
  private let toggleEarlier: (@MainActor () -> Void)?
  private let toggleViewed: (@MainActor () -> Void)?

  @Environment(\.openURL) private var openURL
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Creates the controls.
  /// - Parameters:
  ///   - state: What they show.
  ///   - toggleEarlier: Shows or hides earlier comments.
  ///   - toggleViewed: Marks the file viewed or not.
  public init(
    state: PullRequestFileActionsState, toggleEarlier: (@MainActor () -> Void)?,
    toggleViewed: (@MainActor () -> Void)?
  ) {
    self.state = state
    self.toggleEarlier = toggleEarlier
    self.toggleViewed = toggleViewed
  }

  private var compact: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// The view.
  public var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if state.conversations > 0 {
        Label("\(state.conversations)", systemImage: "text.bubble")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(
            state.conversations == 1 ? "1 conversation" : "\(state.conversations) conversations")
      }
      if !compact {
        Button {
          Pasteboard.copy(state.path)
        } label: {
          Image(systemName: "doc.on.doc").accessibilityLabel("Copy path \(state.path)")
        }
        .help("Copy path")
      }
      menu
      if state.offersViewed, let toggleViewed {
        VStack(alignment: .trailing, spacing: Theme.Spacing.tiny) {
          PullRequestCheckbox(
            title: "Viewed", isOn: state.viewed, accessibilityLabel: "Viewed \(state.path)",
            toggle: toggleViewed)
          if state.changedSinceViewed {
            Text("Changed since viewed")
              .font(.caption2)
              .padding(.horizontal, Theme.Spacing.extraSmall)
              .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator) }
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.borderless)
  }

  private var menu: some View {
    Menu {
      if state.hasEarlierComments, let toggleEarlier {
        Button(
          state.earlierCommentsShown ? "Hide earlier comments" : "Show earlier comments",
          action: toggleEarlier)
      }
      if compact {
        Button("Copy path") { Pasteboard.copy(state.path) }
      }
      if let previous = state.previousPath {
        Button("Copy previous path") { Pasteboard.copy(previous) }
      }
      if let url = state.openURL {
        Button(state.openLabel) { openURL(url) }
      } else {
        Button {
        } label: {
          Text(state.openLabel)
          Text(state.openUnavailable)
        }
        .disabled(true)
      }
    } label: {
      Image(systemName: "ellipsis").accessibilityLabel("More actions for \(state.path)")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

/// "Earlier conversations and unavailable diffs": comments whose file the diff can't show,
/// grouped by path.
public struct PullRequestUnavailableCommentsView: View {
  private let groups: [PullRequestUnavailableComments]

  /// Creates the section.
  /// - Parameter groups: The comments, by file.
  public init(groups: [PullRequestUnavailableComments]) {
    self.groups = groups
  }

  /// The view.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Earlier conversations and unavailable diffs").font(.callout.weight(.medium))
      ForEach(groups) { group in
        HStack {
          Text(group.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          Spacer(minLength: 0)
          if let actions = group.actions { actions }
        }
        .padding(.top, Theme.Spacing.small)
        group.comments
      }
    }
    .padding(Theme.Spacing.medium)
    .accessibilityIdentifier("pr-unavailable-comments")
  }
}

/// A local review comment for the agent, as the web's `LocalReviewComment`: where it is, from
/// an earlier revision or addressed, its text, and edit and delete for its author.
nonisolated public struct PullRequestLocalCommentState: Hashable, Sendable, Identifiable {
  /// Id.
  public var id: String
  /// "New lines 3–5".
  public var lineLabel: String
  /// Written at another revision.
  public var earlier: Bool
  /// The agent addressed it.
  public var addressed: Bool
  /// Markdown.
  public var body: String
  /// The viewer may edit and delete it.
  public var canEdit: Bool

  /// Creates the state.
  public init(
    id: String, lineLabel: String, earlier: Bool, addressed: Bool, body: String, canEdit: Bool
  ) {
    self.id = id
    self.lineLabel = lineLabel
    self.earlier = earlier
    self.addressed = addressed
    self.body = body
    self.canEdit = canEdit
  }

  /// "Old lines 2–4", or "New line 7".
  public static func lineLabel(old: Bool, start: UInt64?, end: UInt64) -> String {
    "\(old ? "Old" : "New") lines \(start ?? end)\u{2013}\(end)"
  }
}

/// What local comments can do.
public struct PullRequestLocalCommentActions {
  /// Saves new text; answers whether it was saved.
  public var edit:
    (@MainActor (_ id: String, _ body: String, _ done: @escaping (Bool) -> Void) -> Void)?
  /// Deletes it.
  public var delete: (@MainActor (_ id: String) -> Void)?
  /// A change is in flight.
  public var isBusy = false

  /// No actions.
  public init() {}
}

/// The local comments under a line or a file header.
public struct PullRequestLocalCommentsView: View {
  private let comments: [PullRequestLocalCommentState]
  private let actions: PullRequestLocalCommentActions

  /// Creates the view.
  public init(comments: [PullRequestLocalCommentState], actions: PullRequestLocalCommentActions) {
    self.comments = comments
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      ForEach(comments) { comment in
        PullRequestLocalCommentCard(comment: comment, actions: actions)
      }
    }
  }
}

private struct PullRequestLocalCommentCard: View {
  let comment: PullRequestLocalCommentState
  let actions: PullRequestLocalCommentActions
  @State private var draft: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack {
        Text(header).font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if comment.canEdit {
          if actions.edit != nil {
            Button {
              draft = comment.body
            } label: {
              Image(systemName: "pencil").accessibilityLabel("Edit local comment")
            }
            .disabled(actions.isBusy || draft != nil)
            .help("Edit comment")
          }
          if let delete = actions.delete {
            Button {
              delete(comment.id)
            } label: {
              Image(systemName: "trash").accessibilityLabel("Delete local comment")
            }
            .disabled(actions.isBusy)
            .help("Delete comment")
          }
        }
      }
      .buttonStyle(.borderless)
      if let draft, let edit = actions.edit {
        TextField(
          "Edit local comment", text: Binding(get: { draft }, set: { self.draft = $0 }),
          axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...8)
        HStack {
          Button("Save") {
            edit(comment.id, draft) { saved in if saved { self.draft = nil } }
          }
          .disabled(actions.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Cancel") { self.draft = nil }.disabled(actions.isBusy)
        }
      } else {
        MarkdownView(comment.body).textSelection(.enabled)
      }
    }
    .padding(Theme.Spacing.small)
    .background(
      ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        .strokeBorder(.separator)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Local review comment")
    .accessibilityIdentifier("pr-local-comment-\(comment.id)")
  }

  private var header: String {
    var parts = ["Local comment", comment.lineLabel]
    if comment.earlier { parts.append("Earlier revision") }
    if comment.addressed { parts.append("Addressed") }
    return parts.joined(separator: " \u{00B7} ")
  }
}
