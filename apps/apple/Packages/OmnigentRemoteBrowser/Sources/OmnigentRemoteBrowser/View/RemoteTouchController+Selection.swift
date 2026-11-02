#if os(iOS)
  import OmnigentCoreFFI
  import UIKit

  /// Long press to select, the edit menu at the selection, pointer hover, and which gestures
  /// run together (design doc section 16.5).
  extension RemoteTouchController: UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    // MARK: Long press: select, then the edit menu

    @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
      guard let view, let store, store.canSendInput else { return }
      let location = recognizer.location(in: view)
      guard let point = css(location, clamped: true) else { return }
      switch recognizer.state {
      case .began:
        stopMomentum()
        editMenu?.dismissMenu()
        // The keyboard stays up while editing a field, as in Safari.
        if !view.keyboardProxy.isFirstResponder { view.becomeFirstResponder() }
        // A double click selects the word; holding the second click and moving extends the
        // selection by word, as Chromium does for a double-click drag.
        mouse(.move, point)
        mouse(.down, point, button: .left, clicks: 1, held: .leftButton)
        mouse(.up, point, button: .left, clicks: 1)
        mouse(.down, point, button: .left, clicks: 2, held: .leftButton)
      case .changed:
        mouse(.move, point, held: .leftButton)
      case .ended, .cancelled, .failed:
        mouse(.up, point, button: .left, clicks: 2)
        menuAnchor = location
        // The host's selection report follows within about 100 ms.
        Task { [weak self] in
          do {
            try await Task.sleep(for: .milliseconds(250))
          } catch {
            return
          }
          self?.presentEditMenu()
        }
      default:
        break
      }
    }

    /// Shows the edit menu at the page's selection (or where the finger lifted).
    func presentEditMenu() {
      guard let view, let editMenu else { return }
      let anchor = selectionRect().map { CGPoint(x: $0.midX, y: $0.minY) } ?? menuAnchor
      guard let anchor else { return }
      if !view.isFirstResponder, !view.keyboardProxy.isFirstResponder {
        view.becomeFirstResponder()
      }
      editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor))
    }

    /// The host's selection rectangle in view points.
    private func selectionRect() -> CGRect? {
      guard let rect = store?.snapshot.selection?.rect, let geometry = view?.displayGeometry
      else { return nil }
      let origin = geometry.viewPoint(for: CGPoint(x: rect.x, y: rect.y))
      return CGRect(
        x: origin.x, y: origin.y, width: rect.width * geometry.scale,
        height: rect.height * geometry.scale)
    }

    func editMenuInteraction(
      _ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
      selectionRect()
        ?? CGRect(origin: configuration.sourcePoint, size: .zero).insetBy(dx: -1, dy: -1)
    }

    // MARK: Hover

    @objc func handleHover(_ recognizer: UIHoverGestureRecognizer) {
      // A pointer move in the middle of a touch gesture (a long press's double click, a drag)
      // would move the page's mouse away from the finger.
      let touching = [longPress, pan, pinch].contains {
        $0.state == .began || $0.state == .changed
      }
      guard !touching, let view, let point = css(recognizer.location(in: view), clamped: true)
      else { return }
      mouse(recognizer.state == .ended ? .leave : .move, point)
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      let pair = Set([ObjectIdentifier(gestureRecognizer), ObjectIdentifier(other)])
      return pair == Set([ObjectIdentifier(pinch), ObjectIdentifier(pan)])
        || gestureRecognizer === hover || other === hover
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
      // Taps wait for a double tap only where double tap zooms (not in Mobile Size).
      if gestureRecognizer === tap, other === doubleTap {
        return store?.viewportMode.allowsDoubleTapZoom ?? true
      }
      // Panning waits until a long press is ruled out (the finger moved first).
      return gestureRecognizer === pan && other === longPress
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === doubleTap {
        return store?.viewportMode.allowsDoubleTapZoom ?? true
      }
      return true
    }
  }
#endif
