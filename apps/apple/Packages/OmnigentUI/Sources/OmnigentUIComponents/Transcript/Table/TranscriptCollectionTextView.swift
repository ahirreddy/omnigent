#if os(iOS)
  import Observation
  import OmnigentPlatform
  import SwiftUI
  import UIKit

  /// A settled message drawn without SwiftUI on iPhone and iPad
  /// (``TranscriptCollectionTextStyle/draws(_:)``): its text as a run drawn ahead
  /// (``MessageTextRunView``), in a prompt's bubble or over an answer's "Worked for" line, laid
  /// out from the run's size. A long press on the text selects it, and the edit menu offers Reply
  /// and Ask in side chat for the selection and the message's own actions; elsewhere a long press
  /// opens the message's context menu, as on its SwiftUI row. VoiceOver reads it as that row,
  /// with the row's actions.
  final class TranscriptCollectionTextView: UIView, TranscriptCollectionRowView {
    let style: TranscriptCollectionTextStyle
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    private(set) var message: TranscriptTableTextMessage?
    private(set) var document: MessageTextDocument?
    private(set) var runView: MessageTextRunView?
    let bubbleView = UIView()
    private(set) var workedLabel: UILabel?
    private(set) var frames: TranscriptCollectionTextFrames?
    /// Told when the row's height changed by itself: its math typeset, a cited path found.
    var sizeChanged: ((TranscriptCollectionTextView) -> Void)?
    /// Told when the drawing at a new width took the place of the old one, at another height.
    var drawingLanded: ((TranscriptCollectionTextView) -> Void)?
    /// Told, with the row's id, when the row can't be drawn as text and is SwiftUI's from now on.
    var cannotDraw: ((String) -> Void)?
    /// Where row `id` is in the transcript, for drawing its run at a new width: the rows
    /// nearest the reader are drawn first.
    var redrawPosition: ((String) -> Double?)?
    /// The width the run is being drawn at off the main thread, while its drawing at the width
    /// it had stands in.
    private(set) var awaitedWidth: CGFloat?
    private var styleSerial = -1
    /// The row shown, to show again once its math is typeset or its links are found.
    private var shownRow: TranscriptTableRow?
    private var typesetting: Task<Void, Never>?
    /// Lists the folders of the workspace paths the shown message cites, while in a window.
    var linkCheck: Task<Void, Never>?
    /// Counts reads of the links' state; only the latest read's change shows the row again.
    var linkWatch = 0
    var flashView: UIView?
    var flashingRowID: String?
    var flashFading: Task<Void, Never>?

    init(style: TranscriptCollectionTextStyle) {
      self.style = style
      super.init(frame: .zero)
      backgroundColor = .clear
      bubbleView.isHidden = true
      bubbleView.isUserInteractionEnabled = false
      bubbleView.layer.cornerRadius = Theme.Radius.bubble
      bubbleView.layer.cornerCurve = .continuous
      addSubview(bubbleView)
      addInteraction(UIContextMenuInteraction(delegate: self))
      isAccessibilityElement = false
      accessibilityContainerType = .semanticGroup
    }

    required init?(coder: NSCoder) { nil }

    var rowView: UIView { self }

    // MARK: Showing

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      let isRestyle = next == shown && styleSerial != style.serial
      guard next != shown || isRestyle || runView?.isReleased == true else { return }
      // Shown again as it was: its drawing comes back from the cache, if it is there.
      if next == shown, !isRestyle, takeBitmapBack() { return }
      guard let message = style.message(for: row, version: version) else {
        releaseContent()
        return
      }
      let isNewRow = next.id != shown?.id || next.version != shown?.version
      let textWidth = style.textWidth(of: message, width: width)
      if isNewRow { runView?.endSelecting() }
      shownRow = row
      self.message = message
      guard let document = style.document(for: message, linked: linkedPaths(of: message)),
        style.canDraw(document, width: textWidth),
        let raster = drawing(
          of: document, width: textWidth, rowID: row.id, standsIn: !isNewRow && !isRestyle),
        raster.size.height * raster.scale <= TranscriptCollectionTextStyle.tallestDrawing
      else {
        style.keepHosted(row.id, version: version)
        releaseContent()
        cannotDraw?(row.id)
        return
      }
      let previous = frames?.height
      shown = next
      kind = .text(row.kind)
      styleSerial = style.serial
      if isNewRow { restartLinkCheck() }
      if let run = message.runs.first, let ramp = style.style?.ramp {
        let soFar = TranscriptCollectionTextStyle.typesetMath(run.inlineMath, ramp: ramp)
        typeset(run.inlineMath.filter { soFar[$0] == nil }, ramp: ramp, for: next)
      }
      adopt(document, raster: raster)
      layOut(message, document: document, raster: raster, width: width)
      accessibilityIdentifier = "message-\(message.row.id)"
      accessibilityLabel = message.speaker
      runView?.accessibilityIdentifier =
        message.role == .answer ? "message-text-\(message.row.id)" : nil
      showFlash(style.environment.values?.transcriptFocus?.flashedRowID)
      if isRestyle, let previous, abs(previous - (frames?.height ?? 0)) >= 0.5 {
        sizeChanged?(self)
      }
    }

    /// Shows `document` drawn as `raster`: in the run view that shows it already, else a new
    /// one.
    private func adopt(_ document: MessageTextDocument, raster: MessageTextRaster) {
      if let runView, document === self.document {
        if raster !== runView.raster { runView.show(raster) }
        return
      }
      runView?.endSelecting()
      runView?.removeFromSuperview()
      self.document = document
      let view = MessageTextRunView(run: document.run, raster: raster)
      view.chrome = document.chrome
      view.openURL = { [weak self] url in self?.openLink(url) }
      view.selectionActions = { [weak self] in self?.selectionMenu(for: $0) ?? [] }
      view.accessibilityActions = { [weak self] in self?.messageAccessibilityActions() ?? [] }
      view.makeChrome = { [weak self, weak document] block in
        guard let self, let chrome = document?.chrome[block] else { return nil }
        return self.makeChrome(chrome)
      }
      view.refreshChrome()
      addSubview(view)
      runView = view
    }

    /// A block's controls over the drawing: a code block's Download and Copy, a table's row.
    private func makeChrome(_ chrome: MessageTextChrome) -> UIView? {
      switch chrome {
      case .code(let code, let language):
        guard let palette = style.palette else { return nil }
        return MessageTextCodeControls(code: code, language: language, palette: palette)
      case .table(let table):
        return MessageTextTableControls.make(table: table, environment: style.environment.values)
      }
    }

    /// Places the run, the bubble and the "Worked for" line where the frames say.
    private func layOut(
      _ message: TranscriptTableTextMessage, document: MessageTextDocument,
      raster: MessageTextRaster, width: CGFloat
    ) {
      let drawn = style.runSize(
        raster.size, of: document, role: message.role, textWidth: raster.width)
      // A drawing standing in at a narrower width shrinks to fit until its own lands.
      let fit = min(1, style.textWidth(of: message, width: width) / max(1, raster.width))
      let size = CGSize(width: drawn.width * fit, height: drawn.height * fit)
      let frames = style.frames(of: message, runSize: size, width: width)
      self.frames = frames
      if let runView {
        // The run view is as wide as its drawing, so a selection lays the text out as drawn;
        // touches past a prompt's text pass to the bubble.
        let origin = frames.run.origin
        runView.transform = .identity
        runView.frame = CGRect(
          origin: origin, size: CGSize(width: raster.width, height: drawn.height))
        if fit < 1 {
          runView.transform = CGAffineTransform(scaleX: fit, y: fit)
          runView.center = CGPoint(
            x: origin.x + raster.width * fit / 2, y: origin.y + drawn.height * fit / 2)
        }
        runView.touchWidth = message.role == .user ? drawn.width : nil
      }
      if let bubble = frames.bubble {
        bubbleView.frame = bubble
        bubbleView.backgroundColor = style.bubble
        bubbleView.isHidden = false
      } else {
        bubbleView.isHidden = true
      }
      if let workedFor = message.decoration.workedFor, let frame = frames.worked {
        let label = workedLabel ?? makeWorkedLabel()
        label.font = style.captionFont
        label.text = TurnElapsed.worked(workedFor)
        label.frame = frame
        label.accessibilityCustomActions = messageAccessibilityActions()
        label.isHidden = false
      } else {
        workedLabel?.isHidden = true
      }
      if flashingRowID != nil { flashView?.frame = flashFrame }
    }

    private func makeWorkedLabel() -> UILabel {
      let label = UILabel()
      label.textColor = .secondaryLabel
      label.accessibilityIdentifier = "worked-for"
      addSubview(label)
      workedLabel = label
      return label
    }

    func idealHeight(at width: CGFloat) -> CGFloat { frames?.height ?? 0 }

    /// Shows the row again as if it were new: its math typeset or its links found since.
    func showAgain() {
      guard let shown, let row = shownRow else { return }
      let previous = frames?.height ?? 0
      self.shown = nil
      show(row, version: shown.version, width: shown.width)
      if self.shown != nil, abs(previous - (frames?.height ?? 0)) >= 0.5 { sizeChanged?(self) }
    }

    /// Lets go of what the row shows.
    func releaseContent() {
      typesetting?.cancel()
      typesetting = nil
      stopLinkCheck()
      endFlash()
      runView?.endSelecting()
      runView?.removeFromSuperview()
      runView = nil
      document = nil
      awaitedWidth = nil
      message = nil
      shown = nil
      shownRow = nil
      frames = nil
      bubbleView.isHidden = true
      workedLabel?.isHidden = true
    }

    /// Off screen, the drawing's bitmap goes; the rasters' cache keeps it under its budget.
    func didLeaveScreen() {
      runView?.releaseBitmap()
      endFlash()
    }

    /// Takes the drawing's bitmap back from the rasters' cache.
    /// - Returns: Whether the run shows its drawing again.
    private func takeBitmapBack() -> Bool {
      guard let runView, let document else { return false }
      guard runView.isReleased else { return true }
      let key = MessageTextRasterKey(
        document: document.serial, width: runView.raster.width, scale: runView.raster.scale)
      guard let raster = MessageTextRasters.shared.raster(for: key) else { return false }
      runView.show(raster)
      return true
    }

    /// Typesets `math` the shown message doesn't have yet, then shows it again with it; math
    /// KaTeX rejects keeps its Unicode form, as in the SwiftUI markdown.
    private func typeset(_ math: [String], ramp: TypeRamp, for shown: TranscriptTableShown) {
      typesetting?.cancel()
      typesetting = nil
      guard !math.isEmpty else { return }
      typesetting = Task { [weak self] in
        var typeset = false
        for tex in math {
          let request = TranscriptCollectionTextStyle.mathRequest(tex, ramp: ramp)
          do {
            let image = try await RichBlockRenderer.shared.render(request)
            MessageTextTypesetMath.shared.store(image, for: request)
            typeset = true
          } catch is CancellationError {
            return
          } catch {
            continue
          }
        }
        guard typeset, !Task.isCancelled, let self, self.shown == shown else { return }
        self.showAgain()
      }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil { stopLinkCheck() } else { startLinkCheck() }
    }
  }

  extension TranscriptCollectionTextView {
    // MARK: Drawings at a new width

    /// `document`'s drawing `width` wide: the one kept or shown, else, for the run this view
    /// shows at another width (`standsIn`), its drawing there while the new one is drawn off
    /// the main thread, else one drawn now.
    private func drawing(
      of document: MessageTextDocument, width: CGFloat, rowID: String, standsIn: Bool
    ) -> MessageTextRaster? {
      if let kept = style.keptRaster(for: document, width: width) {
        awaitedWidth = nil
        return kept
      }
      if document === self.document, let own = standInDrawing() {
        if abs(own.width - width) < 0.5 {
          awaitedWidth = nil
          return own
        }
        if standsIn,
          style.redraw(
            document, width: width, at: redrawPosition?(rowID) ?? 0,
            landed: { [weak self, serial = document.serial] raster in
              self?.redrawLanded(raster, serial: serial)
            })
        {
          awaitedWidth = width
          return own
        }
      }
      awaitedWidth = nil
      return style.raster(for: document, width: width)
    }

    /// The drawing the run view shows, or showed before it let its bitmap go, if the rasters'
    /// cache still has it.
    private func standInDrawing() -> MessageTextRaster? {
      guard let runView, let document else { return nil }
      guard runView.isReleased else { return runView.raster }
      let key = MessageTextRasterKey(
        document: document.serial, width: runView.raster.width, scale: runView.raster.scale)
      return MessageTextRasters.shared.raster(for: key)
    }

    /// The run's drawing at the width it waited for landed: it takes the old one's place, and
    /// the row's height follows it.
    private func redrawLanded(_ raster: MessageTextRaster, serial: UInt64) {
      guard let awaitedWidth, abs(raster.width - awaitedWidth) < 0.5, let document,
        document.serial == serial, let message, let shown
      else { return }
      self.awaitedWidth = nil
      guard raster.size.height * raster.scale <= TranscriptCollectionTextStyle.tallestDrawing
      else {
        style.keepHosted(shown.id, version: shown.version)
        releaseContent()
        cannotDraw?(shown.id)
        return
      }
      let previous = frames?.height ?? 0
      adopt(document, raster: raster)
      layOut(message, document: document, raster: raster, width: shown.width)
      if window == nil { runView?.releaseBitmap() }
      if abs(previous - (frames?.height ?? 0)) >= 0.5 { drawingLanded?(self) }
    }
  }
#endif
