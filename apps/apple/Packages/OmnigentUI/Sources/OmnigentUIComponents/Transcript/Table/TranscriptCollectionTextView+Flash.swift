#if os(iOS)
  import SwiftUI
  import UIKit

  /// A text row's linked-message flash, as ``MessageFlash`` tints a SwiftUI row: a
  /// warning tint a little larger than the message that holds a moment and fades.
  extension TranscriptCollectionTextView {
    // MARK: Flash

    /// How long a linked message's tint holds before it fades, and how long it fades for.
    static let flashHold: Duration = .seconds(0.6)
    static let flashFade: TimeInterval = 0.9

    /// Tints the message while `flashedRowID` is the row shown, as ``MessageFlash`` does.
    func showFlash(_ flashedRowID: String?) {
      guard let id = shown?.id, flashedRowID == id else {
        endFlash()
        return
      }
      guard flashingRowID != id else { return }
      flashingRowID = id
      let view = flashView ?? makeFlashView()
      let isDark = style.environment.values?.colorScheme == .dark
      let warning = style.environment.values.map {
        UIColor(Color(ThemeColor.warning.resolve(in: $0).resolve(in: $0)))
      }
      view.backgroundColor = warning?.withAlphaComponent(isDark ? 0.24 : 0.16)
      view.frame = flashFrame
      view.alpha = 1
      view.isHidden = false
      flashFading?.cancel()
      flashFading = Task { [weak self] in
        do {
          try await Task.sleep(for: Theme.Timing.pause(Self.flashHold))
        } catch {
          return  // The flash ended, or another took over, with a fade of its own.
        }
        self?.fadeFlash()
      }
    }

    /// A little larger than the message, as ``MessageFlash`` pads it.
    var flashFrame: CGRect {
      (frames?.content ?? .zero).insetBy(dx: -Theme.Spacing.small, dy: -Theme.Spacing.small)
    }

    func endFlash() {
      flashFading?.cancel()
      flashFading = nil
      flashingRowID = nil
      flashView?.isHidden = true
    }

    func fadeFlash() {
      guard let view = flashView else { return }
      let reduceMotion = style.environment.values?.accessibilityReduceMotion ?? false
      guard Theme.Motion.isEnabled, !reduceMotion else {
        view.alpha = 0
        return
      }
      UIView.animate(withDuration: Self.flashFade, delay: 0, options: .curveEaseOut) {
        view.alpha = 0
      }
    }

    func makeFlashView() -> UIView {
      let view = UIView()
      view.isUserInteractionEnabled = false
      view.isAccessibilityElement = false
      view.layer.cornerRadius = Theme.Radius.medium
      view.layer.cornerCurve = .continuous
      insertSubview(view, at: 0)
      flashView = view
      return view
    }
  }
#endif
