import Foundation
import SwiftUI

#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers

  /// Images on a Mac pasteboard, for ⌘V in the composer: its editor is plain text and cannot
  /// paste an image, so the composer attaches one instead.
  enum PasteboardImages {
    /// Whether ⌘V should attach rather than paste text: some item holds an image, and any text
    /// is no more than a link (Safari copies an image with its address).
    static func shouldAttach(_ pasteboard: NSPasteboard) -> Bool {
      let items = pasteboard.pasteboardItems ?? []
      guard items.contains(where: { !imageTypes($0).isEmpty }) else { return false }
      let text = pasteboard.string(forType: .string)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard let text, !text.isEmpty else { return true }
      return URL(string: text)?.scheme != nil && !text.contains(where: \.isWhitespace)
    }

    /// One provider per item holding an image, offering its image representations as read now.
    /// One another app promised but did not give fails to load, naming its format.
    static func providers(_ pasteboard: NSPasteboard) -> [NSItemProvider] {
      (pasteboard.pasteboardItems ?? []).compactMap { item in
        let types = imageTypes(item)
        guard !types.isEmpty else { return nil }
        let provider = NSItemProvider()
        for (pasteboardType, type) in types {
          let data = item.data(forType: pasteboardType)
          provider.registerDataRepresentation(for: type, visibility: .all) { completion in
            if let data {
              completion(data, nil)
            } else {
              completion(nil, MissingRepresentation(format: type.identifier))
            }
            return nil
          }
        }
        return provider
      }
    }

    struct MissingRepresentation: LocalizedError {
      let format: String
      var errorDescription: String? { "the pasteboard did not give its \(format) data" }
    }

    private static func imageTypes(
      _ item: NSPasteboardItem
    ) -> [(NSPasteboard.PasteboardType, UTType)] {
      item.types.compactMap { pasteboardType in
        guard let type = UTType(pasteboardType.rawValue), type.conforms(to: .image) else {
          return nil
        }
        return (pasteboardType, type)
      }
    }
  }

  /// Turns ⌘V into `paste` while `isActive` (the composer's editor has focus in this window) and
  /// the pasteboard holds an image (``PasteboardImages/shouldAttach(_:)``).
  struct ImagePasteWatcher: NSViewRepresentable {
    let isActive: Bool
    let paste: @MainActor ([NSItemProvider]) -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
      view.isActive = isActive
      view.paste = paste
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
      view.stop()
    }

    final class WatcherView: NSView {
      var isActive = false
      var paste: (@MainActor ([NSItemProvider]) -> Void)?
      private var monitor: Any?

      override func hitTest(_ point: NSPoint) -> NSView? { nil }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        // AppKit declares `window` unowned(unsafe); it is only compared here, never retained.
        guard unsafe window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
          guard let self, unsafe event.window === self.window, self.handle(event) else {
            return event
          }
          return nil
        }
      }

      func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard isActive, let paste, modifiers == .command,
          event.charactersIgnoringModifiers?.lowercased() == "v",
          PasteboardImages.shouldAttach(.general)
        else { return false }
        paste(PasteboardImages.providers(.general))
        return true
      }
    }
  }
#endif

extension View {
  /// On the Mac, ⌘V with an image on the pasteboard attaches it while `isActive` (the plain-text
  /// editor cannot paste images); elsewhere the Add menu's Paste does.
  func imagePaste(
    isActive: Bool, paste: @escaping @MainActor ([NSItemProvider]) -> Void
  ) -> some View {
    #if os(macOS)
      background { ImagePasteWatcher(isActive: isActive, paste: paste) }
    #else
      self
    #endif
  }
}
