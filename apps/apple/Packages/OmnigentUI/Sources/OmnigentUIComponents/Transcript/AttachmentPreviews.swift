public import Foundation
public import SwiftUI

/// Reads the images uploaded with a session's messages for inline previews, as the web's
/// `SessionImage` does. A file id names fixed bytes, so each is read once (the last 32 are kept)
/// and concurrent views of one image share a read. The host supplies the read.
@MainActor
public final class AttachmentPreviews {
  private let read: @MainActor (String) async throws -> Data
  private var cache = BoundedCache<String, Data>(limit: 32)
  private var inFlight: [String: Task<Data, any Error>] = [:]

  /// Previews over `read`, which returns the bytes of an attachment reference.
  /// - Parameter read: The bytes of one of the session's files, by reference.
  public init(read: @escaping @MainActor (String) async throws -> Data) {
    self.read = read
  }

  /// The bytes of the attachment `reference` names.
  func data(for reference: String) async throws -> Data {
    if let cached = cache.cached(reference) { return cached }
    if let running = inFlight[reference] { return try await running.value }
    let task = Task { @MainActor in try await read(reference) }
    inFlight[reference] = task
    defer { inFlight[reference] = nil }
    let data = try await task.value
    return cache.value(for: reference) { data }
  }
}

extension Attachment {
  /// The reference of an uploaded image a preview can read; embedded bytes were dropped.
  var previewableImage: String? {
    guard kind == .image, !isEmbedded else { return nil }
    return reference
  }
}

extension EnvironmentValues {
  /// Reads uploaded message images; `nil` shows every attachment as a chip.
  @Entry public var attachmentPreviews: AttachmentPreviews?
}
