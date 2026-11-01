internal import AppKit
internal import os

/// Drag and drop in both directions (protocol 1.1). Drops into the page become Chromium drag
/// target events; a drag the page starts becomes a native `NSDraggingSession`, so content can
/// leave for Finder and other apps. See DESIGN.md, "Input".
extension WebSurfaceView: NSDraggingSource {
  static let acceptedDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .html]

  /// What the pasteboard of an incoming drag carries.
  static func dragData(from pasteboard: NSPasteboard) -> WebDragData {
    // AppKit's reader resolves Finder's file-reference URLs; it takes the class object.
    // swiftlint:disable:next legacy_objc_type
    let classes: [AnyClass] = [NSURL.self]
    let files =
      pasteboard.readObjects(forClasses: classes, options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    return WebDragData(
      text: pasteboard.string(forType: .string), html: pasteboard.string(forType: .html),
      url: pasteboard.string(forType: .URL), paths: files.map(\.path))
  }

  private func viewPoint(_ sender: any NSDraggingInfo) -> CGPoint {
    convert(sender.draggingLocation, from: nil)
  }

  /// The operation to report to AppKit: the page's last answer, or copy until it answers.
  private func acceptedOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let offered = sender.draggingSourceOperationMask
    let page = webView.dragOperation.dragOperation
    if !page.isEmpty { return page.intersection(offered) }
    return offered.contains(.copy) ? .copy : offered
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard webView.session.supportsBrowserUI else { return [] }
    webView.renderer.dragEntered(
      Self.dragData(from: sender.draggingPasteboard), at: viewPoint(sender),
      operations: WebDragOperations(sender.draggingSourceOperationMask),
      modifiers: NSEvent.modifierFlags)
    return acceptedOperation(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard webView.session.supportsBrowserUI else { return [] }
    webView.renderer.dragUpdated(
      at: viewPoint(sender), operations: WebDragOperations(sender.draggingSourceOperationMask),
      modifiers: NSEvent.modifierFlags)
    return acceptedOperation(sender)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    webView.renderer.dragExited()
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    webView.session.supportsBrowserUI
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    webView.renderer.performDrop(at: viewPoint(sender), modifiers: NSEvent.modifierFlags)
    return true
  }

  // MARK: Page-started drags

  func beginPageDrag(_ start: WebDragStart) {
    guard let event = lastMouseDown, pageDrag == nil else {
      Logger.view.error("The page started a drag without a mouse-down to begin it from.")
      webView.renderer.dragSourceEnded(at: start.location, operation: [])
      return
    }
    pageDrag = start
    let item = NSDraggingItem(pasteboardWriter: Self.pasteboardWriter(for: start.data))
    let image = start.image.flatMap(NSImage.init(data:)) ?? Self.placeholderImage
    item.setDraggingFrame(CGRect(origin: start.location, size: image.size), contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  /// A file wins over text, so Finder receives the file; otherwise text, HTML and the link.
  static func pasteboardWriter(for data: WebDragData) -> any NSPasteboardWriting {
    let item = NSPasteboardItem()
    if let path = data.paths.first {
      item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
      return item
    }
    if let text = data.text { item.setString(text, forType: .string) }
    if let html = data.html { item.setString(html, forType: .html) }
    if let url = data.url {
      item.setString(url, forType: .URL)
      if data.text == nil { item.setString(url, forType: .string) }
    }
    return item
  }

  private static var placeholderImage: NSImage {
    NSImage(systemSymbolName: "doc", accessibilityDescription: "Dragged content")
      ?? NSImage(size: NSSize(width: 32, height: 32))
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    pageDrag?.operations.dragOperation ?? []
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    pageDrag = nil
    var point = CGPoint.zero
    if let window = hostWindow {
      point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
    }
    webView.renderer.dragSourceEnded(at: point, operation: WebDragOperations(operation))
  }
}
