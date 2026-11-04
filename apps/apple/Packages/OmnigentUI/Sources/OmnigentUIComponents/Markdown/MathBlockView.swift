import SwiftUI

/// Display math: the TeX drawn as Unicode (``MathText``) in a serif face, centered, scrolling
/// sideways when wide. The TeX source is its help text and accessibility value.
struct MathBlockView: View {
  let tex: String
  @Environment(\.typeRamp) private var ramp

  var body: some View {
    ScrollView(.horizontal) {
      Text(verbatim: MathText.unicode(tex))
        .font(.system(size: ramp.body * 1.1, design: .serif))
        .italic()
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .fixedSize()
        .padding(.vertical, Theme.Spacing.small)
    }
    .scrollIndicators(.automatic)
    .frame(maxWidth: .infinity)
    .help(tex)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Math")
    .accessibilityValue(tex)
  }
}

extension TypeRamp {
  /// `text` with its inline math set in the serif face at `size`.
  func sizingMath(in text: AttributedString, size: CGFloat) -> AttributedString {
    var sized = text
    for run in text.runs where run[MathSpanAttribute.self] == true {
      sized[run.range].swiftUI.font = .system(size: size, design: .serif).italic()
    }
    return sized
  }
}
