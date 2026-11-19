import OmnigentPlatform
public import SwiftUI

/// A workflow's page, laid out as the web's `/workflows/:id`: the way back, the name with Edit
/// plan, Delete, Share, Clone, Create automation and Run; the description, edited in place; the
/// plan as a graph, with Save plan while the planning chat proposes changes; the automations that
/// run it; and its runs. A shared one is read-only: its owner's actions show disabled with why.
/// The planning chat sits beside the page, or covers it when expanded.
public struct WorkflowDetailView<Planner: View>: View {
  private let state: WorkflowDetailState
  private let actions: WorkflowDetailActions
  private let planner: Planner?
  @Binding private var plannerExpanded: Bool
  @State private var confirmingDelete = false
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the page.
  /// - Parameters:
  ///   - state: The workflow.
  ///   - actions: What the page can do.
  ///   - plannerExpanded: The planning chat covers the page.
  ///   - planner: The planning chat beside the page; `nil` while it is closed.
  public init(
    state: WorkflowDetailState, actions: WorkflowDetailActions,
    plannerExpanded: Binding<Bool> = .constant(false), planner: Planner?
  ) {
    self.state = state
    self.actions = actions
    self.planner = planner
    _plannerExpanded = plannerExpanded
  }

  /// The page.
  public var body: some View {
    #if os(macOS)
      HStack(spacing: 0) {
        if !(plannerExpanded && planner != nil) { page }
        if let planner {
          if !plannerExpanded { Divider() }
          planner
            .frame(
              minWidth: 380, idealWidth: 460,
              maxWidth: plannerExpanded ? .infinity : 560
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflow-planner")
        }
      }
    #else
      page.sheet(
        isPresented: Binding(get: { planner != nil }, set: { if !$0 { actions.closePlanner?() } })
      ) {
        planner
      }
    #endif
  }

  private var page: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let back = actions.back {
          // A back button as the platform draws one: the chevron and the page it returns to.
          Button(action: back) {
            Label("Workflows", systemImage: "chevron.backward")
          }
          .buttonStyle(.borderless)
          .keyboardShortcut("[", modifiers: .command)
          .help("Back to Workflows")
          .accessibilityIdentifier("workflow-detail-back")
          .padding(.bottom, Theme.Spacing.large)
        }
        header
        if let error = state.actionError {
          AutomationErrorBanner(
            message: error, actionTitle: actions.dismissError == nil ? nil : "Dismiss",
            action: actions.dismissError
          )
          .padding(.top, Theme.Spacing.large)
        }
        WorkflowDescriptionSection(state: state, actions: actions)
          .padding(.top, Theme.Spacing.extraLarge)
        planSection.padding(.top, Theme.Spacing.extraLarge)
        if let automations = state.automations { automationsSection(automations) }
        if let runs = state.runs {
          Divider().padding(.vertical, Theme.Spacing.extraLarge)
          WorkflowRunsSection(
            runs: runs, hasMore: state.hasMoreRuns, isLoadingMore: state.isLoadingMoreRuns,
            actions: actions)
        }
      }
      .padding(.horizontal, AutomationStyle.gutter(layoutWidth))
      .padding(.vertical, Theme.Spacing.extraLarge)
      .frame(maxWidth: Theme.inboxWidth, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .themeCanvas()
    .navigationTitle(state.name)
    .confirmationDialog("Delete workflow?", isPresented: $confirmingDelete) {
      Button("Delete workflow", role: .destructive) { actions.delete?() }
    } message: {
      Text("\u{201C}\(state.name)\u{201D} will be deleted. This cannot be undone.")
    }
  }

