#if os(iOS)
  import IOSurface
  import OmnigentPlatform
  import UIKit

  /// A run of message text drawn ahead (``MessageTextRaster``), shown as layer contents, so
  /// scrolling moves it and draws nothing: the iPhone and iPad text cells' surface. A long press
  /// lays a TextKit 2 text view over it with the run's text, its glyphs clear so the drawing
  /// shows through, for selecting and copying until a tap ends it; a tap on a link opens it from
  /// the raster's link rectangles. A block's controls (``makeChrome``) sit over the drawing, and
  /// VoiceOver reads the text as SwiftUI's markdown exposes it (``MessageTextAccessibilityItem``).
  final class MessageTextRunView: UIView, UITextViewDelegate {
    let run: MessageTextRun
    private(set) var raster: MessageTextRaster
    let image = MessageTextRunImageView()
    /// The text view laid over the drawing while the reader selects.
    private(set) var live: MessageTextSelectionView?
    var openURL: ((URL) -> Void)?
    /// The app's actions for selected text, which the edit menu offers after Copy.
    var selectionActions: ((String) -> [UIMenuElement])?
    /// The actions VoiceOver offers on each of the run's elements.
    var accessibilityActions: () -> [UIAccessibilityCustomAction] = { [] }
    /// Each block's control, for a code block's language in what VoiceOver reads.
    var chrome: [Int: MessageTextChrome] = [:]
    /// Makes the controls over a block (a code block's header, a table's row), by block.
    var makeChrome: ((Int) -> UIView?)?
    /// The controls made, by block.
    private(set) var chromeViews: [Int: UIView] = [:]
    /// Touches beyond this width pass through: a prompt's bubble hugs its text.
    var touchWidth: CGFloat?
    /// Whether the bitmap was let go while the view is off screen (``releaseBitmap()``).
    private(set) var isReleased = false
    /// VoiceOver's elements, built when it first asks.
    private var elements: [Any] = []
    private var elementsAreBuilt = false

    init(run: MessageTextRun, raster: MessageTextRaster) {
      self.run = run
      self.raster = raster
      super.init(frame: .zero)
      backgroundColor = .clear
      addSubview(image)
      show(raster)
      isAccessibilityElement = false
      addGestureRecognizer(
        UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:))))
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `raster`, a drawing of this view's run; the controls it has no view for are made.
    func show(_ raster: MessageTextRaster) {
      self.raster = raster
      isReleased = false
      image.show(raster.surface, scale: raster.scale)
      refreshChrome()
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }

    /// Makes the controls of the blocks the drawing has and no view shows yet, and lets go of
    /// those of blocks it no longer has.
    func refreshChrome() {
      elementsAreBuilt = false
      for (block, view) in chromeViews where raster.chromeFrames[block] == nil {
        view.removeFromSuperview()
        chromeViews[block] = nil
      }
      for block in raster.chromeFrames.keys.sorted() where chromeViews[block] == nil {
        guard let view = makeChrome?(block) else { continue }
        addSubview(view)
        chromeViews[block] = view
      }
    }

    /// Lets the bitmap go while the view is off screen; ``show(_:)`` takes one again.
    func releaseBitmap() {
      guard !isReleased else { return }
      endSelecting()
      raster = raster.withoutBitmap()
      image.show(nil, scale: raster.scale)
      isReleased = true
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: raster.width, height: raster.size.height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
      super.layoutSubviews()
      image.frame = CGRect(
        x: 0, y: raster.topInset, width: raster.width,
        height: max(0, raster.size.height - raster.topInset))
      for (block, view) in chromeViews {
        guard let frame = raster.chromeFrames[block] else { continue }
        view.frame = frame.offsetBy(dx: 0, dy: raster.topInset)
      }
      let textFrame = CGRect(x: 0, y: 0, width: raster.width, height: bounds.height)
      if let live, live.frame != textFrame { live.frame = textFrame }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      if live == nil, let touchWidth, point.x > touchWidth { return false }
      return super.point(inside: point, with: event)
    }

    /// `point` in this view, in the raster's text coordinates.
    func textPoint(_ point: CGPoint) -> CGPoint {
      CGPoint(x: point.x, y: point.y - raster.topInset)
    }

    // MARK: Taps and presses

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
      tap(at: gesture.location(in: self))
    }

    /// A tap ends a selection, else opens the link under it.
    func tap(at point: CGPoint) {
      if live != nil {
        endSelecting()
      } else if let url = raster.link(at: textPoint(point)) {
        openURL?(url)
      }
    }

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
      guard gesture.state == .began else { return }
      beginSelecting(at: gesture.location(in: self))
    }

    /// Lays the live text view over the drawing and selects the word at `point`.
    func beginSelecting(at point: CGPoint) {
      let view = live ?? makeLive()
      view.layoutIfNeeded()
      let inText = convert(point, to: view)
      if let position = view.closestPosition(to: inText),
        let word = view.tokenizer.rangeEnclosingPosition(
          position, with: .word, inDirection: .storage(.forward))
          ?? view.tokenizer.rangeEnclosingPosition(
            position, with: .word, inDirection: .storage(.backward))
      {
        view.selectedTextRange = word
      }
      view.becomeFirstResponder()
    }

    /// Takes the live text view away; the drawing shows the run again.
    func endSelecting() {
      guard let view = live else { return }
      live = nil
      view.resigned = nil
      view.resignFirstResponder()
      view.removeFromSuperview()
    }

    /// The run's text laid out as the raster lays it out, its glyphs and links' styling clear,
    /// so the selection draws over the drawing and links open from this view's taps.
    private func makeLive() -> MessageTextSelectionView {
      let view = MessageTextSelectionView(usingTextLayoutManager: true)
      view.isEditable = false
      view.isSelectable = true
      view.isScrollEnabled = false
      view.backgroundColor = .clear
      view.textContainerInset = UIEdgeInsets(top: raster.topInset, left: 0, bottom: 0, right: 0)
      view.textContainer.lineFragmentPadding = 0
      let text = NSMutableAttributedString(attributedString: run.text)
      let whole = NSRange(location: 0, length: text.length)
      text.removeAttribute(.link, range: whole)
      text.addAttribute(.foregroundColor, value: UIColor.clear, range: whole)
      view.attributedText = text
      view.delegate = self
      view.resigned = { [weak self] in self?.endSelecting() }
      view.frame = CGRect(x: 0, y: 0, width: raster.width, height: bounds.height)
      // Under the controls, which stay pressable while the reader selects.
      if let first = chromeViews.values.first {
        insertSubview(view, belowSubview: first)
      } else {
        addSubview(view)
      }
      live = view
      return view
    }

    /// The edit menu: the system's first group (Copy, Select All), then the app's actions for
    /// the selection, then the rest of the system's.
    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      let selected = run.text.messageCopyText(in: range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !selected.isEmpty, let own = selectionActions?(selected), !own.isEmpty else {
        return nil
      }
      var children: [UIMenuElement] = Array(suggestedActions.prefix(1))
      children.append(UIMenu(options: .displayInline, children: own))
      children += suggestedActions.dropFirst()
      return UIMenu(children: children)
    }

    // MARK: VoiceOver

    // UIKit's signature makes them optional.
    // swiftlint:disable:next discouraged_optional_collection
    override var accessibilityElements: [Any]? {
      get {
        if !elementsAreBuilt {
          elements = makeAccessibilityElements()
          elementsAreBuilt = true
        }
        return elements
      }
      set {
        elements = newValue ?? []
        elementsAreBuilt = newValue != nil
      }
    }

    /// The text's elements, as SwiftUI exposes MarkdownView's, each block's controls in their
    /// place: a code block's after its label, a table's after its cells.
    private func makeAccessibilityElements() -> [Any] {
      let items = MessageTextAccessibilityItem.items(in: run.text, chrome: chrome)
      let frames = MessageTextRunFrames(run, width: raster.width)
      let actions = accessibilityActions()
      func element(_ item: MessageTextAccessibilityItem) -> MessageTextRunElement {
        let element = MessageTextRunElement(item: item, container: self)
        element.accessibilityFrameInContainerSpace = frames.frame(of: item.range)
        element.accessibilityCustomActions = actions
        return element
      }
      var built: [Any] = []
      for item in items {
        switch item.role {
        case .codeBlock(let block):
          built.append(element(item))
          if let controls = chromeViews[block] { built.append(controls) }
          built += item.children.dropFirst().map(element)
        case .table(let block):
          built += item.children.map(element)
          if let controls = chromeViews[block] { built.append(controls) }
        case .text:
          built.append(element(item))
          built += item.children.map(element)
        case .heading, .link, .image:
          built.append(element(item))
        }
      }
      return built
    }
  }

  /// One element of a drawn run's text: a heading, a paragraph, a link that opens, a list's
  /// number or task box, a code block's label or code, or a table's cell.
  final class MessageTextRunElement: UIAccessibilityElement {
    let item: MessageTextAccessibilityItem
    private weak var run: MessageTextRunView?

    init(item: MessageTextAccessibilityItem, container: MessageTextRunView) {
      self.item = item
      run = container
      super.init(accessibilityContainer: container)
      accessibilityLabel = item.label ?? item.value
      switch item.role {
      case .heading: accessibilityTraits = [.staticText, .header]
      case .text, .codeBlock, .table: accessibilityTraits = .staticText
      case .link: accessibilityTraits = .link
      case .image: accessibilityTraits = .image
      }
    }

    override func accessibilityActivate() -> Bool {
      guard case .link(let url) = item.role, let openURL = run?.openURL else { return false }
      openURL(url)
      return true
    }
  }

  /// Where ranges of a run's text land, laid out as its raster lays it out: for VoiceOver's
  /// frames, made only when it asks.
  struct MessageTextRunFrames {
    private let manager: NSTextLayoutManager
    private let topInset: CGFloat

    init(_ run: MessageTextRun, width: CGFloat) {
      let storage = NSTextContentStorage()
      manager = NSTextLayoutManager()
      storage.addTextLayoutManager(manager)
      let container = NSTextContainer(size: CGSize(width: width, height: 10_000_000))
      container.lineFragmentPadding = 0
      manager.textContainer = container
      storage.textStorage?.setAttributedString(run.text)
      manager.ensureLayout(for: manager.documentRange)
      topInset = run.topInset
    }

    /// The union of `range`'s line segments, in the run view's coordinates.
    func frame(of range: NSRange) -> CGRect {
      guard let content = manager.textContentManager,
        let start = content.location(content.documentRange.location, offsetBy: range.location),
        let end = content.location(start, offsetBy: range.length),
        let textRange = NSTextRange(location: start, end: end)
      else { return .zero }
      var union: CGRect?
      manager.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
        union = union?.union(frame) ?? frame
        return true
      }
      return (union ?? .zero).offsetBy(dx: 0, dy: topInset)
    }
  }

  /// The text laid over a drawn run while the reader selects. A copy gives the text as the
  /// message reads (no list markers, math in its Unicode form), not its clear glyphs; giving up
  /// the keyboard ends the selection.
  final class MessageTextSelectionView: UITextView {
    var resigned: (() -> Void)?

    /// What a copy of the selection gives.
    var copiedText: String { attributedText.messageCopyText(in: selectedRange) }

    override func copy(_ sender: Any?) {
      Pasteboard.copy(copiedText)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
      let didResign = super.resignFirstResponder()
      if didResign { resigned?() }
      return didResign
    }
  }

  /// A raster's bitmap as layer contents. Touches pass through it to the run view.
  final class MessageTextRunImageView: UIView {
    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
      backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    /// Whether it shows a drawing.
    var showsDrawing: Bool { layer.contents != nil }

    func show(_ surface: IOSurface?, scale: CGFloat) {
      layer.contents = surface
      layer.contentsScale = scale
    }
  }
#endif
