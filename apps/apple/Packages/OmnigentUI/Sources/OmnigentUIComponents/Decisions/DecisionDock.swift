public import SwiftUI

/// Pending and just-answered decision cards, docked above the composer so they can never be
/// scrolled out of view. The cards also stay inline in the transcript; while a card is on screen
/// there, the dock leaves it to the card and names it in one line ("1 request needs you · Answer
/// it above"), so a request never offers its actions twice.
///
/// Compact (the default): one line per request with the agent or session; simple approvals and
/// short questions are answered right there, anything substantial shows "Review". Expanded: a
/// selectable request list above the selected card in full. At compact width (iPhone) a request
/// opens in a native sheet instead. Drafts are shared with the inline cards.
public struct DecisionDock: View {
  private let state: ConversationViewState
  private let actions: ConversationActions

  @State private var expansion = Expansion.automatic
  @State private var selectedID: String?
  @State private var showsSheet = false
  @State private var sheetPath: [String] = []
  @Environment(DecisionDrafts.self) private var sharedDrafts: DecisionDrafts?
  @State private var localDrafts = DecisionDrafts()
  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.decisionDockStartsExpanded) private var startsExpanded
  @Environment(\.commandReturnOwner) private var commandReturnOwner
  @Environment(DecisionSurfaces.self) private var surfaces: DecisionSurfaces?

  private var drafts: DecisionDrafts { sharedDrafts ?? localDrafts }

  /// Creates the dock.
  /// - Parameters:
  ///   - state: The conversation, for its cards and their phases.
  ///   - actions: Host actions (`respond`, `validateForm`, `openURL`).
  public init(state: ConversationViewState, actions: ConversationActions) {
    self.state = state
    self.actions = actions
  }

  /// Until the user expands or collapses it, the dock follows `decisionDockStartsExpanded`.
  private enum Expansion {
    case automatic
    case compact
    case expanded
  }

  private var model: DecisionDockModel {
    let isExpanded =
      switch expansion {
      case .automatic: startsExpanded
      case .compact: false
      case .expanded: true
      }
    return DecisionDockModel(
      state: state, selectedID: selectedID, isExpanded: isExpanded, layoutWidth: layoutWidth,
      inline: surfaces?.visibility ?? InlineDecisionVisibility())
  }

  /// The dock; empty when there are no cards.
  public var body: some View {
    let model = model
    if !model.cards.isEmpty {
      let target = model.shortcutTarget
      Group {
        if model.dockCards.isEmpty {
          summary(model)
        } else if model.isExpanded {
          expanded(model)
        } else {
          compact(model)
        }
      }
      .decisionApproveShortcut(target, on: .dock, owner: commandReturnOwner)
      .preference(key: ApproveShortcutCandidate.self, value: target)
      .padding(.top, Theme.Spacing.small)
      .readingColumn()
      .environment(\.openURL, openURLAction)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(model.headline)
      .accessibilityIdentifier("decision-dock")
      .onChange(of: model.cards.map(\.id)) { _, ids in
        drafts.drafts = drafts.drafts.filter { ids.contains($0.key) }
      }
      .sheet(isPresented: $showsSheet) {
        DecisionSheet(
          state: state, actions: actions, path: $sheetPath, close: { showsSheet = false }
        )
        .environment(drafts)
        .environment(\.openURL, openURLAction)
      }
    }
  }

  // MARK: Summary

  /// Every pending request is on screen inline: the dock only names them.
  private func summary(_ model: DecisionDockModel) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: "arrow.up")
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.brandAccent)
        .accessibilityHidden(true)
      Text(
        "\(model.headline) \u{00B7} \(model.aboveCount == 1 ? "Answer it above" : "Answer them above")"
      )
      .font(Theme.Typography.section)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .cardSurface(cornerRadius: Theme.Radius.large)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("decision-dock-summary")
  }

  // MARK: Compact

  private func compact(_ model: DecisionDockModel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.dockCards.count > 1 || model.aboveCount > 0 {
        HStack(spacing: Theme.Spacing.small) {
          Text(model.dockHeadline)
            .font(Theme.Typography.section)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("decision-dock-headline")
          Spacer(minLength: Theme.Spacing.small)
          showAllButton(model)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.small)
      }
      ForEach(Array(model.compactCards.enumerated()), id: \.element.id) { index, card in
        if index > 0 { Divider().padding(.leading, Theme.Spacing.medium) }
        row(card, model: model, showsActions: true)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
      }
      // On a phone the header's Show all already opens the rest.
      if model.hiddenCount > 0, layoutWidth != .compact {
        Divider()
        Button("Show \(model.hiddenCount) more") { open(nil, model: model) }
          .buttonStyle(.borderless)
          .tint(.secondary)
          .font(.callout)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.small)
          .accessibilityIdentifier("decision-dock-show-more")
      }
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
    .cardSurface(cornerRadius: Theme.Radius.large)
    .environment(\.decisionIDPrefix, "dock-")
  }

  private func showAllButton(_ model: DecisionDockModel) -> some View {
    Button {
      open(nil, model: model)
    } label: {
      Label("Show all", systemImage: "chevron.up")
        .labelStyle(TrailingIconLabelStyle())
    }
    .buttonStyle(.borderless)
    .tint(.secondary)
    .font(.callout)
    .accessibilityHint("Lists every request with the selected one in full")
    .accessibilityIdentifier("decision-dock-expand")
  }

  // MARK: Expanded

  private func expanded(_ model: DecisionDockModel) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(spacing: Theme.Spacing.small) {
        Text(model.dockHeadline)
          .font(Theme.Typography.section)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("decision-dock-headline")
        Spacer(minLength: Theme.Spacing.small)
        Button {
          expansion = .compact
        } label: {
          Label("Collapse", systemImage: "chevron.down")
            .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .font(.callout)
        .accessibilityIdentifier("decision-dock-collapse")
      }
      .padding(.horizontal, Theme.Spacing.extraSmall)
      if model.dockCards.count > 1 { requestList(model) }
      if let card = model.selected {
        BoundedScrollView(
          maxHeight: layoutWidth == .compact
            ? Theme.Control.compactDockHeight : Theme.Control.dockHeight
        ) {
          DecisionCardView(
            card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
            context: model.context(for: card),
            respond: actions.respond.map { respond in { respond(card, $0) } },
            validate: actions.validateForm.map { validate in { validate(card, $0) } },
            draft: drafts.binding(card.id)
          )
          .id(card.id)
        }
        .accessibilityIdentifier("decision-dock-scroll")
      }
    }
    // The same card also shows inline in the transcript; the dock's copy has its own ids.
    .environment(\.decisionIDPrefix, "dock-")
  }

  /// Every request, selectable; the selected one shows in full below.
  private func requestList(_ model: DecisionDockModel) -> some View {
    BoundedScrollView(maxHeight: 156) {
      VStack(spacing: Theme.Spacing.tiny) {
        ForEach(model.dockCards) { card in
          row(card, model: model, showsActions: false)
            .padding(.vertical, Theme.Spacing.tiny)
        }
      }
      .padding(Theme.Spacing.extraSmall)
    }
    .cardSurface(cornerRadius: Theme.Radius.large)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Requests")
    .accessibilityIdentifier("decision-dock-list")
  }

  private func row(
    _ card: DecisionCard, model: DecisionDockModel, showsActions: Bool
  ) -> some View {
    DecisionSummaryRow(
      card: card, phase: state.phase(of: card), context: model.context(for: card),
      canRespond: model.canRespond(card, hasResponder: actions.respond != nil),
      showsActions: showsActions, isSelected: !showsActions && model.selected?.id == card.id,
      act: { response in respond(card, response) },
      open: {
        if showsActions {
          open(card.id, model: model)
        } else {
          selectedID = card.id
        }
      })
  }

  // MARK: Actions

  /// Opens `id` (or the whole list): a sheet at compact width, else the expanded dock.
  private func open(_ id: String?, model: DecisionDockModel) {
    if layoutWidth == .compact {
      sheetPath = id.map { [$0] } ?? []
      showsSheet = true
    } else {
      selectedID = id ?? model.selected?.id
      expansion = .expanded
    }
  }

  /// Rows answer only binary choices and plain answers, which never widen permissions.
  private func respond(_ card: DecisionCard, _ response: DecisionResponse) {
    actions.respond?(card, response)
  }

  private var openURLAction: OpenURLAction {
    OpenURLAction { url in
      if let open = actions.openURL {
        open(url)
        return .handled
      }
      return .systemAction
    }
  }
}

