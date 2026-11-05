public import SwiftUI

/// The Automations page (the web's `/tasks`): the caller's scheduled agent sessions with search,
/// an All / Active / Paused filter, a New automation menu and the suggestions.
public struct AutomationsView: View {
  private let state: AutomationsViewState
  private let actions: AutomationsActions
  @State private var filter: AutomationsFilter = .all
  @State private var search = ""
  @State private var confirmingDelete: AutomationRow?

  /// Creates the page.
  public init(state: AutomationsViewState, actions: AutomationsActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        header
        TextField("Search automations\u{2026}", text: $search)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("automations-search")
        if state.hasAny {
          Picker("Filter", selection: $filter) {
            ForEach(AutomationsFilter.allCases) { Text($0.title).tag($0) }
          }
          .pickerStyle(.segmented)
          .fixedSize()
          .accessibilityIdentifier("automations-filter")
        }
        if let error = state.actionError { actionErrorBanner(error) }
        content
        if filter == .all, !state.rows.isEmpty { suggestions(heading: true) }
      }
      .padding(Theme.Spacing.gutter)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle("Automations")
    .onChange(of: filter) { actions.filter?(filter, search) }
    .onChange(of: search) { actions.filter?(filter, search) }
    .confirmationDialog(
      "Delete this automation?",
      isPresented: Binding(
        get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
      presenting: confirmingDelete
    ) { row in
      Button("Delete", role: .destructive) { actions.delete?(row.id) }
    } message: { row in
      Text("\u{201C}\(row.name)\u{201D} stops running. Sessions it started stay.")
    }
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text("Automations").font(.largeTitle.weight(.semibold))
        Text("Run agent sessions on a recurring schedule.").foregroundStyle(.secondary)
      }
      Spacer()
      if let create = actions.create {
        Menu("New automation") {
          Button("Create manually", systemImage: "pencil") { create(nil) }
          if let createTrigger = actions.createTrigger, !state.triggers.isEmpty {
            Section("When something happens") {
              ForEach(state.triggers) { chip in
                Button(chip.title, systemImage: chip.systemImage) { createTrigger(chip.id) }
              }
            }
          }
          Section("From a template") {
            ForEach(AutomationSuggestion.all) { suggestion in
              Button(suggestion.title, systemImage: suggestion.systemImage) { create(suggestion) }
            }
          }
        }
        .fixedSize()
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("automations-new")
      }
    }
  }

  @ViewBuilder private var content: some View {
    if let error = state.loadError {
      HStack {
        Label("Couldn\u{2019}t load automations.", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        if let retry = actions.retry { Button("Retry", action: retry) }
      }
      .padding(Theme.Spacing.medium)
      .cardSurface(cornerRadius: Theme.Radius.medium)
      .accessibilityIdentifier("automations-load-error")
    } else if state.isLoading {
      ProgressView("Loading automations\u{2026}").frame(maxWidth: .infinity).padding()
    } else if state.rows.isEmpty {
      emptyState
    } else {
      LazyVStack(spacing: Theme.Spacing.small) {
        ForEach(state.rows) { row in AutomationRowView(row: row, actions: rowActions(row)) }
      }
      .accessibilityIdentifier("automations-list")
    }
  }

  @ViewBuilder private var emptyState: some View {
    if state.hasAny {
      Text("No automations found").foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
    } else {
      VStack(spacing: Theme.Spacing.small) {
        Image(systemName: "clock").font(.largeTitle).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
        Text("No automations yet").font(Theme.Typography.label)
        Text("Create an automation to run an agent session automatically on a recurring schedule.")
          .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        if filter == .all { suggestions(heading: false) }
      }
      .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
      .accessibilityIdentifier("automations-empty")
    }
  }

  @ViewBuilder private func suggestions(heading: Bool) -> some View {
    if let create = actions.create {
      VStack(alignment: heading ? .leading : .center, spacing: Theme.Spacing.small) {
        if heading {
          Divider()
          Text("Suggestions").font(.callout).foregroundStyle(.secondary)
        }
        HStack(spacing: Theme.Spacing.small) {
          if let createTrigger = actions.createTrigger {
            ForEach(state.triggers) { chip in
              Button(chip.title, systemImage: chip.systemImage) { createTrigger(chip.id) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("automations-trigger-\(chip.id)")
            }
          }
          ForEach(AutomationSuggestion.all) { suggestion in
            Button(suggestion.title, systemImage: suggestion.systemImage) { create(suggestion) }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("automations-suggestion-\(suggestion.id)")
          }
        }
      }
    }
  }

  private func actionErrorBanner(_ message: String) -> some View {
    HStack {
      Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      Spacer()
      if let dismiss = actions.dismissError { Button("Dismiss", action: dismiss) }
    }
    .font(.callout)
    .padding(Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.medium)
  }

  private func rowActions(_ row: AutomationRow) -> AutomationRowView.Actions {
    var rowActions = AutomationRowView.Actions()
    let id = row.id
    if let edit = actions.edit { rowActions.edit = { edit(id) } }
    if let setPaused = actions.setPaused {
      let paused = !row.isPaused
      rowActions.togglePaused = { setPaused(id, paused) }
    }
    if let runNow = actions.runNow { rowActions.runNow = { runNow(id) } }
    if actions.delete != nil { rowActions.delete = { confirmingDelete = row } }
    rowActions.openLastRun = openLastRun(row)
    if let openDetail = actions.openDetail { rowActions.open = { openDetail(id) } }
    return rowActions
  }

  private func openLastRun(_ row: AutomationRow) -> (@MainActor () -> Void)? {
    guard let id = row.lastRunSessionID, let open = actions.openSession else { return nil }
    return { open(id) }
  }
}

/// One automation card: name, Paused pill, schedule and next run, and its menu.
struct AutomationRowView: View {
  struct Actions {
    var edit: (@MainActor () -> Void)?
    var togglePaused: (@MainActor () -> Void)?
    var runNow: (@MainActor () -> Void)?
    var delete: (@MainActor () -> Void)?
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
          if row.isPaused {
            Text("Paused").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
              .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
              .background(Capsule().fill(.quaternary))
              .accessibilityIdentifier("automation-paused-\(row.id)")
          }
        }
        Text(scheduleLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
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
      if let open = actions.open { open() } else { actions.edit?() }
    }
    .contextMenu { menuItems }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-\(row.id)")
  }

  private var scheduleLine: String {
    guard let next = row.nextRunText else { return row.scheduleText }
    return "\(row.scheduleText) \u{00B7} Next run \(next)"
  }

  @ViewBuilder private var menuItems: some View {
    if let runNow = actions.runNow { Button("Run now", systemImage: "play", action: runNow) }
    if let edit = actions.edit { Button("Edit", systemImage: "pencil", action: edit) }
    if let toggle = actions.togglePaused {
      if row.isPaused {
        Button("Resume", systemImage: "play.circle", action: toggle)
      } else {
        Button("Pause", systemImage: "pause", action: toggle)
      }
    }
    if let open = actions.openLastRun {
      Button("Open last run", systemImage: "arrow.up.forward.app", action: open)
    }
    if let delete = actions.delete {
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
    }
  }
}
