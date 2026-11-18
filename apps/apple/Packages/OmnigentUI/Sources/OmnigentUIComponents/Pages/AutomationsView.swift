import OmnigentPlatform
public import SwiftUI

/// The Automations page (the web's `/tasks`): tabs for the caller's automations, those shared
/// with them and the integration templates; search, an All / Active / Paused filter, New, and
/// the templates suggested under the list.
public struct AutomationsView: View {
  private let state: AutomationsViewState
  private let actions: AutomationsActions
  @State private var tab: AutomationsTab
  @State private var filter: AutomationsFilter = .all
  @State private var search = ""
  @State private var confirmingDelete: AutomationRow?

  /// Creates the page.
  /// - Parameters:
  ///   - state: The lists and templates.
  ///   - actions: What the page can do.
  ///   - initialTab: The tab it opens on.
  public init(
    state: AutomationsViewState, actions: AutomationsActions, initialTab: AutomationsTab = .yours
  ) {
    self.state = state
    self.actions = actions
    _tab = State(initialValue: initialTab)
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        header
        Picker("Automation views", selection: $tab) {
          ForEach(tabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("automations-tabs")
        switch tab {
        case .yours: yours
        case .shared: shared
        case .templates: templates
        }
      }
      .padding(Theme.Spacing.gutter)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle("Automations")
    .onChange(of: filter) { actions.filter?(filter, search) }
    .onChange(of: search) { actions.filter?(filter, search) }
    .onChange(of: tab) { _, tab in if tab == .shared { actions.loadShared?() } }
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

  private var tabs: [AutomationsTab] {
    AutomationsTab.allCases.filter { $0 != .shared || state.shared != nil }
  }

  private var header: some View {
    HStack(alignment: .top) {
      Text("Automations").font(.largeTitle.weight(.semibold))
      Spacer()
      if let create = actions.create {
        Button("New", systemImage: "plus", action: create)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("automations-new")
      }
    }
  }

  private func controls(hasAny: Bool) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      TextField("Search automations\u{2026}", text: $search)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("automations-search")
      if hasAny {
        Picker("Filter", selection: $filter) {
          ForEach(AutomationsFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityIdentifier("automations-filter")
      }
      if let error = state.actionError { actionErrorBanner(error) }
    }
  }

  @ViewBuilder private var yours: some View {
    controls(hasAny: state.hasAny)
    if let error = state.loadError {
      loadError("Couldn\u{2019}t load automations.", detail: error, retry: actions.retry)
        .accessibilityIdentifier("automations-load-error")
    } else if state.isLoading {
      LoadingCaption(title: "Loading automations\u{2026}").frame(maxWidth: .infinity).padding()
    } else if state.rows.isEmpty {
      emptyState
    } else {
      rows(state.rows).accessibilityIdentifier("automations-list")
    }
    if state.loadError == nil, !state.isLoading, filter == .all,
      search.trimmingCharacters(in: .whitespaces).isEmpty, !state.templates.isEmpty
    {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Divider()
        Text("Suggested").font(.headline)
        gallery
      }
    }
  }

  @ViewBuilder private var shared: some View {
    if let shared = state.shared {
      controls(hasAny: shared.hasAny)
      if let error = shared.loadError {
        loadError(
          "Couldn\u{2019}t load automations shared with you.", detail: error,
          retry: actions.loadShared)
      } else if shared.isLoading || (!shared.hasAny && shared.hasMore) {
        LoadingCaption(title: "Loading automations\u{2026}").frame(maxWidth: .infinity).padding()
      } else if shared.rows.isEmpty {
        Text(shared.hasAny ? "No automations found" : "No automations are shared with you yet")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
          .accessibilityIdentifier("automations-shared-empty")
      } else {
        rows(shared.rows).accessibilityIdentifier("automations-shared-list")
      }
      if shared.loadError == nil, shared.hasAny, shared.hasMore, let more = actions.loadMoreShared {
        HStack {
          Spacer()
          Button(action: more) {
            if shared.isLoadingMore {
              ProgressView().controlSize(.small)
            } else {
              Text("Show more")
            }
          }
          .disabled(shared.isLoadingMore)
          .accessibilityIdentifier("automations-shared-more")
          Spacer()
        }
      }
    }
  }

  @ViewBuilder private var templates: some View {
    if state.templates.isEmpty {
      Text(state.templatesUnavailable).foregroundStyle(.secondary)
        .padding(.vertical, Theme.Spacing.section)
        .accessibilityIdentifier("automations-templates-unavailable")
    } else {
      gallery
    }
  }

  private var gallery: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Spacing.medium)],
      alignment: .leading, spacing: Theme.Spacing.medium
    ) {
      ForEach(state.templates) { card in
        Button {
          actions.createTrigger?(card.id)
        } label: {
          AutomationTemplateCardView(card: card)
        }
        .buttonStyle(.plain)
        .disabled(actions.createTrigger == nil)
        .accessibilityLabel(card.title)
        .accessibilityHint("\(card.description) \(card.requirement)")
        .accessibilityIdentifier("automations-trigger-\(card.id)")
      }
    }
    .accessibilityIdentifier("automations-templates")
  }

  private func rows(_ rows: [AutomationRow]) -> some View {
    LazyVStack(spacing: Theme.Spacing.small) {
      ForEach(rows) { row in AutomationRowView(row: row, actions: rowActions(row)) }
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
      }
      .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
      .accessibilityIdentifier("automations-empty")
    }
  }

  private func loadError(_ title: String, detail: String, retry: (@MainActor () -> Void)?)
    -> some View
  {
    HStack {
      Label(title, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
      Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      Spacer()
      if let retry { Button("Retry", action: retry) }
    }
    .padding(Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.medium)
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
    if let runNow = actions.runNow, !row.isTrigger { rowActions.runNow = { runNow(id) } }
    if actions.delete != nil { rowActions.delete = { confirmingDelete = row } }
    if let share = actions.share, row.canShare { rowActions.share = { share(id) } }
    rowActions.openLastRun = openLastRun(row)
    if let openDetail = actions.openDetail { rowActions.open = { openDetail(id) } }
    return rowActions
  }

  private func openLastRun(_ row: AutomationRow) -> (@MainActor () -> Void)? {
    guard let id = row.lastRunSessionID, let open = actions.openSession else { return nil }
    return { open(id) }
  }
}

/// A template card: the service's mark, its title, what it does and what it needs.
struct AutomationTemplateCardView: View {
  let card: AutomationTemplateCard
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      Image(systemName: card.systemImage)
        .font(.title3)
        .frame(width: 40, height: 40)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium).fill(.quaternary))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(card.title).font(.headline)
        Text(card.description).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(card.requirement).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.Spacing.large)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.large)
    .opacity(isHovered ? 0.85 : 1)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}
