import SwiftUI

/// The completions over the composer: every match, scrolling past a few rows, with "Commands"
/// and "Skills" headers. Up and Down move the highlighted row; Return and Tab apply it. While an
/// `@` mention browses the workspace, a folder row opens the folder and its Attach button (or
/// Tab) attaches it whole.
struct CompletionList: View {
  let items: [ComposerCompletions.Item]
  /// Why the list may be incomplete.
  var note: String?
  /// The row Return and Tab apply.
  var highlighted: Int?
  /// The folder an `@` mention browses (`""` for the workspace root), for the header.
  var mentionFolder: String?
  /// Attaches a folder row whole; `nil` hides the button.
  var attachFolder: ((ComposerCompletions.Item) -> Void)?
  let pick: (ComposerCompletions.Item) -> Void
  @Environment(\.composerLayoutStyle) private var layout

  /// The list's tallest height before it scrolls.
  private static let maxHeight: CGFloat = 320

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let mentionFolder, !items.isEmpty {
        mentionHeader(mentionFolder)
      }
      ViewThatFits(in: .vertical) {
        rows
        ScrollViewReader { proxy in
          ScrollView { rows }
            .onChange(of: highlighted) { _, index in
              guard let index, items.indices.contains(index) else { return }
              proxy.scrollTo(items[index].id)
            }
        }
      }
      .frame(maxHeight: Self.maxHeight)
      if let note {
        Label(note, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .accessibilityIdentifier("composer-completion-note")
      }
      if !items.isEmpty, layout != .touch {
        Text(hint)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.extraSmall)
      }
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    .padding(.horizontal, Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-completions")
  }

  private var hint: String {
    if items.contains(where: \.isFolder) {
      return "\u{2191}\u{2193} to choose, Return to open a folder, Tab to attach, Esc to dismiss"
    }
    return "\u{2191}\u{2193} to choose, Tab or Return to complete, Esc to dismiss"
  }

  private func mentionHeader(_ folder: String) -> some View {
    Text(folder.isEmpty ? "Workspace" : "/\(folder)")
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.head)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .accessibilityAddTraits(.isHeader)
      .accessibilityIdentifier("composer-completion-folder")
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if let section = item.section {
          Text(section)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.top, index == 0 ? 0 : Theme.Spacing.small)
            .padding(.bottom, Theme.Spacing.tiny)
            .accessibilityAddTraits(.isHeader)
        }
        row(item, isHighlighted: index == highlighted)
          .id(item.id)
      }
    }
  }

  private func row(_ item: ComposerCompletions.Item, isHighlighted: Bool) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Button {
        pick(item)
      } label: {
        HStack(spacing: Theme.Spacing.small) {
          Image(systemName: item.systemImage)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .accessibilityHidden(true)
          Text(item.title).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
          if !item.detail.isEmpty {
            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(item.isFolder ? "Opens the folder" : "")
      .accessibilityIdentifier("composer-completion-\(item.id)")
      if item.isFolder, let attachFolder {
        Button("Attach", systemImage: "plus") { attachFolder(item) }
          .font(.caption)
          .buttonStyle(.bordered)
          .controlSize(.small)
          .help("Attach the whole folder")
          .accessibilityLabel("Attach whole folder \(item.title)")
          .accessibilityIdentifier("composer-completion-attach-\(item.id)")
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        .fill(ThemeColor.hover.opacity(isHighlighted ? 1 : 0))
    )
    .hoverHighlight()
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
  }
}
