#if os(macOS)
  import AppKit
  import SwiftUI

  /// A part of a settled message beside its text that SwiftUI draws, hosted on its own in a
  /// text cell as the message row draws it.
  enum TranscriptTableAccessory: Hashable {
    /// The message's attachments: uploaded images inline, everything else as chips.
    case attachments([Attachment])
  }

  /// One accessory at the width its stack offers it, sized as that stack sizes it: as wide as
  /// it lays out there, and as tall.
  struct TranscriptTableAccessoryRoot: View {
    var accessory: TranscriptTableAccessory?
    /// The message it belongs to; a view reused for another message starts its state afresh.
    var rowID: String
    var width: CGFloat
    let environment: TranscriptTableEnvironment

    var body: some View {
      let values = environment.values
      TranscriptTableOfferedWidth(width: max(0, width)) {
        switch accessory {
        case .attachments(let attachments): AttachmentStrip(attachments: attachments)
        case nil: EmptyView()
        }
      }
      .id(rowID)
      .transformEnvironment(\.self) { own in
        if let values { own = values }
      }
    }
  }

  /// Offers its content `width` and takes the size the content asks for there, as a stack
  /// sizes a child it offers its width: a strip of chips is as wide as its widest line.
  struct TranscriptTableOfferedWidth: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      guard let content = subviews.first else { return .zero }
      let size = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
      return CGSize(width: min(width, size.width), height: size.height)
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      subviews.first?.place(
        at: bounds.origin, anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
  }

  /// The hosting view for one accessory of a text cell's message.
  final class TranscriptTableAccessoryView: TranscriptTablePieceView<TranscriptTableAccessoryRoot> {
    static func make(environment: TranscriptTableEnvironment) -> TranscriptTableAccessoryView {
      let view = TranscriptTableAccessoryView(
        rootView: TranscriptTableAccessoryRoot(
          accessory: nil, rowID: "", width: 0, environment: environment))
      view.configure()
      return view
    }

    var accessory: TranscriptTableAccessory? { rootView.accessory }

    /// Shows message `rowID`'s `accessory` offered `width`, unless it shows it already.
    func show(_ accessory: TranscriptTableAccessory, rowID: String, width: CGFloat) {
      let root = rootView
      guard accessory != root.accessory || rowID != root.rowID || width != root.width else {
        return
      }
      present(
        TranscriptTableAccessoryRoot(
          accessory: accessory, rowID: rowID, width: width, environment: root.environment))
      // What loads as it first shows (an image read from the cache) reports before the cell
      // takes reports; a size that changed by then is reported once it has shown.
      MainRunLoop.performAfterDisplay { [weak self] in
        MainActor.assumeIsolated { self?.reportIfResized() }
      }
    }

    /// The size the cell last laid it out at.
    private var takenSize: CGSize?

    /// Its size at the width it was offered, laid out now if it has to be; the cell lays it
    /// out at this size.
    var idealSize: CGSize {
      let size = intrinsicContentSize
      let rounded = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
      takenSize = rounded
      return rounded
    }

    private func reportIfResized() {
      guard let takenSize else { return }
      let size = intrinsicContentSize
      let rounded = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
      if rounded != takenSize { sizeChanged?() }
    }
  }
#endif
