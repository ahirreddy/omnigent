import OmnigentPlatform
import SwiftUI

/// Display math typeset by KaTeX (``RichBlockRenderer``), centered and scrolling sideways when
/// wide. While its block streams, while it typesets, or when KaTeX rejects it, the TeX draws as
/// Unicode (``MathText``) instead. The TeX source is its help text, copy action and
/// accessibility value.
struct MathBlockView: View {
  let tex: String
  @Environment(\.typeRamp) private var ramp
  @Environment(\.markdownBlockIsOpen) private var isOpen
  @State private var drawn: [RichBlockRequest: RenderedRichBlock] = [:]
  @State private var failure: String?

  private func equation(_ typeset: RenderedRichBlock?) -> some View {
    Group {
      if let typeset {
        typeset.templateImage
          .frame(width: typeset.size.width, height: typeset.size.height)
      } else {
        Text(verbatim: MathText.unicode(tex))
          .font(.system(size: ramp.body * 1.1, design: .serif))
          .italic()
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
      }
    }
    .fixedSize()
    .padding(.vertical, Theme.Spacing.small)
  }

  private var helpText: String {
    guard let failure else { return tex }
    return tex + "\n\n" + failure
  }

  var body: some View {
    let request = RichBlockRequest(kind: .math(display: true, size: ramp.body), source: tex)
    let equation = equation(drawn[request] ?? RichBlockRenderer.shared.cached(request))
    ViewThatFits(in: .horizontal) {
      equation.frame(maxWidth: .infinity)
      ScrollView(.horizontal) { equation }.scrollIndicators(.automatic)
    }
    .help(helpText)
    .contextMenu {
      Button("Copy TeX", systemImage: "doc.on.doc") { Pasteboard.copy(tex) }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Math")
    .accessibilityValue(tex)
    .task(id: isOpen ? nil : request) {
      guard !isOpen, drawn[request] == nil else { return }
      do {
        drawn = [request: try await RichBlockRenderer.shared.render(request)]
        failure = nil
      } catch {
        failure = error.localizedDescription
      }
    }
  }
}

/// A paragraph's text. Its inline math (`\(…\)`) is typeset: each span becomes a KaTeX image
/// set on the text's baseline once it is ready, and Unicode until then or if KaTeX rejects it.
struct MarkdownParagraphText: View {
  let text: AttributedString
  @Environment(\.typeRamp) private var ramp
  @Environment(\.markdownBlockIsOpen) private var isOpen
  @State private var drawn: [RichBlockRequest: RenderedRichBlock] = [:]

  var body: some View {
    let requests = Self.requests(in: text, size: ramp.body)
    if requests.isEmpty {
      Text(text)
    } else {
      Self.compose(text, size: ramp.body) { drawn[$0] ?? RichBlockRenderer.shared.cached($0) }
        .accessibilityLabel(Text(text))
        .task(id: isOpen ? [] : requests) {
          guard !isOpen else { return }
          for request in requests where drawn[request] == nil {
            // A span KaTeX rejects keeps its Unicode form; inline text has no room to say why.
            if let typeset = try? await RichBlockRenderer.shared.render(request) {
              drawn[request] = typeset
            }
          }
        }
    }
  }

  /// The math spans to typeset, in order.
  static func requests(in text: AttributedString, size: CGFloat) -> [RichBlockRequest] {
    text.runs.compactMap { run in
      run[MathSpanAttribute.self].map {
        RichBlockRequest(kind: .math(display: false, size: size), source: $0)
      }
    }
  }

  /// `text` with each typeset math span replaced by its image.
  static func compose(
    _ text: AttributedString, size: CGFloat,
    typeset: (RichBlockRequest) -> RenderedRichBlock?
  ) -> Text {
    var composed = Text(verbatim: "")
    for run in text.runs {
      let piece: Text
      if let tex = run[MathSpanAttribute.self],
        let image = typeset(RichBlockRequest(kind: .math(display: false, size: size), source: tex))
      {
        piece = Text(image.templateImage).baselineOffset(image.baseline - image.size.height)
      } else {
        piece = Text(AttributedString(text[run.range]))
      }
      composed = Text("\(composed)\(piece)")
    }
    return composed
  }
}

extension RenderedRichBlock {
  /// The snapshot as an image drawn in the current foreground style (KaTeX draws in black).
  var templateImage: Image {
    Image(decorative: image, scale: scale).renderingMode(.template)
  }
}

extension TypeRamp {
  /// `text` with its inline math set in the serif face at `size`.
  func sizingMath(in text: AttributedString, size: CGFloat) -> AttributedString {
    var sized = text
    for run in text.runs where run[MathSpanAttribute.self] != nil {
      sized[run.range].swiftUI.font = .system(size: size, design: .serif).italic()
    }
    return sized
  }
}
