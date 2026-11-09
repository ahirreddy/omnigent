#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  /// A symbol name the system doesn't have draws nothing and leaves its button zero sized.
  @Suite("Symbol names")
  struct SymbolNamesTests {
    private static var sources: URL {
      URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources")
    }

    /// The names in `systemImage:` and `systemName:` arguments, with both arms of a conditional.
    static func names(in source: String) -> Set<String> {
      var found: Set<String> = []
      for line in source.split(separator: "\n")
      where line.contains("systemImage:") || line.contains("systemName:") {
        for match in line.matches(of: /"([a-z0-9]+(?:\.[a-z0-9]+)*)"/) {
          found.insert(String(match.output.1))
        }
      }
      return found
    }

    @Test("finds both arms of a conditional name")
    func parsing() {
      let line = #"Image(systemName: isOpen ? "chevron.down" : "chevron.right")"#
      #expect(Self.names(in: line) == ["chevron.down", "chevron.right"])
      #expect(Self.names(in: #"Text("not.a.symbol")"#).isEmpty)
    }

    @Test("every symbol this package names exists")
    func everySymbolExists() throws {
      let files = try #require(
        FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
      var checked = 0
      for case let file as URL in files where file.pathExtension == "swift" {
        for name in Self.names(in: try String(contentsOf: file, encoding: .utf8)) {
          checked += 1
          #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "\(name) in \(file.lastPathComponent)")
        }
      }
      #expect(checked > 20, "the sources were found")
    }
  }
#endif
