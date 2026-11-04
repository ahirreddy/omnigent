import SwiftUI

extension View {
  /// Presents the right panel beside the view, or over it while full screen (the web's
  /// maximized rail), and handles Shift-Command-F for the panel's Search in the focused pane.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - actions: Host actions.
  ///   - slots: The panel's content.
  ///   - isPresented: Whether the panel shows; hiding it leaves full screen.
  ///   - tab: The panel's fixed tab.
  /// - Returns: The view with the panel.
  func workspaceInspector(
    state: ConversationViewState, actions: ConversationActions, slots: WorkspaceSlots,
    isPresented: Binding<Bool>, tab: Binding<InspectorTab>
  ) -> some View {
    modifier(
      WorkspaceInspectorPresentation(
        state: state, actions: actions, slots: slots, isPresented: isPresented, tab: tab))
  }
}

private struct WorkspaceInspectorPresentation: ViewModifier {
  let state: ConversationViewState
  let actions: ConversationActions
  let slots: WorkspaceSlots
  @Binding var isPresented: Bool
  @Binding var tab: InspectorTab
  @Environment(\.isActiveTabPane) private var handlesShortcuts
  @State private var maximized = false

  private var panel: WorkspaceInspector {
    WorkspaceInspector(
      state: state, actions: actions, slots: slots, tab: $tab, maximized: $maximized)
  }

  func body(content: Content) -> some View {
    content
      .overlay {
        if isPresented, maximized { panel }
      }
      .inspector(isPresented: sideColumnPresented) {
        panel.inspectorColumnWidth(min: 260, ideal: 360, max: 600)
      }
      .onChange(of: isPresented) { _, shows in
        if !shows { maximized = false }
      }
      .background { searchShortcut }
  }

  /// The side column, hidden while the panel fills the screen.
  private var sideColumnPresented: Binding<Bool> {
    Binding(get: { isPresented && !maximized }, set: { isPresented = $0 })
  }

  @ViewBuilder private var searchShortcut: some View {
    if handlesShortcuts, slots.search != nil {
      Button("Search Files") {
        tab = .search
        slots.documents?.showPanel()
        isPresented = true
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
  }
}

/// The tab row's trailing controls, as on the web: "Open new" (+), the panel picker that also
/// lists the open files, and Full Screen.
struct InspectorTrailingControls: View {
  let openNewSections: (@MainActor () -> [InspectorMenuSection])?
  let panels: [InspectorTab]
  let documents: InspectorDocuments?
  let maximized: Binding<Bool>?
  let label: (InspectorTab) -> String
  let select: (InspectorTab) -> Void

  var body: some View {
    let openNew = openNewSections?() ?? []
    HStack(spacing: Theme.Spacing.tiny) {
      if !openNew.isEmpty {
        Menu {
          ForEach(openNew) { section in
            Section {
              ForEach(section.items) { item in
                Button(item.title, systemImage: item.systemImage, action: item.action)
                  .disabled(!item.isEnabled)
              }
            } header: {
              if let title = section.title { Text(title) }
            }
          }
        } label: {
          Label("Open new", systemImage: "plus")
        }
        .help("Open new")
        .accessibilityIdentifier("inspector-open-new")
      }
      if let documents, !documents.tabs.isEmpty {
        Menu {
          Section("Panels") {
            ForEach(panels) { panel in
              Button(label(panel), systemImage: panel.systemImage) { select(panel) }
            }
          }
          Section("Open Files") {
            ForEach(documents.tabs) { tab in
              Toggle(
                tab.detail,
                isOn: Binding(
                  get: { documents.selected == tab.id }, set: { _ in documents.select(tab.id) }))
            }
          }
        } label: {
          Label("Select panel", systemImage: "chevron.down")
        }
        .help("Select panel")
        .accessibilityIdentifier("inspector-select-panel")
      }
      if let maximized {
        Button {
          maximized.wrappedValue.toggle()
        } label: {
          Label(
            maximized.wrappedValue ? "Exit full screen" : "Full screen",
            systemImage: maximized.wrappedValue
              ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.borderless)
        .help(maximized.wrappedValue ? "Exit full screen" : "Full screen")
        .accessibilityIdentifier("inspector-full-screen")
      }
    }
    .labelStyle(.iconOnly)
    .menuIndicator(.hidden)
    #if os(macOS)
      .menuStyle(.borderlessButton)
    #endif
    .foregroundStyle(ThemeColor.mutedText)
    .fixedSize()
  }
}

/// The files and diffs open as tabs, each with a close button, scrolling sideways when they
/// do not fit.
struct InspectorDocumentStrip: View {
  let documents: InspectorDocuments

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: Theme.Spacing.extraSmall) {
          ForEach(documents.tabs) { tab in
            DocumentTabChip(
              tab: tab, isSelected: tab.id == documents.selected,
              select: { documents.select(tab.id) }, close: { documents.close(tab.id) }
            )
            .id(tab.id)
          }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.small)
      }
      .scrollIndicators(.never)
      .onChange(of: documents.selected, initial: true) { _, selected in
        if let selected { proxy.scrollTo(selected) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open files")
    .accessibilityIdentifier("inspector-open-files")
  }
}

private struct DocumentTabChip: View {
  let tab: InspectorDocumentTab
  let isSelected: Bool
  let select: () -> Void
  let close: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      Button(action: select) {
        Label(tab.title, systemImage: tab.systemImage)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 160, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.caption2.weight(.semibold))
          .frame(width: 14, height: 14)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close \(tab.title)")
      .accessibilityLabel("Close \(tab.title)")
    }
    .font(.callout)
    .foregroundStyle(isSelected ? ThemeColor.primary : ThemeColor.mutedText)
    .padding(.horizontal, Theme.Spacing.small)
    .frame(height: 24)
    .background {
      if isSelected || isHovered {
        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
          .fill(ThemeColor.hover)
      }
    }
    .onHover { isHovered = $0 }
    .help(tab.detail)
    .contextMenu {
      Button("Close Tab", action: close)
    }
  }
}
