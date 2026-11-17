#if os(macOS)
  import AppKit
  import OmnigentPlatform
  import SwiftUI

  /// A text cell's chrome: the actions hover reveals, and the message's context menu.
  extension TranscriptTableTextCell {
    // MARK: Actions

    /// Whether the actions show: on hover or keyboard focus, or always on the last settled
    /// answer.
    var revealsActions: Bool {
      isHovered || message?.decoration.showsActions == true || hasKeyboardFocus
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
      view.focusChanged = { [weak self] in self?.focusMoved() }
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

    /// The message's menu, as ``MessageContextMenu`` builds it: its actions (one that doesn't
    /// apply disabled, with why), Share, then Copy Message ID.
    override func menu(for event: NSEvent) -> NSMenu? {
      guard let message, let values = style.environment.values else { return nil }
      let menu = NSMenu()
      menu.autoenablesItems = false
      let items = MessageActionItem.items(
        for: message.row, actions: values.conversationActions,
        copy: values.copyWithConfirmation)
      for item in items {
        let menuItem = menuItem(
          item.menuTitle, systemImage: item.systemImage, enabled: item.unavailableReason == nil,
          perform: item.perform)
        if let reason = item.unavailableReason {
          menuItem.subtitle = reason
          menuItem.toolTip = reason
        }
        menu.addItem(menuItem)
      }
      menu.addItem(shareItem(for: message.row.text))
      menu.addItem(.separator())
      let id = message.row.id
      let copy = values.copyWithConfirmation
      menu.addItem(
        menuItem("Copy Message ID", systemImage: "number", enabled: true) {
          copy(id, confirmation: "Message ID copied")
        })
      return menu
    }

    /// Share, for the message's text: the system's share item, as a SwiftUI `ShareLink` in a
    /// menu gives, disabled when there is no text.
    private func shareItem(for text: String) -> NSMenuItem {
      let picker = NSSharingServicePicker(items: [text])
      let item = picker.standardShareMenuItem
      item.title = "Share"
      item.image = Self.menuImage("square.and.arrow.up", title: "Share")
      item.isEnabled = !text.isEmpty
      return item
    }

    private func menuItem(
      _ title: String, systemImage: String, enabled: Bool,
      perform: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
      item.target = self
      item.isEnabled = enabled
      item.image = Self.menuImage(systemImage, title: title)
      item.representedObject = TranscriptMenuAction(perform)
      return item
    }

    /// A menu item's symbol, as a SwiftUI menu's label shows it.
    private static func menuImage(_ name: String, title: String) -> NSImage? {
      NSImage(systemSymbolName: name, accessibilityDescription: title)
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
    private(set) var buttons: [TranscriptMessageActionButton] = []
    /// Told when one of the buttons takes or gives up the keyboard.
    var focusChanged: (() -> Void)?
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

    /// The buttons' looks, so items that look the same keep their buttons.
    private var shownItems: [ShownItem] = []
    private var shownTimestamp: String?

    private struct ShownItem: Equatable {
      var systemImage: String
      var title: String
      var identifier: String
      var unavailableReason: String?
    }

    func show(_ items: [MessageActionItem], timestamp date: Date?) {
      performs = items.map(\.perform)
      copyIndex = items.firstIndex { $0.kind == .copy }
      let looks = items.map {
        ShownItem(
          systemImage: $0.systemImage, title: $0.title, identifier: $0.identifier,
          unavailableReason: $0.unavailableReason)
      }
      let stamp = date.map { MessageTimestamp.format($0, now: Date()) }
      // A cell shown again, or hovered again, keeps its buttons: only their actions change.
      guard looks != shownItems || stamp != shownTimestamp else { return }
      shownItems = looks
      shownTimestamp = stamp
      copyReset?.cancel()
      for button in buttons { button.removeFromSuperview() }
      buttons = []
      for (index, item) in items.enumerated() {
        let button = TranscriptMessageActionButton(
          image: Self.symbol(item.systemImage, title: item.title), target: self,
          action: #selector(press(_:)))
        button.focusChanged = { [weak self] in self?.focusChanged?() }
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.tag = index
        button.isEnabled = item.unavailableReason == nil
        button.toolTip = item.unavailableReason ?? item.title
        button.setAccessibilityLabel(item.title)
        button.setAccessibilityIdentifier(item.identifier)
        addSubview(button)
        buttons.append(button)
      }
      timestamp.stringValue = stamp ?? ""
      timestamp.isHidden = stamp == nil
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

    private static var symbols: [String: NSImage] = [:]

    /// The action's symbol, looked up once.
    private static func symbol(_ name: String, title: String) -> NSImage {
      if let kept = symbols[name] { return kept }
      let image = NSImage(systemSymbolName: name, accessibilityDescription: title) ?? NSImage()
      symbols[name] = image
      return image
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
