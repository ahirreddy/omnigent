#if os(macOS)
  import AppKit
  import SwiftUI

  /// How the table transcript's SwiftUI rows are sized: `omnigent:transcript-hosting`.
  /// `autolayout` (the default) hosts each in a hosting view sized by its intrinsic content
  /// size; `fitted` asks a hosting controller for the row's size with no constraints at all, so
  /// the hosting views take no part in the window's constraint pass.
  nonisolated enum TranscriptTableHostingStyle: String, Sendable {
    case autolayout
    case fitted

    static let key = "omnigent:transcript-hosting"

    /// The style this launch's defaults choose.
    static let launchValue = Self(defaults: .standard)

    init(defaults: UserDefaults) {
      self = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) ?? .autolayout
    }
  }

  /// Tells a fitted cell its content's height after each SwiftUI layout.
  @MainActor
  final class TranscriptTableHeightReport {
    var changed: (CGFloat) -> Void = { _ in }
  }

  /// A fitted cell's SwiftUI content: the row at its ideal height, reporting that height.
  struct TranscriptTableFittedRoot: View {
    var row: TranscriptTableRow?
    var width: CGFloat
    let environment: TranscriptTableEnvironment
    let report: TranscriptTableHeightReport

    var body: some View {
      let values = environment.values
      TranscriptTableRowContent(row: row)
        // A reused cell starts the next row's view state afresh.
        .id(row?.id)
        .frame(width: max(0, width))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: { [report] height in
          report.changed(height)
        }
        .transformEnvironment(\.self) { own in
          if let values { own = values }
        }
        // Where a row's views are in its cell, for those that ask the viewport over it.
        .coordinateSpace(.named(TranscriptTableViewport.cellSpace))
    }
  }

  /// A cell hosting a row's SwiftUI view in a hosting controller that makes no constraints:
  /// its height is the controller's fitting size at the cell's width, and its content reports
  /// a later change of height (a group opened, an image loaded) by itself.
  final class TranscriptTableFittedCell: NSView, TranscriptTableCell {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    private let controller: NSHostingController<TranscriptTableFittedRoot>
    private let report = TranscriptTableHeightReport()
    /// The height at the width shown, once measured.
    private var measured: CGFloat?
    /// The new content hasn't been laid out and drawn yet: its first report is no change.
    private var isSettling = false

    init(environment: TranscriptTableEnvironment) {
      controller = NSHostingController(
        rootView: TranscriptTableFittedRoot(
          row: nil, width: 0, environment: environment, report: report))
      controller.sizingOptions = []
      controller.safeAreaRegions = []
      controller.sceneBridgingOptions = []
      super.init(frame: .zero)
      addSubview(controller.view)
      report.changed = { [weak self] height in self?.reported(height) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown else { return }
      shown = next
      kind = .hosted(row.kind)
      measured = nil
      controller.rootView = TranscriptTableFittedRoot(
        row: row, width: width, environment: controller.rootView.environment, report: report)
      settle()
    }

    var idealHeight: CGFloat {
      if let measured { return measured }
      let width = shown?.width ?? 0
      let size = controller.sizeThatFits(
        in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
      let height = size.height.rounded(.up)
      measured = height
      needsLayout = true
      return height
    }

    func settle() {
      guard !isSettling else { return }
      isSettling = true
      MainRunLoop.performAfterDisplay { [weak self] in
        MainActor.assumeIsolated { self?.isSettling = false }
      }
    }

    override func layout() {
      super.layout()
      // The content sits at the top at its own height, whatever the row's is meanwhile.
      let frame = CGRect(x: 0, y: 0, width: bounds.width, height: measured ?? bounds.height)
      if controller.view.frame != frame { controller.view.frame = frame }
    }

    /// The content laid out at `height`: a change after it first showed is told to the table.
    private func reported(_ height: CGFloat) {
      guard !isSettling, let measured, abs(height.rounded(.up) - measured) >= 0.5 else { return }
      self.measured = nil
      idealSizeChanged?(self)
    }
  }
#endif
