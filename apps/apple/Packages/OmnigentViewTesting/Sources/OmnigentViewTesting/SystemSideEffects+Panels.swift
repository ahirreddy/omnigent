// These replace Objective-C methods, so their signatures use its reference types.
// swiftlint:disable legacy_objc_type

#if os(macOS)
  import AppKit
  import ObjectiveC
  import os

  extension SystemSideEffects {
    private typealias PanelSheet =
      @convention(c) (NSSavePanel, Selector, NSWindow?, ResponseHandler?) -> Void
    private typealias PanelURL = @convention(c) (NSSavePanel, Selector) -> NSURL?

    static func installPanels() {
      let run: @convention(c) (NSSavePanel, Selector) -> Int = { _, _ in
        Self.note { $0.panelCount += 1 }
        return Self.state.withLock { $0.panelResponse.rawValue }
      }
      replace(NSSavePanel.self, "runModal", with: run)
      replace(NSOpenPanel.self, "runModal", with: run)
      let sheet: PanelSheet = { _, _, _, done in
        Self.note { $0.panelCount += 1 }
        done?(Self.state.withLock { $0.panelResponse.rawValue })
      }
      replace(NSSavePanel.self, "beginSheetModalForWindow:completionHandler:", with: sheet)
      let begin: @convention(c) (NSSavePanel, Selector, ResponseHandler?) -> Void = { _, _, done in
        Self.note { $0.panelCount += 1 }
        done?(Self.state.withLock { $0.panelResponse.rawValue })
      }
      replace(NSSavePanel.self, "beginWithCompletionHandler:", with: begin)
      installPanelChoice()
      let chosenURLs: @convention(c) (NSOpenPanel, Selector) -> NSArray = { _, _ in
        let urls = Self.state.withLock { $0.panelURL }.map { [$0 as NSURL] } ?? []
        return urls as NSArray
      }
      replace(NSOpenPanel.self, "URLs", with: chosenURLs)
    }

    /// A panel holds the file a test chose. With none, a save panel still names its own folder and
    /// file, and an open panel holds nothing, as they do unshown.
    private static func installPanelChoice() {
      let selector = NSSelectorFromString("URL")
      guard let saveMethod = unsafe class_getInstanceMethod(NSSavePanel.self, selector),
        let openMethod = unsafe class_getInstanceMethod(NSOpenPanel.self, selector)
      else {
        preconditionFailure("SystemSideEffects: panels have no URL")
      }
      let chosen: PanelURL = { panel, selector in
        if let url = Self.state.withLock({ $0.panelURL }) { return url as NSURL }
        guard let original = unsafe Self.originalPanelURL else { return nil }
        return unsafe unsafeBitCast(original, to: PanelURL.self)(panel, selector)
      }
      unsafe originalPanelURL = method_setImplementation(
        saveMethod, unsafeBitCast(chosen, to: IMP.self))
      if unsafe openMethod != saveMethod {
        let chosenToOpen: PanelURL = { _, _ in
          Self.state.withLock { $0.panelURL }.map { $0 as NSURL }
        }
        unsafe method_setImplementation(openMethod, unsafeBitCast(chosenToOpen, to: IMP.self))
      }
    }
  }
#endif

// swiftlint:enable legacy_objc_type
