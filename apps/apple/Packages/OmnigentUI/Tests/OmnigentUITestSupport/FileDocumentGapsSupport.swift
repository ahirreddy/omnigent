#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers

  /// The configurations SwiftUI hands a `FileDocument`, which only it can make: a save panel never
  /// reads a document back, and off screen none opens. Their public layout is these two fields.
  enum FileDocumentConfigurations {
    static func read(_ file: FileWrapper) -> FileDocumentReadConfiguration {
      unsafe unsafeBitCast((UTType.plainText, file), to: FileDocumentReadConfiguration.self)
    }

    static func write() -> FileDocumentWriteConfiguration {
      let existing: FileWrapper? = nil
      return unsafe unsafeBitCast(
        (UTType.plainText, existing), to: FileDocumentWriteConfiguration.self)
    }
  }
#endif
