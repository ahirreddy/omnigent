import SwiftUI

/// What a design-tool message was about, under its words: the element or page beside the
/// tool's symbol, and a note when it went without its screenshot.
struct DesignRequestSubject: View {
  let request: DesignRequest

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
      Label {
        // Wraps rather than clips: its fields are capped, and long selectors need reading.
        Text(request.subject).fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(
          systemName: request.kind == .element ? "cursorarrow.click.2" : "pencil.and.scribble")
      }
      .font(.callout)
      if request.noScreenshot {
        Text(DesignRequest.noScreenshotNote).font(.caption)
      }
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("design-request-subject")
  }
}
