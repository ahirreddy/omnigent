#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  /// A window as drawn, read a point at a time, in points from the top left of its host.
  @MainActor
  struct Snapshot {
    let bitmap: NSBitmapImageRep
    let scale: CGFloat

    init(_ screen: OffscreenWindow<some View>) throws {
      let host = screen.host
      bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
    }

    /// Whether `point` draws in another color than `background`.
    func inks(_ point: CGPoint, against background: CGPoint) -> Bool {
      guard let ink = color(point), let blank = color(background) else { return false }
      return Self.differs(ink, blank)
    }

    /// The first point along the height `line` from `start` that draws in another color than
    /// `background`.
    func firstInk(
      from start: CGFloat, to end: CGFloat, along line: CGFloat, against background: CGPoint
    ) -> CGFloat? {
      stride(from: start, to: end, by: 0.5).first {
        inks(CGPoint(x: $0, y: line), against: background)
      }
    }

    /// The runs of columns from `start` to `end`, leading to trailing, where a pixel within the
    /// heights `band` differs from the most common color there: the background, or a row's fill.
    /// Each run ends where the first blank column starts.
    func inkRuns(from start: CGFloat, to end: CGFloat, band: ClosedRange<CGFloat>)
      -> [ClosedRange<CGFloat>]
    {
      let pixel = 1 / scale
      let columns = Array(stride(from: (start * scale).rounded(.down) * pixel, to: end, by: pixel))
      let heights = Array(stride(from: band.lowerBound, through: band.upperBound, by: pixel))
      let grid = columns.map { column in
        heights.compactMap { color(CGPoint(x: column, y: $0)) }
      }
      var counts: [UInt32: (count: Int, color: NSColor)] = [:]
      for color in grid.joined() {
        let key = Self.key(color)
        counts[key] = ((counts[key]?.count ?? 0) + 1, color)
      }
      guard let background = counts.values.max(by: { $0.count < $1.count })?.color else {
        return []
      }
      var runs: [ClosedRange<CGFloat>] = []
      var runStart: CGFloat?
      for (column, colors) in zip(columns, grid) {
        let inked = colors.contains { Self.differs($0, background) }
        if inked, runStart == nil { runStart = column }
        if !inked, let first = runStart {
          runs.append(first...column)
          runStart = nil
        }
      }
      if let first = runStart { runs.append(first...end) }
      return runs
    }

    private func color(_ point: CGPoint) -> NSColor? {
      bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
    }

    private static func differs(_ ink: NSColor, _ blank: NSColor) -> Bool {
      let difference = max(
        abs(ink.redComponent - blank.redComponent), abs(ink.greenComponent - blank.greenComponent),
        abs(ink.blueComponent - blank.blueComponent))
      return difference > 0.06
    }

    /// A color in 5 bits a channel, so near-equal colors count as one.
    private static func key(_ color: NSColor) -> UInt32 {
      let channel = { (value: CGFloat) in UInt32(min(max(value, 0), 1) * 31) }
      return channel(color.redComponent) << 10 | channel(color.greenComponent) << 5
        | channel(color.blueComponent)
    }
  }

  /// A sidebar row as drawn: where it is, and what draws across its icon's height.
  struct DrawnRow {
    /// The whole list row.
    let frame: CGRect
    /// The marks within 8 points of the row's middle, leading to trailing.
    let marks: [ClosedRange<CGFloat>]

    /// The row's icon, a session's harness mark or a folder: its first mark wider than 13
    /// points, past a chevron or a connector's turn, which are narrower.
    var icon: ClosedRange<CGFloat>? {
      marks.first { $0.upperBound - $0.lowerBound > 13 }
    }

    /// Where the title starts: the first mark after the icon.
    var title: CGFloat? {
      guard let icon else { return nil }
      return marks.first { $0.lowerBound >= icon.upperBound + 2 }?.lowerBound
    }

    /// The marks before the icon: a chevron, or a connector's turn.
    var lead: [ClosedRange<CGFloat>] {
      guard let icon else { return marks }
      return marks.filter { $0.upperBound <= icon.lowerBound }
    }
  }

  extension OffscreenWindow {
    /// The list rows holding the elements `identifiers` name, as `picture` draws them from
    /// `start` to `end`. A row whose content is its only element reports its whole cell as that
    /// element's frame, so the row's icon and title are found by their ink, not by frame.
    func drawnRows(
      _ identifiers: [String], in picture: Snapshot, from start: CGFloat = 14,
      to end: CGFloat = 160
    ) throws -> [String: DrawnRow] {
      let list = try #require(list)
      let frames = try withAccessibilityTree {
        try identifiers.map { ($0, try listElementFrame($0)) }
      }
      var rows: [String: DrawnRow] = [:]
      for (identifier, element) in frames {
        let index = list.row(
          at: list.convert(CGPoint(x: element.midX, y: element.midY), from: host))
        rows[identifier] = try drawnRow(
          try #require(index >= 0 ? index : nil), in: picture, from: start, to: end)
      }
      return rows
    }

    /// The list's row `index` as `picture` draws it from `start` to `end`, found without the
    /// accessibility tree, so a window's first drawing can be read before anything else runs.
    func drawnRow(
      _ index: Int, in picture: Snapshot, from start: CGFloat = 14, to end: CGFloat = 160
    ) throws -> DrawnRow {
      let list = try #require(list)
      let frame = list.convert(list.rect(ofRow: index), to: host)
      let marks = picture.inkRuns(from: start, to: end, band: (frame.midY - 8)...(frame.midY + 8))
      return DrawnRow(frame: frame, marks: marks)
    }
  }
#endif
