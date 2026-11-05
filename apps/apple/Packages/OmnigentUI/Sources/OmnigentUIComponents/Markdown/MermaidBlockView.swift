import SwiftUI

/// A ```` ```mermaid ```` block drawn as its diagram (``RichBlockRenderer``), with copy, show
/// code and full-size actions, as the web shows it. While the block streams or draws it is code;
/// when Mermaid rejects it, the code follows a note that says why.
struct MermaidBlockView: View {
  let source: String
  @Environment(\.colorScheme) private var scheme
  @Environment(\.markdownBlockIsOpen) private var isOpen
  @State private var drawn: [RichBlockRequest: RenderedRichBlock] = [:]
  @State private var failure: String?
  @State private var showsCode = false
  @State private var showsLightbox = false

  var body: some View {
    let request = RichBlockRequest(kind: .mermaid(dark: scheme == .dark), source: source)
    content(drawn[request] ?? RichBlockRenderer.shared.cached(request))
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

  @ViewBuilder
  private func content(_ diagram: RenderedRichBlock?) -> some View {
    if let diagram, !showsCode {
      diagramCard(diagram)
    } else if diagram != nil {
      VStack(alignment: .trailing, spacing: Theme.Spacing.extraSmall) {
        CodeBlockView(code: source, language: "mermaid")
        showDiagramButton
      }
    } else if let failure, !isOpen {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Label {
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text("Mermaid couldn\u{2019}t render this diagram")
            Text(verbatim: failure.split(separator: "\n").first.map(String.init) ?? failure)
              .foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(ThemeColor.failure)
        }
        .font(.callout)
        .textSelection(.enabled)
        CodeBlockView(code: source, language: "mermaid")
      }
    } else {
      CodeBlockView(code: source, language: "mermaid")
    }
  }

  private func diagramCard(_ diagram: RenderedRichBlock) -> some View {
    let image = Image(decorative: diagram.image, scale: diagram.scale)
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Text("Diagram")
          .font(Theme.Typography.section)
          .foregroundStyle(.secondary)
        Spacer(minLength: Theme.Spacing.small)
        Button("Show Code", systemImage: "chevron.left.forwardslash.chevron.right") {
          showsCode = true
        }
        .labelStyle(.iconOnly)
        .help("Show the diagram\u{2019}s source")
        Button("View Full Size", systemImage: "arrow.up.left.and.arrow.down.right") {
          showsLightbox = true
        }
        .labelStyle(.iconOnly)
        .help("View full size")
        CopyButton(text: source, label: "Copy code", showsLabel: true)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.extraSmall)
      .background(ThemeColor.hover)
      Divider()
      Button {
        showsLightbox = true
      } label: {
        image.resizable().scaledToFit()
          .frame(maxWidth: diagram.size.width, maxHeight: min(diagram.size.height, 640))
          .frame(maxWidth: .infinity)
          .padding(Theme.Spacing.large)
      }
      .buttonStyle(.plain)
      .help("Click to enlarge")
      .accessibilityLabel("Mermaid diagram")
      .accessibilityValue(source)
      .accessibilityHint("Opens the diagram larger")
    }
    .background(ThemeColor.codeSurface)
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.large).strokeBorder(ThemeColor.border)
    }
    .sheet(isPresented: $showsLightbox) {
      ImageLightbox(image: image, size: diagram.size, title: "Diagram")
    }
  }

  private var showDiagramButton: some View {
    Button("Show Diagram", systemImage: "point.3.connected.trianglepath.dotted") {
      showsCode = false
    }
    .buttonStyle(.borderless)
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}
