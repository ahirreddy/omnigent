#if os(iOS)
  import SwiftUI
  import UIKit

  /// One row in a collection cell: the table's row content at the list's width, at the top of a
  /// cell that may still have its last height, in the transcript's environment. It reports the
  /// height SwiftUI lays the row out at, which changes on its own when a fold opens or an image
  /// arrives.
  struct TranscriptCollectionRowRoot: View {
    var row: TranscriptTableRow?
    var width: CGFloat
    let environment: TranscriptTableEnvironment
    let heightChanged: (CGFloat) -> Void

    var body: some View {
      let values = environment.values
      TranscriptTableRowContent(row: row)
        // A reused host starts the next row's view state afresh.
        .id(row?.id)
        .frame(width: max(0, width))
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          heightChanged($0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The list insets the rows itself.
        .ignoresSafeArea()
        .transformEnvironment(\.self) { own in
          if let values { own = values }
        }
    }
  }

  /// What a collection cell shows a row in, apart from the cells: a row measured ahead of the
  /// scroll, or shown before, keeps its content when a cell takes it
  /// (``TranscriptTableCellPool``). A row is hosted in SwiftUI (``TranscriptCollectionRowHost``)
  /// or, for a settled message, drawn as text (``TranscriptCollectionTextView``).
  @MainActor
  protocol TranscriptCollectionRowView: AnyObject {
    var rowView: UIView { get }
    var shown: TranscriptTableShown? { get }
    var kind: TranscriptTableCellKind? { get }
    /// Shows `row`, unless it shows that version of it at `width` already.
    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat)
    /// The row's height at `width`, laid out now if it has to be.
    func idealHeight(at width: CGFloat) -> CGFloat
    /// The row left the screen: what it can make again when it comes back goes.
    func didLeaveScreen()
  }

  extension TranscriptCollectionRowView {
    var shownID: String? { shown?.id }
  }

  /// A row's hosting view. The view is a `UIHostingConfiguration`'s.
  @MainActor
  final class TranscriptCollectionRowHost: TranscriptCollectionRowView {
    typealias Configuration = UIHostingConfiguration<TranscriptCollectionRowRoot, EmptyView>

    let view: any UIView & UIContentView
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    /// Told the height SwiftUI laid the row out at, each time it changes.
    var heightChanged: ((TranscriptCollectionRowHost, CGFloat) -> Void)?
    /// Times the row was measured again for what SwiftUI laid it out at, since it was shown.
    var remeasures = 0
    private let environment: TranscriptTableEnvironment
    private let relay: HeightRelay

    var rowView: UIView { view }

    init(environment: TranscriptTableEnvironment) {
      self.environment = environment
      let relay = HeightRelay()
      self.relay = relay
      view = Self.configuration(row: nil, width: 0, environment: environment, relay: relay)
        .makeContentView()
      view.backgroundColor = .clear
      relay.host = self
    }

    /// Shows `row`, unless the host shows that version of it at `width` already.
    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown else { return }
      shown = next
      kind = .hosted(row.kind)
      remeasures = 0
      view.configuration = Self.configuration(
        row: row, width: width, environment: environment, relay: relay)
    }

    /// The row's height at `width`, laid out now if it has to be.
    func idealHeight(at width: CGFloat) -> CGFloat {
      let size = view.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
      return size.height.rounded(.up)
    }

    /// SwiftUI keeps the rendered row for when it comes back.
    func didLeaveScreen() {}

    private static func configuration(
      row: TranscriptTableRow?, width: CGFloat, environment: TranscriptTableEnvironment,
      relay: HeightRelay
    ) -> Configuration {
      UIHostingConfiguration {
        TranscriptCollectionRowRoot(
          row: row, width: width, environment: environment,
          heightChanged: { [weak relay] height in relay?.report(height) })
      }
      .margins(.all, 0)
      .minSize(width: 0, height: 0)
    }

    /// Passes SwiftUI's height reports to the host, which the configuration cannot hold itself.
    @MainActor
    private final class HeightRelay {
      weak var host: TranscriptCollectionRowHost?

      func report(_ height: CGFloat) {
        guard let host else { return }
        host.heightChanged?(host, height)
      }
    }
  }

  /// A collection cell: it holds the view of the row it shows, which the controller hands it and
  /// takes back when the row leaves the screen. The model sizes it, not Auto Layout.
  final class TranscriptCollectionCell: UICollectionViewCell {
    private(set) var host: (any TranscriptCollectionRowView)?

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }

    /// Shows `host`'s view, filling the cell.
    func attach(_ host: any TranscriptCollectionRowView) {
      guard host !== self.host else { return }
      _ = detach()
      self.host = host
      host.rowView.frame = contentView.bounds
      host.rowView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      contentView.addSubview(host.rowView)
    }

    /// Takes the host out of the cell.
    /// - Returns: The host it held.
    func detach() -> (any TranscriptCollectionRowView)? {
      guard let host else { return nil }
      if host.rowView.superview === contentView { host.rowView.removeFromSuperview() }
      self.host = nil
      return host
    }

    override func preferredLayoutAttributesFitting(
      _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
      layoutAttributes
    }
  }

  /// One column of rows at the controller's heights (``TranscriptRowOffsets``). Nothing here sizes
  /// a cell or moves the content: the controller does both, keeping the reader's place.
  final class TranscriptCollectionLayout: UICollectionViewLayout {
    weak var owner: TranscriptCollectionController?

    override var collectionViewContentSize: CGSize {
      guard let owner, let collectionView else { return .zero }
      return CGSize(width: collectionView.bounds.width, height: owner.offsets.contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect)
      -> [UICollectionViewLayoutAttributes]
    {
      guard let owner else { return [] }
      return owner.offsets.rows(from: rect.minY, to: rect.maxY).map { attributes(at: $0, owner) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath)
      -> UICollectionViewLayoutAttributes?
    {
      guard let owner, indexPath.section == 0, indexPath.item < owner.offsets.count else {
        return nil
      }
      return attributes(at: indexPath.item, owner)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
      newBounds.size != collectionView?.bounds.size
    }

    /// The content stays where it is: on a new size UIKit proposes an offset that keeps the
    /// viewport's middle, and the controller keeps the reader's row instead.
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint)
      -> CGPoint
    {
      collectionView?.contentOffset ?? proposedContentOffset
    }

    private func attributes(at index: Int, _ owner: TranscriptCollectionController)
      -> UICollectionViewLayoutAttributes
    {
      let attributes = UICollectionViewLayoutAttributes(
        forCellWith: IndexPath(item: index, section: 0))
      attributes.frame = owner.frame(ofRow: index)
      return attributes
    }
  }

  /// The transcript's collection view: before each layout pass, the controller measures the rows
  /// the pass is about to show, and those just beyond in the direction of the scroll, and moves
  /// the content with the reader's row when rows above it change height.
  final class TranscriptCollectionView: UICollectionView {
    weak var owner: TranscriptCollectionController?

    override func layoutSubviews() {
      owner?.willLayout()
      super.layoutSubviews()
    }
  }
#endif
