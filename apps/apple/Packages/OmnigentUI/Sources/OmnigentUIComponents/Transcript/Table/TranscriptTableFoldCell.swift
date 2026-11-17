#if os(macOS)
  import AppKit
  import SwiftUI

  /// Which rows the table transcript draws in AppKit beyond settled messages:
  /// `omnigent:transcript-cells`. `native` (the default) draws Worked folds and an empty header
  /// or footer in AppKit cells; `hosted` keeps them SwiftUI's, as the stack draws them.
  nonisolated enum TranscriptTableCellStyle: String, Sendable {
    case native
    case hosted

    static let key = "omnigent:transcript-cells"

    /// The style this launch's defaults choose.
    static let launchValue = Self(defaults: .standard)

    init(defaults: UserDefaults) {
      self = defaults.string(forKey: Self.key).flatMap(Self.init(rawValue:)) ?? .native
    }

    /// Whether `row` draws in an AppKit cell of its own (a fold, an empty header or footer).
    func drawsNatively(_ row: TranscriptTableRow, isCLI: Bool) -> Bool {
      guard self == .native else { return false }
      switch row.content {
      case .segment(let entry):
        if case .worked = entry.segment { return true }
        return false
      case .header(let header):
        // The header doesn't say which style it is in; the chat's is drawn here.
        return header == TranscriptTableHeader() && !isCLI
      case .footer(let footer):
        return footer == TranscriptTableFooter(isCLI: footer.isCLI)
      case .block:
        return false
      }
    }
  }

  /// The Worked folds and long prompts the reader opened or closed, kept in the transcript's
  /// ``TranscriptDisclosures``: a fold under ``WorkedFold``'s key, which a fold SwiftUI draws
  /// reads too, and a prompt under its row's id. A row's cell shows other rows once it scrolls
  /// away, so the choice lives with the table.
  @MainActor
  final class TranscriptTableFolds {
    let disclosures: TranscriptDisclosures

    init(disclosures: TranscriptDisclosures = TranscriptDisclosures()) {
      self.disclosures = disclosures
    }

    /// Whether fold `key` is open: as the reader left it, else open while its turn is live.
    func isExpanded(_ key: String, isLive: Bool) -> Bool {
      disclosures.madeChoice(key) ?? isLive
    }

    func setExpanded(_ isExpanded: Bool, for key: String) {
      disclosures.choice(key).isExpanded = isExpanded
    }
  }

  /// A Worked fold drawn in AppKit, as ``WorkedFold`` draws it: its title ("4 steps") and
  /// chevron as a plain button with a hover highlight, the hairline under it, and, while open,
  /// its items, which SwiftUI draws. A closed fold's height is known without a SwiftUI pass.
  final class TranscriptTableFoldCell: NSView, TranscriptTableCell {
    private(set) var shown: TranscriptTableShown?
    private(set) var kind: TranscriptTableCellKind?
    var idealSizeChanged: ((any TranscriptTableCell) -> Void)?

    let style: TranscriptTableTextStyle
    let folds: TranscriptTableFolds
    let button = TranscriptTableFoldButton()
    let divider = TranscriptTableRuleView()
    /// The open fold's items.
    private(set) var itemsView: TranscriptTableFoldItemsView?
    private var fold: Fold?
    private var styleSerial = -1
    private var width: CGFloat = 0
    private var height: CGFloat = 0

    /// A hairline as wide as the column, as SwiftUI's `Divider` draws one.
    static let dividerHeight: CGFloat = 1

    private struct Fold {
      var id: String
      var items: [TranscriptItem]
      var decorations: [String: MessageDecoration]
      var isLive: Bool

      /// Where the reader's choice is kept.
      var key: String { WorkedFold.disclosureKey(items: items) }
    }

    init(style: TranscriptTableTextStyle, folds: TranscriptTableFolds) {
      self.style = style
      self.folds = folds
      super.init(frame: .zero)
      addSubview(button)
      addSubview(divider)
      button.toggled = { [weak self] in self?.toggle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Whether the fold it shows is open.
    var isExpanded: Bool {
      guard let fold else { return false }
      return folds.isExpanded(fold.key, isLive: fold.isLive)
    }

    func show(_ row: TranscriptTableRow, version: Int, width: CGFloat) {
      let next = TranscriptTableShown(id: row.id, version: version, width: width)
      guard next != shown || styleSerial != style.serial else { return }
      guard case .segment(let entry) = row.content,
        case .worked(_, _, let items, let isLive) = entry.segment
      else { return }
      let isRestyle = next == shown
      shown = next
      kind = .native(row.kind)
      styleSerial = style.serial
      self.width = width
      fold = Fold(id: row.id, items: items, decorations: entry.decorations, isLive: isLive)
      button.show(
        title: WorkedFold.title(items: items), identifier: items.first?.id ?? "empty",
        tooltip: entry.duration.map(TurnElapsed.worked), size: style.labelSize,
        hover: style.palette?.hover)
      let previous = height
      height = layOut()
      if isRestyle, abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    var idealHeight: CGFloat { height }

    /// Its height is known at show; an open fold's items report their own changes.
    func settle() {}

    /// Places the button, the hairline and an open fold's items; returns the row's height.
    private func layOut() -> CGFloat {
      guard let fold else { return 0 }
      let metrics = style.metrics(width: width)
      let isExpanded = folds.isExpanded(fold.key, isLive: fold.isLive)
      button.isExpanded = isExpanded
      let size = button.fittingSize
      button.frame = CGRect(x: metrics.columnX, y: 0, width: size.width, height: size.height)
      var bottom = size.height + Theme.Spacing.small
      divider.frame = CGRect(
        x: metrics.columnX, y: bottom, width: metrics.columnWidth, height: Self.dividerHeight)
      bottom += Self.dividerHeight
      if isExpanded {
        let view = itemsView ?? makeItemsView()
        view.show(
          id: fold.id, items: fold.items, decorations: fold.decorations,
          width: metrics.columnWidth)
        bottom += Theme.Spacing.small
        let itemsHeight = view.idealHeight
        view.frame = CGRect(
          x: metrics.columnX, y: bottom, width: metrics.columnWidth, height: itemsHeight)
        bottom += itemsHeight
      } else if let itemsView {
        // A closed fold keeps no SwiftUI view: it draws nothing of its items.
        itemsView.sizeChanged = nil
        itemsView.removeFromSuperview()
        self.itemsView = nil
      }
      return (bottom + Theme.Spacing.row).rounded(.up)
    }

    private func makeItemsView() -> TranscriptTableFoldItemsView {
      let view = TranscriptTableFoldItemsView.make(environment: style.environment)
      itemsView = view
      addSubview(view)
      view.sizeChanged = { [weak self] in self?.itemsSizeChanged() }
      return view
    }

    /// An open fold's items took another height: the cell lays out again and tells the table.
    private func itemsSizeChanged() {
      let previous = height
      height = layOut()
      if abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }

    /// The reader opened or closed the fold.
    private func toggle() {
      guard let fold else { return }
      folds.setExpanded(!isExpanded, for: fold.key)
      let previous = height
      height = layOut()
      if let itemsView { button.reveal(itemsView) }
      if abs(previous - height) >= 0.5 { idealSizeChanged?(self) }
    }
  }

  /// A fold's open content: its items behind a hairline guide, as ``WorkedFold`` shows them.
  struct TranscriptTableFoldItemsRoot: View {
    var id: String?
    var items: [TranscriptItem]
    var decorations: [String: MessageDecoration]
    var width: CGFloat
    let environment: TranscriptTableEnvironment

    var body: some View {
      let values = environment.values
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        ForEach(items) { item in
          TranscriptItemView(item: item, decorations: decorations)
        }
      }
      .padding(.leading, Theme.Spacing.medium)
      .overlay(alignment: .leading) {
        Rectangle().fill(.separator).frame(width: 1)
      }
      // A view reused for another fold starts its items' view state afresh.
      .id(id)
      .frame(width: max(0, width), alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .transformEnvironment(\.self) { own in
        if let values { own = values }
      }
    }
  }

  /// The hosting view for an open fold's items.
  final class TranscriptTableFoldItemsView: TranscriptTablePieceView<TranscriptTableFoldItemsRoot> {
    static func make(environment: TranscriptTableEnvironment) -> TranscriptTableFoldItemsView {
      let view = TranscriptTableFoldItemsView(
        rootView: TranscriptTableFoldItemsRoot(
          id: nil, items: [], decorations: [:], width: 0, environment: environment))
      view.configure()
      return view
    }

    /// Shows fold `id`'s items at `width`, unless it shows them already.
    func show(
      id: String, items: [TranscriptItem], decorations: [String: MessageDecoration],
      width: CGFloat
    ) {
      let root = rootView
      guard
        id != root.id || items != root.items || decorations != root.decorations
          || width != root.width
      else { return }
      present(
        TranscriptTableFoldItemsRoot(
          id: id, items: items, decorations: decorations, width: width,
          environment: root.environment))
    }
  }
#endif
