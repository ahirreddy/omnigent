public import SwiftUI

/// Colors and metrics for the workspace views, matching the web UI's diff and file panels.
public enum WorkspaceTheme {
  /// The monospaced body font.
  public static let code = Font.system(size: 12, design: .monospaced)
  /// The line-number gutter font.
  public static let gutter = Font.system(size: 11, design: .monospaced)
  /// Row height for one code line.
  public static let lineHeight: CGFloat = 17

  /// Background of added lines.
  /// - Parameter scheme: The color scheme.
  /// - Returns: The color.
  public static func addedBackground(_ scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.16, green: 0.33, blue: 0.20).opacity(0.55)
      : Color(red: 0.86, green: 0.97, blue: 0.88)
  }

  /// Background of removed lines.
  /// - Parameter scheme: The color scheme.
  /// - Returns: The color.
  public static func removedBackground(_ scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.42, green: 0.16, blue: 0.18).opacity(0.55)
      : Color(red: 1.0, green: 0.90, blue: 0.90)
  }

  /// The stronger tint marking the changed span of a paired line.
  /// - Parameters:
  ///   - kind: Added or removed.
  ///   - scheme: The color scheme.
  /// - Returns: The color.
  public static func spanBackground(_ kind: DiffLineKind, _ scheme: ColorScheme) -> Color {
    switch kind {
    case .added: Color.green.opacity(scheme == .dark ? 0.45 : 0.30)
    case .removed: Color.red.opacity(scheme == .dark ? 0.45 : 0.25)
    case .context: Color.clear
    }
  }

  /// Background of hunk headers.
  /// - Parameter scheme: The color scheme.
  /// - Returns: The color.
  public static func hunkBackground(_ scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.17, green: 0.20, blue: 0.30) : Color(red: 0.93, green: 0.95, blue: 1.0)
  }

  /// Gutter background.
  /// - Parameter scheme: The color scheme.
  /// - Returns: The color.
  public static func gutterBackground(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.025)
  }

  /// The highlight of a search match.
  /// - Parameter scheme: The color scheme.
  /// - Returns: The color.
  public static func matchBackground(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.yellow.opacity(0.35) : Color.yellow.opacity(0.45)
  }

  /// The badge color of a change status.
  /// - Parameter status: The status.
  /// - Returns: The color.
  public static func statusColor(_ status: ChangeStatus) -> Color {
    switch status {
    case .created: .green
    case .modified: .orange
    case .deleted: .red
    case .unknown: .secondary
    }
  }

  /// The color of a syntax token.
  /// - Parameters:
  ///   - token: The token class.
  ///   - scheme: The color scheme.
  /// - Returns: The color.
  public static func tokenColor(_ token: SyntaxToken, _ scheme: ColorScheme) -> Color {
    let (dark, light): (Color, Color) =
      switch token {
      case .keyword:
        (Color(red: 0.99, green: 0.47, blue: 0.66), Color(red: 0.61, green: 0.14, blue: 0.58))
      case .string:
        (Color(red: 0.99, green: 0.55, blue: 0.40), Color(red: 0.77, green: 0.10, blue: 0.09))
      case .comment:
        (Color(red: 0.50, green: 0.55, blue: 0.60), Color(red: 0.36, green: 0.42, blue: 0.47))
      case .number:
        (Color(red: 0.82, green: 0.75, blue: 0.47), Color(red: 0.11, green: 0.00, blue: 0.81))
      case .type:
        (Color(red: 0.36, green: 0.85, blue: 1.0), Color(red: 0.04, green: 0.31, blue: 0.47))
      }
    return scheme == .dark ? dark : light
  }

}

/// A status badge such as "M" in the status color.
struct ChangeBadge: View {
  let status: ChangeStatus

  var body: some View {
    Text(status.badge)
      .font(.system(size: 10, weight: .bold, design: .monospaced))
      .foregroundStyle(WorkspaceTheme.statusColor(status))
      .frame(width: 16, height: 16)
      .background(WorkspaceTheme.statusColor(status).opacity(0.14), in: .rect(cornerRadius: 4))
      .accessibilityLabel(status.label)
  }
}

/// `+12 -3` counts.
struct LineCounts: View {
  let added: UInt64?
  let removed: UInt64?

  var body: some View {
    HStack(spacing: 4) {
      if let added { Text("+\(added)").foregroundStyle(.green) }
      if let removed { Text("-\(removed)").foregroundStyle(.red) }
    }
    .font(.system(size: 11, design: .monospaced))
    .accessibilityElement(children: .combine)
  }
}

/// A failure in place of content, with an optional retry.
struct FailureView: View {
  let failure: WorkspaceFailure
  var retry: (() -> Void)?

  var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: failure.symbol)
    } description: {
      Text(failure.message)
        .textSelection(.enabled)
    } actions: {
      if let retry {
        Button("Try Again", action: retry)
      }
    }
  }

  private var title: String {
    switch failure.kind {
    case .notConnected: "Not Connected"
    case .invalidInput: "Invalid Request"
    case .notFound: "Not Found"
    case .notChanged: "No Changes"
    case .unavailable: "No Workspace"
    case .forbidden: "No Access"
    case .runnerOffline: "Runner Offline"
    case .searchDisabled: "Search Unavailable"
    case .searchFailed: "Search Failed"
    case .server: "Could Not Load"
    }
  }
}

/// A compact inline failure row, for lists.
struct InlineFailure: View {
  let failure: WorkspaceFailure
  var retry: (() -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: failure.symbol)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text(failure.message)
        .lineLimit(2)
        .foregroundStyle(.secondary)
      if let retry {
        Button("Retry", action: retry)
          .buttonStyle(.borderless)
      }
    }
    .font(.caption)
  }
}

/// A notice strip above content: truncation, approximation, partial results.
struct NoticeBar: View {
  let symbol: String
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .accessibilityHidden(true)
      Text(text)
      Spacer(minLength: 0)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.yellow.opacity(0.12))
  }
}

/// The path context menu shared by tree rows, search results and changed files.
struct PathMenu: View {
  let path: String
  let source: any WorkspaceDataSource
  let actions: WorkspaceActions

  var body: some View {
    Button("Copy Path") { WorkspacePlatform.copy(path) }
    if let absolute = source.absoluteLocation(of: path) {
      Button("Copy Absolute Path") { WorkspacePlatform.copy(absolute) }
      if let reveal = actions.reveal {
        Button("Reveal in \(WorkspacePlatform.fileManagerName)") { reveal(absolute) }
      }
      if let open = actions.openExternally {
        Button("Open in Editor") { open(absolute) }
      }
    }
    if let mention = actions.mention {
      Divider()
      Button("Mention in Message") { mention(path) }
    }
  }
}
