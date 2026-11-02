public import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// A window's tab content in one pane or two side by side, each showing its own tab, with a
/// draggable divider. The other pane is dimmed a little, as Claude Code does, and the focused one
/// publishes its menu commands (``EnvironmentValues/isActiveTabPane``); a click or tap in the
/// other pane focuses it.
///
/// At compact widths, and where both panes would be narrower than
/// ``TabSplitState/minimumPaneWidth``, only the focused pane shows; the split comes back when
/// the window widens. On an unfolded iPhone Duo the panes sit either side of the hinge.
///
/// While a tab is dragged out of the strip (``TabDragTracker``), the content previews where it
/// would land: either edge shows it in that pane.
public struct TabSplitView<Content: View>: View {
  private let split: TabSplitState?
  private let actions: TabActions
  private let content: (TabPane) -> Content

  /// The content's width; assumed wide enough until measured, so a split never starts single.
  @State private var width = CGFloat.greatestFiniteMagnitude
  @State private var liveFraction: Double?
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(TabDragTracker.self) private var tracker: TabDragTracker?

  /// Creates the view.
  /// - Parameters:
  ///   - split: The panes; `nil` shows one pane.
  ///   - actions: Focus, divider and drop actions.
  ///   - content: A pane's content: its tab.
  public init(
    split: TabSplitState?, actions: TabActions,
    @ViewBuilder content: @escaping (TabPane) -> Content
  ) {
    self.split = split
    self.actions = actions
    self.content = content
  }

  /// Whether both panes show: split, not compact, and wide enough for both.
  var showsBoth: Bool {
    split != nil && sizeClass != .compact && TabSplitState.fits(width: width)
  }

  /// The view.
  public var body: some View {
    Group {
      if let split, showsBoth {
        // The panes share the safe area; the outer panes' backgrounds and scroll views still
        // reach under a floating sidebar or inspector, as one pane's do. An unfolded Duo's
        // hinge is read here, in the panes' coordinates.
        GeometryReader { proxy in
          let inner = proxy.size.width
          let hinge = TabSplitLayout.hinge(in: proxy)
          let frames = TabSplitLayout(
            width: inner, fraction: liveFraction ?? split.fraction, hinge: hinge)
          HStack(spacing: 0) {
            pane(.leading, split: split).frame(width: frames.leading)
            divider(frames: frames, total: inner).zIndex(1)
              .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .global).midX
              } action: {
                tracker?.dividerX = $0
              }
            pane(.trailing, split: split).frame(width: frames.trailing)
          }
          .coordinateSpace(.named(TabSplitLayout.space))
        }
      } else {
        content(split?.focused ?? .leading)
          .environment(\.isActiveTabPane, true)
      }
    }
    .overlay { TabDropPreview(isSplit: showsBoth, fraction: split?.fraction ?? 0.5) }
    #if os(iOS)
      .dropDestination(for: String.self) { items, location in
        guard let showInPane = actions.showInPane,
          let id = items.lazy.compactMap(TabDropPayload.tabID(in:)).first
        else { return false }
        showInPane(id, location.x < width / 2 ? .leading : .trailing)
        return true
      }
    #endif
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
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

  private func pane(_ pane: TabPane, split: TabSplitState) -> some View {
    let isFocused = split.focused == pane
    return content(pane)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
      .environment(\.isActiveTabPane, isFocused)
      .overlay { PaneDim(isDimmed: !isFocused) }
      .modifier(PaneFocusOnClick(isFocused: isFocused) { actions.focusPane?(pane) })
      // A marker beside the content, so the content keeps its own accessibility elements.
      .background {
        Color.clear
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(isFocused ? "\(pane.label) pane, focused" : "\(pane.label) pane")
          .accessibilityIdentifier("tab-pane-\(pane.rawValue)")
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
            .accessibilityValue("\(Int((liveFraction ?? split?.fraction ?? 0.5) * 100)) percent")
            .accessibilityAdjustableAction { direction in
              let step = direction == .increment ? 0.05 : -0.05
              actions.setSplitFraction?((split?.fraction ?? 0.5) + step)
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

/// Where the panes and the divider go for a width: the share, kept so both panes stay at least
/// ``TabSplitState/minimumPaneWidth``, or either side of a hinge that leaves both that wide.
struct TabSplitLayout: Equatable {
  /// The coordinate space the divider is dragged in.
  static let space = "tab-split"

  var leading: CGFloat
  var gap: CGFloat
  var trailing: CGFloat
  var isAtHinge = false

  init(width: CGFloat, fraction: Double, hinge: CGRect? = nil) {
    let minimum = TabSplitState.minimumPaneWidth
    if let hinge, hinge.minX >= minimum, width - hinge.maxX >= minimum {
      leading = hinge.minX
      gap = hinge.width
      trailing = width - hinge.maxX
      isAtHinge = true
      return
    }
    gap = TabSplitMetrics.divider
    let room = max(0, width - gap)
    let wanted = (room * TabSplitState.clamp(fraction)).rounded()
    leading = min(max(wanted, minimum), max(minimum, room - minimum))
    trailing = max(0, room - leading)
  }

  /// The hinge's frame when it splits the content side by side.
  nonisolated static func hinge(in proxy: GeometryProxy) -> CGRect? {
    #if os(iOS)
      if #available(iOS 27.1, *) { return proxy.sideBySideHinge() }
    #endif
    return nil
  }

  /// The left pane's share for a divider dragged to `position`.
  static func fraction(at position: CGFloat, width: CGFloat) -> Double {
    guard width > 0 else { return 0.5 }
    let minimum = TabSplitState.minimumPaneWidth
    let clamped = min(max(position, minimum), max(minimum, width - minimum))
    return TabSplitState.clamp(Double(clamped / width))
  }
}

/// A wash of the theme's canvas over the pane without focus, so the focused one reads first. It
/// takes no clicks and is lighter with Increase Contrast, which needs the text legible.
private struct PaneDim: View {
  let isDimmed: Bool
  @Environment(\.omnigentTheme) private var theme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How much of the canvas covers the other pane.
  static let strength = 0.3

  var body: some View {
    let canvas =
      theme.palette(for: colorScheme).canvas ?? Color(white: colorScheme == .dark ? 0.08 : 1)
    let strength = contrast == .increased ? Self.strength / 2 : Self.strength
    Rectangle()
      .fill(canvas.opacity(isDimmed ? strength : 0))
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isDimmed)
  }
}

/// Focuses a pane when it is clicked or tapped, without taking the click from its content. On
/// the Mac it watches mouse-down events, so pages and terminals (AppKit views) focus it too.
private struct PaneFocusOnClick: ViewModifier {
  let isFocused: Bool
  let focus: @MainActor () -> Void

  func body(content: Content) -> some View {
    #if os(macOS)
      content.background { PaneClickMonitor(isActive: !isFocused, onClick: focus) }
    #else
      content.simultaneousGesture(TapGesture().onEnded { if !isFocused { focus() } })
    #endif
  }
}

#if os(macOS)
  /// Calls `onClick` for a mouse-down inside its frame while `isActive`.
  private struct PaneClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let onClick: @MainActor () -> Void

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
      var onClick: (@MainActor () -> Void)?
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
        if bounds.contains(point) { onClick?() }
      }
    }
  }
#endif

/// The highlight over the half a dragged tab would land in.
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
