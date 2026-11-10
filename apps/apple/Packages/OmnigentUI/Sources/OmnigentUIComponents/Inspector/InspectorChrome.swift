import SwiftUI

extension View {
  /// Presents the right panel beside the view, or over it while full screen (the web's
  /// maximized rail), and handles Shift-Command-F for the panel's Search and Option-Command-1
  /// onward for its tabs in the focused pane.
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
        state: state, actions: actions, slots: slots, shows: isPresented, tab: tab))
  }
}

/// The right panel: the inspector column on the Mac. iOS lays out its own column (regular
/// width) or sheet (compact): SwiftUI's `.inspector` there kept a pushed conversation in a
/// layout loop (main thread at 100%, the screen frozen on its previous frame) even while hidden.
private struct InspectorColumn<Panel: View>: ViewModifier {
  @Binding var isPresented: Bool
  @ViewBuilder let panel: () -> Panel
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The sheet's binding at regular width (`.constant` counts as changed on every update).
    @State private var sheetHidden = false
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
      // One structure for both size classes: rotating a large iPhone or resizing an iPad window
      // across them must not rebuild the conversation (its whole transcript) underneath.
      let isCompact = sizeClass == .compact
      PanelColumnLayout {
        content
        if isPresented, !isCompact {
          HStack(spacing: 0) {
            Divider().ignoresSafeArea()
            panel()
          }
          .transition(.move(edge: .trailing))
        }
      }
      .sheet(isPresented: isCompact ? $isPresented : $sheetHidden) {
        panel().presentationDetents([.medium, .large])
      }
    #else
      content.inspector(isPresented: $isPresented) {
        panel().inspectorColumnWidth(min: 260, ideal: 360, max: 600)
      }
      #if DEBUG
        .onChange(of: isPresented) { old, new in
          LoopProbe.record("right panel shown", "\(old) -> \(new)")
        }
      #endif
    #endif
  }
}

/// The iPad's conversation and right panel side by side: the panel takes the Mac inspector's
/// ideal width, narrowing to keep the conversation readable in a tight split.
struct PanelColumnLayout: Layout {
  /// The panel's widest and narrowest widths.
  static let panelWidth: ClosedRange<CGFloat> = 260...360
  /// The share of the width the panel may take before it narrows.
  static let panelShare: CGFloat = 0.45

  /// The panel's width in `width`.
  static func panelWidth(in width: CGFloat) -> CGFloat {
    min(panelWidth.upperBound, max(panelWidth.lowerBound, (width * panelShare).rounded(.down)))
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let content = subviews.first else { return }
    let panel = subviews.count > 1 ? Self.panelWidth(in: bounds.width) : 0
    content.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width - panel, height: bounds.height))
    for subview in subviews.dropFirst() {
      subview.place(
        at: CGPoint(x: bounds.maxX - panel, y: bounds.minY),
        proposal: ProposedViewSize(width: panel, height: bounds.height))
    }
  }
}

private struct WorkspaceInspectorPresentation: ViewModifier {
  let state: ConversationViewState
  let actions: ConversationActions
  let slots: WorkspaceSlots
  @Binding var shows: Bool
  @Binding var tab: InspectorTab
  @Environment(\.isActiveTabPane) private var handlesShortcuts
  @Environment(\.isTabContentHidden) private var isHiddenTab
  @State private var maximized = false
  /// A hidden tab's panel stays closed (`.constant` counts as changed on every update).
  @State private var hiddenPanel = false

  private var panel: WorkspaceInspector {
    WorkspaceInspector(
      state: state, actions: actions, slots: slots, tab: $tab, maximized: $maximized)
  }

  /// Whether the panel shows: the conversation's choice while its tab is on screen. Read here
  /// and not by the conversation, whose body then does not run when its tab hides or shows.
  private var presented: Binding<Bool> { isHiddenTab ? $hiddenPanel : $shows }

  func body(content: Content) -> some View {
    let isPresented = presented.wrappedValue
    content
      .holdsSizeWhileTabHidden()
      .unmeasuredMinimum(UnmeasuredMinimum.column)
      .overlay {
        if isPresented, maximized { panel }
      }
      .modifier(InspectorColumn(isPresented: sideColumnPresented) { panel })
      .onChange(of: isPresented) { _, isShowing in
        if !isShowing { maximized = false }
      }
      .background { shortcuts }
  }

  /// The side column, hidden while the panel fills the screen.
  private var sideColumnPresented: Binding<Bool> {
    let presented = presented
    return Binding(
      get: { presented.wrappedValue && !maximized }, set: { presented.wrappedValue = $0 })
  }

  /// Shift-Command-F for Search and Option-Command-1 onward for the shown tabs, in order.
  @ViewBuilder private var shortcuts: some View {
    if handlesShortcuts {
      Group {
        if slots.search != nil {
          Button("Search Files") { show(.search) }
            .keyboardShortcut(AppShortcuts.searchWorkspace)
        }
        let panels = InspectorTab.shown(hasSearch: slots.search != nil)
        ForEach(panels.indices, id: \.self) { index in
          Button(panels[index].title) { show(panels[index]) }
            .keyboardShortcut(AppShortcuts.rightPanelTab(index))
        }
      }
      .opacity(0)
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
  }

  private func show(_ panel: InspectorTab) {
    tab = panel
    slots.documents?.showPanel()
    shows = true
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
