import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The delivery state above the composer: an uncertain send (blocking until acknowledged) or a
/// failed one.
struct DeliveryBanner: View {
  let delivery: DeliveryState
  let acknowledge: (@MainActor () -> Void)?
  let dismiss: (@MainActor () -> Void)?

  var body: some View {
    switch delivery {
    case .idle, .sending:
      EmptyView()
    case .uncertain(let message):
      VStack(alignment: .leading, spacing: 8) {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text("Delivery uncertain").font(.callout.weight(.semibold))
            Text(message).font(.callout)
          }
        } icon: {
          Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning)
        }
        if let acknowledge {
          Button("I Checked the Conversation, Allow Another Send", action: acknowledge)
            .accessibilityIdentifier("composer-acknowledge-uncertain")
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(
        cornerRadius: Theme.Radius.medium, tint: Theme.warning,
        stroke: Theme.warning.opacity(0.4)
      )
      .accessibilityIdentifier("composer-uncertain")
    case .failed(let message):
      ErrorBanner(message: message, dismiss: dismiss)
    }
  }
}

/// Loads picked photos and pasted items into attachment inputs, collecting every failure.
enum AttachmentLoading {
  struct Result {
    var inputs: [ComposerAttachmentInput] = []
    var failures: [String] = []
  }

  static func photos(_ items: [PhotosPickerItem]) async -> Result {
    var result = Result()
    for (offset, item) in items.enumerated() {
      let type = item.supportedContentTypes.first ?? .image
      do {
        guard let data = try await item.loadTransferable(type: Data.self) else {
          result.failures.append("Photo \(offset + 1) has no data this app can read.")
          continue
        }
        let name = "Photo \(offset + 1).\(type.preferredFilenameExtension ?? "dat")"
        result.inputs.append(.data(data, suggestedName: name, contentType: type))
      } catch {
        result.failures.append("Photo \(offset + 1): \(error.localizedDescription)")
      }
    }
    return result
  }

  static func providers(_ providers: [NSItemProvider]) async -> Result {
    var result = Result()
    for (offset, provider) in providers.enumerated() {
      do {
        result.inputs.append(try await ItemProviderLoader.load(provider, index: offset))
      } catch {
        result.failures.append(error.localizedDescription)
      }
    }
    return result
  }
}

/// Reads pasted or dropped item providers into attachment inputs.
enum ItemProviderLoader {
  enum LoadError: LocalizedError {
    case unsupported(String)
    case empty(String)

    var errorDescription: String? {
      switch self {
      case .unsupported(let name): "\(name) is not a file or an image."
      case .empty(let name): "\(name) had no data."
      }
    }
  }

  static func load(_ provider: NSItemProvider, index: Int) async throws -> ComposerAttachmentInput {
    let name = provider.suggestedName ?? "Pasted item \(index + 1)"
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      let data = try await data(from: provider, type: .fileURL)
      guard let url = URL(dataRepresentation: data, relativeTo: nil) else {
        throw LoadError.empty(name)
      }
      return .file(url: url)
    }
    guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) })
    else { throw LoadError.unsupported(name) }
    let data = try await data(from: provider, type: type)
    let fileName = "\(name).\(type.preferredFilenameExtension ?? "png")"
    return .data(data, suggestedName: fileName, contentType: type)
  }

  private static func data(from provider: NSItemProvider, type: UTType) async throws -> Data {
    let name = provider.suggestedName ?? "The item"
    return try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: LoadError.empty(name))
        }
      }
    }
  }
}

/// A `TextEditor` that grows with its text between `minLines` and `maxLines`, then scrolls.
struct GrowingTextEditor: View {
  @Binding var text: String
  let placeholder: String
  var minLines = 1
  var maxLines = 10
  @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = 17

  #if os(macOS)
    private let inset = EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
  #else
    private let inset = EdgeInsets(top: 8, leading: 5, bottom: 8, trailing: 5)
  #endif

  private var verticalInsets: CGFloat { inset.top + inset.bottom }