  /// The name with its actions beside it; on a phone Run goes under the name, the others in a
  /// menu beside it.
  @ViewBuilder private var header: some View {
    if layoutWidth == .compact {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        titleBlock
        HStack(spacing: Theme.Spacing.small) {
          if let run = actions.run {
            Button("Run", systemImage: "play.fill", action: run)
              .buttonStyle(.borderedProminent)
              .disabled(!state.canRun)
              .accessibilityIdentifier("workflow-detail-run")
          }
          Menu("More", systemImage: "ellipsis.circle") { compactMenu }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("workflow-detail-more")
        }
      }
    } else {
      HStack(alignment: .top, spacing: Theme.Spacing.large) {
        titleBlock
        Spacer(minLength: 0)
        headerActions
      }
    }
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text(state.name).font(AutomationStyle.pageTitle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("workflow-detail-title")
      if state.isDraft {
        Text("Draft").font(.caption.weight(.medium)).foregroundStyle(.secondary)
          .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
          .background(.quaternary, in: Capsule())
          .accessibilityIdentifier("workflow-detail-draft")
      }
      if let owner = state.sharedBy {
        Text("Shared by \(owner)").font(AutomationStyle.detail).foregroundStyle(.secondary)
          .accessibilityIdentifier("workflow-detail-owner")
      }
    }
  }

  private var headerActions: some View {
    HStack(spacing: Theme.Spacing.small) {
      if let edit = actions.editPlan {
        iconButton("Edit plan with agent", systemImage: "pencil", action: edit)
          .disabled(state.isReadOnly)
          .help(state.isReadOnly ? WorkflowOwnerOnly.edit : "Edit plan with agent")
          .accessibilityIdentifier("workflow-detail-edit")
      }
      if actions.delete != nil {
        iconButton("Delete workflow", systemImage: "trash") { confirmingDelete = true }
          .disabled(state.isReadOnly)
          .help(state.isReadOnly ? WorkflowOwnerOnly.delete : "Delete workflow")
          .accessibilityIdentifier("workflow-detail-delete")
      }
      shareButton
      if let clone = actions.clone {
        Button(action: clone) {
          if state.isCloning {
            Label {
              Text("Clone")
            } icon: {
              ProgressView().controlSize(.small)
            }
          } else {
            Label("Clone", systemImage: "doc.on.doc")
          }
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(state.isCloning)
        .accessibilityIdentifier("workflow-detail-clone")
      }
      if let create = actions.createAutomation, state.offersAutomations, !state.isReadOnly {
        Button("Create automation", systemImage: "clock", action: create)
          .buttonStyle(.bordered)
          .fixedSize()
          .disabled(!state.canRun)
          .accessibilityIdentifier("workflow-detail-create-automation")
      }
      if let run = actions.run {
        Button("Run", systemImage: "play.fill", action: run)
          .buttonStyle(.borderedProminent)
          .fixedSize()
          .disabled(!state.canRun)
          .help(runHelp)
          .accessibilityIdentifier("workflow-detail-run")
      }
    }
  }

  private var runHelp: String {
    if state.isDraft { return "Save a plan before running it." }
    if state.hasUnsavedPlan { return "Save the plan before running it." }
    return "Run this workflow"
  }

  @ViewBuilder private var shareButton: some View {
    if state.isReadOnly {
      iconButton("Share workflow", systemImage: "square.and.arrow.up") {}
        .disabled(true).help(WorkflowOwnerOnly.share)
        .accessibilityIdentifier("workflow-detail-share")
    } else if let share = state.share {
      switch share {
      case .disabled(let reason):
        iconButton("Share workflow", systemImage: "square.and.arrow.up") {}
          .disabled(true).help(reason)
          .accessibilityIdentifier("workflow-detail-share")
      case .enabled:
        if let action = actions.share {
          iconButton("Share workflow", systemImage: "square.and.arrow.up", action: action)
            .accessibilityIdentifier("workflow-detail-share")
        }
      }
    }
  }

  /// An icon-only button in the platform's bordered style, named by its tooltip.
  private func iconButton(
    _ title: String, systemImage: String, action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(title, systemImage: systemImage, action: action)
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .help(title)
  }

}

/// The page's plan and automations.
extension WorkflowDetailView {
  /// A phone's menu of the header's other actions; a viewer's show disabled.
  @ViewBuilder private var compactMenu: some View {
    if let edit = actions.editPlan {
      Button("Edit plan with agent", systemImage: "pencil", action: edit)
        .disabled(state.isReadOnly)
    }
    if let clone = actions.clone {
      Button("Clone", systemImage: "doc.on.doc", action: clone).disabled(state.isCloning)
    }
    if let create = actions.createAutomation, state.offersAutomations, !state.isReadOnly {
      Button("Create automation", systemImage: "clock", action: create).disabled(!state.canRun)
    }
    if state.isReadOnly || state.share != nil {
      Button("Share workflow", systemImage: "square.and.arrow.up") { actions.share?() }
        .disabled(state.isReadOnly || state.share != .enabled || actions.share == nil)
    }
    if actions.delete != nil {
      Divider()
      Button("Delete workflow", systemImage: "trash", role: .destructive) {
        confirmingDelete = true
      }
      .disabled(state.isReadOnly)
    }
  }

