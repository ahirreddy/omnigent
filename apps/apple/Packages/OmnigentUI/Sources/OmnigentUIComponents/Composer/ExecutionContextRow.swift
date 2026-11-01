import SwiftUI

/// The execution-context line in the composer tray: `Codex · Mac Studio · omnigent / auth-refresh`
/// with the host's status, and a warning when nothing can run there. Click for the server, host,
/// sandbox and directory.
struct ExecutionContextRow: View {
  let context: ExecutionContext
  var includesWorkspace = true

  @State private var isPresented: Bool

  /// Creates the row.
  /// - Parameters:
  ///   - context: What to show.
  ///   - includesWorkspace: Show the workspace in the line (off when a folder picker shows it).
  ///   - isPresented: Start with the details open (playground captures).
  init(context: ExecutionContext, includesWorkspace: Bool = true, isPresented: Bool = false) {
    self.context = context
    self.includesWorkspace = includesWorkspace
    _isPresented = State(initialValue: isPresented)
  }

  private var summary: String { context.summary(includingWorkspace: includesWorkspace) }

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        if context.unavailableReason != nil {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.warning)
            .accessibilityHidden(true)
        } else {
          Image(systemName: context.hostKind == .cloud ? "cloud" : "desktopcomputer")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        Text(summary)
          .lineLimit(1)
          .truncationMode(.middle)
        if context.unavailableReason == nil, let online = context.isHostOnline {
          StatusDot(isOnline: online)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(
      context.unavailableReason == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning)
    )
    .help(context.unavailableReason ?? "Where this runs: \(summary)")
    .accessibilityLabel("Runs on \(summary)")
    .accessibilityValue(
      context.unavailableReason ?? (context.isHostOnline == false ? "Host offline" : "")
    )
    .accessibilityHint("Shows the server, host, sandbox and directory")
    .accessibilityIdentifier("composer-context")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      ExecutionContextDetails(context: context)
        .presentationCompactAdaptation(.popover)
    }
  }
}

/// A host status dot: filled when online, hollow when not.
private struct StatusDot: View {
  let isOnline: Bool

  var body: some View {
    Circle()
      .fill(isOnline ? AnyShapeStyle(Theme.success) : AnyShapeStyle(.clear))
      .overlay { Circle().strokeBorder(.secondary, lineWidth: isOnline ? 0 : 1) }
      .frame(width: 6, height: 6)
      .accessibilityHidden(true)
  }
}

/// The context row's popover: every part of where the session runs, labelled.
struct ExecutionContextDetails: View {
  let context: ExecutionContext

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      if let reason = context.unavailableReason {
        Label {
          Text(reason).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
        .font(.callout)
        .accessibilityIdentifier("composer-context-unavailable")
      }
      Grid(
        alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.medium,
        verticalSpacing: Theme.Spacing.small
      ) {
        row("Agent", context.agent)
        row("Server", context.server)
        row("Host", hostLine)
        row("Sandbox", context.sandbox)
        row("Directory", context.directory, monospaced: true)
        row("Branch", context.branch, monospaced: true)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-context-details")
  }

  private var hostLine: String? {
    guard let host = context.host else { return nil }
    switch context.isHostOnline {
    case true?: return "\(host) \u{00B7} online"
    case false?: return "\(host) \u{00B7} offline"
    case nil: return host
    }
  }

  @ViewBuilder
  private func row(_ title: String, _ value: String?, monospaced: Bool = false) -> some View {
    GridRow {
      Text(title)
        .font(.callout)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value ?? "Not reported")
        .font(monospaced && value != nil ? .callout.monospaced() : .callout)
        .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .textSelection(.enabled)
        .lineLimit(3)
        .truncationMode(.middle)
    }
  }
}
