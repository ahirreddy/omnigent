public import SwiftUI

/// How the diff is laid out.
nonisolated public enum DiffLayoutMode: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// Side by side when the view is wide enough, unified otherwise.
  case automatic
  /// One column with removals above additions.
  case unified
  /// Old and new side by side.
  case split

  /// The width from which `automatic` shows side by side.
  public static let splitMinimumWidth: CGFloat = 860

  /// The layout used at `width`.
  /// - Parameter width: The available width.
  /// - Returns: `.unified` or `.split`.
  public func resolved(width: CGFloat) -> Self {
    switch self {
    case .automatic: width >= Self.splitMinimumWidth ? .split : .unified
    case .unified, .split: self
    }
  }

  /// The picker title.
  public var title: String {
    switch self {
    case .automatic: "Automatic"
    case .unified: "Unified"
    case .split: "Side by Side"
    }
  }

  /// The raw value.
  public var id: String { rawValue }
}

/// Which hunk is current, for previous and next navigation.
nonisolated public struct HunkNavigator: Hashable, Sendable {
  /// The number of hunks.
  public let total: Int
  /// The current hunk; `nil` before the first move.
  public private(set) var current: Int?

  /// A navigator over `total` hunks.
  /// - Parameter total: The number of hunks.
  public init(total: Int) {
    self.total = total
  }

  /// Moves to the next hunk, stopping at the last.
  /// - Returns: The new current hunk, or `nil` when there are none.
  @discardableResult
  public mutating func next() -> Int? {
    guard total > 0 else { return nil }
    current = current.map { min($0 + 1, total - 1) } ?? 0
    return current
  }

  /// Moves to the previous hunk, stopping at the first.
  /// - Returns: The new current hunk, or `nil` when there are none.
  @discardableResult
  public mutating func previous() -> Int? {
    guard total > 0 else { return nil }
    current = current.map { max($0 - 1, 0) } ?? 0
    return current
  }

  /// "Change 2 of 5".
  public var label: String {
    guard total > 0 else { return "No changes" }
    guard let current else { return total == 1 ? "1 change" : "\(total) changes" }
    return "Change \(current + 1) of \(total)"
  }
}

/// A changed file's diff, unified or side by side (automatically side by side on wide
/// windows), with previous and next change navigation (Option-Command-Up and Down, or `p` and
/// `n`). Binary, identical, approximate and too-large diffs say so instead of rendering.
public struct DiffViewerView: View {
  private let diff: FileDiff
  private let source: any WorkspaceDataSource
  private let actions: WorkspaceActions
  @State private var mode: DiffLayoutMode
  @State private var navigator: HunkNavigator
  @FocusState private var focused: Bool

  /// A diff viewer.
  /// - Parameters:
  ///   - diff: The diff, computed by the core.
  ///   - mode: The initial layout.
  ///   - source: Used for absolute paths.
  ///   - actions: Host hooks.
  public init(
    diff: FileDiff, mode: DiffLayoutMode = .automatic, source: any WorkspaceDataSource,
    actions: WorkspaceActions = .none
  ) {
    self.diff = diff
    self.source = source
    self.actions = actions
    _mode = State(initialValue: mode)
    _navigator = State(initialValue: HunkNavigator(total: diff.hunks.count))
  }

  /// The view.
  public var body: some View {
    GeometryReader { geometry in
      let layout = mode.resolved(width: geometry.size.width)
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          header(proxy: proxy)
          Divider()
          if diff.approximate {
            NoticeBar(
              symbol: "wand.and.rays",
              text: "This change is too large to align line by line; it is shown as a replacement.")
          }
          content(layout: layout, width: geometry.size.width)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(characters: ["n", "j"]) { _ in
          move(forward: true, proxy: proxy)
          return .handled
        }
        .onKeyPress(characters: ["p", "k"]) { _ in
          move(forward: false, proxy: proxy)
          return .handled
        }
      }
    }
    .accessibilityIdentifier("workspace.diff")
  }

  private func header(proxy: ScrollViewProxy) -> some View {
    HStack(spacing: 8) {
      Image(systemName: changeSymbol)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(WorkspacePaths.name(of: diff.path))
          .font(.headline)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .textSelection(.enabled)
      }
      Spacer(minLength: 8)
      LineCounts(added: diff.added, removed: diff.removed)
      Text(navigator.label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      navigationControls(proxy: proxy)
      Menu {
        PathMenu(path: diff.path, source: source, actions: actions)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("File actions")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  @ViewBuilder private func navigationControls(proxy: ScrollViewProxy) -> some View {
    ControlGroup {
      Button {
        move(forward: false, proxy: proxy)
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Previous change")
      }
      .keyboardShortcut(.upArrow, modifiers: [.option, .command])
      .help("Previous change")
      Button {
        move(forward: true, proxy: proxy)
      } label: {
        Image(systemName: "chevron.down")
          .accessibilityLabel("Next change")
      }
      .keyboardShortcut(.downArrow, modifiers: [.option, .command])
      .help("Next change")
    }
    .disabled(diff.hunks.isEmpty)
    .fixedSize()
    Picker("Layout", selection: $mode) {
      ForEach(DiffLayoutMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
    .labelsHidden()
    .fixedSize()
  }

  @ViewBuilder private func content(layout: DiffLayoutMode, width: CGFloat) -> some View {
    if diff.binary {
      ContentUnavailableView(
        "Binary File", systemImage: "doc.zipper",
        description: Text("Binary files have no line diff."))
    } else if diff.tooLarge {
      ContentUnavailableView(
        "Diff Too Large", systemImage: "rectangle.stack.badge.minus",
        description: Text("This change is too large to show. Open the file to review it."))
    } else if diff.isIdentical {
      ContentUnavailableView(
        "No Differences", systemImage: "equal.circle",
        description: Text("The file matches its state at the start of the session."))
    } else if layout == .split {
      SplitDiffBody(rows: diff.splitRows, current: navigator.current)
    } else {
      UnifiedDiffBody(hunks: diff.hunks, current: navigator.current, width: width)
    }
  }

  private var subtitle: String {
    switch diff.change {
    case .renamed, .copied:
      "\(diff.oldPath ?? "") \u{2192} \(diff.newPath ?? "")"
    case .added: "\(diff.path), new file"
    case .deleted: "\(diff.path), deleted"
    case .modified: diff.path
    }
  }

  private var changeSymbol: String {
    switch diff.change {
    case .added: "doc.badge.plus"
    case .deleted: "trash"
    case .renamed, .copied: "arrow.right.doc.on.clipboard"
    case .modified: "doc.badge.ellipsis"
    }
  }

  private func move(forward: Bool, proxy: ScrollViewProxy) {
    let target = forward ? navigator.next() : navigator.previous()
    guard let target else { return }
    withAnimation(.easeInOut(duration: 0.15)) {
      proxy.scrollTo(DiffIDs.hunk(target), anchor: .top)
    }
  }
}

#Preview("Diff, unified") {
  DiffViewerView(
    diff: WorkspaceSamples.mainDiff, mode: .unified, source: SampleWorkspaceDataSource()
  )
  .frame(width: 700, height: 420)
}

#Preview("Diff, side by side") {
  DiffViewerView(diff: WorkspaceSamples.mainDiff, mode: .split, source: SampleWorkspaceDataSource())
    .frame(width: 1_000, height: 420)
}
