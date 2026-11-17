#if os(macOS)
  import AppKit

  /// A shared session author's initials in their color, beside their prompt's bubble, as
  /// ``AuthorAvatar`` draws them: 11 pt bold rounded white initials, narrowed to fit, in a
  /// 24 pt circle, with the name as its tooltip and accessibility label.
  final class TranscriptTableAvatarView: NSView {
    /// The circle's size, as the row's avatar.
    static let size: CGFloat = 24
    /// How far the initials may shrink to fit, as SwiftUI's minimum scale factor.
    static let minimumScale: CGFloat = 0.8

    private(set) var initials = ""
    private var color = NSColor.clear

    init() {
      super.init(frame: .zero)
      setAccessibilityElement(true)
      setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `author`'s initials in their color.
    func show(author: String) {
      let initials = AuthorAvatar.initials(author)
      let hex = AuthorAvatar.color(for: author)
      let color = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      toolTip = author
      setAccessibilityLabel(author)
      guard initials != self.initials || color != self.color else { return }
      self.initials = initials
      self.color = color
      needsDisplay = true
    }

    /// The initials' font at `scale` of their 11 pt size.
    static func font(scale: CGFloat) -> NSFont {
      let size = 11 * scale
      let bold = NSFont.systemFont(ofSize: size, weight: .bold)
      guard let rounded = bold.fontDescriptor.withDesign(.rounded) else { return bold }
      return NSFont(descriptor: rounded, size: size) ?? bold
    }

    /// The initials, centered in the circle, narrowed to fit as SwiftUI narrows them.
    func drawnInitials() -> NSAttributedString {
      let full = Self.attributed(initials, scale: 1)
      let width = full.size().width
      guard width > bounds.width, width > 0 else { return full }
      return Self.attributed(initials, scale: max(Self.minimumScale, bounds.width / width))
    }

    private static func attributed(_ text: String, scale: CGFloat) -> NSAttributedString {
      NSAttributedString(
        string: text, attributes: [.font: font(scale: scale), .foregroundColor: NSColor.white])
    }

    override func draw(_ dirtyRect: NSRect) {
      color.setFill()
      NSBezierPath(ovalIn: bounds).fill()
      let text = drawnInitials()
      let size = text.size()
      text.draw(
        at: CGPoint(
          x: ((bounds.width - size.width) / 2).rounded(),
          y: ((bounds.height - size.height) / 2).rounded()))
    }
  }
#endif
