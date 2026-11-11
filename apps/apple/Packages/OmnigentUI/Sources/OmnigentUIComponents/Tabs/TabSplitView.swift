public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// A window's tabs: one shown, or two side by side in panes with a draggable divider, and the
/// rest kept built out of sight (``KeptAliveTabs``). Both panes look the same; the strip marks
/// the focused pane's tab. The focused pane publishes its menu commands
/// (``EnvironmentValues/isActiveTabPane``); a click or tap in the other pane focuses it.
///
/// A tab is the same view shown whole, in a pane or hidden, so splitting, unsplitting and
/// showing another session's tabs build nothing that was built.
///
/// At compact widths, and where both panes would be narrower than
/// ``TabSplitState/minimumPaneWidth``, only the focused pane shows; the split comes back when
/// the window widens. On an unfolded iPhone Duo the panes sit either side of the hinge.
///
/// While a tab is dragged out of the strip (``TabDragTracker``), the content previews where it
/// would land: the other pane of a split, or either edge of a single pane.
public struct TabSplitView<Item: Identifiable, Content: View>: View {
  private let items: [Item]
  private let shownID: Item.ID
  private let paneOf: (Item) -> TabPane?
  private let split: TabSplitState?
  private let actions: TabActions
  private let content: (Item) -> Content

  /// Whether the content is wide enough for both panes; assumed so until measured, so a split
  /// never starts single. A flag, not the width, so resizing re-renders only when it flips.
  @State private var fitsBoth = true
  @State private var measured = MeasuredWidth()
  @State private var liveFraction: Double?
  /// An unfolded Duo's hinge, in the content's coordinates.
  @State private var hinge: CGRect?
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(TabDragTracker.self) private var tracker: TabDragTracker?

  /// Creates the view over tabs that stay built.
  /// - Parameters:
  ///   - tabs: The tabs to keep built, the shown ones among them, in a stable order.
  ///   - shownID: The tab on screen, or the focused pane's when split.
  ///   - split: The panes and their tabs; `nil` shows one pane.
  ///   - actions: Focus, divider and drop actions.
  ///   - content: A tab's content.
  public init(
    _ tabs: [Item], shownID: String, split: TabSplitState?, actions: TabActions,
    @ViewBuilder content: @escaping (Item) -> Content
  ) where Item.ID == String {
    items = tabs
    self.shownID = shownID
    paneOf = { tab in TabPane.allCases.first { split?.activeID($0) == tab.id } }
    self.split = split
    self.actions = actions
    self.content = content
  }

  /// Creates the view over one tab per pane, with nothing kept beside them.
  /// - Parameters:
  ///   - split: The panes; `nil` shows one pane.
  ///   - actions: Focus, divider and drop actions.
  ///   - content: A pane's content: its tab.
  public init(
    split: TabSplitState?, actions: TabActions,
    @ViewBuilder content: @escaping (TabPane) -> Content
  ) where Item == TabPane {
    items = split == nil ? [.leading] : TabPane.allCases
    shownID = split?.focused ?? .leading
    paneOf = { $0 }
    self.split = split
    self.actions = actions
    self.content = content
  }

  /// Whether both panes show: split, not compact, and wide enough for both.
  var showsBoth: Bool {
    split != nil && sizeClass != .compact && fitsBoth
  }

  /// The left pane's share, following the divider while it is dragged.
  private var fraction: Double {
    liveFraction ?? split?.fraction ?? 0.5
  }

  /// Where a tab goes: its pane while both show, else the whole content for the shown one.
  private func place(_ item: Item) -> KeptTabPlace {
    if let split, showsBoth {
      return paneOf(item).map { .pane($0, isFocused: $0 == split.focused) } ?? .hidden
    }
    return item.id == shownID ? .whole : .hidden
  }

