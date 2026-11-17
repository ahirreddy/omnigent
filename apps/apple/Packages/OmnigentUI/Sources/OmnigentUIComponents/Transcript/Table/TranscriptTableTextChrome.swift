#if os(macOS)
  import AppKit
  import OmnigentPlatform
  import SwiftUI

  /// A text cell's chrome: the actions hover reveals, and the message's context menu.
  extension TranscriptTableTextCell {
    // MARK: Actions

    /// Whether the actions show: on hover, or always on the last settled answer.
    private var revealsActions: Bool {
      isHovered || message?.decoration.showsActions == true
    }

    /// Builds the actions' row once it first shows, and places or hides it.
    func refreshActions() {
      guard let message, revealsActions, let values = style.environment.values else {
        actionsView?.isHidden = true
        return
      }
      let view = actionsView ?? makeActionsView()
      let items = MessageActionItem.items(
        for: message.row, actions: values.conversationActions,
        copy: values.copyWithConfirmation)
      view.show(items, timestamp: message.decoration.timestamp)
      let size = view.frame.size
      let top =
        actionsLineHeight > 0
        ? actionsTop + ((actionsLineHeight - size.height) / 2).rounded() : actionsTop
      view.frame = CGRect(
        x: actionsTrailing - size.width, y: top, width: size.width, height: size.height)
      view.isHidden = false
    }

    private func makeActionsView() -> TranscriptMessageActionsView {
      let view = TranscriptMessageActionsView()
      addSubview(view)
      actionsView = view
      return view
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // One area that follows the visible rect, so scrolling rebuilds nothing.
      guard hoverArea == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
      isHovered = true
      refreshActions()
    }

    override func mouseExited(with event: NSEvent) {
      isHovered = false
      refreshActions()
    }

    /// The message's actions, then Copy Message ID.
    override func menu(for event: NSEvent) -> NSMenu? {
      guard let message, let values = style.environment.values else { return nil }
      let menu = NSMenu()
      menu.autoenablesItems = false
      let items = MessageActionItem.items(
        for: message.row, actions: values.conversationActions,
        copy: values.copyWithConfirmation)
      for item in items {
        menu.addItem(
          menuItem(item.menuTitle, enabled: item.unavailableReason == nil, perform: item.perform))
      }
      menu.addItem(.separator())
      let id = message.row.id
      let copy = values.copyWithConfirmation
      menu.addItem(
        menuItem("Copy Message ID", enabled: true) { copy(id, confirmation: "Message ID copied") })
      return menu
    }

    private func menuItem(
      _ title: String, enabled: Bool, perform: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
      item.target = self
      item.isEnabled = enabled
      item.representedObject = TranscriptMenuAction(perform)
      return item
    }

    @objc private func runMenuItem(_ item: NSMenuItem) {
      (item.representedObject as? TranscriptMenuAction)?.perform()
    }
  }

  /// A user message's bubble: a rounded fill behind the text.
  final class TranscriptTableBubbleView: NSView {
    var color = NSColor.clear {
      didSet { if color != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
      color.setFill()
      NSBezierPath(
        roundedRect: bounds, xRadius: Theme.Radius.bubble, yRadius: Theme.Radius.bubble
      ).fill()
    }
  }

  /// What a context-menu item runs, held by the item.
  final class TranscriptMenuAction: NSObject {
    let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
      self.perform = perform
    }
  }

  /// A message's action buttons (Copy, Fork from here, Copy link) and its timestamp, in AppKit,
  /// as ``MessageActionRow`` draws them.
  final class TranscriptMessageActionsView: NSView {
    private var buttons: [NSButton] = []
    private var performs: [@MainActor () -> Void] = []
    private let timestamp = NSTextField(labelWithString: "")
    private var copyReset: Task<Void, Never>?
    private var copyIndex: Int?

    override var isFlipped: Bool { true }

    init() {
      super.init(frame: .zero)
      timestamp.font = .preferredFont(forTextStyle: .caption1)
      timestamp.textColor = .secondaryLabelColor
      addSubview(timestamp)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    func show(_ items: [MessageActionItem], timestamp date: Date?) {
      for button in buttons { button.removeFromSuperview() }
      buttons = []
      performs = []
      copyIndex = nil
      for (index, item) in items.enumerated() {
        let button = NSButton(
          image: NSImage(systemSymbolName: item.systemImage, accessibilityDescription: item.title)
            ?? NSImage(), target: self, action: #selector(press(_:)))
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.tag = index
        button.isEnabled = item.unavailableReason == nil
        button.toolTip = item.unavailableReason ?? item.title
        button.setAccessibilityLabel(item.title)
        button.setAccessibilityIdentifier(item.identifier)
        if item.kind == .copy { copyIndex = index }
        addSubview(button)
        buttons.append(button)
        performs.append(item.perform)
      }
      timestamp.stringValue = date.map { MessageTimestamp.format($0, now: Date()) } ?? ""
      timestamp.isHidden = date == nil
      layOutControls()
    }

    private func layOutControls() {
      let target = Theme.Control.target
      var leading: CGFloat = 0
      for button in buttons {
        button.frame = CGRect(x: leading, y: 0, width: target, height: target)
        leading += target + Theme.Spacing.medium
      }
      if !timestamp.isHidden {
        let size = timestamp.intrinsicContentSize
        timestamp.frame = CGRect(
          x: leading, y: ((target - size.height) / 2).rounded(), width: size.width.rounded(.up),
          height: size.height)
        leading += size.width.rounded(.up)
      } else if !buttons.isEmpty {
        leading -= Theme.Spacing.medium
      }
      setFrameSize(NSSize(width: max(0, leading), height: target))
    }

    @objc private func press(_ sender: NSButton) {
      guard performs.indices.contains(sender.tag) else { return }
      performs[sender.tag]()
      guard sender.tag == copyIndex else { return }
      sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
      sender.setAccessibilityLabel("Copied")
      copyReset?.cancel()
      copyReset = Task { [weak sender] in
        do {
          try await Task.sleep(for: Theme.Timing.pause(.seconds(1.5)))
        } catch {
          // A newer copy or the view going away cancelled it; that one shows its own state.
          return
        }
        sender?.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        sender?.setAccessibilityLabel("Copy")
      }
    }
  }
#endif