  var body: some View {
    // The editor does not size to its text; a hidden copy measures it. A layout (not state)
    // clamps the height, so there is no measure-and-update feedback loop.
    EditorHeightLayout(
      minHeight: lineHeight * CGFloat(minLines) + verticalInsets,
      maxHeight: lineHeight * CGFloat(maxLines) + verticalInsets
    ) {
      Text(verbatim: text.isEmpty ? " " : text + (text.hasSuffix("\n") ? " " : ""))
        .font(.body)
        .padding(inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
      TextEditor(text: $text)
        .font(.body)
        .scrollContentBackground(.hidden)
    }
    .overlay(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .font(.body)
          .foregroundStyle(.tertiary)
          .padding(inset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
  }
}

struct DraftAttachmentStrip: View {
  let attachments: [DraftAttachment]
  let remove: ((DraftAttachment) -> Void)?

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(attachments) { attachment in
          DraftAttachmentChip(attachment: attachment, remove: remove)
        }
      }
      .padding(.horizontal, 2)
      .padding(.vertical, 2)
    }
    .scrollIndicators(.never)
  }
}

private struct DraftAttachmentChip: View {
  let attachment: DraftAttachment
  let remove: ((DraftAttachment) -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      icon
      VStack(alignment: .leading, spacing: 0) {
        Text(attachment.title).font(.caption).lineLimit(1)
        Text(detail)
          .font(.caption2)
          .foregroundStyle(isFailed ? Theme.failure : .secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: 200, alignment: .leading)
      if let remove {
        Button("Remove \(attachment.title)", systemImage: "xmark.circle.fill") {
          remove(attachment)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: isFailed ? Theme.failure : nil,
      stroke: isFailed ? Theme.failure.opacity(0.4) : nil
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("draft-attachment-\(attachment.id)")
  }

  private var isFailed: Bool {
    if case .failed = attachment.state { return true }
    return false
  }

  @ViewBuilder private var icon: some View {
    switch attachment.state {
    case .uploading(let progress):
      if let progress {
        ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
      } else {
        ProgressView().controlSize(.small)
      }
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.failure)
        .accessibilityLabel("Failed")
    case .ready, .uploaded:
      Image(systemName: attachment.kind == .image ? "photo" : "doc")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  private var detail: String {
    switch attachment.state {
    case .failed(let message): return message
    case .uploading: return "Uploading"
    case .uploaded: return "Uploaded"
    case .ready:
      return attachment.byteCount.map {
        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
      } ?? "Ready"
    }
  }
}

private struct ComposerSurface: ViewModifier {
  let isTargeted: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    content
      .background {
        if reduceTransparency {
          shape.fill(.background)
        } else {
          shape.fill(.regularMaterial)
        }
      }
      .overlay {
        shape.strokeBorder(
          isTargeted ? Theme.accent : ThemeColor.secondary.opacity(0.25),
          lineWidth: isTargeted ? 2 : 0.5)
      }
      .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
  }
}

extension View {
  func composerSurface(isTargeted: Bool) -> some View {
    modifier(ComposerSurface(isTargeted: isTargeted))
  }
}

/// Tracks whether a drop is hovering, for the composer's highlight. Drop sessions arrived in
/// iOS 27; earlier iOS accepts drops without the highlight.
struct DropTargetTracking: ViewModifier {
  @Binding var isTargeted: Bool

  func body(content: Content) -> some View {
    if #available(iOS 27.0, *) {
      content.onDropSessionUpdated { session in
        switch session.phase {
        case .entering, .active: isTargeted = true
        case .exiting, .ended, .dataTransferCompleted: isTargeted = false
        @unknown default: isTargeted = false
        }
      }
    } else {
      content
    }
  }
}

/// Sizes to its first subview's ideal height for the proposed width, clamped, and gives every
/// subview that frame.
struct EditorHeightLayout: Layout {
  let minHeight: CGFloat
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 320
    let measured =
      subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? minHeight
    return CGSize(width: width, height: min(max(measured, minHeight), maxHeight))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
  }
}
