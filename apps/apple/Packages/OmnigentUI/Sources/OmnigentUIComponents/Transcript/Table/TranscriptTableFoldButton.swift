#if os(macOS)
  import AppKit
  import SwiftUI

  /// A fold's title and chevron as a plain button, as ``WorkedFold`` draws its own: a hover
  /// highlight, a click toggles it, and accessibility sees a button named by the fold's size
  /// whose value says whether it is open.
  final class TranscriptTableFoldButton: NSView {
    var toggled: (() -> Void)?
    let highlight = NSView()
    let title = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    private var area: NSTrackingArea?
    private var isHovered = false
    private var hoverColor: NSColor?
    private var size: CGFloat = 0

    /// An `NSTextField` draws its text this far inside its frame; SwiftUI's text starts at its
    /// frame's edge.
    static let labelInset: CGFloat = 2

    var isExpanded = false {
      didSet {
        guard isExpanded != oldValue else { return }
        chevron.frameCenterRotation = isExpanded ? -90 : 0
        setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      }
    }

    init() {
      super.init(frame: .zero)
      highlight.wantsLayer = true
      highlight.alphaValue = 0
      highlight.layer?.cornerRadius = Theme.Radius.small
      highlight.layer?.cornerCurve = .continuous
      title.textColor = .secondaryLabelColor
      title.lineBreakMode = .byClipping
      title.setAccessibilityElement(false)
      chevron.imageScaling = .scaleNone
      chevron.contentTintColor = .secondaryLabelColor
      chevron.setAccessibilityElement(false)
      chevron.wantsLayer = true
      addSubview(highlight)
      addSubview(title)
      addSubview(chevron)
      setAccessibilityElement(true)
      setAccessibilityRole(.button)
      setAccessibilityValue("Collapsed")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    /// Shows a fold's title at the transcript's label size.
    func show(
      title text: String, identifier: String, tooltip: String?, size: CGFloat, hover: NSColor?
    ) {
      if title.stringValue != text { title.stringValue = text }
      if size != self.size {
        self.size = size
        title.font = .systemFont(ofSize: size)
      }
      if chevron.image == nil { chevron.image = Self.chevronImage }
      toolTip = tooltip
      hoverColor = hover
      highlight.layer?.backgroundColor = hover?.cgColor
      setAccessibilityLabel(text)
      setAccessibilityIdentifier("worked-fold-\(identifier)")
      needsLayout = true
    }

    /// The chevron, at the caption's size and semibold, as SwiftUI sets the fold's symbol.
    static let chevronImage: NSImage? = {
      let size = NSFont.preferredFont(forTextStyle: .caption2).pointSize
      return NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }()

    /// The title's width and height, as SwiftUI sets the text.
    private var titleSize: CGSize {
      let font = title.font ?? .systemFont(ofSize: size)
      let width = title.attributedStringValue.size().width.rounded(.up)
      return CGSize(
        width: width, height: (font.ascender - font.descender + font.leading).rounded(.up))
    }

    /// The title, the gap and the chevron, padded to a control's height at least.
    override var fittingSize: NSSize {
      let text = titleSize
      let symbol = chevron.image?.size ?? .zero
      let content = max(text.height, symbol.height)
      return NSSize(
        width: text.width + Theme.Spacing.small + symbol.width,
        height: max(Theme.Control.target, content + 2 * Theme.Spacing.extraSmall))
    }

    override func layout() {
      super.layout()
      highlight.frame = bounds
      let text = titleSize
      let labelHeight = title.intrinsicContentSize.height
      title.frame = CGRect(
        x: -Self.labelInset, y: ((bounds.height - labelHeight) / 2).rounded(),
        width: text.width + 2 * Self.labelInset, height: labelHeight)
      let symbol = chevron.image?.size ?? .zero
      let rotation = chevron.frameCenterRotation
      chevron.frameCenterRotation = 0
      chevron.frame = CGRect(
        x: text.width + Theme.Spacing.small, y: ((bounds.height - symbol.height) / 2).rounded(),
        width: symbol.width, height: symbol.height)
      chevron.frameCenterRotation = rotation
    }

    /// Fades `content` in as the fold opens, and turns the chevron, unless motion is reduced.
    func reveal(_ content: NSView) {
      guard Self.animates else { return }
      let rotation = chevron.frameCenterRotation
      chevron.frameCenterRotation = isExpanded ? 0 : -90
      content.alphaValue = 0
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        chevron.animator().frameCenterRotation = rotation
        content.animator().alphaValue = 1
      }
    }

    /// Whether views animate: not with reduced motion, nor in tests.
    static var animates: Bool {
      Theme.Motion.isEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
      frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // One area that follows the visible rect, so scrolling rebuilds nothing.
      guard area == nil else { return }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self)
      addTrackingArea(area)
      self.area = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
      guard hovered != isHovered else { return }
      isHovered = hovered
      let alpha: CGFloat = hovered && hoverColor != nil ? 1 : 0
      guard Self.animates else {
        highlight.alphaValue = alpha
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.16
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        highlight.animator().alphaValue = alpha
      }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
      guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
      toggled?()
    }

    override func accessibilityPerformPress() -> Bool {
      toggled?()
      return true
    }
  }

  /// A hairline in the separator color, as SwiftUI's `Divider` draws one.
  final class TranscriptTableRuleView: NSView {
    init() {
      super.init(frame: .zero)
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
      // The effective appearance is current here, so the color resolves for it.
      layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  /// A header or footer with nothing in it: only the space the stack keeps at its end.
  final class TranscriptTableSpacerCell: NSView, TranscriptTableCell {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    private(set) var idealHeight: CGFloat = 0

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      shown = TranscriptTableShown(id: row.id, version: version, width: width)
      kind = .native(row.kind)
      switch row.content {
      case .header: idealHeight = TranscriptTableHeaderView.topPadding(isCLI: false)
      case .footer(let footer):
        idealHeight = TranscriptTableFooterView.bottomPadding(
          isCLI: footer.isCLI, hasContent: false)
      case .segment, .block: idealHeight = 0
      }
    }

    func settle() {}

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif
