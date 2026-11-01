import SwiftUI

/// The composer's controls. The open row: Add, Host and the approval mode on the leading side;
/// the agent, model and effort, Mic and Expand on the trailing side; then Stop and Send. The
/// touch bar's collapsed row keeps only Add, a Full access warning, Mic and Send or Stop.
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

  var toolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        leading
        Spacer(minLength: Theme.Spacing.small)
        trailing
        send
      }
      // Touch keeps one row: the model name gives way before the row wraps.
      if layout == .touch {
        HStack(spacing: Theme.Spacing.extraSmall) {
          leading
          Spacer(minLength: Theme.Spacing.small)
          configuration(showsModel: false)
          editorButtons
          send
        }
      }
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        FlowLayout(spacing: Theme.Spacing.extraSmall) { leading }
        HStack(spacing: Theme.Spacing.extraSmall) {
          trailing
          Spacer(minLength: Theme.Spacing.extraSmall)
          send
        }
      }
    }
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
      dictate: actions.extras.dictate, isEditable: isEditable, showsExpand: false,
      isExpanded: $isExpanded)
    send
  }

  @ViewBuilder private var addMenu: some View {
    if state.acceptsAttachments, actions.addAttachments != nil {
      AddMenu(
        canAttach: canAttach, extras: actions.extras, chooseFiles: { isImporting = true },
        choosePhotos: { isPickingPhotos = true }, paste: loadProviders
      )
      .tint(.secondary)
    }
  }

  @ViewBuilder private var leading: some View {
    addMenu
    // On touch a locked host is already named in the context row.
    if let hosts = state.hosts, layout == .card || !hosts.isLocked {
      HostChip(hosts: hosts, actions: actions.extras, showsName: layoutWidth == .regular)
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
      dictate: actions.extras.dictate, isEditable: isEditable,
      showsExpand: layoutWidth == .regular, isExpanded: $isExpanded)
  }

  private var send: some View {
    ComposerSendControls(
      state: state, rules: rules, hasDraft: hasDraft, perform: perform,
      interrupt: actions.interrupt)
  }
}
