import SwiftUI

/// A link's place in a text, as a layout numbers characters: by UTF-16 unit from the start of
/// each paragraph, where a line break ends a paragraph and is not counted.
/// ``LinkGeometry/spans(in:)`` finds them.
nonisolated struct LinkSpan: Hashable, Sendable {
  var paragraph: Int
  var range: Range<Int>
}

/// Where a laid-out text's links are, for the pointing hand the Mac shows over them.
nonisolated enum LinkGeometry {
  /// Each link in `text`, in order. Text with no link is read through its link runs alone,
  /// never its characters.
  static func spans(in text: AttributedString) -> [LinkSpan] {
    var counter = SpanCounter()
    var position = text.startIndex
    for (link, range) in text.runs[\.link] where link != nil {
      counter.count(text.utf16[position..<range.lowerBound], isLinked: false)
      counter.count(text.utf16[range], isLinked: true)
      position = range.upperBound
    }
    return counter.spans
  }

  /// As ``spans(in:)`` for a text drawn with one image in place of each run `isImage` accepts:
  /// a layout numbers an image as one character.
  static func spans(
    in text: AttributedString, imageRuns isImage: (AttributedString.Runs.Run) -> Bool
  ) -> [LinkSpan] {
    var counter = SpanCounter()
    for run in text.runs {
      if isImage(run) {
        counter.countImage(isLinked: run.link != nil)
      } else {
        counter.count(text.utf16[run.range], isLinked: run.link != nil)
      }
    }
    return counter.spans
  }

  /// Counts a text's characters paragraph by paragraph, keeping the linked stretches.
  private struct SpanCounter {
    var spans: [LinkSpan] = []
    private var paragraph = 0
    private var offset = 0
    private var followsReturn = false

    mutating func count(_ units: AttributedString.UTF16View, isLinked: Bool) {
      var start = offset
      for unit in units {
        // A line feed, a carriage return, the two together, or a paragraph separator.
        let isBreak = unit == 0x0A || unit == 0x0D || unit == 0x2029
        if isBreak, !(unit == 0x0A && followsReturn) {
          if isLinked { keep(start..<offset) }
          paragraph += 1
          offset = 0
          start = 0
        } else if !isBreak {
          offset += 1
        }
        followsReturn = unit == 0x0D
      }
      if isLinked { keep(start..<offset) }
    }

    mutating func countImage(isLinked: Bool) {
      if isLinked { keep(offset..<offset + 1) }
      offset += 1
      followsReturn = false
    }

    /// Stretches that touch are one: a link styled in pieces, or two links with nothing between.
    private mutating func keep(_ range: Range<Int>) {
      guard !range.isEmpty else { return }
      if let last = spans.last, last.paragraph == paragraph,
        last.range.upperBound == range.lowerBound
      {
        spans[spans.count - 1].range = last.range.lowerBound..<range.upperBound
      } else {
        spans.append(LinkSpan(paragraph: paragraph, range: range))
      }
    }
  }

  /// The paragraph of each laid-out line, from the lowest and highest character its glyphs draw
  /// (`nil` for an empty line). Each paragraph is numbered from zero, so a line that does not
  /// go on from the one above it starts a paragraph.
  static func paragraphs<Index: Comparable>(ofLines lines: [ClosedRange<Index>?]) -> [Int] {
    var paragraphs: [Int] = []
    var above: ClosedRange<Index>?
    for (number, line) in lines.enumerated() {
      let goesOn = line.flatMap { line in above.map { line.lowerBound > $0.upperBound } } ?? false
      paragraphs.append(number == 0 ? 0 : paragraphs[number - 1] + (goesOn ? 0 : 1))
      above = line
    }
    return paragraphs
  }

  /// The glyphs of one laid-out run that draw a link, as ranges of positions in `characters`:
  /// the UTF-16 offset each glyph starts at, rising or (right to left) falling.
  static func linkedPositions(in characters: [Int], links: [Range<Int>]) -> [Range<Int>] {
    guard let first = characters.first, let last = characters.last else { return [] }
    let span = min(first, last)...max(first, last)
    let near = links.filter { $0.overlaps(span) }
    guard !near.isEmpty else { return [] }
    var found: [Range<Int>] = []
    var start: Int?
    for (position, character) in characters.enumerated() {
      let isLinked = near.contains { $0.contains(character) }
      if isLinked, start == nil { start = position }
      if !isLinked, let begun = start {
        found.append(begun..<position)
        start = nil
      }
    }
    if let begun = start { found.append(begun..<characters.count) }
    return found
  }

  /// One line's link rectangles from left to right, with those that touch made one.
  static func joined(_ rects: [CGRect]) -> [CGRect] {
    var joined: [CGRect] = []
    for rect in rects.sorted(by: { $0.minX < $1.minX }) {
      if let last = joined.last, rect.minX - last.maxX < 1 {
        joined[joined.count - 1] = last.union(rect)
      } else {
        joined.append(rect)
      }
    }
    return joined
  }

  /// The rectangle of each link on each line of `layout`, in the layout's own coordinates.
  static func rects(of links: [LinkSpan], in layout: Text.Layout) -> [CGRect] {
    let glyphs = layout.map { line in line.map(\.characterIndices) }
    let extents = glyphs.map { runs -> ClosedRange<Text.Layout.CharacterIndex>? in
      let all = runs.joined()
      guard let lowest = all.min(), let highest = all.max() else { return nil }
      return lowest...highest
    }
    let lineParagraphs = paragraphs(ofLines: extents)
    var rects: [CGRect] = []
    var start: Text.Layout.CharacterIndex?
    for (number, line) in layout.enumerated() {
      // A paragraph's first line holds its first character.
      if number == 0 || lineParagraphs[number] != lineParagraphs[number - 1] {
        start = extents[number]?.lowerBound
      }
      let ranges = links.filter { $0.paragraph == lineParagraphs[number] }.map(\.range)
      guard let start, !ranges.isEmpty else { continue }
      var onLine: [CGRect] = []
      for (run, indices) in zip(line, glyphs[number]) {
        let characters = indices.map { start.distance(to: $0) }
        for positions in linkedPositions(in: characters, links: ranges) {
          onLine.append(run[positions].typographicBounds.rect)
        }
      }
      rects.append(contentsOf: joined(onLine))
    }
    return rects
  }
}
