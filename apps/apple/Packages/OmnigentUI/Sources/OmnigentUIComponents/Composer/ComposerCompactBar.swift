public import SwiftUI

/// How the composer lays out: the Mac's card, or the touch bar that iPhone and iPad use (see
/// `docs/composer-sizing.md`). Touch never mentions Escape and keeps Stop in the thumb zone.
nonisolated public enum ComposerLayoutStyle: Hashable, Sendable {
  /// The card: a two-line editor over a row of chips. Esc stops a run.
  case card
  /// A 48 pt bar (+, one line, Mic, Send or Stop) that opens into the editor and one control
  /// row while focused or holding a draft.
  case touch

  /// The platform's style.
  public static var platformDefault: Self {
    #if os(iOS)
      .touch
    #else
      .card
    #endif
  }
}

extension EnvironmentValues {
  /// The composer's layout; the playground sets `.touch` to preview the iPhone bar on the Mac.
  @Entry public var composerLayoutStyle: ComposerLayoutStyle = .platformDefault
}

/// Metrics for the touch bar, from the ChatGPT, Claude and Gemini comparison.
enum ComposerBarMetrics {
  /// The idle bar's height: one 44 pt row plus 2 pt above and below.
  static let collapsedVerticalPadding: CGFloat = 2
  static let collapsedHorizontalPadding: CGFloat = 6
  static let openPadding = EdgeInsets(top: 6, leading: 10, bottom: 4, trailing: 6)
  /// Space above and below the composer (12 pt on the Mac).
  static let outerPadding: CGFloat = 6
  /// Lines before the editor scrolls.
  static let maxLines = 6
  /// Send and Stop: a 36 pt circle in a 44 pt hit area.
  static let sendCircle: CGFloat = 36
  /// The open row's model and approval-mode names, so one row fits an iPhone.
  static let modelWidth: CGFloat = 96
  static let modeWidth: CGFloat = 96
}

extension ComposerLayoutStyle {
  /// Send and Stop's visible circle.
  var sendCircle: CGFloat {
    self == .touch ? ComposerBarMetrics.sendCircle : Theme.Control.send
  }

  /// Send and Stop's hit area.
  var sendTarget: CGFloat {
    self == .touch ? max(Theme.Control.target, ComposerBarMetrics.sendCircle) : Theme.Control.send
  }
}
