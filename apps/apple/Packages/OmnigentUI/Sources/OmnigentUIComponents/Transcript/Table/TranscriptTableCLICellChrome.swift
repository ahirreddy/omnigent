#if os(macOS)
  import AppKit
  import OmnigentPlatform
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

    /// The message's actions, then Copy Message ID; in tool work, the actions of the line under
    /// the pointer, else the group's.
    override func menu(for event: NSEvent) -> NSMenu? {
      if block?.kind == .work { return workMenu(at: convert(event.locationInWindow, from: nil)) }
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

    // MARK: Tool work

    /// The id of the innermost region of tool work under `point`, in the cell's coordinates.
    func workRegion(at point: CGPoint) -> String? {
      guard block?.kind == .work, let document else { return nil }
      let local = CGPoint(x: point.x - textFrame.minX, y: point.y - textFrame.minY)
      // Inner regions come first: a line before its cell.
      for case .region(let rect, let id) in document.decorations where rect.contains(local) {
        return id
      }
      return nil
    }

    /// What "… +N lines" under `point` opens, if one is there.
    private func moreAction(at point: CGPoint) -> String? {
      guard let id = workRegion(at: point), id.hasPrefix(CLITextDecoration.morePrefix) else {
        return nil
      }
      return String(id.dropFirst(CLITextDecoration.morePrefix.count))
    }

    /// "… +N lines" takes the click, not the text under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
      // AppKit declares `superview` unowned(unsafe); it is only read here.
      let local = convert(point, from: unsafe superview)
      if bounds.contains(local), moreAction(at: local) != nil { return self }
      return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
      guard let action = moreAction(at: convert(event.locationInWindow, from: nil)) else {
        super.mouseDown(with: event)
        return
      }
      toggle(action)
    }

    /// A tool line's Show output, Copy input and Copy output, an activity's Show details and
    /// Copy, or the group's Collapse work.
    private func workMenu(at point: CGPoint) -> NSMenu? {
      guard let block else { return nil }
      var actions: [CLIAction] = []
      if let id = workRegion(at: point), let target = block.work?.targets[id] {
        let isOpen = expansions.isOpen(id)
        switch target {
        case .steps(let steps):
          actions = CLIToolStep.actions(for: steps, isExpanded: isOpen) { [weak self] in
            self?.toggle(id)
          }
        case .activity(let row):
          actions = activityActions(row, isOpen: isOpen)
        }
      } else if let group = block.group {
        let isCollapsed = expansions.isCollapsed(group)
        actions = [
          CLIAction(
            title: isCollapsed ? "Expand work" : "Collapse work",
            systemImage: isCollapsed ? "chevron.down" : "chevron.up",
            identifier: "worked-fold-\(group)",
            perform: { [weak self] in self?.toggle(group, collapsing: true) })
        ]
      }
      guard !actions.isEmpty else { return nil }
      let menu = NSMenu()
      menu.autoenablesItems = false
      for action in actions {
        menu.addItem(menuItem(action.title, enabled: true, perform: action.perform))
      }
      return menu
    }

    /// Show details and Copy, as ``CLIActivityLine`` offers them.
    private func activityActions(_ row: Row, isOpen: Bool) -> [CLIAction] {
      guard let activity = row.activity else { return [] }
      var actions: [CLIAction] = []
      let summary = activity.detail("summary") ?? activity.summary
      if !summary.isEmpty {
        let id = row.id
        actions.append(
          CLIAction(
            title: isOpen ? "Hide details" : "Show details",
            systemImage: isOpen ? "chevron.up" : "chevron.down",
            identifier: "reasoning-toggle-\(row.id)",
            perform: { [weak self] in self?.toggle(id) }))
      }
      let copyText = row.text.isEmpty ? activity.summary : row.text
      if !copyText.isEmpty {
        actions.append(
          CLIAction(
            title: "Copy", systemImage: "doc.on.doc", identifier: "activity-copy-\(row.id)",
            perform: { Pasteboard.copy(copyText) }))
      }
      return actions
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
