import OmnigentPlatform
public import SwiftUI

/// The Workflows page (the web's `/workflows`): the title with New workflow, a search once there
/// is anything to search, the caller's workflows, and those shared with them. A row opens the
/// workflow's page; its menu runs, clones, deletes or makes an automation of it.
public struct WorkflowsView: View {
  private let state: WorkflowsViewState
  private let actions: WorkflowsActions
  @State private var search = ""
  @State private var creating = false
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  /// - Parameters:
  ///   - state: The lists.
  ///   - actions: What the page can do.
  public init(state: WorkflowsViewState, actions: WorkflowsActions) {
    self.state = state
    self.actions = actions
  }

  /// The page.
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header.padding(.bottom, Theme.Spacing.extraLarge)
        if state.hasAnyWorkflow || !search.isEmpty {
          SearchField("Search workflows", text: $search, identifier: "workflows-search")
            .controlSize(.large)
            .padding(.bottom, Theme.Spacing.large)
        }
        if let error = state.actionError {
          AutomationErrorBanner(
            message: error, actionTitle: actions.dismissError == nil ? nil : "Dismiss",
            action: actions.dismissError
          )
          .padding(.bottom, Theme.Spacing.large)
        }
        yours
        if let shared = state.shared { sharedSection(shared) }
      }
      .padding(.horizontal, AutomationStyle.gutter(layoutWidth))
      .padding(.vertical, Theme.Spacing.extraLarge)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle("Workflows")
    .onChange(of: search) { actions.search?(search) }
    .sheet(isPresented: $creating) {
      NewWorkflowSheet(create: actions.create, nameTaken: actions.nameTaken) { creating = false }
    }
    .workflowDeleteConfirmation(state.deletePrompt, actions: actions)
  }

  /// The title and what workflows are, with New workflow on the right.
  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.large) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text("Workflows").font(AutomationStyle.pageTitle)
          .accessibilityAddTraits(.isHeader)
        Text("Reusable step-by-step routines that agents can run for you.")
          .font(AutomationStyle.detail).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if actions.create != nil {
        // A phone keeps the title whole: New shows as its symbol.
        if layoutWidth == .compact {
          newButton.labelStyle(.iconOnly).buttonBorderShape(.circle)
        } else {
          newButton
        }
      }
    }
  }

  private var newButton: some View {
    Button("New workflow", systemImage: "plus") { creating = true }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .fixedSize()
      .help("New workflow")
      .accessibilityIdentifier("workflows-new")
  }

  @ViewBuilder private var yours: some View {
    let list = state.yours
    if let error = list.loadError {
      AutomationErrorBanner(
        message: "Couldn\u{2019}t load workflows.", detail: error,
        actionTitle: actions.retry == nil ? nil : "Retry", action: actions.retry
      )
      .accessibilityIdentifier("workflows-load-error")
    } else if list.isLoading {
      AutomationLoadingRow(title: "Loading workflows\u{2026}")
    } else if list.rows.isEmpty {
      // The shared list may yet have workflows.
      if state.shared.map({ $0.rows.isEmpty && !$0.isLoading && !$0.hasMore }) ?? true {
        emptyState
      }
    } else {
      rows(list.rows).accessibilityIdentifier("workflows-list")
    }
    if list.loadError == nil, list.hasMore, let more = actions.loadMore {
      moreButton("Load more workflows", isLoading: list.isLoadingMore, action: more)
        .accessibilityIdentifier("workflows-more")
    }
  }

  @ViewBuilder private func sharedSection(_ shared: WorkflowListState) -> some View {
    if let error = shared.loadError {
      AutomationErrorBanner(
        message: "Couldn\u{2019}t load the workflows shared with you.", detail: error,
        actionTitle: actions.retryShared == nil ? nil : "Retry", action: actions.retryShared
      )
      .padding(.top, Theme.Spacing.section)
      .accessibilityIdentifier("workflows-shared-load-error")
    } else if !shared.rows.isEmpty || shared.hasMore {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text("Shared with you").font(AutomationStyle.sectionTitle)
          .accessibilityAddTraits(.isHeader)
        rows(shared.rows)
        if shared.hasMore, let more = actions.loadMoreShared {
          moreButton("Load more shared workflows", isLoading: shared.isLoadingMore, action: more)
        }
      }
      .padding(.top, Theme.Spacing.section)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("workflows-shared")
    }
  }

  private func rows(_ rows: [WorkflowRowState]) -> some View {
    LazyVStack(spacing: Theme.Spacing.small) {
      ForEach(rows) { row in
        WorkflowRowView(row: row, actions: rowActions(row), isCloning: state.isCloning)
      }
    }
  }

  private func moreButton(
    _ title: String, isLoading: Bool, action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.small) {
        if isLoading { ProgressView().controlSize(.mini) }
        Text(isLoading ? "Loading\u{2026}" : title)
      }
    }
    .controlSize(.small)
    .disabled(isLoading)
    .frame(maxWidth: .infinity)
    .padding(.top, Theme.Spacing.medium)
  }

  /// The system's empty state: none yet, or none matching the search.
  @ViewBuilder private var emptyState: some View {
    if state.hasAnyWorkflow {
      ContentUnavailableView("No workflows found", systemImage: "magnifyingglass")
        .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
        .accessibilityIdentifier("workflows-empty")
    } else {
      ContentUnavailableView {
        Label("No workflows yet", systemImage: "flowchart")
      } description: {
        Text("Create a workflow to get started.")
      }
      .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.section)
      .accessibilityIdentifier("workflows-empty")
    }
  }

  private func rowActions(_ row: WorkflowRowState) -> WorkflowRowView.Actions {
    let id = row.id
    var rowActions = WorkflowRowView.Actions()
    if let open = actions.open { rowActions.open = { open(id) } }
    if let run = actions.run { rowActions.run = { run(id) } }
    if let create = actions.createAutomation, state.offersAutomations, !row.isReadOnly {
      rowActions.createAutomation = { create(id) }
    }
    if let clone = actions.clone { rowActions.clone = { clone(id) } }
    if let delete = actions.delete, !row.isReadOnly { rowActions.delete = { delete(id) } }
    return rowActions
  }
}

