import SwiftUI

/// Why each action on an automation shared with the caller is disabled (the web's
/// `OWNER_ONLY_REASONS`).
enum OwnerOnlyReason {
  static let runNow = "Only the automation\u{2019}s owner can run it."
  static let edit = "Only the automation\u{2019}s owner can edit it."
  static let share = "Only the automation\u{2019}s owner can share it."
  static let pause = "Only the automation\u{2019}s owner can pause it."
  static let resume = "Only the automation\u{2019}s owner can resume it."
  static let delete = "Only the automation\u{2019}s owner can delete it."
}

/// One automation card: name, failure warning, Paused pill, schedule and next run (or that a
/// trigger runs when items match), and its menu. A shared one's actions show disabled.
struct AutomationRowView: View {
  struct Actions {
    var edit: (@MainActor () -> Void)?
    var togglePaused: (@MainActor () -> Void)?
    var runNow: (@MainActor () -> Void)?
    var delete: (@MainActor () -> Void)?
    var share: (@MainActor () -> Void)?
    var openLastRun: (@MainActor () -> Void)?
    /// Opens the automation's page; without it a double click edits.
    var open: (@MainActor () -> Void)?
  }

  let row: AutomationRow
  let actions: Actions
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Spacing.medium) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        HStack(spacing: Theme.Spacing.small) {
          Text(row.name).font(.headline).lineLimit(1)
          if row.lastRunFailed {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(Theme.failure)
              .help("Last run failed")
              .accessibilityLabel("Last run failed")
              .accessibilityIdentifier("automation-failed-\(row.id)")
          }
          if row.isPaused {
            Text("Paused").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
              .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
              .background(Capsule().fill(.quaternary))
              .accessibilityIdentifier("automation-paused-\(row.id)")
          }
        }
        Text(row.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          .accessibilityIdentifier("automation-schedule-\(row.id)")
      }
      Spacer(minLength: 0)
      if row.isBusy { ProgressView().controlSize(.small) }
      Menu {
        menuItems
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(row.isBusy)
      .opacity(isHovered || row.isBusy ? 1 : 0.4)
      .accessibilityLabel("Actions for \(row.name)")
      .accessibilityIdentifier("automation-menu-\(row.id)")
    }
    .padding(.vertical, Theme.Spacing.medium)
    .padding(.horizontal, Theme.Spacing.large)
    .cardSurface(cornerRadius: Theme.Radius.medium)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: actions.open == nil ? 2 : 1) {
      if let open = actions.open {
        open()
      } else if !row.isReadOnly {
        actions.edit?()
      }
    }
    // As the row's own menu: a write is in flight, so nothing else can start on this row.
    .contextMenu {
      if !row.isBusy { menuItems }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-\(row.id)")
  }

  @ViewBuilder private var menuItems: some View {
    if !row.isTrigger {
      item("Run now", "play", actions.runNow, ownerOnly: OwnerOnlyReason.runNow)
    }
    item("Edit", "pencil", actions.edit, ownerOnly: OwnerOnlyReason.edit)
    if row.isReadOnly {
      item("Share", "square.and.arrow.up", nil, ownerOnly: OwnerOnlyReason.share)
    } else if let reason = row.shareDisabledReason {
      Button("Share", systemImage: "square.and.arrow.up") {}.disabled(true).help(reason)
    } else if let share = actions.share {
      Button("Share", systemImage: "square.and.arrow.up", action: share)
        .accessibilityIdentifier("automation-share")
    }
    if row.isPaused {
      item("Resume", "play.circle", actions.togglePaused, ownerOnly: OwnerOnlyReason.resume)
    } else {
      item("Pause", "pause", actions.togglePaused, ownerOnly: OwnerOnlyReason.pause)
    }
    if let open = actions.openLastRun, !row.isReadOnly {
      Button("Open last run", systemImage: "arrow.up.forward.app", action: open)
    }
    if actions.delete != nil || row.isReadOnly {
      Divider()
      item(
        "Delete", "trash", actions.delete, ownerOnly: OwnerOnlyReason.delete, role: .destructive)
    }
  }

  /// An action, shown disabled with the owner-only reason on a shared automation.
  @ViewBuilder private func item(
    _ title: String, _ image: String, _ action: (@MainActor () -> Void)?, ownerOnly: String,
    role: ButtonRole? = nil
  ) -> some View {
    if row.isReadOnly {
      Button(title, systemImage: image, role: role) {}.disabled(true).help(ownerOnly)
    } else if let action {
      Button(title, systemImage: image, role: role, action: action)
    }
  }
}
