#if os(macOS)
  import AppKit
  import OmnigentPlatform
  import SwiftUI
  import UniformTypeIdentifiers

  /// A code block's header, as ``CodeBlockView`` draws it: the language, then Wrap, Download and
  /// a Copy button that says "Copied" for a moment.
  final class MessageCodeHeaderView: NSView {
    private let label: NSAttributedString
    private let labelFont: NSFont
    let wrapButton: NSButton
    let downloadButton: NSButton
    let copyButton: MessageHoverButton
    private let code: String
    private let language: String?
    private let palette: MessageTextPalette
    private var reset: Task<Void, Never>?
    /// Wrap was turned on or off.
    var wrapChanged: ((Bool) -> Void)?

    /// Whether long lines wrap; otherwise they scroll sideways.
    var wrapsLines: Bool {
      get { wrapButton.state == .on }
      set {
        wrapButton.state = newValue ? .on : .off
        showWrap()
      }
    }

    init(language: String?, code: String, palette: MessageTextPalette) {
      self.code = code
      self.language = language
      self.palette = palette
      labelFont = palette.sectionFont
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      label = NSAttributedString(
        string: CodeLanguageName.label(for: language),
        attributes: [
          .font: palette.sectionFont, .foregroundColor: palette.secondary, .paragraphStyle: style,
        ])
      let symbolSize = palette.style.ramp.body
      wrapButton = Self.iconButton(
        "text.word.spacing", label: "Wrap code lines", size: symbolSize)
      downloadButton = Self.iconButton(
        "arrow.down.circle", label: "Download code", size: symbolSize)
      copyButton = MessageHoverButton(highlight: palette.hover)
      super.init(frame: .zero)
      wrapButton.setButtonType(.pushOnPushOff)
      wrapButton.state = .on
      wrapButton.setAccessibilityLabel("Wrap code lines")
      wrapButton.target = self
      wrapButton.action = #selector(toggleWrap)
      downloadButton.toolTip = "Download code"
      downloadButton.setAccessibilityLabel("Download code")
      downloadButton.setAccessibilityIdentifier("markdown.code.download")
      downloadButton.target = self
      downloadButton.action = #selector(download)
      copyButton.isBordered = false
      copyButton.imagePosition = .imageLeading
      copyButton.imageHugsTitle = true
      copyButton.font = palette.sectionFont
      copyButton.contentTintColor = palette.secondary
      copyButton.toolTip = "Copy code"
      copyButton.target = self
      copyButton.action = #selector(copyCode)
      for button in [wrapButton, downloadButton] { button.contentTintColor = palette.secondary }
      showWrap()
      showCopied(false)
      addSubview(wrapButton)
      addSubview(downloadButton)
      addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// A borderless button showing one symbol, which names it to accessibility.
    private static func iconButton(_ name: String, label: String, size: CGFloat) -> NSButton {
      let button = NSButton(title: "", target: nil, action: nil)
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.setAccessibilityLabel(label)
      button.image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
      return button
    }

    /// The label's baseline and leading edge, as SwiftUI sets it in a message: one line of the
    /// prose's exact line height, centered in the band, its baseline the font's size down.
    var labelBaseline: CGPoint {
      let scale = max(palette.style.scale, 1)
      let top = (bounds.height - palette.style.ramp.bodyLineHeight) / 2
      let baseline = ((top + labelFont.pointSize) * scale).rounded() / scale
      return CGPoint(x: Theme.Spacing.medium, y: baseline)
    }

    override func layout() {
      super.layout()
      let target = Theme.Control.target
      let scale = max(palette.style.scale, 1)
      let top = ((bounds.height - target) / 2).rounded()
      var trailing = bounds.maxX - Theme.Spacing.medium
      for button in [copyButton, downloadButton, wrapButton] {
        // Copy is as wide as its icon, the gap and its title, as SwiftUI's label is.
        let content =
          button === copyButton
          ? (button.image?.size.width ?? 0) + Theme.Spacing.extraSmall
            + button.attributedTitle.size().width : 0
        let width = max(target, (content * scale).rounded(.up) / scale)
        button.frame = CGRect(x: trailing - width, y: top, width: width, height: target)
        trailing -= width + Theme.Spacing.small
      }
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      let baseline = labelBaseline
      let width = max(0, wrapButton.frame.minX - Theme.Spacing.small - baseline.x)
      let lineHeight = (labelFont.ascender - labelFont.descender + labelFont.leading).rounded(.up)
      label.draw(
        with: CGRect(
          x: baseline.x, y: baseline.y - labelFont.ascender, width: width, height: lineHeight),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    @objc private func toggleWrap() {
      showWrap()
      wrapChanged?(wrapsLines)
    }

    private func showWrap() {
      wrapButton.toolTip = wrapsLines ? "Scroll long lines" : "Wrap long lines"
    }

    @objc private func download() {
      MessageTextExport.save(
        code, name: "snippet.\(CodeFileExtension.for(language))", from: self)
    }

    @objc private func copyCode() {
      Pasteboard.copy(code)
      showCopied(true)
      reset?.cancel()
      reset = Task { [weak self] in
        do {
          try await Task.sleep(for: Theme.Timing.pause(.seconds(1.5)))
        } catch {
          // A newer copy or the view going away cancelled it; that one shows its own state.
          return
        }
        self?.showCopied(false)
      }
    }

    private func showCopied(_ copied: Bool) {
      copyButton.title = copied ? "Copied" : "Copy code"
      copyButton.image = NSImage(
        systemSymbolName: copied ? "checkmark" : "doc.on.doc",
        accessibilityDescription: copied ? "Copied" : "Copy code")?
        .withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: labelFont.pointSize, weight: .medium))
      copyButton.setAccessibilityLabel(copied ? "Copied" : "Copy code")
      needsLayout = true
    }
  }

  /// A table's controls in a row under it, as ``MarkdownTableBlock``'s: Copy (as Markdown, CSV or
  /// TSV) and Download (CSV or Markdown) menus, and Expand, which shows the table on its own.
  final class MessageTableControlsView: NSView {
    let copyButton: NSPopUpButton
    let downloadButton: NSPopUpButton
    let expandButton: NSButton
    private let table: MarkdownTable
    private let palette: MessageTextPalette
    private var expanded: NSWindow?

    init(table: MarkdownTable, palette: MessageTextPalette) {
      self.table = table
      self.palette = palette
      let size = palette.style.ramp.body
      copyButton = Self.menuButton("doc.on.doc", label: "Copy table", size: size)
      downloadButton = Self.menuButton("arrow.down.circle", label: "Download table", size: size)
      expandButton = NSButton(title: "", target: nil, action: nil)
      super.init(frame: .zero)
      expandButton.isBordered = false
      expandButton.imagePosition = .imageOnly
      expandButton.image = Self.symbol(
        "arrow.up.left.and.arrow.down.right", label: "Expand table", size: size)
      expandButton.toolTip = "Expand table"
      expandButton.setAccessibilityLabel("Expand table")
      copyButton.setAccessibilityIdentifier("markdown.table.copy")
      downloadButton.setAccessibilityIdentifier("markdown.table.download")
      expandButton.setAccessibilityIdentifier("markdown.table.expand")
      for (index, choice) in copyChoices.enumerated() {
        add(choice.title, tag: index, action: #selector(copyChoice(_:)), to: copyButton)
      }
      for (index, choice) in downloadChoices.enumerated() {
        add(choice.title, tag: index, action: #selector(downloadChoice(_:)), to: downloadButton)
      }
      expandButton.target = self
      expandButton.action = #selector(expand)
      for button in [copyButton, downloadButton, expandButton] {
        button.contentTintColor = palette.secondary
        addSubview(button)
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private static func symbol(_ name: String, label: String, size: CGFloat) -> NSImage? {
      NSImage(systemSymbolName: name, accessibilityDescription: label)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    /// A borderless pull-down showing one symbol, as SwiftUI's button-style `Menu` is.
    private static func menuButton(_ name: String, label: String, size: CGFloat)
      -> NSPopUpButton
    {
      let button = NSPopUpButton(frame: .zero, pullsDown: true)
      button.isBordered = false
      (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
      button.imagePosition = .imageOnly
      let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      face.image = symbol(name, label: label, size: size)
      button.menu?.addItem(face)
      button.toolTip = label
      button.setAccessibilityLabel(label)
      return button
    }

    private func add(_ title: String, tag: Int, action: Selector, to button: NSPopUpButton) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.tag = tag
      button.menu?.addItem(item)
    }

    override func layout() {
      super.layout()
      let target = Theme.Control.target
      var leading: CGFloat = 0
      for button in [copyButton, downloadButton, expandButton] where !button.isHidden {
        button.frame = CGRect(x: leading, y: 0, width: target, height: target)
        leading += target + Theme.Spacing.extraSmall
      }
    }

    /// The Copy menu's items and what each copies.
    var copyChoices: [(title: String, text: String)] {
      [
        ("Copy as Markdown", MarkdownTableText.markdown(table)),
        ("Copy as CSV", MarkdownTableText.csv(table)),
        ("Copy as TSV", MarkdownTableText.tsv(table)),
      ]
    }

    /// One of the Download menu's items: what it saves, under which name and type.
    struct Download {
      var title: String
      var text: String
      var name: String
      var type: UTType
    }

    /// The Download menu's items.
    var downloadChoices: [Download] {
      [
        Download(
          title: "Download CSV", text: MarkdownTableText.csv(table), name: "table.csv",
          type: .commaSeparatedText),
        Download(
          title: "Download Markdown", text: MarkdownTableText.markdown(table), name: "table.md",
          type: .plainText),
      ]
    }

    @objc private func copyChoice(_ item: NSMenuItem) {
      let choices = copyChoices
      guard choices.indices.contains(item.tag) else { return }
      Pasteboard.copy(choices[item.tag].text)
    }

    @objc private func downloadChoice(_ item: NSMenuItem) {
      let choices = downloadChoices
      guard choices.indices.contains(item.tag) else { return }
      let choice = choices[item.tag]
      MessageTextExport.save(choice.text, name: choice.name, type: choice.type, from: self)
    }

    /// Shows the table on its own in a sheet, scrolling both ways; Expand hides meanwhile.
    @objc private func expand() {
      // AppKit declares `window` unowned(unsafe); it is only used while this view shows in it.
      guard expanded == nil, let window = unsafe window else { return }
      let style = palette.style
      let sheet = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      sheet.contentMinSize = CGSize(width: 640, height: 420)
      sheet.contentViewController = NSHostingController(
        rootView: ExpandedTable(table: table) { [weak self] in self?.closeExpanded() }
          .environment(\.typeRamp, style.ramp)
          .environment(\.colorScheme, style.isDark ? .dark : .light)
          .readingProseStyle())
      sheet.setContentSize(CGSize(width: 960, height: 640))
      expanded = sheet
      expandButton.isHidden = true
      needsLayout = true
      window.beginSheet(sheet) { [weak self] _ in
        self?.expanded = nil
        self?.expandButton.isHidden = false
        self?.needsLayout = true
      }
    }

    private func closeExpanded() {
      guard let sheet = expanded, let window = sheet.sheetParent else { return }
      window.endSheet(sheet)
    }
  }
#endif
