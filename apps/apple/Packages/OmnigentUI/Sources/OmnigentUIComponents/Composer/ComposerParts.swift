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
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Label {
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text("Delivery uncertain").font(.callout.weight(.semibold))
            Text(message).font(.callout)
          }
        } icon: {
          Image(systemName: "questionmark.circle.fill").foregroundStyle(Theme.warning)
        }
        if let acknowledge {
          Button(action: acknowledge) {
            Text("I checked the conversation. Allow another send.")
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityIdentifier("composer-acknowledge-uncertain")
        }
      }
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, alignment: .leading)
      .cardSurface(
        cornerRadius: Theme.Radius.medium, tint: Theme.warning,
        stroke: Theme.warning.opacity(0.4)
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("composer-uncertain")
    case .failed(let message):
      ErrorBanner(message: message, dismiss: dismiss, identifier: "composer-delivery-error")
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
  /// The text view's accessibility identifier. Set on the editor alone, so the measuring copy,
  /// the placeholder and the editor's scroll view never carry it.
  var identifier: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .body) private var lineHeight: CGFloat = Theme.Typography
    .editorLineHeight

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
        .proseStyle()
        .padding(inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hidden()
      TextEditor(text: $text)
        .proseStyle()
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier(identifier ?? "", isEnabled: identifier != nil)
    }
    .animation(reduceMotion ? nil : Theme.Motion.feedback, value: Theme.lineCount(text))
    .overlay(alignment: .topLeading) {
      if text.isEmpty {
        Text(placeholder)
          .proseStyle()
          .foregroundStyle(.secondary)
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
      HStack(spacing: Theme.Spacing.small) {
        ForEach(attachments) { attachment in
          DraftAttachmentChip(attachment: attachment, remove: remove)
        }
      }
      .padding(.horizontal, Theme.Spacing.tiny)
      .padding(.vertical, Theme.Spacing.tiny)
    }
    .scrollIndicators(.never)
  }
}

private struct DraftAttachmentChip: View {
  let attachment: DraftAttachment
  let remove: ((DraftAttachment) -> Void)?

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
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
        .accessibilityIdentifier("draft-attachment-remove-\(attachment.id)")
      }
    }
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: isFailed ? Theme.failure : nil,
      stroke: isFailed ? Theme.failure.opacity(0.4) : nil
    )
    .accessibilityElement(children: .contain)
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
  let isFocused: Bool
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovered = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
    content
      .background {
        if reduceTransparency || contrast == .increased {
          shape.fill(ThemeColor.surface)
        } else {
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(ThemeColor.surface.opacity(0.65))
          }
        }
      }
      .overlay {
        shape.strokeBorder(
          isTargeted || isFocused ? Theme.accent : ThemeColor.border,
          lineWidth: isTargeted || isFocused || contrast == .increased ? 1.5 : 0.5)
      }
      .shadow(
        color: .black.opacity(isFocused ? 0.1 : 0.06), radius: Theme.Spacing.large,
        y: Theme.Spacing.extraSmall
      )
      .onHover { isHovered = $0 }
      .overlay {
        shape.strokeBorder(ThemeColor.border.opacity(isHovered && !isFocused ? 1 : 0), lineWidth: 1)
          .allowsHitTesting(false)
      }
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isFocused)
  }
}

extension View {
  func composerSurface(isTargeted: Bool, isFocused: Bool) -> some View {
    modifier(ComposerSurface(isTargeted: isTargeted, isFocused: isFocused))
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
