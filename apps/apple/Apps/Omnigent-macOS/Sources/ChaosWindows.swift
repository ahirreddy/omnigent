#if DEBUG
  import AppKit
  import OmnigentUIComponents

  /// Window changes ``ChaosDriver`` makes: the system's window commands, sizes no person drags
  /// to, and a look change. Each says what it does through `log` before doing it.
  @MainActor
  enum ChaosWindows {
    /// The ways ``change(_:choice:look:log:)`` changes a window.
    static let changes = 7

    /// The visible windows' frames and their screens' visible frames, for a loop report.
    static func frames() -> String {
      NSApp.windows.filter(\.isVisible).map { window in
        let screen = window.screen.map { "\($0.visibleFrame)" } ?? "none"
        return "\(ChaosLog.describe(window)) \(window.frame) min \(window.minSize) on \(screen)"
      }.joined(separator: "; ")
    }

    /// Records each window's frame for ``LoopProbe``, so a loop report shows a window something
    /// outside the app keeps resizing.
    static func probeFrames() {
      _ = NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification, object: nil, queue: .main
      ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
          LoopProbe.record("window frame \(window.windowNumber)", "\(window.frame)")
          ChaosLog.recordIfOversized(window)
        }
      }
    }

    /// Minimizes and restores, zooms, enters or leaves full screen, shrinks the window to its
    /// minimum, switches the app between light, dark and the system's look, moves the window off
    /// every screen and back, or opens a new window, as `choice` says.
    static func change(_ window: NSWindow, choice: Int, look: Int, log: (String) -> Void) {
      switch choice {
      case 0:
        log("window minimize and restore")
        window.miniaturize(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { window.deminiaturize(nil) }
      case 1:
        log("window zoom")
        window.zoom(nil)
      case 2:
        log("window full screen")
        window.toggleFullScreen(nil)
      case 3:
        log("window smallest")
        window.setFrame(
          CGRect(origin: window.frame.origin, size: smallestSize(of: window)), display: true)
      case 4:
        let looks: [NSAppearance.Name?] = [nil, .aqua, .darkAqua]
        let name = looks[look % looks.count]
        log("appearance \(name?.rawValue ?? "system")")
        NSApp.appearance = name.flatMap(NSAppearance.init(named:))
      case 5:
        log("window off screen and back")
        let frame = window.frame
        window.setFrameOrigin(CGPoint(x: -40_000, y: -40_000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          window.setFrame(frame, display: true)
        }
      default:
        log("window new")
        ChaosInput.press(.shortcut("n"), [.command, .shift], in: window)
      }
    }

    /// The smallest frame a person could drag `window` to: its minimum size and the frame
    /// around its content's minimum, and never less than its title bar. `setFrame` honors
    /// neither, and a window with no height is on no screen.
    static func smallestSize(of window: NSWindow) -> CGSize {
      let content = window.frameRect(
        forContentRect: CGRect(origin: .zero, size: window.contentMinSize)
      ).size
      let titleBar = window.frame.height - window.contentLayoutRect.height
      return CGSize(
        width: max(window.minSize.width, content.width, 100),
        height: max(window.minSize.height, content.height, titleBar + 40))
    }

    /// The heights a sweep from `start` to `end` in `steps` steps sets, rounded to points.
    nonisolated static func sweepHeights(from start: CGFloat, to end: CGFloat, steps: Int)
      -> [CGFloat]
    {
      let count = max(1, steps)
      return (0...count).map { index in
        (start + (end - start) * CGFloat(index) / CGFloat(count)).rounded()
      }
    }

    /// Sets `window` to each height in turn, `pause` seconds apart, keeping its top edge and
    /// giving it `width`: a short window lays its dock and cards out differently at each height.
    static func sweep(_ window: NSWindow, width: CGFloat, heights: [CGFloat], pause: TimeInterval) {
      let top = window.frame.maxY
      for (index, height) in heights.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + pause * Double(index)) {
          let frame = CGRect(
            x: window.frame.minX, y: top - height, width: width, height: height)
          window.setFrame(frame, display: true)
        }
      }
    }
  }
#endif
