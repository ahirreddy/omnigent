#if os(macOS)
  import AppKit

  extension TranscriptTableCLICell {
    /// Shows `document`'s wide tables in copies that scroll sideways, as SwiftUI scrolls
    /// ``CLITableView``; another document's copies go.
    func placeOverflows(_ document: CLITextDocument) {
      if overflowsDocument !== document {
        removeOverflows()
        overflowViews = document.overflows.map { makeOverflow($0, palette: document.text.palette) }
        overflowsDocument = document
      }
      for (view, overflow) in zip(overflowViews, document.overflows) {
        view.frame = overflow.frame.offsetBy(dx: textFrame.minX, dy: textFrame.minY)
        view.fit()
      }
    }

    /// A copy of a wide table's rows and their rules, over the text's unseen rows.
    private func makeOverflow(_ overflow: CLITextOverflow, palette: MessageTextPalette)
      -> MessageTextOverflowView
    {
      let view = MessageTextOverflowView(
        text: overflow.text, palette: palette, trailingPadding: 0,
        minimumWidth: overflow.contentWidth)
      let rules = TranscriptTableCLIDecorationsView()
      rules.frame = CGRect(
        x: 0, y: 0, width: view.contentWidth, height: overflow.frame.height)
      rules.show(overflow.rules, style: style)
      view.textView.addSubview(rules)
      addSubview(view, positioned: .above, relativeTo: run?.view)
      return view
    }

    func removeOverflows() {
      for view in overflowViews { view.removeFromSuperview() }
      overflowViews = []
      overflowsDocument = nil
    }
  }
#endif
