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
  /// The open row's approval-mode name, so one row fits an iPhone; the model name takes the
  /// row's free width.
  static let modeWidth: CGFloat = 96
}

/// Metrics for the Mac's pill: one 48 pt row (32 pt controls in 8 pt padding) that grows with
/// the text, and a row of plain controls under it.
enum ComposerPillMetrics {
  static let padding: CGFloat = 8
  /// The editor's single line and the buttons share this height.
  static let row: CGFloat = 32
  /// Send and Stop: a 28 pt rounded square in the row's height.
  static let button: CGFloat = 28
  static let buttonRadius: CGFloat = 8
}

extension ComposerLayoutStyle {
  /// Send and Stop's visible size.
  var sendCircle: CGFloat {
    self == .touch ? ComposerBarMetrics.sendCircle : ComposerPillMetrics.button
  }

  /// Send and Stop's hit area.
  var sendTarget: CGFloat {
    self == .touch
      ? max(Theme.Control.target, ComposerBarMetrics.sendCircle) : ComposerPillMetrics.row
  }

  /// Send and Stop's shape: a circle on touch, a rounded square in the Mac's pill.
  var sendShape: RoundedRectangle {
    self == .touch
      ? RoundedRectangle(cornerRadius: sendCircle / 2, style: .circular)
      : RoundedRectangle(cornerRadius: ComposerPillMetrics.buttonRadius, style: .continuous)
  }
}
