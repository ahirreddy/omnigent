#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  /// A text cell's linked-message flash, as ``MessageFlash`` tints a SwiftUI row: a warning
  /// tint a little larger than the message, behind it, that holds for a moment and fades out.
  extension TranscriptTableTextCell {
    /// How long the tint holds before it fades, and how long it fades for.
    static let flashHold: Duration = .seconds(0.6)
    static let flashFade: TimeInterval = 0.9

    /// Tints the message while `flashedRowID` is the row shown, and stops otherwise.
    func showFlash(_ flashedRowID: String?) {
      guard let id = shown?.id, flashedRowID == id else {
        endFlash()
        return
      }
      guard flashingRowID != id else { return }
      flashingRowID = id
      let view = flashView ?? makeFlashView()
      view.layer?.backgroundColor = flashColor()
      view.frame = flashFrame
      view.alphaValue = 1
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

    /// Where the tint goes: a little larger than the message, as ``MessageFlash`` pads it.
    var flashFrame: CGRect {
      contentFrame.insetBy(dx: -Theme.Spacing.small, dy: -Theme.Spacing.small)
    }

    /// Takes the tint away at once: the flash ended, or the cell shows another row.
    func endFlash() {
      flashFading?.cancel()
      flashFading = nil
      flashingRowID = nil
      flashView?.isHidden = true
    }

    private func fadeFlash() {
      guard let view = flashView else { return }
      let reduceMotion = style.environment.values?.accessibilityReduceMotion ?? false
      guard Theme.Motion.isEnabled, !reduceMotion else {
        view.alphaValue = 0
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Self.flashFade
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.animator().alphaValue = 0
      }
    }

    /// The warning color at the flash's strength for the transcript's light or dark look.
    private func flashColor() -> CGColor? {
      guard let values = style.environment.values else { return nil }
      let warning = NSColor(Color(ThemeColor.warning.resolve(in: values).resolve(in: values)))
      return warning.withAlphaComponent(values.colorScheme == .dark ? 0.24 : 0.16).cgColor
    }

    private func makeFlashView() -> NSView {
      let view = TranscriptTableFlashView()
      view.wantsLayer = true
      view.layer?.cornerRadius = Theme.Radius.medium
      view.layer?.cornerCurve = .continuous
      addSubview(view, positioned: .below, relativeTo: nil)
      flashView = view
      return view
    }
  }

  /// The tint behind a flashed message: it takes no clicks and reads as nothing.
  final class TranscriptTableFlashView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
  }

  extension TranscriptTableController {
    /// Follows the window's linked-message flash: the text cell showing the flashed row tints,
    /// as a SwiftUI row reading the focus does.
    func watchFlash() {
      guard !awaitsFlash, let focus = environment.values?.transcriptFocus else { return }
      awaitsFlash = true
      let flashed = withObservationTracking {
        focus.flashedRowID
      } onChange: { [weak self] in
        MainRunLoop.perform {
          MainActor.assumeIsolated {
            self?.awaitsFlash = false
            self?.watchFlash()
          }
        }
      }
      tableView.enumerateAvailableRowViews { rowView, _ in
        guard rowView.numberOfColumns > 0 else { return }
        (rowView.view(atColumn: 0) as? TranscriptTableTextCell)?.showFlash(flashed)
      }
    }
  }
#endif
