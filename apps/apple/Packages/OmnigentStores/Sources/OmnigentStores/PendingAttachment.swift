public import Foundation

/// A file staged on the new-session form, uploaded to the session once it exists.
public struct PendingAttachment: Identifiable, Equatable, Sendable {
  /// Stable within the form.
  public let id: UUID
  /// File name.
  public let filename: String
  /// Declared media type.
  public let mediaType: String?
  /// The bytes.
  public let data: Data

  /// Creates a staged file.
  public init(filename: String, mediaType: String?, data: Data) {
    id = UUID()
    self.filename = filename
    self.mediaType = mediaType
    self.data = data
  }
}
