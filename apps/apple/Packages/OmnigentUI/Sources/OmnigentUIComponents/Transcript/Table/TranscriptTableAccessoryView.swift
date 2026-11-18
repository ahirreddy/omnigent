#if os(macOS) || os(iOS)
  import SwiftUI

  /// A part of a settled message beside its text that SwiftUI draws, hosted on its own in a
  /// text cell as the message row draws it.
  enum TranscriptTableAccessory: Hashable {
    /// The message's attachments: uploaded images inline, everything else as chips.
    case attachments([Attachment])
    /// A prompt's @-mentioned workspace files and folders, as chips above its text.
    case mentions([UserPrompt.Mention])
    /// A long prompt's "Show full prompt" button, or "Collapse prompt" once it shows whole.
    case promptToggle(title: String, collapses: Bool)
    /// "Interrupted": under an answer's text, or under a prompt's bubble.
    case interrupted
    /// A content part this app can't show: one quiet line that opens to any safe text.
    case unsupported(Activity)
    /// "From @sender" over an open message another session sent, with its collapse button.
    case origin(sessionID: String)
    /// A collapsed message from another session: its sender and first line.
    case collapsedOrigin(sessionID: String, preview: String)

    /// Whether its button opens or closes a message from another session, not a long prompt.
    var togglesOrigin: Bool {
      switch self {
      case .origin, .collapsedOrigin: true
      default: false
      }
    }
  }
#endif

#if os(macOS)
  import AppKit
  import SwiftUI

  /// One accessory at the width its stack offers it, sized as that stack sizes it: as wide as
  /// it lays out there, and as tall.
  struct TranscriptTableAccessoryRoot: View {
    var accessory: TranscriptTableAccessory?
    /// The message it belongs to; a view reused for another message starts its state afresh.
    var rowID: String
    var width: CGFloat
    /// What a button in it does.
    var action: (@MainActor () -> Void)?
    let environment: TranscriptTableEnvironment

    var body: some View {
      let values = environment.values
      TranscriptTableOfferedWidth(width: max(0, width)) {
        switch accessory {
        case .attachments(let attachments): AttachmentStrip(attachments: attachments)
        case .mentions(let mentions): AttachedPathChips(mentions: mentions)
        case .promptToggle(let title, let collapses):
          UserPromptToggle(title: title, collapses: collapses) { action?() }
        case .interrupted: InterruptedLabel(rowID: rowID)
        case .unsupported(let activity): UnsupportedContentView(activity: activity, rowID: rowID)
        case .origin(let sessionID):
          SessionOriginHeader(sessionID: sessionID) { action?() }
        case .collapsedOrigin(let sessionID, let preview):
          CollapsedSessionMessage(sessionID: sessionID, preview: preview) { action?() }
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
    /// What a button in it does: set once by the cell, which knows the message it shows.
    var action: (@MainActor () -> Void)?

    /// Shows message `rowID`'s `accessory` offered `width`, unless it shows it already.
    func show(_ accessory: TranscriptTableAccessory, rowID: String, width: CGFloat) {
      let root = rootView
      guard accessory != root.accessory || rowID != root.rowID || width != root.width else {
        return
      }
      present(
        TranscriptTableAccessoryRoot(
          accessory: accessory, rowID: rowID, width: width, action: action,
          environment: root.environment))
    }
  }
#endif
