#if DEBUG
  import OSLog
  import OmnigentPlatform
  import UIKit

  /// Debug builds launched with `-OmnigentPerfDriver YES` act on Darwin notifications that a
  /// measuring script posts (`xcrun simctl spawn <udid> notifyutil -p <name>`), for motion that
  /// the simulator cannot otherwise drive without UI tests (see docs/performance.md):
  ///
  /// - `ai.omnigent.perf.scroll` / `.scroll.leading`: scrolls the view under the window's center
  ///   (or its leading sixth, iPad's sidebar) toward the top for 3 s, then back for 3 s.
  /// - `ai.omnigent.perf.type` / `.type.top`: types 20 characters into the lowest text input
  ///   (the composer) or the highest (search), one every 80 ms, then deletes them.
  /// - `ai.omnigent.perf.keyboard`: focuses the composer, or ends editing when something is.
  /// - `ai.omnigent.perf.rotate`: turns the window between portrait and landscape.
  /// - `ai.omnigent.perf.sidebar`: shows or hides the split view's sidebar, resizing the detail.
  @MainActor
  final class PerfDriver: NSObject {
    static let launchArgument = "OmnigentPerfDriver"
    private static var shared: PerfDriver?
    private static let logger = Logger(subsystem: FrameMonitor.subsystem, category: "driver")

    private struct Scroll {
      let view: UIScrollView
      /// Points per second.
      let speed: CGFloat
      var phaseEnd: CFTimeInterval
      var isUp = true
    }

    private var scroll: Scroll?
    private var link: CADisplayLink?

    static func startIfRequested() {
      guard shared == nil, UserDefaults.standard.bool(forKey: launchArgument) else { return }
      let driver = PerfDriver()
      shared = driver
      let actions: [(String, @MainActor () -> Void)] = [
        ("scroll", { driver.startScroll(atX: 0.5) }),
        ("scroll.leading", { driver.startScroll(atX: 1.0 / 6) }),
        ("type", { driver.type(intoLowest: true) }),
        ("type.top", { driver.type(intoLowest: false) }),
        ("keyboard", { driver.toggleKeyboard() }),
        ("rotate", { driver.rotate() }),
        ("sidebar", { driver.toggleSidebar() }),
      ]
      for (name, action) in actions {
        DarwinNotifications.observe("ai.omnigent.perf.\(name)") {
          logger.notice("action \(name, privacy: .public)")
          action()
        }
      }
    }

    private var keyWindow: UIWindow? {
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow)
    }

    // MARK: Scrolling

    private func startScroll(atX fraction: CGFloat) {
      guard let window = keyWindow else { return }
      let point = CGPoint(x: window.bounds.width * fraction, y: window.bounds.midY)
      var view = window.hitTest(point, with: nil)
      while let current = view, !Self.scrollsVertically(current) { view = current.superview }
      guard let scrollView = view as? UIScrollView else {
        Self.logger.error("No scroll view at \(point.debugDescription, privacy: .public)")
        return
      }
      // About a quick flick's speed, a few screens a second.
      scroll = Scroll(view: scrollView, speed: 2400, phaseEnd: CACurrentMediaTime() + 3)
      if link == nil {
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
      }
    }

    private static func scrollsVertically(_ view: UIView) -> Bool {
      guard let scrollView = view as? UIScrollView else { return false }
      return scrollView.contentSize.height > scrollView.bounds.height + 1
    }

    @objc private func step(_ link: CADisplayLink) {
      guard var scroll else {
        link.invalidate()
        self.link = nil
        return
      }
      let view = scroll.view
      let elapsed = link.targetTimestamp - link.timestamp
      let top = -view.adjustedContentInset.top
      let bottom = max(
        top, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
      let delta = scroll.speed * elapsed * (scroll.isUp ? -1 : 1)
      view.contentOffset.y = min(max(view.contentOffset.y + delta, top), bottom)
      if CACurrentMediaTime() >= scroll.phaseEnd {
        if scroll.isUp {
          scroll.isUp = false
          scroll.phaseEnd = CACurrentMediaTime() + 3
        } else {
          self.scroll = nil
          return
        }
      }
      self.scroll = scroll
    }

    // MARK: Text

    /// Visible, hit-testable text inputs, top to bottom.
    private func textInputs() -> [UIView] {
      guard let window = keyWindow else { return [] }
      var found: [UIView] = []
      var stack: [UIView] = [window]
      while let view = stack.popLast() {
        if view.isHidden || view.alpha < 0.01 { continue }
        if (view as? UITextView)?.isEditable == true || view is UITextField {
          let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
          if let hit = window.hitTest(center, with: nil), hit.isDescendant(of: view) {
            found.append(view)
          }
          continue
        }
        stack.append(contentsOf: view.subviews)
      }
      return found.sorted {
        $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY
      }
    }

    private func type(intoLowest: Bool) {
      let inputs = textInputs()
      let found = intoLowest ? inputs.last : inputs.first ?? searchField()
      guard let input = found as? (any UIView & UIKeyInput) else {
        Self.logger.error("No text input to type into")
        return
      }
      input.becomeFirstResponder()
      Task { @MainActor in
        do {
          for character in "measure the composer" {
            try await Task.sleep(for: .milliseconds(80))
            input.insertText(String(character))
          }
          for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(80))
            input.deleteBackward()
          }
        } catch {
          Self.logger.error("Typing stopped: \(error.localizedDescription, privacy: .public)")
        }
      }
    }

    /// A collapsed `.searchable` field: its search controller, activated.
    private func searchField() -> UIView? {
      var queue = keyWindow?.rootViewController.map { [$0] } ?? []
      while !queue.isEmpty {
        let next = queue.removeFirst()
        if let search = next.navigationItem.searchController {
          search.isActive = true
          return search.searchBar.searchTextField
        }
        queue.append(contentsOf: next.children)
        if let presented = next.presentedViewController { queue.append(presented) }
      }
      return nil
    }

    private func toggleKeyboard() {
      let inputs = textInputs()
      if let focused = inputs.first(where: \.isFirstResponder) {
        focused.resignFirstResponder()
      } else if let composer = inputs.last {
        composer.becomeFirstResponder()
      } else {
        Self.logger.error("No text input to focus")
      }
    }

    // MARK: Window

    /// The session id in `tmp/perf-link.txt` in the app's container, which the measuring script
    /// writes before posting `ai.omnigent.perf.open` (handled by the root view).
    static func requestedSession() -> String? {
      let file = FileManager.default.temporaryDirectory.appending(path: "perf-link.txt")
      do {
        return try String(contentsOf: file, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      } catch {
        logger.error("No session to open: \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }

    private func rotate() {
      guard let scene = keyWindow?.windowScene else { return }
      let isLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
      let target: UIInterfaceOrientationMask = isLandscape ? .portrait : .landscapeRight
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
        Self.logger.error("Rotation refused: \(error.localizedDescription, privacy: .public)")
      }
    }

    private func toggleSidebar() {
      var controller = keyWindow?.rootViewController
      var queue = controller.map { [$0] } ?? []
      controller = nil
      while !queue.isEmpty {
        let next = queue.removeFirst()
        if next is UISplitViewController {
          controller = next
          break
        }
        queue.append(contentsOf: next.children)
      }
      guard let split = controller as? UISplitViewController else {
        Self.logger.error("No split view to resize")
        return
      }
      if split.isCollapsed { return }
      let shown = split.displayMode != .secondaryOnly
      UIView.animate(withDuration: 0.35) {
        if shown { split.hide(.primary) } else { split.show(.primary) }
      }
    }
  }
#endif
