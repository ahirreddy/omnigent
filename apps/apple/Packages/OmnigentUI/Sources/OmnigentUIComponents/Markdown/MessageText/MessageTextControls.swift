#if os(macOS)
  import AppKit
  import OmnigentPlatform

  /// A code block's header: its language and a Copy button that says "Copied" for a moment.
  final class MessageCodeHeaderView: NSView {
    private let label: NSTextField
    let copyButton: NSButton
    private let code: String
    private var reset: Task<Void, Never>?

    init(label text: String, code: String, palette: MessageTextPalette) {
      self.code = code
      label = NSTextField(labelWithString: text)
      label.font = palette.sectionFont
      label.textColor = palette.secondary
      label.lineBreakMode = .byTruncatingTail
      copyButton = NSButton(title: "Copy", target: nil, action: nil)
      super.init(frame: .zero)
      copyButton.isBordered = false
      copyButton.imagePosition = .imageLeading
      copyButton.font = palette.sectionFont
      copyButton.contentTintColor = palette.secondary
      copyButton.toolTip = "Copy code"
      copyButton.setAccessibilityLabel("Copy code")
      copyButton.target = self
      copyButton.action = #selector(copyCode)
      showCopied(false)
      addSubview(label)
      addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      let inset = Theme.Spacing.medium
      let target = Theme.Control.target
      let buttonWidth = max(target, copyButton.intrinsicContentSize.width)
      copyButton.frame = CGRect(
        x: bounds.maxX - inset - buttonWidth, y: ((bounds.height - target) / 2).rounded(),
        width: buttonWidth, height: target)
      let labelHeight = label.intrinsicContentSize.height
      label.frame = CGRect(
        x: inset, y: ((bounds.height - labelHeight) / 2).rounded(),
        width: max(0, copyButton.frame.minX - inset * 2), height: labelHeight)
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
      copyButton.title = copied ? "Copied" : "Copy"
      copyButton.image = NSImage(
        systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
      copyButton.setAccessibilityLabel(copied ? "Copied" : "Copy code")
      needsLayout = true
    }
  }

  /// A table's Copy menu: as Markdown, CSV or TSV.
  final class MessageTableControlsView: NSView {
    let copyButton: NSButton
    private let table: MarkdownTable

    init(table: MarkdownTable, palette: MessageTextPalette) {
      self.table = table
      copyButton = NSButton(title: "", target: nil, action: nil)
      super.init(frame: .zero)
      copyButton.isBordered = false
      copyButton.image = NSImage(
        systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy table")
      copyButton.contentTintColor = palette.secondary
      copyButton.toolTip = "Copy table"
      copyButton.setAccessibilityLabel("Copy table")
      copyButton.setAccessibilityIdentifier("markdown.table.copy")
      copyButton.target = self
      copyButton.action = #selector(showMenu)
      addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      let target = Theme.Control.target
      copyButton.frame = CGRect(x: 0, y: 0, width: target, height: target)
    }

    /// The menu's items and what each copies.
    var copyChoices: [(title: String, text: String)] {
      [
        ("Copy as Markdown", MarkdownTableText.markdown(table)),
        ("Copy as CSV", MarkdownTableText.csv(table)),
        ("Copy as TSV", MarkdownTableText.tsv(table)),
      ]
    }

    @objc private func showMenu() {
      let menu = NSMenu()
      for (index, choice) in copyChoices.enumerated() {
        let item = NSMenuItem(
          title: choice.title, action: #selector(copyChoice(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        menu.addItem(item)
      }
      _ = menu.popUp(
        positioning: nil, at: CGPoint(x: 0, y: copyButton.bounds.maxY), in: copyButton)
    }

    @objc private func copyChoice(_ item: NSMenuItem) {
      let choices = copyChoices
      guard choices.indices.contains(item.tag) else { return }
      Pasteboard.copy(choices[item.tag].text)
    }
  }
#endif
