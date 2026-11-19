import OmnigentPlatform
public import SwiftUI

/// The Automations page (the web's `/tasks`): the title with the guide's button and New, tabs
/// for the caller's automations, those shared with them and the integration templates; search,
/// an All / Active / Paused filter, the cards, and the templates suggested under the list.
public struct AutomationsView: View {
  private let state: AutomationsViewState
  private let actions: AutomationsActions
  @State private var tab: AutomationsTab
  @State private var filter: AutomationsFilter = .all
  @State private var search = ""
  @State private var confirmingDelete: AutomationRow?
  @Environment(\.layoutWidth) private var layoutWidth

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
      VStack(alignment: .leading, spacing: 0) {
        header.padding(.bottom, Theme.Spacing.extraLarge)
        Picker("Automation views", selection: $tab) {
          ForEach(tabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("automations-tabs")
        VStack(alignment: .leading, spacing: 0) {
          switch tab {
          case .yours: yours
          case .shared: shared
          case .templates: templates
          }
        }
        .padding(.top, Theme.Spacing.large)
      }
      .padding(.horizontal, AutomationStyle.gutter(layoutWidth))
      .padding(.vertical, Theme.Spacing.extraLarge)
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

  /// The title with the guide's button, and New on the right.
  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.large) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Text("Automations").font(AutomationStyle.pageTitle)
          .accessibilityAddTraits(.isHeader)
        if let showIntro = actions.showIntro {
          Button("About automations", systemImage: "info.circle", action: showIntro)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .imageScale(.large)
            .help("About automations")
            .accessibilityIdentifier("automations-intro-button")
        }
      }
      Spacer(minLength: 0)
      if let create = actions.create {
        Button("New", systemImage: "plus", action: create)
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .fixedSize()
          .accessibilityIdentifier("automations-new")
      }
    }
  }

  /// The system's search field and, once there is anything to filter, the All / Active /
  /// Paused segments.
  private func controls(hasAny: Bool) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      SearchField("Search automations", text: $search, identifier: "automations-search")
        .controlSize(.large)
      if hasAny {
        Picker("Filter automations", selection: $filter) {
          ForEach(AutomationsFilter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("automations-filter")
      }
      if let error = state.actionError {
        AutomationErrorBanner(
          message: error, actionTitle: actions.dismissError == nil ? nil : "Dismiss",
          action: actions.dismissError)
      }
    }
    .padding(.bottom, Theme.Spacing.large)
  }

  @ViewBuilder private var yours: some View {
    controls(hasAny: state.hasAny)
    if let error = state.loadError {
      AutomationErrorBanner(
        message: "Couldn\u{2019}t load automations.", detail: error,
        actionTitle: actions.retry == nil ? nil : "Retry", action: actions.retry
      )
      .accessibilityIdentifier("automations-load-error")
    } else if state.isLoading {
      AutomationLoadingRow(title: "Loading automations\u{2026}")
    } else if state.rows.isEmpty {
      emptyState
    } else {
      rows(state.rows).accessibilityIdentifier("automations-list")
    }
    if state.loadError == nil, !state.isLoading, filter == .all,
      search.trimmingCharacters(in: .whitespaces).isEmpty, !state.templates.isEmpty
    {
      suggested
    }
  }

  /// The templates under the list, past a rule, as the web's preview gallery.
  private var suggested: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text("Suggested").font(AutomationStyle.sectionTitle)
        .accessibilityAddTraits(.isHeader)
      gallery
    }
    .padding(.top, Theme.Spacing.extraLarge)
    .overlay(alignment: .top) { Divider() }
    .padding(.top, Theme.Spacing.extraLarge)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automations-suggested")
  }

  @ViewBuilder private var shared: some View {
    if let shared = state.shared {
      controls(hasAny: shared.hasAny)
      if let error = shared.loadError {
        AutomationErrorBanner(
          message: "Couldn\u{2019}t load automations shared with you.", detail: error,
          actionTitle: actions.loadShared == nil ? nil : "Retry", action: actions.loadShared)
      } else if shared.isLoading || (!shared.hasAny && shared.hasMore) {
        AutomationLoadingRow(title: "Loading automations\u{2026}")
      } else if shared.rows.isEmpty {
        Text(shared.hasAny ? "No automations found" : "No automations are shared with you yet")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 72)
          .accessibilityIdentifier("automations-shared-empty")
      } else {
        rows(shared.rows).accessibilityIdentifier("automations-shared-list")
      }
      if shared.loadError == nil, shared.hasAny, shared.hasMore, let more = actions.loadMoreShared {
        Button(action: more) {
          HStack(spacing: Theme.Spacing.small) {
            if shared.isLoadingMore { ProgressView().controlSize(.mini) }
            Text("Show more")
          }
        }
        .controlSize(.small)
        .disabled(shared.isLoadingMore)
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.medium)
        .accessibilityIdentifier("automations-shared-more")
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

  /// Two columns where there is room, as the web's `md:grid-cols-2`.
  private var gallery: some View {
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(), spacing: Theme.Spacing.medium, alignment: .top),
        count: layoutWidth == .compact ? 1 : 2),
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

  /// The system's empty state.
  @ViewBuilder private var emptyState: some View {
    if state.hasAny {
      ContentUnavailableView("No automations found", systemImage: "magnifyingglass")
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
        .accessibilityIdentifier("automations-empty")
    } else {
      ContentUnavailableView {
        Label("No automations yet", systemImage: "clock")
      } description: {
        Text("Create an automation to run an agent session automatically on a recurring schedule.")
      }
      .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
      .accessibilityIdentifier("automations-empty")
    }
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

/// A template card: the service's mark in its brand color, its title, what it does and what it
/// needs, on the system's material.
struct AutomationTemplateCardView: View {
  let card: AutomationTemplateCard
  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      Image(systemName: card.systemImage)
        .font(.title3)
        .foregroundStyle(AutomationStyle.brandColor(card.id))
        .frame(width: 36, height: 36)
        .background(
          AutomationStyle.brandColor(card.id).opacity(0.12),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(card.title).font(AutomationStyle.cardTitle)
        Text(card.description).font(AutomationStyle.detail).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(card.requirement).font(.caption).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .automationCard(isHighlighted: isHovered)
    .contentShape(RoundedRectangle(cornerRadius: AutomationStyle.cardRadius, style: .continuous))
    .onHover { isHovered = $0 }
  }
}