/// The iPhone presentation: every request in a list, each opening the full card. Answering the
/// open request returns to the list, or closes the sheet when nothing else is waiting.
struct DecisionSheet: View {
  let state: ConversationViewState
  let actions: ConversationActions
  @Binding var path: [String]
  let close: () -> Void
  @Environment(DecisionDrafts.self) private var drafts: DecisionDrafts?

  private var model: DecisionDockModel {
    DecisionDockModel(state: state, selectedID: path.last, isExpanded: true, layoutWidth: .compact)
  }

  var body: some View {
    NavigationStack(path: $path) {
      List(model.cards) { card in
        NavigationLink(value: card.id) {
          SheetRow(card: card, phase: state.phase(of: card), context: model.context(for: card))
        }
        .accessibilityIdentifier("sheet-decision-select-\(card.id)")
      }
      .navigationTitle("Requests")
      .navigationDestination(for: String.self) { id in
        detail(id)
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: close).accessibilityIdentifier("decision-sheet-done")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    #if os(macOS)
      // A narrow Mac window has no detents; a list on its own would collapse to no rows.
      .frame(minWidth: 480, minHeight: 560)
    #endif
    .environment(\.decisionIDPrefix, "sheet-")
    .accessibilityIdentifier("decision-sheet")
    .onChange(of: state.pendingDecisions.map(\.id)) { _, pending in
      if pending.isEmpty {
        close()
      } else if let open = path.last, !pending.contains(open) {
        path = []
      }
    }
  }

  @ViewBuilder private func detail(_ id: String) -> some View {
    if let card = model.cards.first(where: { $0.id == id }) {
      ScrollView {
        DecisionCardView(
          card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
          context: model.context(for: card),
          respond: actions.respond.map { respond in { respond(card, $0) } },
          validate: actions.validateForm.map { validate in { validate(card, $0) } },
          draft: drafts?.binding(card.id)
        )
        .padding(Theme.Spacing.compactGutter)
      }
      .navigationTitle(DecisionSummary(card).plain)
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
    } else {
      ContentUnavailableView(
        "Request answered", systemImage: "checkmark.circle",
        description: Text("This request is no longer waiting for you."))
    }
  }
}

private struct SheetRow: View {
  let card: DecisionCard
  let phase: DecisionPhase
  let context: String?

  var body: some View {
    let summary = DecisionSummary(card)
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      DecisionStateGlyph(card: card, phase: phase)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        SummaryText(summary: summary).lineLimit(2)
        if let secondary = [summary.secondary, context].compactMap(\.self).first {
          Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
  }
}
