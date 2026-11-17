#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers

  /// A borderless button with ``View/hoverHighlight(cornerRadius:)``'s fill under the pointer.
  final class MessageHoverButton: NSButton {
    private let highlight: NSColor
    private var hoverArea: NSTrackingArea?
    /// Whether the pointer is over it, for tests.
    private(set) var isHovered = false {
      didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    init(highlight: NSColor) {
      self.highlight = highlight
      super.init(frame: .zero)
      title = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      guard hoverArea == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      isHovered = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow == nil { isHovered = false }
    }

    override func draw(_ dirtyRect: NSRect) {
      if isHovered, isEnabled {
        highlight.setFill()
        NSBezierPath(
          roundedRect: bounds, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small
        ).fill()
      }
      super.draw(dirtyRect)
    }
  }

  /// Saves text where the person picks in the save panel, as ``TextExporter`` does for SwiftUI;
  /// a failure shows in an alert.
  @MainActor
  enum MessageTextExport {
    static func save(_ text: String, name: String, type: UTType? = nil, from view: NSView) {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = name
      let named = UTType(filenameExtension: URL(filePath: name).pathExtension)
      if let kind = type ?? named { panel.allowedContentTypes = [kind] }
      panel.allowsOtherFileTypes = true
      // AppKit declares `window` unowned(unsafe); it is only used to present the panel.
      let window = unsafe view.window
      let finish: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return }
        do {
          try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
          showFailure(error, in: window)
        }
      }
      if let window {
        panel.beginSheetModal(for: window, completionHandler: finish)
      } else {
        panel.begin(completionHandler: finish)
      }
    }

    private static func showFailure(_ error: any Error, in window: NSWindow?) {
      let alert = NSAlert()
      alert.messageText = "Could Not Save"
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: "OK")
      if let window {
        alert.beginSheetModal(for: window)
      } else {
        alert.runModal()
      }
    }
  }
#endif
