public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// Every file of a change set in one scroll, unified or side by side: a header per file that
/// collapses it, its hunks, unchanged context that expands ten lines at a time, views under
/// lines and headers, the active find match, and line numbers that choose lines for a review.
public struct StackedDiffList: View {
  private let content: StackedDiffContent
  private let actions: StackedDiffActions
  @State private var topPath: String?

  /// A stacked diff.
  /// - Parameters:
  ///   - content: What it shows.
  ///   - actions: What its controls do.
  public init(content: StackedDiffContent, actions: StackedDiffActions = StackedDiffActions()) {
    self.content = content
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    GeometryReader { geometry in
      let split = content.layout.resolved(width: geometry.size.width) == .split
      let layout = StackedDiffLayout(content, split: split, expands: actions.expand != nil)
      ScrollViewReader { proxy in
        scroll(layout, split: split, width: geometry.size.width)
          .onChange(of: content.scroll) { _, request in
            perform(request, in: layout, proxy: proxy)
          }
          .onAppear { perform(content.scroll, in: layout, proxy: proxy) }
      }
    }
    .accessibilityIdentifier("workspace.stacked-diff")
  }

  private func perform(
    _ request: StackedDiffScroll?, in layout: StackedDiffLayout, proxy: ScrollViewProxy
  ) {
    guard let request, let id = layout.id(of: request.target) else { return }
    let anchor: UnitPoint = if case .line = request.target { .center } else { .top }
    let scrolled = actions.scrolled
    // The revealed file's rows lay out first.
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(id, anchor: anchor)
      scrolled?(request.token)
    }
  }

  @ViewBuilder
  private func scroll(_ layout: StackedDiffLayout, split: Bool, width: CGFloat) -> some View {
    let stack = LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(layout.rows) { entry in
        StackedDiffRowView(
          row: entry.row, content: content, actions: actions, split: split, width: width)
      }
    }
    .scrollTargetLayout()
    .textSelection(.enabled)
    Group {
      if split {
        ScrollView(.vertical) { stack.frame(width: width, alignment: .leading) }
      } else {
        ScrollView([.vertical, .horizontal]) {
          stack.frame(minWidth: width, alignment: .leading)
        }
        .defaultScrollAnchor(.topLeading, for: .alignment)
      }
    }
    .onScrollTargetVisibilityChange(idType: String.self) { visible in
      let top = visible.compactMap { layout.paths[$0] }.min { $0.index < $1.index }?.path
      guard let top, top != topPath else { return }
      topPath = top
      actions.topFileChanged?(top)
    }
  }
}

/// One row of a stacked diff.
private struct StackedDiffRowView: View {
  let row: StackedDiffRow
  let content: StackedDiffContent
  let actions: StackedDiffActions
  let split: Bool
  let width: CGFloat

  var body: some View {
    switch row {
    case .header(let file):
      header(file)
    case .notice(_, let text):
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    case .largeFile(let path, let lines):
      largeFile(path, lines: lines)
    case .hunk(_, _, let header):
      HunkHeaderRow(header: header, isCurrent: false)
    case .gap(let path, let gap, let header, let hidden):
      gapRow(path, gap: gap, header: header, hidden: hidden)
    case .line(let path, let hunk, let line, let highlight):
      unified(line, path: path, hunk: hunk, highlight: highlight)
    case .split(let path, let hunk, let left, let right, let highlight):
      splitRow(path, hunk: hunk, left: left, right: right, highlight: highlight)
    case .annotation(let view):
      annotation(view)
    }
  }

  private func header(_ file: StackedDiffFile) -> some View {
    let toggle = actions.toggle
    return StackedFileHeader(
      file: file, isCollapsed: content.collapsed.contains(file.path),
      accessory: content.annotations.headers[file.path],
      toggle: { toggle?(file.path) }
    )
    .frame(width: width)
  }

  private func largeFile(_ path: String, lines: Int) -> some View {
    HStack(spacing: 12) {
      Text("Large diff \u{2014} \(lines.formatted()) lines")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let show = actions.showLargeFile {
        Button("Show diff") { show(path) }
          .buttonStyle(.borderless)
          .font(.caption)
      }
    }
    .padding(10)
  }

  private func gapRow(_ path: String, gap: DiffGap, header: String?, hidden: Int?) -> some View {
    var expand: (@MainActor (DiffExpansion) -> Void)?
    if let grow = actions.expand {
      expand = { expansion in grow(path, gap, expansion) }
    }
    return DiffGapRow(
      gap: gap, header: header, hidden: hidden, state: content.context[path], expand: expand)
  }

  private func splitRow(
    _ path: String, hunk: Int?, left: SplitCell?, right: SplitCell?, highlight: SplitHighlight?
  ) -> some View {
    HStack(spacing: 0) {
      cell(left, side: .old, path: path, hunk: hunk, highlight: highlight)
      Divider()
      cell(right, side: .new, path: path, hunk: hunk, highlight: highlight)
    }
    .frame(width: width)
  }

