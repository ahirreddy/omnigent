/// Makes server-supplied text safe to show verbatim.
///
/// Server and identity-provider text (a refusal reason, a server name, an unknown mode) is shown
/// as given, never interpreted: views render it with `Text(verbatim:)`, so Markdown and links stay
/// literal. This also escapes the characters that would let it misrepresent itself on screen:
/// control characters and Unicode bidirectional overrides become visible `\u{...}` escapes, and
/// overlong text is cut with an ellipsis.
public nonisolated enum ServerText {
  /// The longest reason shown, in characters.
  public static let defaultLimit = 500

  /// `text` with control and bidi-override characters escaped and its length capped.
  /// - Parameters:
  ///   - text: Server-supplied text.
  ///   - limit: The longest result, in characters, before the ellipsis.
  /// - Returns: The displayable text.
  public static func escaped(_ text: String, limit: Int = defaultLimit) -> String {
    var result = ""
    var count = 0
    for scalar in text.unicodeScalars {
      if count >= limit {
        result.append("\u{2026}")
        break
      }
      if scalar == "\n" || scalar == "\t" {
        result.unicodeScalars.append(scalar)
      } else if needsEscape(scalar) {
        result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
      } else {
        result.unicodeScalars.append(scalar)
      }
      count += 1
    }
    return result
  }

  private static func needsEscape(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F:
      // C0 and C1 controls, including CR and ESC.
      return true
    case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C:
      // Directional marks, embeddings, overrides and isolates.
      return true
    case 0x2028, 0x2029:
      // Line and paragraph separators.
      return true
    default:
      return false
    }
  }
}
