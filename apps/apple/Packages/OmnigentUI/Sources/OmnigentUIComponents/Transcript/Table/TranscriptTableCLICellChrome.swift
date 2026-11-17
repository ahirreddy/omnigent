#if os(macOS)
  import AppKit
  import SwiftUI

  /// A CLI text cell's chrome: the message's actions that hover reveals in the CLI's floating
  /// cluster (``CLIActionCluster``), and its context menu.
  extension TranscriptTableCLICell {
    /// Builds the cluster once it first shows, and places or hides it: centered on the block's
    /// top edge at the column's trailing side, so it never moves the text.
    func refreshActions() {
      guard isHovered, let block, let message = block.message,
        let values = style.environment.values
      else {
        cluster?.isHidden = true
        return
      }
      let view = cluster ?? makeCluster()
      let items = MessageActionItem.items(
        for: message, actions: values.conversationActions, copy: values.copyWithConfirmation)
      let palette = style.text?.palette ?? .fallback
      view.show(
        items, timestamp: block.decoration.timestamp, fill: palette.composerBand.platformColor,
        border: palette.rule.platformColor)
      let size = view.frame.size
      view.frame = CGRect(
        x: actionsTrailing - size.width, y: -(size.height / 2).rounded(), width: size.width,
        height: size.height)
      view.isHidden = false
    }

    private func makeCluster() -> TranscriptTableCLIClusterView {
      let view = TranscriptTableCLIClusterView()
      addSubview(view)
      cluster = view
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
      guard let message = block?.message, let values = style.environment.values else {
        return nil
      }
      let menu = NSMenu()
      menu.autoenablesItems = false
      let items = MessageActionItem.items(
        for: message, actions: values.conversationActions, copy: values.copyWithConfirmation)
      for item in items {
        menu.addItem(
          menuItem(item.menuTitle, enabled: item.unavailableReason == nil, perform: item.perform))
      }
      menu.addItem(.separator())
      let id = message.id
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

  /// The CLI's floating action cluster in AppKit: a message's buttons and timestamp
  /// (``TranscriptMessageActionsView``) on a small rounded surface with a hairline border.
  final class TranscriptTableCLIClusterView: NSView {
    let actions = TranscriptMessageActionsView()
    private var fill = NSColor.clear
    private var border = NSColor.clear

    /// The space beside the buttons, as the cluster pads them.
    static let padding = Theme.Spacing.extraSmall
    static let radius: CGFloat = 6

    init() {
      super.init(frame: .zero)
      wantsLayer = true
      addSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override var wantsUpdateLayer: Bool { true }

    func show(
      _ items: [MessageActionItem], timestamp: Date?, fill: NSColor, border: NSColor
    ) {
      actions.show(items, timestamp: timestamp)
      actions.frame.origin = CGPoint(x: Self.padding, y: 0)
      setFrameSize(
        NSSize(width: actions.frame.width + 2 * Self.padding, height: actions.frame.height))
      if fill != self.fill || border != self.border {
        self.fill = fill
        self.border = border
        needsDisplay = true
      }
    }

    override func updateLayer() {
      guard let layer else { return }
      layer.backgroundColor = fill.cgColor
      layer.borderColor = border.cgColor
      layer.borderWidth = 1
      layer.cornerRadius = Self.radius
    }
  }
#endif
