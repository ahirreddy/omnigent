#if os(macOS)
  import AppKit

  extension TranscriptTableTextCell {
    /// Runs this short draw now when none was drawn ahead: a prompt or a short answer costs
    /// less drawn once than as a live view.
    static let drawsNowBelow = 1_200

    /// A new run for `document`: its raster (drawn now when the run is short), else a live view,
    /// drawn ahead for next time.
    func makeRun(
      _ document: MessageTextDocument, raster: MessageTextRaster?, width: CGFloat
    ) -> TranscriptTableTextRun {
      var raster = raster
      if raster == nil, style.drawsAhead, let rasterStyle = style.rasterStyle,
        document.text.length < Self.drawsNowBelow
      {
        let drawn = MessageTextRaster.make(
          document.run, width: width, scale: style.scale, style: rasterStyle)
        MessageTextRasters.shared.store(
          drawn,
          for: MessageTextRasterKey(document: document.serial, width: width, scale: style.scale))
        MessageTextSizes.shared.store(drawn.size, document: document.serial, width: width)
        if !drawn.overflows { raster = drawn }
      }
      if let raster {
        let view = MessageTextRasterView(document: document, raster: raster)
        view.wrapChanged = { [weak self, weak document] block, wraps in
          guard let document else { return }
          self?.showLive(document, block: block, wraps: wraps)
        }
        addSubview(view)
        return .raster(view)
      }
      if style.drawsAhead, let rasterStyle = style.rasterStyle {
        MessageTextPrewarm.shared.draw(
          document, width: width, scale: style.scale, style: rasterStyle)
      }
      let view = MessageTextViews.shared.checkOut(document)
      addSubview(view)
      return .live(view)
    }

    // A hosted piece reports a change before SwiftUI has its new size: the cell lays out
    // again on the next pass, as for a live text view (``invalidateIntrinsicContentSize()``).

    func makeBlockView() -> TranscriptTableBlockView {
      let view = TranscriptTableBlockView.make(environment: style.environment)
      view.sizeChanged = { [weak self] in self?.invalidateIntrinsicContentSize() }
      addSubview(view)
      return view
    }

    func makeAccessoryView() -> TranscriptTableAccessoryView {
      let view = TranscriptTableAccessoryView.make(environment: style.environment)
      view.sizeChanged = { [weak self] in self?.invalidateIntrinsicContentSize() }
      view.action = { [weak self] in self?.togglePrompt() }
      addSubview(view)
      return view
    }
  }
#endif