  /// "Plan" with whether it is saved, Save plan, and the steps or how to make some.
  private var planSection: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text("Plan").font(AutomationStyle.sectionTitle).accessibilityAddTraits(.isHeader)
          if state.hasUnsavedPlan || !state.isDraft {
            Text(state.hasUnsavedPlan ? "Unsaved changes" : "Saved plan")
              .font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("workflow-plan-status")
          }
        }
        Spacer(minLength: 0)
        if state.hasUnsavedPlan, let save = actions.savePlan {
          Button(action: save) {
            if state.isSavingPlan {
              Label {
                Text("Save plan")
              } icon: {
                ProgressView().controlSize(.small)
              }
            } else {
              Label("Save plan", systemImage: "square.and.arrow.down")
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .disabled(state.isSavingPlan)
          .accessibilityIdentifier("workflow-save-plan")
        }
      }
      if let error = state.planError {
        Label(
          "Couldn\u{2019}t save the plan. \(error)", systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(Theme.failure).font(.callout)
        .accessibilityIdentifier("workflow-plan-error")
      }
      if let error = state.proposalError {
        HStack(spacing: Theme.Spacing.small) {
          Text("Couldn\u{2019}t load the latest proposal.").foregroundStyle(Theme.failure)
            .help(error)
          if let retry = actions.retryProposal {
            Button("Retry", action: retry).controlSize(.small)
          }
        }
        .font(.callout)
      }
      if let graph = state.graph, !graph.steps.isEmpty {
        WorkflowStepsGraph(graph: graph)
      } else {
        noPlan
      }
    }
  }

  /// The empty plan's placeholder, in a card where the graph goes.
  private var noPlan: some View {
    VStack(spacing: Theme.Spacing.small) {
      Image(systemName: "flowchart").font(.largeTitle).foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text("No plan yet").font(.headline)
      Text(
        state.isReadOnly
          ? "Its owner hasn\u{2019}t saved a plan yet."
          : "Describe the workflow to an agent.\nYour proposed steps will appear here."
      )
      .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if !state.isReadOnly, planner == nil, let edit = actions.editPlan {
        Button("Create plan", action: edit)
          .padding(.top, Theme.Spacing.small)
          .accessibilityIdentifier("workflow-create-plan")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.section)
    .automationCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workflow-no-plan")
  }

  @ViewBuilder private func automationsSection(
    _ automations: WorkflowSectionLoad<WorkflowAutomationRowState>
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Automations").font(AutomationStyle.sectionTitle).accessibilityAddTraits(.isHeader)
      switch automations {
      case .loading:
        AutomationLoadingRow(
          title: "Loading automations\u{2026}", verticalPadding: Theme.Spacing.medium)
      case .failed:
        Text("Couldn\u{2019}t load automations.").foregroundStyle(.secondary)
          .accessibilityIdentifier("workflow-automations-error")
      case .loaded(let rows) where rows.isEmpty:
        Text("No automations yet.").foregroundStyle(.secondary)
          .accessibilityIdentifier("workflow-automations-empty")
      case .loaded(let rows):
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          ForEach(rows) { row in
            WorkflowAutomationRow(row: row) { actions.openAutomation?(row.id) }
          }
        }
        .accessibilityIdentifier("workflow-automations")
      }
    }
    .padding(.top, Theme.Spacing.extraLarge)
  }
}

/// Why someone a workflow is shared with can't take each action only its owner takes.
enum WorkflowOwnerOnly {
  static let edit = "Only the workflow\u{2019}s owner can edit it."
  static let share = "Only the workflow\u{2019}s owner can share it."
  static let delete = "Only the workflow\u{2019}s owner can delete it."
}