/// One workflow's card: its name, whether it is a draft or whose it is, two lines of what it
/// does, and its menu, which the row's context menu repeats.
struct WorkflowRowView: View {
  struct Actions {
    var open: (@MainActor () -> Void)?
    var run: (@MainActor () -> Void)?
    var createAutomation: (@MainActor () -> Void)?
    var clone: (@MainActor () -> Void)?
    var delete: (@MainActor () -> Void)?
  }

  let row: WorkflowRowState
  let actions: Actions
  var isCloning = false
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Spacing.medium) {
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(row.name).font(AutomationStyle.cardTitle).lineLimit(1)
        if row.isDraft {
          Text("Draft \u{00B7} No saved plan").font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("workflow-draft-\(row.id)")
        }
        if let owner = row.sharedBy {
          Text("Shared by \(owner)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .accessibilityIdentifier("workflow-owner-\(row.id)")
        }
        Text(row.description).font(AutomationStyle.detail).foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
      if row.isBusy { ProgressView().controlSize(.small) }
      Menu {
        menuItems
      } label: {
        Label("Actions", systemImage: "ellipsis.circle")
          .labelStyle(.iconOnly)
          .imageScale(.large)
          .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
          .frame(width: Theme.Control.target, height: Theme.Control.target)
          .contentShape(Rectangle())
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .menuIndicator(.hidden)
      .fixedSize()
      .disabled(row.isBusy)
      .help("Actions")
      .accessibilityLabel("Actions for \(row.name)")
      .accessibilityIdentifier("workflow-menu-\(row.id)")
    }
    .padding(.vertical, Theme.Spacing.medium)
    .padding(.leading, Theme.Spacing.large)
    .padding(.trailing, Theme.Spacing.small)
    .automationCard(isHighlighted: isHovered)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture { actions.open?() }
    .contextMenu {
      if !row.isBusy { menuItems }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("workflow-\(row.id)")
  }

  @ViewBuilder private var menuItems: some View {
    if let run = actions.run {
      Button("Run", systemImage: "play", action: run).disabled(row.isDraft)
        .accessibilityIdentifier("workflow-run")
    }
    if let create = actions.createAutomation {
      Button("Create automation", systemImage: "clock", action: create).disabled(row.isDraft)
        .accessibilityIdentifier("workflow-create-automation")
    }
    if let clone = actions.clone {
      Button("Clone", systemImage: "doc.on.doc", action: clone).disabled(isCloning)
        .accessibilityIdentifier("workflow-clone")
    }
    if let delete = actions.delete {
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        .accessibilityIdentifier("workflow-delete")
    }
  }
}

extension View {
  /// The Delete confirmation for a workflow, once the automations that run it are checked.
  func workflowDeleteConfirmation(
    _ prompt: WorkflowDeletePrompt?, actions: WorkflowsActions
  ) -> some View {
    let ready = prompt.flatMap { prompt -> WorkflowDeletePrompt? in
      if case .ready = prompt { return prompt }
      return nil
    }
    let failed = prompt.flatMap { prompt -> WorkflowDeletePrompt? in
      if case .checkFailed = prompt { return prompt }
      return nil
    }
    let dismiss = { actions.cancelDelete?() }
    return
      alert(
        ready?.automationsTitle ?? "Delete workflow?",
        isPresented: Binding(get: { ready != nil }, set: { if !$0 { dismiss() } }),
        presenting: ready
      ) { prompt in
        Button("Delete workflow", role: .destructive) { actions.confirmDelete?(prompt.id) }
        Button("Cancel", role: .cancel) { dismiss() }
      } message: { prompt in
        Text(prompt.message)
      }
      .alert(
        "Couldn\u{2019}t check which automations use this workflow.",
        isPresented: Binding(get: { failed != nil }, set: { if !$0 { dismiss() } })
      ) {
        Button("Retry") { actions.retryDeleteCheck?() }
        Button("Cancel", role: .cancel) { dismiss() }
      }
  }
}
