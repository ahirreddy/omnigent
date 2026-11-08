import SwiftUI

/// The transcript's reading rules and reading anchor, kept outside view state: scroll and
/// geometry callbacks (several a frame while the keyboard, a rotation or a resize moves the
/// transcript) update them without re-rendering it. Not observed.
@MainActor
final class TranscriptScrollState {
  var follow = TranscriptFollow()
  /// Scrolls a row to an anchor; the transcript sets it to its scroll view's proxy.
  var scrollToRow: (String, UnitPoint) -> Void = { _, _ in }
  /// The content heights the transcript recently scrolled to the bottom for.
  var followedHeights = FollowedHeights()
  /// The row under the viewport's middle at the current width, and at the width before it.
  private var anchor: TranscriptReadingAnchor?
  private var anchorBefore: TranscriptReadingAnchor?
  /// A restored anchor waiting for its row's height at the new width.
  private var pending: (anchor: TranscriptReadingAnchor, width: CGFloat)?

  /// Records the row under the viewport's middle, and finishes a pending restore once that
  /// row reports its height at the new width.
  func record(_ sample: TranscriptReadingAnchor) {
    if let anchor, anchor.viewportWidth != sample.viewportWidth { anchorBefore = anchor }
    anchor = sample
    guard let pending, pending.anchor.id == sample.id, pending.width == sample.viewportWidth
    else { return }
    self.pending = nil
    scrollToRow(sample.id, pending.anchor.unitPoint(in: sample))
  }

  /// The row that was under the viewport's middle while it was `width` wide.
  func readingAnchor(atWidth width: CGFloat) -> TranscriptReadingAnchor? {
    [anchor, anchorBefore].lazy.compactMap { $0 }.first { $0.viewportWidth == width }
  }

  /// After a width change, puts what was at the viewport's middle back there: at once with
  /// the row's old proportions, then exactly when the row reports its new height.
  func restoreReading(from oldWidth: CGFloat, to newWidth: CGFloat) {
    #if DEBUG
      LoopProbe.record(
        "transcript width", "\(oldWidth) -> \(newWidth), anchor \(String(describing: anchor))")
    #endif
    guard let before = readingAnchor(atWidth: oldWidth) else { return }
    if let now = anchor, now.id == before.id, now.viewportWidth == newWidth {
      scrollToRow(before.id, before.unitPoint(in: now))
    } else {
      scrollToRow(before.id, UnitPoint(x: 0.5, y: before.fraction))
      pending = (before, newWidth)
    }
  }

  /// Records a scroll geometry change for ``LoopProbe``, in Debug builds, counted for this
  /// transcript alone so several windows changing at once do not add up to a loop.
  func probe(_ name: String, _ detail: @autoclosure () -> String) {
    #if DEBUG
      LoopProbe.record("\(name) \(probeTag)", detail())
    #endif
  }

  /// A short tag for this transcript in loop reports.
  var probeTag: String { String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000) }

  /// A resize that pins the bottom drops a pending restore.
  func cancelRestore() {
    #if DEBUG
      LoopProbe.record("transcript keeps bottom", "anchor \(String(describing: anchor))")
    #endif
    pending = nil
  }
}

/// Content heights a following transcript recently scrolled to the bottom for. After such a
/// scroll the lazy rows above the viewport are estimated again, and in a short viewport the
/// estimate can come back to a height already followed; following it again would repeat every
/// frame. New output reaches a new height, so only a repeat is let go.
nonisolated struct FollowedHeights {
  /// How long a height counts as recently followed after it last came back.
  static let memory: TimeInterval = 2

  private var recent: [(height: CGFloat, at: Date)] = []

  /// Whether growth to `height` should be followed: not when the transcript followed the same
  /// height within ``memory`` seconds. Remembers `height` either way.
  mutating func follows(_ height: CGFloat, at now: Date = Date()) -> Bool {
    recent.removeAll { now.timeIntervalSince($0.at) > Self.memory }
    if let index = recent.firstIndex(where: { abs($0.height - height) < 1 }) {
      recent[index].at = now
      return false
    }
    recent.append((height, now))
    return true
  }
}

