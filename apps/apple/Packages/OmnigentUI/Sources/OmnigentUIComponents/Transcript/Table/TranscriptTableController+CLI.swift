#if os(macOS)
  import AppKit
  import SwiftUI

  /// What the table keeps for CLI text cells: their style, each row's CLI text by content
  /// version, and the texts handed to the prewarm.
  @MainActor
  final class TranscriptTableCLIState {
    let style: TranscriptTableCLIStyle
    /// The tool work the reader opened, closed or collapsed.
    let expansions = CLIWorkExpansions()
    /// Each row's CLI text, `nil` for a row hosted in SwiftUI.
    var texts: [String: Known] = [:]

    /// A row's CLI text, for its content version and the work opened when it was worked out.
    struct Known {
      var version: Int
      var opened: Int
      var text: TranscriptTableCLIText?
    }
    /// Texts handed to the prewarm, by row id and version.
    var prewarmed: [String: Int] = [:]
    /// Texts offered to the prewarm to lay out while the reader is still, by row id and version.
    var offered: [String: Int] = [:]
    /// The text idle measuring waits for the prewarm to lay out, and since when.
    var awaited: (id: String, since: CFTimeInterval)?
    /// The specs of the texts idle measuring waits for, by their prewarm keys.
    var awaitedSpecs: [String: CLITextSpec] = [:]

    init(environment: TranscriptTableEnvironment, textStyle: TranscriptTableTextStyle) {
      style = TranscriptTableCLIStyle(environment: environment, textStyle: textStyle)
    }

    /// Forgets what each row drew as, after the style changed.
    func forget() {
      texts = [:]
      prewarmed = [:]
      offered = [:]
    }
  }

  extension TranscriptTableController {
    /// The CLI text row `index` shows, or `nil` when the row stays hosted in SwiftUI; worked
    /// out once per content version.
    func cliText(at index: Int) -> TranscriptTableCLIText? {
      guard isCLI, cli.style.isEnabled else { return nil }
      let row = model.rows[index]
      let version = model.version(at: index)
      let opened = cli.expansions.serial
      if let known = cli.texts[row.id], known.version == version, known.opened == opened {
        return known.text
      }
      let text = cli.style.text.flatMap {
        TranscriptTableCLIText.make(
          row, rendering: cli.style.rendering, palette: $0.palette, expansions: cli.expansions)
      }
      cli.texts[row.id] = TranscriptTableCLIState.Known(
        version: version, opened: opened, text: text)
      return text
    }

    /// CLI row `index`'s height far from view, from its built document, with no views; `nil`
    /// for a row that isn't CLI text.
    func cliMeasuredHeight(at index: Int) -> CGFloat? {
      guard let text = cliText(at: index) else { return nil }
      return TranscriptTableCLICell.measuredHeight(of: text, style: cli.style, width: model.width)
    }

    /// Hands the CLI texts in `rect` to the prewarm, each once per version, at its place, so
    /// they lay out and draw off the main thread before they scroll in, nearest the reader
    /// first.
    func prewarmCLI(in rect: NSRect, upward: Bool) {
      guard cli.style.isEnabled, tableView.numberOfRows > 0 else { return }
      let range = tableView.rows(in: rect)
      guard range.length > 0 else { return }
      var indexes = Array(range.location..<(range.location + range.length))
      if upward { indexes.reverse() }
      var specs: [CLITextSpec] = []
      var positions: [Double] = []
      for index in indexes where model.rows.indices.contains(index) {
        let id = model.rows[index].id
        let version = model.version(at: index)
        guard cli.prewarmed[id] != version, let text = cliText(at: index) else { continue }
        cli.prewarmed[id] = version
        specs.append(text.spec)
        positions.append(Double(tableView.rect(ofRow: index).midY))
      }
      CLITextPrewarm.shared.prioritize(specs, at: positions)
    }

    /// While the reader is still, offers the prewarm the CLI texts in `rect` not built yet,
    /// nearest `position` first, for a couple of milliseconds a pass: they lay out behind those
    /// asked for ahead, so a scroll later finds them built.
    func offerCLI(in rect: NSRect, around position: CGFloat) {
      guard isCLI, cli.style.isEnabled, CLITextPrewarm.shared.context != nil,
        tableView.numberOfRows > 0
      else { return }
      let range = tableView.rows(in: rect)
      guard range.length > 0 else { return }
      let center = max(range.location, tableView.row(at: NSPoint(x: 1, y: position)))
      let indexes = (range.location..<(range.location + range.length)).sorted {
        abs($0 - center) < abs($1 - center)
      }
      let width = cli.style.column(width: model.width).width
      let deadline = CACurrentMediaTime() + Self.offerBudget
      var specs: [CLITextSpec] = []
      for index in indexes where model.rows.indices.contains(index) {
        guard CACurrentMediaTime() < deadline else { break }
        let id = model.rows[index].id
        let version = model.version(at: index)
        guard cli.offered[id] != version else { continue }
        cli.offered[id] = version
        guard let text = cliText(at: index),
          cli.style.builtDocument(for: text.spec, width: width) == nil
        else { continue }
        specs.append(text.spec)
      }
      CLITextPrewarm.shared.offer(specs)
    }

    /// The main thread time one idle pass may spend offering CLI texts.
    static let offerBudget: CFTimeInterval = 0.002

    /// The prewarm key of CLI row `index` when the prewarm lays it out and it is not built
    /// yet: idle measuring leaves it to the prewarm rather than build it here, for a while.
    func cliLaidOutAhead(at index: Int) -> String? {
      guard let context = CLITextPrewarm.shared.context, let text = cliText(at: index) else {
        return nil
      }
      let column = cli.style.column(width: model.width)
      guard context.width == column.width,
        cli.style.builtDocument(for: text.spec, width: column.width) == nil
      else {
        cli.awaited = nil
        return nil
      }
      let id = model.rows[index].id
      let now = CACurrentMediaTime()
      if let awaited = cli.awaited, awaited.id == id {
        guard now - awaited.since < Self.prewarmPatience else { return nil }
      } else {
        cli.awaited = (id, now)
      }
      let key = text.spec.key
      cli.awaitedSpecs[key] = text.spec
      return key
    }

    /// Tells the prewarms where the reader is and which way they scroll.
    func focusPrewarms(at position: Double, direction: Int) {
      for prewarm in [MessageTextPrewarm.shared, .prompts] {
        prewarm.focus(at: position, direction: direction)
      }
      CLITextPrewarm.shared.focus(at: position, direction: direction)
    }

    /// Asks the prewarm for the texts idle measuring waits for, at their places.
    func prioritizeAwaited(_ texts: [String], at positions: [Double]) {
      guard isCLI else {
        MessageTextPrewarm.shared.prioritize(texts, at: positions)
        return
      }
      var specs: [CLITextSpec] = []
      var places: [Double] = []
      for (key, position) in zip(texts, positions) {
        guard let spec = cli.awaitedSpecs[key] else { continue }
        specs.append(spec)
        places.append(position)
      }
      cli.awaitedSpecs = [:]
      CLITextPrewarm.shared.prioritize(specs, at: places)
    }
  }
#endif
