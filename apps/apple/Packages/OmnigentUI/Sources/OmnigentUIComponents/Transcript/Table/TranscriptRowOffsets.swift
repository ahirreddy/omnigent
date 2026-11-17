import SwiftUI

/// Where each row of a list stacked top to bottom starts: the running sum of the rows' heights.
/// A height change lays out only the rows from it down.
nonisolated struct TranscriptRowOffsets: Equatable, Sendable {
  /// Each row's top, then the content's height.
  private(set) var tops: [CGFloat] = [0]

  var count: Int { tops.count - 1 }

  var isEmpty: Bool { tops.count < 2 }

  var contentHeight: CGFloat { tops[count] }

  /// Lays `count` rows out from scratch.
  mutating func rebuild(count: Int, height: (Int) -> CGFloat) {
    tops = [0]
    tops.reserveCapacity(count + 1)
    for index in 0..<count { tops.append(tops[index] + height(index)) }
  }

  /// Lays the rows from `first` down out again, after their heights changed.
  mutating func update(from first: Int, height: (Int) -> CGFloat) {
    guard first >= 0, first < count else { return }
    for index in first..<count { tops[index + 1] = tops[index] + height(index) }
  }

  func top(of index: Int) -> CGFloat { tops[index] }

  func height(of index: Int) -> CGFloat { tops[index + 1] - tops[index] }

  /// The row under `point`, the first or last row beyond either end; `nil` without rows.
  func row(at point: CGFloat) -> Int? {
    guard !isEmpty else { return nil }
    // The last top at or above `point`.
    var low = 0
    var high = count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if tops[middle] <= point { low = middle } else { high = middle - 1 }
    }
    return low
  }

  /// The rows that reach into `minY..<maxY`, top to bottom.
  func rows(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
    guard !isEmpty, maxY > minY, maxY > 0, minY < contentHeight,
      let first = row(at: minY), let last = row(at: maxY)
    else { return 0..<0 }
    // A row starting exactly at `maxY` does not reach into the range.
    let end = tops[last] < maxY ? last + 1 : last
    return first..<max(first, end)
  }
}

/// What a row's height depends on besides its content and width: the text's size and weight, and
/// the transcript's appearance (style, text sizes, column). A change measures every row again.
struct TranscriptTableMetrics: Equatable {
  var dynamicTypeSize: DynamicTypeSize
  var legibilityWeight: LegibilityWeight?
  var appearance: TranscriptAppearance

  init(_ environment: EnvironmentValues) {
    dynamicTypeSize = environment.dynamicTypeSize
    legibilityWeight = environment.legibilityWeight
    appearance = environment.transcriptAppearance
  }
}
