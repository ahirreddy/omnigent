#if os(macOS)
  import AppKit
  import SwiftUI

  /// While the sidebar is collapsed, shows it over the content when the pointer rests on the
  /// window's leading edge (``SidebarPeek``). The peek floats: the content keeps its width.
  struct SidebarPeekOverlay<Panel: View>: ViewModifier {
    let isCollapsed: Bool
    let panel: () -> Panel

    @State private var peek: SidebarPeek
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isCollapsed: Bool, startsShown: Bool = false, @ViewBuilder panel: @escaping () -> Panel) {
      self.isCollapsed = isCollapsed
      self.panel = panel
      _peek = State(initialValue: SidebarPeek(isShown: startsShown))
    }

    /// The panel's width, the sidebar column's ideal one.
    static var panelWidth: CGFloat { AppShellMetrics.sidebarIdealWidth }

    func body(content: Content) -> some View {
      content
        .overlay(alignment: .leading) {
          ZStack(alignment: .leading) {
            if isCollapsed, peek.isShown {
              panel()
                .environment(\.isSidebarPeek, true)
                .frame(width: Self.panelWidth)
                .frame(maxHeight: .infinity)
                .glassSurface(
                  in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                )
                .padding(Theme.Spacing.small)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .accessibilityIdentifier("sidebar-peek")
            }
          }
          // Only the panel animates; the content under it stays still.
          .animation(reduceMotion ? nil : Theme.Motion.disclosure, value: peek.isShown)
        }
        .overlay {
          if isCollapsed {
            LeadingEdgePointerTracker { offset, isBlocked in
              peek.pointerMoved(
                to: offset, panelWidth: Self.panelWidth + Theme.Spacing.small * 2,
                isBlocked: isBlocked)
            }
            .ignoresSafeArea()
          }
        }
        .task(id: peek.pendingTimer) {
          guard let timer = peek.pendingTimer else { return }
          do {
            try await Task.sleep(for: timer.delay)
          } catch {
            // Cancelled: the pointer moved again and superseded this delay.
            return
          }
          peek.timerFired(timer.token)
        }
        .onChange(of: isCollapsed) { peek.reset() }
    }
  }

  /// Reports the pointer's distance from the window's leading edge as it moves over the view,
  /// and `nil` when it leaves. It takes no clicks, and reports only in the key window, so a
  /// sheet over the window stops it.
  private struct LeadingEdgePointerTracker: NSViewRepresentable {
    let onMove: @MainActor (_ offset: CGFloat?, _ isBlocked: Bool) -> Void
    @Environment(\.layoutDirection) private var layoutDirection

    func makeNSView(context: Context) -> TrackingView {
      let view = TrackingView()
      updateNSView(view, context: context)
      return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
      view.onMove = onMove
      view.isRightToLeft = layoutDirection == .rightToLeft
    }

    final class TrackingView: NSView {
      var onMove: (@MainActor (CGFloat?, Bool) -> Void)?
      var isRightToLeft = false
      private var area: NSTrackingArea?

      override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(
          rect: .zero,
          options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
          owner: self)
        addTrackingArea(area)
        self.area = area
      }

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func mouseEntered(with event: NSEvent) { report(event) }
      override func mouseMoved(with event: NSEvent) { report(event) }
      override func mouseExited(with event: NSEvent) { onMove?(nil, isBlocked) }

      private func report(_ event: NSEvent) {
        let pointX = convert(event.locationInWindow, from: nil).x
        onMove?(isRightToLeft ? bounds.width - pointX : pointX, isBlocked)
      }

      /// A button is down (a tab, divider or selection drag) or a sheet or modal is up.
      private var isBlocked: Bool {
        // AppKit declares `window` unowned(unsafe); it is only read here, never retained.
        let hasSheet = unsafe window?.attachedSheet != nil
        return NSEvent.pressedMouseButtons != 0 || hasSheet || NSApp.modalWindow != nil
      }
    }
  }
#endif
