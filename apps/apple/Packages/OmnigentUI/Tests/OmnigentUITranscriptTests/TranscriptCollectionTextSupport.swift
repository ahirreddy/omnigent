#if os(iOS)
  import OmnigentViewTesting
  import SwiftUI
  import UIKit

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The width text row suites lay rows out at: an iPhone's.
  let textRowWidth: CGFloat = 393

  /// The style text rows draw in, from a chat environment with the TextKit renderer at 2x,
  /// which the test adds to.
  @MainActor
  func textRowStyle(_ transform: (inout EnvironmentValues) -> Void = { _ in })
    -> TranscriptCollectionTextStyle
  {
    let environment = TranscriptTableEnvironment()
    var values = EnvironmentValues()
    values.messageTextRenderer = .textKit
    values.layoutWidth = .compact
    values.displayScale = 2
    transform(&values)
    environment.values = values
    let style = TranscriptCollectionTextStyle(environment: environment)
    style.refresh()
    return style
  }

  /// A list row showing `message` with `decoration`.
  @MainActor
  func textRow(_ message: Row, decoration: MessageDecoration = MessageDecoration())
    -> TranscriptTableRow
  {
    TranscriptTableRow(
      .segment(
        SegmentEntry(
          segment: .item(.message(message)), decorations: [message.id: decoration],
          duration: nil)))
  }

  /// A text row showing `message` at ``textRowWidth``, in a window.
  @MainActor
  func shownTextRow(
    _ message: Row, decoration: MessageDecoration = MessageDecoration(),
    style: TranscriptCollectionTextStyle
  ) throws -> (TranscriptCollectionTextView, InProcessWindow) {
    let view = TranscriptCollectionTextView(style: style)
    view.show(textRow(message, decoration: decoration), version: 0, width: textRowWidth)
    let window = try InProcessWindow(view: UIView(), width: textRowWidth, height: 800)
    window.controller.view.addSubview(view)
    view.frame = CGRect(
      x: 0, y: 0, width: textRowWidth, height: view.idealHeight(at: textRowWidth))
    window.window.layoutIfNeeded()
    return (view, window)
  }

  /// Every title in `elements`, submenus' included, in order.
  @MainActor
  func menuTitles(_ elements: [UIMenuElement]) -> [String] {
    elements.flatMap { element -> [String] in
      if let menu = element as? UIMenu { return [menu.title] + menuTitles(menu.children) }
      return [element.title]
    }.filter { !$0.isEmpty }
  }
#endif
