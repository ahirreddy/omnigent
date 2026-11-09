public import SwiftUI

/// A terminal's badge in the list. Mirrors the core's `TerminalStatus`.
public enum TerminalListStatus: Hashable, Sendable {
  /// Output in the last moment.
  case active
  /// Running and quiet.
  case idle
  /// The process exited.
  case exited
  /// The runner did not say.
  case unknown
}

/// One row of the terminal list. The store builds it from the core's `TerminalInventory` rows.
public struct TerminalListItem: Identifiable, Hashable, Sendable {
  /// The terminal resource id, for example `terminal_zsh_u-1a2b3c`.
  public let id: String
  /// The display label, for example `zsh · u-1a2b3c`.
  public let title: String
  /// The badge.
  public let status: TerminalListStatus
  /// Whether this is the session's harness TUI rather than a user shell. It cannot be closed
  /// from the list.
  public let isAgentTerminal: Bool

  /// A row.
  public init(id: String, title: String, status: TerminalListStatus, isAgentTerminal: Bool) {
    self.id = id
    self.title = title
    self.status = status
    self.isAgentTerminal = isAgentTerminal
  }
}

/// The session's terminals with create, close and attach actions.
public struct TerminalListView: View {
  private let items: [TerminalListItem]
  private let shellChoices: [String]
  private let canEdit: Bool
  private let errorMessage: String?
  @Binding private var selection: TerminalListItem.ID?
  private let onCreate: (String) -> Void
  private let onClose: (TerminalListItem.ID) -> Void
  @State private var confirmClose: TerminalListItem?

  /// A list.
  ///
  /// - Parameters:
  ///   - items: The rows, in creation order.
  ///   - shellChoices: Terminal names the agent declares (for example `zsh`, `bash`). Empty
  ///     hides the New Terminal menu.
  ///   - canEdit: Whether the caller may create and close terminals (edit access).
  ///   - errorMessage: The last create, close or load error, shown above the list.
  ///   - selection: The attached terminal.
  ///   - onCreate: Launch a terminal with this name.
  ///   - onClose: Close (kill) this terminal, after the user confirmed.
  public init(
    items: [TerminalListItem], shellChoices: [String], canEdit: Bool, errorMessage: String?,
    selection: Binding<TerminalListItem.ID?>, onCreate: @escaping (String) -> Void,
    onClose: @escaping (TerminalListItem.ID) -> Void
  ) {
    self.items = items
    self.shellChoices = shellChoices
    self.canEdit = canEdit
    self.errorMessage = errorMessage
    _selection = selection
    self.onCreate = onCreate
    self.onClose = onClose
  }

  /// The view's content.
  public var body: some View {
    List(selection: $selection) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .font(.callout)
      }
      if items.isEmpty {
        Text("No terminals yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(items) { item in
        TerminalListRow(item: item)
          .tag(item.id)
          .contextMenu {
            if canEdit, !item.isAgentTerminal {
              Button("Close Terminal", systemImage: "xmark.circle", role: .destructive) {
                confirmClose = item
              }
            }
          }
          .swipeActions {
            if canEdit, !item.isAgentTerminal {
              Button("Close", systemImage: "xmark", role: .destructive) { confirmClose = item }
            }
          }
      }
    }
    .toolbar {
      if canEdit, !shellChoices.isEmpty {
        NewTerminalMenu(shellChoices: shellChoices, onCreate: onCreate)
      }
    }
    .confirmationDialog(
      "Close \(confirmClose?.title ?? "terminal")?", isPresented: closeBinding,
      titleVisibility: .visible
    ) {
      Button("Close Terminal", role: .destructive) {
        if let item = confirmClose { onClose(item.id) }
        confirmClose = nil
      }
    } message: {
      Text("Its program is stopped and its output is lost.")
    }
  }

  private var closeBinding: Binding<Bool> {
    Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } })
  }
}

/// One row: icon, label and badge.
struct TerminalListRow: View {
  let item: TerminalListItem

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: item.isAgentTerminal ? "sparkles.rectangle.stack" : "terminal")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title).font(.body.monospaced())
        if item.isAgentTerminal {
          Text("Agent terminal").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      TerminalStatusBadge(status: item.status)
    }
    .accessibilityElement(children: .combine)
  }
}

/// The colored status capsule.
public struct TerminalStatusBadge: View {
  private let status: TerminalListStatus

  /// A badge.
  public init(status: TerminalListStatus) {
    self.status = status
  }

  /// The view's content.
  public var body: some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 7, height: 7)
        .accessibilityHidden(true)
      Text(label).font(.caption.weight(.medium))
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityLabel("Status: \(label)")
  }

  private var label: String {
    switch status {
    case .active: "Active"
    case .idle: "Idle"
    case .exited: "Exited"
    case .unknown: "Unknown"
    }
  }

  private var color: Color {
    switch status {
    case .active: .green
    case .idle: .blue
    case .exited: .secondary
    case .unknown: .orange
    }
  }
}

/// Launches one of the shells the agent declares.
struct NewTerminalMenu: View {
  let shellChoices: [String]
  let onCreate: (String) -> Void

  var body: some View {
    Menu("New Terminal", systemImage: "plus") {
      ForEach(shellChoices, id: \.self) { shell in
        Button(shell) { onCreate(shell) }
      }
    }
  }
}