  /// The view.
  public var body: some View {
    // The panes share the safe area; the outer panes' backgrounds and scroll views still
    // reach under a floating sidebar or inspector, as one pane's do.
    KeptAliveTabs(items, fraction: fraction, hinge: hinge, place: place, content: content)
      .environment(\.isActiveTabPane, true)
      .modifier(PaneFocusOnClick(isActive: showsBoth) { focusPane(at: $0) })
      // Markers beside the content, so the content keeps its own accessibility elements.
      .background { if let split, showsBoth { paneMarkers(split) } }
      .overlay { if showsBoth { dividerLayer } }
      .overlay { TabDropPreview(isSplit: showsBoth, fraction: split?.fraction ?? 0.5) }
      #if os(iOS)
        .dropDestination(for: String.self) { items, location in
          guard let showInPane = actions.showInPane,
            let id = items.lazy.compactMap(TabDropPayload.tabID(in:)).first
          else { return false }
          showInPane(id, location.x < measured.value / 2 ? .leading : .trailing)
          return true
        }
      #endif
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { width in
        LoopProbe.record("tab split width", "\(width)")
        measured.value = width
        let fits = TabSplitState.fits(width: width)
        if fitsBoth != fits { fitsBoth = fits }
      }
      .onGeometryChange(for: CGRect?.self) {
        TabSplitLayout.hinge(in: $0)
      } action: {
        hinge = $0
      }
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .global)
      } action: {
        tracker?.contentFrame = $0
      }
      .onChange(of: showsBoth, initial: true) { _, both in
        tracker?.isSplit = both
        if !both { tracker?.dividerX = nil }
      }
  }

  /// Focuses the pane a click or tap at `position` landed in, when the other has focus.
  private func focusPane(at position: CGFloat) {
    let frames = TabSplitLayout(width: measured.value, fraction: fraction, hinge: hinge)
    guard let pane = frames.pane(at: position), pane != split?.focused else { return }
    actions.focusPane?(pane)
  }

  private func paneMarkers(_ split: TabSplitState) -> some View {
    GeometryReader { proxy in
      let frames = TabSplitLayout(width: proxy.size.width, fraction: fraction, hinge: hinge)
      HStack(spacing: frames.gap) {
        ForEach(TabPane.allCases, id: \.self) { pane in
          let isFocused = split.focused == pane
          Color.clear
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isFocused ? "\(pane.label) pane, focused" : "\(pane.label) pane")
            .accessibilityIdentifier("tab-pane-\(pane.rawValue)")
            .frame(width: pane == .leading ? frames.leading : frames.trailing)
        }
      }
    }
  }

  /// The divider between the panes, over their content.
  private var dividerLayer: some View {
    GeometryReader { proxy in
      let inner = proxy.size.width
      let frames = TabSplitLayout(width: inner, fraction: fraction, hinge: hinge)
      divider(frames: frames, total: inner)
        .onGeometryChange(for: CGFloat.self) {
          $0.frame(in: .global).midX
        } action: {
          tracker?.dividerX = $0
        }
        .padding(.leading, frames.leading)
        .coordinateSpace(.named(TabSplitLayout.space))
    }
  }

  /// The divider: a hairline with a wider grip, fixed at the hinge on an unfolded Duo.
  private func divider(frames: TabSplitLayout, total: CGFloat) -> some View {
    let line = Rectangle().fill(ThemeColor.border).frame(width: TabSplitMetrics.divider)
    return
      line
      .frame(width: frames.gap)
      .frame(maxHeight: .infinity)
      .overlay {
        if !frames.isAtHinge {
          Color.clear
            .frame(width: TabSplitMetrics.handle)
            .contentShape(Rectangle())
            .gesture(resize(total: total))
            #if os(macOS)
              .pointerStyle(.columnResize)
            #endif
            .accessibilityElement()
            .accessibilityLabel("Split divider")
            .accessibilityValue("\(Int(fraction * 100)) percent")
            .accessibilityAdjustableAction { direction in
              actions.setSplitFraction?(
                TabSplitLayout.adjusted(split?.fraction ?? 0.5, direction: direction))
            }
            .accessibilityIdentifier("tab-split-divider")
        }
      }
  }

  private func resize(total: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(TabSplitLayout.space))
      .onChanged { value in
        liveFraction = TabSplitLayout.fraction(at: value.location.x, width: total)
      }
      .onEnded { value in
        let fraction = TabSplitLayout.fraction(at: value.location.x, width: total)
        liveFraction = nil
        actions.setSplitFraction?(fraction)
      }
  }

}

nonisolated extension TabPane: Identifiable {
  /// The pane itself: a split has one of each.
  public var id: Self { self }
}

/// Reports where the panes are clicked or tapped, without taking the click from their content,
/// so the pane under it can take focus. On the Mac it watches mouse-down events, so pages and
/// terminals (AppKit views) focus their pane too.
private struct PaneFocusOnClick: ViewModifier {
  let isActive: Bool
  /// Called with the click's horizontal position in the content.
  let focus: @MainActor (CGFloat) -> Void

  func body(content: Content) -> some View {
    #if os(macOS)
      content.background { PaneClickMonitor(isActive: isActive, onClick: focus) }
    #else
      content.simultaneousGesture(
        SpatialTapGesture().onEnded { if isActive { focus($0.location.x) } })
    #endif
  }
}

#if os(macOS)
  /// Calls `onClick` for a mouse-down inside its frame while `isActive`.
  private struct PaneClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onClick: @MainActor (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
      let view = MonitorView()
      view.onClick = onClick
      view.isActive = isActive
      return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
      view.onClick = onClick
      view.isActive = isActive
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
      view.stop()
    }

    final class MonitorView: NSView {
      var onClick: (@MainActor (CGFloat) -> Void)?
      var isActive = false
      private var monitor: Any?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard unsafe window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
          matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
          self?.handle(event)
          return event
        }
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      private func handle(_ event: NSEvent) {
        guard isActive, let window = unsafe window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?(point.x) }
      }
    }
  }
#endif

/// The highlight over the pane a dragged tab would land in.
private struct TabDropPreview: View {
  let isSplit: Bool
  let fraction: Double
  @Environment(TabDragTracker.self) private var tracker: TabDragTracker?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      if let target = tracker?.target {
        let share = isSplit ? (target == .leading ? fraction : 1 - fraction) : 0.5
        let width = proxy.size.width * share
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
          .fill(ThemeColor.focus.opacity(0.12))
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
              .strokeBorder(ThemeColor.focus.opacity(0.6), lineWidth: 2)
          }
          .overlay {
            Label("\(target.label) Pane", systemImage: "rectangle.split.2x1")
              .font(.callout.weight(.medium))
              .padding(.horizontal, Theme.Spacing.medium)
              .padding(.vertical, Theme.Spacing.small)
              .glassSurface(in: Capsule())
          }
          .padding(Theme.Spacing.small)
          .frame(width: width)
          .offset(x: target == .leading ? 0 : proxy.size.width - width)
          .transition(.opacity)
          .accessibilityIdentifier("tab-drop-\(target.rawValue)")
      }
    }
    .allowsHitTesting(false)
    .animation(reduceMotion ? nil : Theme.Motion.feedback, value: tracker?.target)
  }
}

/// The content's latest width, read only when a tab drops or a pane is clicked, so it never
/// re-renders the view.
@MainActor
private final class MeasuredWidth {
  var value = CGFloat.greatestFiniteMagnitude
}