/// The row under the transcript viewport's middle and how far down the row that middle is. A
/// resize scrolls that point of the row back to the viewport's middle, so what the reader was
/// looking at stays there however the rows above it reflow.
nonisolated struct TranscriptReadingAnchor: Equatable {
  var id: String
  /// The middle's position in the row, 0 at its top and 1 at its bottom.
  var fraction: Double
  var rowHeight: CGFloat
  var viewportWidth: CGFloat
  var viewportHeight: CGFloat

  /// The anchor for a row of `height` when the viewport (in the row's coordinates) crosses it
  /// at its middle; `nil` otherwise.
  static func sample(id: String, height: CGFloat, viewport: CGRect?) -> Self? {
    guard let viewport, height > 0 else { return nil }
    let middle = viewport.midY
    guard middle >= 0, middle < height else { return nil }
    return Self(
      id: id, fraction: (middle / height * 200).rounded() / 200, rowHeight: height.rounded(),
      viewportWidth: viewport.width.rounded(), viewportHeight: viewport.height.rounded())
  }

  /// The `scrollTo` anchor that puts this anchor's point of the row at the viewport's middle,
  /// given the row and viewport sizes in `layout`. `scrollTo(_:anchor:)` lines up the same unit
  /// point of the row and of the viewport, so the anchor solves
  /// `y * (viewport - row) + fraction * row = viewport / 2`.
  func unitPoint(in layout: Self) -> UnitPoint {
    let row = layout.rowHeight
    let viewport = layout.viewportHeight
    guard abs(viewport - row) >= 1 else { return UnitPoint(x: 0.5, y: fraction) }
    return UnitPoint(x: 0.5, y: (viewport / 2 - fraction * row) / (viewport - row))
  }
}

extension EnvironmentValues {
  /// The transcript's scroll state, for rows reporting the reading anchor.
  @Entry var transcriptScrollState: TranscriptScrollState?
}

extension View {
  /// Reports this transcript row as the reading anchor while it crosses the viewport's middle.
  func reportsReadingAnchor(_ id: String) -> some View {
    modifier(ReadingAnchorReporter(id: id))
  }

  /// Records this row's height for ``LoopProbe`` in Debug builds, so a loop names the row.
  @ViewBuilder func probesRowHeight(_ id: String) -> some View {
    #if DEBUG
      modifier(RowHeightProbe(id: id))
    #else
      self
    #endif
  }
}

#if DEBUG
  private struct RowHeightProbe: ViewModifier {
    let id: String
    @Environment(\.transcriptScrollState) private var scroll

    func body(content: Content) -> some View {
      content.onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: { old, new in
        scroll?.probe("transcript row height", "\(id) \(old) -> \(new)")
      }
    }
  }
#endif

private struct ReadingAnchorReporter: ViewModifier {
  let id: String
  @Environment(\.transcriptScrollState) private var scroll

  func body(content: Content) -> some View {
    content.onGeometryChange(for: TranscriptReadingAnchor?.self) { [id] proxy in
      TranscriptReadingAnchor.sample(
        id: id, height: proxy.size.height, viewport: proxy.bounds(of: .scrollView))
    } action: { sample in
      if let sample { scroll?.record(sample) }
    }
  }
}

/// The viewport's width and whether its bottom is near the content's end, compared together so
/// a width change (rotation, split or sidebar resize) knows where the reader was before it.
nonisolated struct TranscriptViewport: Equatable {
  var width: CGFloat
  var isNearBottom: Bool

  /// How close to the content's end, in points, counts as the bottom.
  static let bottomReach: CGFloat = 80

  /// The viewport of `geometry`; the composer and dock inset the bottom, and rows under them
  /// are not being read.
  init(_ geometry: ScrollGeometry) {
    self.init(
      width: geometry.containerSize.width,
      visibleBottom: geometry.visibleRect.maxY - geometry.contentInsets.bottom,
      contentHeight: geometry.contentSize.height)
  }

  init(width: CGFloat, visibleBottom: CGFloat, contentHeight: CGFloat) {
    self.width = width.rounded()
    isNearBottom = visibleBottom >= contentHeight - Self.bottomReach
  }

  /// Whether the change from `old` resized a viewport that was at the bottom, which must
  /// stay there once the rows lay out at the new width.
  func keepsBottom(after old: Self) -> Bool {
    old.width > 0 && old.width != width && old.isNearBottom
  }
}

/// "Jump to latest", with a dot when output arrived while the user was reading.
struct JumpToLatestPill: View {
  let pill: TranscriptFollow.Pill
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.small) {
        if pill.hasUnseenOutput {
          Circle().fill(Theme.running).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        Label(pill.title, systemImage: "arrow.down")
      }
      .font(Theme.Typography.label)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .frame(minHeight: Theme.Control.target)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassSurface(in: Capsule(), isInteractive: true)
    .glassTransition()
    .accessibilityLabel("Jump to latest message")
    .accessibilityValue(pill.hasUnseenOutput ? "New output" : "")
    .accessibilityIdentifier("jump-to-latest")
  }
}
