import Foundation
import OmnigentWorkspaceUI
import SwiftUI

/// Where a markdown image's bytes come from. Remote images are never fetched (the web blocks
/// them too), and active formats such as SVG are never decoded.
nonisolated enum MarkdownImageSource: Hashable {
  /// A file in the session's workspace, as cited.
  case workspace(String)
  /// A `data:image/…;base64,` URL.
  case data(mimeType: String, base64: Substring)

  /// Largest image decoded from a `data:` URL.
  static let maxDataBytes = 10 * 1024 * 1024
  private static let rasterTypes: Set<String> = [
    "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
  ]

  init?(_ source: String) {
    if source.lowercased().hasPrefix("data:") {
      guard let comma = source.firstIndex(of: ","),
        case let header = source[source.index(source.startIndex, offsetBy: 5)..<comma]
          .lowercased(),
        header.hasSuffix(";base64"), Self.rasterTypes.contains(String(header.dropLast(7)))
      else { return nil }
      self = .data(
        mimeType: String(header.dropLast(7)), base64: source[source.index(after: comma)...])
      return
    }
    guard let path = WorkspacePaths.linkedPath(source) else { return nil }
    self = .workspace(path)
  }

  /// The decoded bytes of a `data:` URL.
  static func decode(_ base64: Substring) throws -> Data {
    guard base64.count / 4 * 3 <= maxDataBytes else { throw MarkdownImageError.tooLarge }
    guard let data = Data(base64Encoded: String(base64), options: .ignoreUnknownCharacters)
    else { throw MarkdownImageError.undecodable }
    return data
  }
}

/// Why an inline image is not shown.
nonisolated enum MarkdownImageError: LocalizedError {
  case tooLarge
  case undecodable
  case unavailable

  var errorDescription: String? {
    switch self {
    case .tooLarge: "The image is larger than 10 MB."
    case .undecodable: "The image data could not be decoded."
    case .unavailable: "Workspace images are not available here."
    }
  }
}

/// An image in a message, sized to fit the column; click to open it in ``ImageLightbox``.
/// While it loads it holds a placeholder; when it cannot be shown it is a compact labelled
/// chip that says why on hover, as on the web.
struct MarkdownImageView: View {
  let source: String
  let alt: String
  @Environment(\.workspaceFileLinks) private var links
  @State private var phase = Phase.loading
  @State private var showsLightbox = false

  private enum Phase {
    case loading
    case loaded(Image, CGSize)
    case failed(String)
  }

  var body: some View {
    content
      .task(id: source) { await load() }
  }

  @ViewBuilder private var content: some View {
    switch phase {
    case .loading:
      RoundedRectangle(cornerRadius: Theme.Radius.small)
        .fill(ThemeColor.hover)
        .frame(width: 160, height: 120)
        .overlay { ProgressView().controlSize(.small) }
        .accessibilityLabel("Loading image \(alt)")
    case .loaded(let image, let size):
      Button {
        showsLightbox = true
      } label: {
        image.resizable().scaledToFit()
          .frame(maxWidth: min(size.width, 560), maxHeight: 256, alignment: .leading)
          .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
      }
      .buttonStyle(.plain)
      .help("Click to enlarge")
      .accessibilityLabel(alt.isEmpty ? "Image" : alt)
      .accessibilityHint("Opens the image larger")
      .sheet(isPresented: $showsLightbox) {
        ImageLightbox(image: image, size: size, title: alt)
      }
    case .failed(let reason):
      Label(alt.isEmpty ? "Image" : alt, systemImage: "photo")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(ThemeColor.hover, in: .rect(cornerRadius: Theme.Radius.small))
        .help(reason)
        .accessibilityLabel("\(alt.isEmpty ? "Image" : alt), not shown: \(reason)")
    }
  }

  private func load() async {
    do {
      let data: Data
      switch MarkdownImageSource(source) {
      case .data(_, let base64): data = try MarkdownImageSource.decode(base64)
      case .workspace(let path):
        guard let links, links.readsImages else { throw MarkdownImageError.unavailable }
        data = try await links.image(at: path)
      case nil: throw MarkdownImageError.undecodable
      }
      guard let decoded = WorkspacePlatform.image(from: data) else {
        throw WorkspaceImageError.notAnImage
      }
      phase = .loaded(decoded.image, decoded.size)
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}

/// An image shown large, fitted to the window, with zoom.
struct ImageLightbox: View {
  let image: Image
  let size: CGSize
  let title: String
  @Environment(\.dismiss) private var dismiss
  @State private var zoom: CGFloat = 1
  @GestureState private var pinch: CGFloat = 1

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let fitted = fittedSize(in: geometry.size)
        ScrollView([.horizontal, .vertical]) {
          image.resizable().scaledToFit()
            .frame(width: fitted.width * scale, height: fitted.height * scale)
            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
        }
        .gesture(
          MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom = clamped(zoom * value.magnification) })
      }
      .navigationTitle(title.isEmpty ? "Image" : title)
      .toolbar {
        ToolbarItemGroup {
          Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = clamped(zoom / 1.5) }
            .keyboardShortcut("-", modifiers: .command)
          Button("Fit to Window", systemImage: "arrow.down.right.and.arrow.up.left") { zoom = 1 }
            .keyboardShortcut("0", modifiers: .command)
          Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = clamped(zoom * 1.5) }
            .keyboardShortcut("=", modifiers: .command)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
    #endif
  }

  private var scale: CGFloat { clamped(zoom * pinch) }

  private func clamped(_ value: CGFloat) -> CGFloat { min(max(value, 0.25), 8) }

  /// The image's size fitted inside `bounds`, never upscaled past its pixels.
  private func fittedSize(in bounds: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return bounds }
    let ratio = min(bounds.width / size.width, bounds.height / size.height, 1)
    return CGSize(width: size.width * ratio, height: size.height * ratio)
  }
}