  private func annotation(_ view: AnyView) -> some View {
    view
      .frame(width: max(width - 24, 0), alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
  }

  @ViewBuilder
  private func unified(_ line: DiffLine, path: String, hunk: Int?, highlight: Range<Int>?)
    -> some View
  {
    let compact = DiffGutter.isCompact(width)
    let row = UnifiedLineRow(line: line, compactGutter: compact, highlight: highlight)
    let gutter = (compact ? DiffGutter.compactWidth : DiffGutter.width * 2) + 8
    if let hunk, let anchor = DiffLineAnchor.of(line, path: path) {
      LineChooser(
        anchor: anchor, hunk: hunk, gutter: gutter, annotations: content.annotations
      ) { row }
    } else {
      row
    }
  }

  @ViewBuilder
  private func cell(
    _ cell: SplitCell?, side: DiffLineAnchor.Side, path: String, hunk: Int?,
    highlight: SplitHighlight?
  ) -> some View {
    let view = SplitCellView(
      cell: cell, highlight: highlight?.side == side ? highlight?.range : nil)
    if let hunk, let cell {
      LineChooser(
        anchor: DiffLineAnchor(path: path, side: side, line: cell.number), hunk: hunk,
        gutter: 52, annotations: content.annotations
      ) { view }
    } else {
      view
    }
  }
}

/// A line whose number chooses it for a review: a click takes the line, and on the Mac
/// Shift-click extends the choice within its side and hunk.
private struct LineChooser<Content: View>: View {
  let anchor: DiffLineAnchor
  let hunk: Int
  let gutter: CGFloat
  let annotations: StackedDiffAnnotations
  @ViewBuilder let content: Content

  var body: some View {
    if let select = annotations.select {
      let chosen = annotations.selection?.contains(anchor) == true
      content
        .overlay(alignment: .leading) {
          Color.accentColor.opacity(chosen ? 0.18 : 0.001)
            .frame(width: gutter)
            .contentShape(Rectangle())
            .onTapGesture { select(selection()) }
            .help("Comment on this line\(Self.extendHint)")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Comment on line \(anchor.line)")
        }
    } else {
      content
    }
  }

  private func selection() -> DiffLineSelection {
    let single = DiffLineSelection(
      path: anchor.path, side: anchor.side, start: anchor.line, end: anchor.line, hunk: hunk)
    #if os(macOS)
      if NSEvent.modifierFlags.contains(.shift), let current = annotations.selection {
        return current.extended(to: anchor, hunk: hunk)
      }
    #endif
    return single
  }

  #if os(macOS)
    private static var extendHint: String { "; Shift-click to choose a range" }
  #else
    private static var extendHint: String { "" }
  #endif
}

/// Hidden unchanged lines between hunks: the next hunk's header, how many lines are hidden, and
/// buttons that show ten more above or below, or all of them.
private struct DiffGapRow: View {
  let gap: DiffGap
  let header: String?
  let hidden: Int?
  let state: DiffContextState?
  let expand: (@MainActor (DiffExpansion) -> Void)?

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 6) {
      if let expand, state?.isLoading != true {
        buttons(expand)
      } else if state?.isLoading == true {
        ProgressView().controlSize(.mini)
      }
      Text(label)
        .font(WorkspaceTheme.gutter)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if let failure = state?.failure {
        Text(failure).font(.caption).foregroundStyle(.red).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    .background(WorkspaceTheme.hunkBackground(scheme))
  }

  private var label: String {
    // The last gap's length is known once the file's text is read.
    let count =
      hidden.map { $0 == 1 ? "1 unchanged line" : "\($0) unchanged lines" }
      ?? "Unchanged lines below"
    return [header, count].compactMap(\.self).joined(separator: "  ")
  }

  /// The first gap grows only upward, the last only downward.
  @ViewBuilder private func buttons(_ expand: @escaping @MainActor (DiffExpansion) -> Void)
    -> some View
  {
    let leading = gap.index == 0
    let trailing = header == nil
    Group {
      if !leading {
        Button {
          expand(.below)
        } label: {
          Image(systemName: "chevron.down").accessibilityLabel("Show lines below")
        }
        .help("Show \(DiffContextState.step) more lines below")
      }
      if !trailing {
        Button {
          expand(.above)
        } label: {
          Image(systemName: "chevron.up").accessibilityLabel("Show lines above")
        }
        .help("Show \(DiffContextState.step) more lines above")
      }
      if hidden != nil {
        Button {
          expand(.all)
        } label: {
          Image(systemName: "arrow.up.and.down").accessibilityLabel("Show all lines")
        }
        .help("Show all hidden lines")
      }
    }
    .buttonStyle(.borderless)
    .font(.caption)
  }
}
