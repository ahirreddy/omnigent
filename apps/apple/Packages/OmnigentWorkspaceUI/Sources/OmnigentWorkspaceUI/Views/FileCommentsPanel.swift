import SwiftUI

/// The file's comments beside (or, when narrow, below) the text, as the web's `CommentsPanel`:
/// Open and Sent tabs, "Address All" sends the open ones to the agent, and each comment can be
/// edited, deleted, resolved or reopened. Selecting one marks its line.
struct FileCommentsPanel: View {
  let review: FileReviewContext
  @Binding var selectedID: String?
  let close: () -> Void
  @State private var tab = Tab.open
  @State private var isSending = false
  @State private var failure: String?

  enum Tab: Hashable { case open, sent }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      Picker("Comments", selection: $tab) {
        Text(title("Open", review.openComments.count)).tag(Tab.open)
        Text(title("Sent", sent.count)).tag(Tab.sent)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(8)
      .accessibilityIdentifier("workspace.comments.tabs")
      if !review.canComment {
        Text("You have read-only access to this session.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
      }
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
          .accessibilityIdentifier("workspace.comments.failure")
      }
      list
    }
    .onChange(of: selectedID) { _, id in
      guard let id, let comment = review.comments.first(where: { $0.id == id }) else { return }
      let shown: Tab = comment.isOpen ? .open : .sent
      if tab != shown { tab = shown }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.comments")
  }

  private var sent: [FileCommentLine] { review.comments.filter { !$0.isOpen } }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Comments")
        .font(.subheadline.weight(.semibold))
      Spacer(minLength: 4)
      if tab == .open {
        Button("Address All", systemImage: "wand.and.sparkles") { sendAll() }
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .controlSize(.small)
          .disabled(review.sendAll == nil || review.openComments.isEmpty || isSending)
          .help("Send the open comments to the agent")
          .accessibilityIdentifier("workspace.comments.addressAll")
      }
      Button("Hide Comments", systemImage: "xmark", action: close)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("workspace.comments.close")
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
  }

  @ViewBuilder private var list: some View {
    let comments = tab == .open ? review.openComments : sent
    if comments.isEmpty {
      Text(tab == .open ? "No open comments." : "No sent comments.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 8) {
            ForEach(comments) { comment in
              CommentCard(
                comment: comment, isSelected: selectedID == comment.id, review: review,
                report: { failure = $0 },
                select: {
                  selectedID = comment.id
                  if let line = comment.line { review.reveal(line) }
                }
              )
              .id(comment.id)
            }
          }
          .padding(10)
        }
        .onChange(of: selectedID) { _, id in
          guard let id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
  }

  private func title(_ name: String, _ count: Int) -> String {
    count > 0 ? "\(name) \(count)" : name
  }

  private func sendAll() {
    guard let send = review.sendAll else { return }
    isSending = true
    failure = nil
    Task {
      do throws(WorkspaceFailure) {
        try await send()
      } catch {
        failure = error.message
      }
      isSending = false
    }
  }
}

/// One comment: the commented text, the comment (four lines until "Show more"), who left it
/// and when, and its actions. Edit replaces the text with a field.
private struct CommentCard: View {
  let comment: FileCommentLine
  let isSelected: Bool
  let review: FileReviewContext
  let report: (String?) -> Void
  let select: () -> Void
  @State private var editing = false
  @State private var draft = ""
  @State private var expanded = false
  @State private var isBusy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let anchor = comment.anchor {
        Text(anchor.trimmingCharacters(in: .whitespacesAndNewlines))
          .font(WorkspaceTheme.code)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      if editing { editor } else { bodyText }
      if !editing { footer }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
      in: .rect(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
    }
    .contentShape(.rect)
    .onTapGesture { if !editing { select() } }
    .accessibilityAddTraits(.isButton)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace.comment.\(comment.id)")
  }

  @ViewBuilder private var bodyText: some View {
    let long = comment.body.count > 240 || comment.body.count { $0 == "\n" } >= 4
    VStack(alignment: .leading, spacing: 2) {
      Text(comment.body)
        .font(.callout)
        .lineLimit(expanded ? nil : 4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if long {
        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
          .buttonStyle(.borderless)
          .foregroundStyle(.tint)
          .font(.caption)
      }
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Comment", text: $draft, axis: .vertical)
        .lineLimit(2...8)
        .textFieldStyle(.roundedBorder)
        .onSubmit(save)
        .accessibilityIdentifier("workspace.comment.editText")
      HStack(spacing: 6) {
        Button("Save", action: save)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
          .accessibilityIdentifier("workspace.comment.save")
        Button("Cancel") { editing = false }
          .keyboardShortcut(.cancelAction)
      }
      .controlSize(.small)
    }
  }

  private var footer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          let name = comment.author ?? "You"
          Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Self.avatarColor(name), in: .circle)
            .accessibilityHidden(true)
          Text(name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(FileCommentTime.label(comment.createdAt))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        if !comment.isOpen {
          Text("Sent")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: .rect(cornerRadius: 4))
        }
      }
      Spacer(minLength: 4)
      actions
    }
  }

  @ViewBuilder private var actions: some View {
    HStack(spacing: 10) {
      if let update = review.update, review.canComment {
        if comment.isOpen, comment.canModify {
          Button("Edit") {
            draft = comment.body
            editing = true
          }
          .accessibilityIdentifier("workspace.comment.edit")
        }
        Button(comment.isOpen ? "Resolve" : "Reopen") {
          let open = !comment.isOpen
          run { () async throws(WorkspaceFailure) in try await update(comment, nil, open) }
        }
        .help(comment.isOpen ? "Mark as addressed without sending it" : "Move back to Open")
        .accessibilityIdentifier(
          comment.isOpen ? "workspace.comment.resolve" : "workspace.comment.reopen")
      }
      if let delete = review.delete, review.canComment, comment.canModify {
        Button("Delete", role: .destructive) {
          run { () async throws(WorkspaceFailure) in try await delete(comment) }
        }
        .accessibilityIdentifier("workspace.comment.delete")
      }
    }
    .buttonStyle(.borderless)
    .font(.caption)
    .disabled(isBusy)
  }

  private func save() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let update = review.update else { return }
    run { () async throws(WorkspaceFailure) in
      try await update(comment, text, nil)
      editing = false
    }
  }

  private func run(_ body: @escaping () async throws(WorkspaceFailure) -> Void) {
    isBusy = true
    report(nil)
    Task {
      do throws(WorkspaceFailure) {
        try await body()
      } catch {
        report(error.message)
      }
      isBusy = false
    }
  }

  /// A steady color per name, as the web's avatar.
  static func avatarColor(_ name: String) -> Color {
    let hash = name.unicodeScalars.reduce(UInt32(0)) { ($0 &* 31) &+ $1.value }
    return Color(hue: Double(hash % 360) / 360, saturation: 0.6, brightness: 0.75)
  }
}

/// When a comment was left, as the web shows it: "3:04 PM Today", "3:04 PM Yesterday", or
/// "Nov 3 3:04 PM".
enum FileCommentTime {
  static func label(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return "\(time) Today" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "\(time) Yesterday"
    }
    return "\(date.formatted(.dateTime.month(.abbreviated).day())) \(time)"
  }
}
