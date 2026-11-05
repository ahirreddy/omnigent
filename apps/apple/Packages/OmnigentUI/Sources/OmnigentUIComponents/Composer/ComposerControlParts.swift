import SwiftUI

/// The composer's controls. The Mac's pill has Add, then Stop, Send and Mic (its other controls
/// are in ``ComposerFooter``). The touch bar's open row: Add, Host and the approval mode on the
/// leading side; the agent, model and effort, and Mic on the trailing side; then Stop and Send.
/// Its collapsed row keeps only Add, a Full access warning, Mic and Send or Stop.
struct ComposerControlParts {
  let state: ComposerViewState
  let actions: ComposerActions
  let rules: ComposerSendRules
  let hasDraft: Bool
  let isEditable: Bool
  let canAttach: Bool
  let layoutWidth: LayoutWidth
  let layout: ComposerLayoutStyle
  @Binding var isImporting: Bool
  @Binding var isPickingPhotos: Bool
  @Binding var isExpanded: Bool
  let loadProviders: ([NSItemProvider]) -> Void
  let perform: (ComposerSendIntent) -> Void
  /// Mic: the host's dictation, else the system's (speech recognition on touch).
  var pillDictate: (@MainActor () -> Void)?

  /// The touch bar's open row; the model name takes the free width and truncates first. The
  /// host's name (also in the context row) gives way first where the row can't fit it, as on an
  /// iPad mini beside the sidebar, so the row never runs past the composer's edge.
  var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      if layoutWidth == .regular { row(showsHostName: true) }
      row(showsHostName: false)
    }
  }

  private func row(showsHostName: Bool) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      HStack(spacing: Theme.Spacing.extraSmall) { leading(showsHostName: showsHostName) }
        .fixedSize()
      Spacer(minLength: Theme.Spacing.small)
      trailing
      send
    }
  }

  /// The Mac pill's leading side: Add.
  @ViewBuilder var pillLeading: some View {
    addMenu.imageScale(.large)
  }

  /// The Mac pill's trailing side: Stop while the agent works, Send once there is something to
  /// send, then Mic. Expand keeps its shortcut without a button.
  var pillTrailing: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      send
      ComposerEditorButtons(
        dictate: pillDictate, isEditable: isEditable, showsExpand: false,
        isExpanded: $isExpanded)
    }
    .background { ComposerExpandShortcut(isExpanded: $isExpanded) }
  }

  /// The collapsed bar's leading side: Add only.
  @ViewBuilder var collapsedLeading: some View {
    addMenu
  }

  /// The collapsed bar's trailing side: Full access stays visible as a warning, then Mic, then
  /// Send or Stop.
  @ViewBuilder var collapsedTrailing: some View {
    if let modes = state.approvalModes, modes.selected?.risk == .fullAccess {
      ApprovalModeChip(modes: modes, select: actions.extras.selectApprovalMode, isCompact: true)
        .disabled(!isEditable)
        .tint(.primary)
    }
    ComposerEditorButtons(
      dictate: pillDictate, isEditable: isEditable, showsExpand: false,
      isExpanded: $isExpanded)
    send
  }

  /// Add: attachments, then the session's side chat, Goal and Plan.
  @ViewBuilder private var addMenu: some View {
    let attaches = state.acceptsAttachments && actions.addAttachments != nil
    let extras = actions.extras
    if attaches || extras.newSideChat != nil || extras.setGoal != nil || extras.togglePlan != nil {
      AddMenu(
        canAttach: attaches && canAttach, extras: extras, chooseFiles: { isImporting = true },
        choosePhotos: { isPickingPhotos = true }, paste: loadProviders
      )
      .tint(.secondary)
    }
  }

  @ViewBuilder private func leading(showsHostName: Bool) -> some View {
    addMenu
    // A locked host is already named in the context row.
    if let hosts = state.hosts, !hosts.isLocked {
      HostChip(hosts: hosts, actions: actions.extras, showsName: showsHostName)
        .tint(.secondary)
    }
    if let modes = state.approvalModes {
      ApprovalModeChip(
        modes: modes, select: actions.extras.selectApprovalMode,
        isCompact: layoutWidth == .compact
      )
      .disabled(!isEditable)
      .tint(.primary)
    }
  }

  @ViewBuilder private var trailing: some View {
    configuration(showsModel: true)
    editorButtons
  }

  @ViewBuilder
  private func configuration(showsModel: Bool) -> some View {
    if let configuration = state.configuration {
      ConfigurationMenu(
        configuration: configuration, actions: actions, isCompact: layoutWidth == .compact,
        showsModel: showsModel
      )
      .disabled(!isEditable)
      .tint(.primary)
    }
  }

  private var editorButtons: some View {
    ComposerEditorButtons(
      dictate: pillDictate, isEditable: isEditable,
      showsExpand: layoutWidth == .regular, isExpanded: $isExpanded)
  }

  private var send: some View {
    ComposerSendControls(
      state: state, rules: rules, hasDraft: hasDraft, perform: perform,
      interrupt: actions.interrupt)
  }
}
