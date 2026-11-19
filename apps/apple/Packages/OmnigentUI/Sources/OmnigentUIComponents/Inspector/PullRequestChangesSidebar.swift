import OmnigentWorkspaceUI
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The Changes file list: the path filter over the changed files as a folder tree, which
/// jumps the diff to a file; its right edge drags to resize it.
struct PullRequestChangesSidebar: View {
  let state: PullRequestChangesState
  let actions: PullRequestChangesActions
  @Binding var width: CGFloat

  @State private var collapsedFolders: Set<String> = []
  @State private var dragStart: CGFloat?

  /// The web's `useResizableColumn(192, 140, 560)`.
  static let widths: ClosedRange<CGFloat> = 140...560

  var body: some View {
    VStack(spacing: 0) {
      if state.offersFilter {
        PullRequestPathFilterField(value: state.pathFilter, set: actions.setPathFilter)
          .padding(Theme.Spacing.small)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          if state.treeLoading {
            ProgressView().frame(maxWidth: .infinity).padding(Theme.Spacing.medium)
          } else if let message = state.treeMessage {
            Text(message)
              .font(.callout)
              .foregroundStyle(.secondary)
              .padding(Theme.Spacing.small)
          } else {
            ForEach(PullRequestFileTree.build(state.treeFiles), id: \.id) { node in
              PullRequestTreeRow(
                node: node, depth: 0, state: state, collapsed: $collapsedFolders,
                jump: actions.jumpToFile)
            }
          }
        }
      }
    }
    .frame(width: width)
    .overlay(alignment: .trailing) { resizeHandle }
    .accessibilityIdentifier("pr-file-tree")
  }

  private var resizeHandle: some View {
    Color.clear
      .frame(width: 6)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { drag in
            let start = dragStart ?? width
            dragStart = start
            width = min(
              max(start + drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound)
          }
          .onEnded { _ in dragStart = nil }
      )
      #if os(macOS)
        .onHover { inside in
          if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
      #endif
      .accessibilityLabel("Resize file list")
  }
}

/// A folder that folds, or a file that jumps the diff to it.
private struct PullRequestTreeRow: View {
  let node: PullRequestFileTree
  let depth: Int
  let state: PullRequestChangesState
  @Binding var collapsed: Set<String>
  let jump: (@MainActor (String) -> Void)?

  /// VS Code's tree indentation, tuned for the narrow list.
  private var indent: CGFloat { CGFloat(depth) * 10 + 8 }

  var body: some View {
    switch node {
    case .file(let name, let file):
      fileRow(name, file)
    case .folder(let name, let path, let children):
      let open = !collapsed.contains(path)
      Button {
        if open { collapsed.insert(path) } else { collapsed.remove(path) }
      } label: {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(open ? 90 : 0))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .accessibilityHidden(true)
          Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
          Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.head)
          Spacer(minLength: 0)
        }
        .padding(.leading, indent)
        .padding(.trailing, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tiny)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .font(.callout)
      .help(path)
      .accessibilityValue(open ? "Expanded" : "Collapsed")
      if open {
        ForEach(children, id: \.id) { child in
          Self(node: child, depth: depth + 1, state: state, collapsed: $collapsed, jump: jump)
        }
      }
    }
  }

  private func fileRow(_ name: String, _ file: PullRequestTreeFile) -> some View {
    let viewed = state.viewedPaths.contains(file.path)
    return Button {
      jump?(file.path)
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        // The chevron column checks viewed files, so icons line up under a folder's.
        Image(systemName: "checkmark")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .opacity(viewed ? 1 : 0)
          .frame(width: 12)
          .accessibilityHidden(true)
        Image(systemName: PullRequestFileGlyph.symbol(file.kind))
          .foregroundStyle(PullRequestFileGlyph.color(file.kind))
          .accessibilityHidden(true)
        Text(name)
          .lineLimit(1)
          .truncationMode(.head)
          .foregroundStyle(viewed ? .secondary : .primary)
        Spacer(minLength: 0)
        PullRequestDiffStat(added: file.added, removed: file.removed)
      }
      .padding(.leading, indent)
      .padding(.trailing, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.tiny)
      // The file in view reads as the list's selection.
      .selectionFill(state.activePath == file.path, cornerRadius: Theme.Radius.small / 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .font(.callout)
    .help(file.path)
    .accessibilityLabel("\(viewed ? "Viewed, " : "")\(file.path)")
    .accessibilityIdentifier("pr-tree-file-\(file.path)")
  }
}

/// The file glyph carrying how a file changed, as the web's `STATUS_META`.
enum PullRequestFileGlyph {
  static func symbol(_ kind: ChangedFileKind) -> String {
    switch kind {
    case .added: "doc.badge.plus"
    case .modified: "doc.badge.ellipsis"
    case .deleted: "doc.badge.minus"
    case .renamed: "arrow.right.doc.on.clipboard"
    }
  }

  static func color(_ kind: ChangedFileKind) -> Color {
    switch kind {
    case .added: .green
    case .modified: .orange
    case .deleted: .red
    case .renamed: .blue
    }
  }
}

/// "+12 −3", each side shown only when counted.
struct PullRequestDiffStat: View {
  let added: UInt64?
  let removed: UInt64?

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if let added { Text("+\(added)").foregroundStyle(ThemeColor.diffAdded) }
      if let removed { Text("\u{2212}\(removed)").foregroundStyle(ThemeColor.diffRemoved) }
    }
    .font(.caption.monospacedDigit())
    .accessibilityElement(children: .combine)
  }
}
