import CoreText
import Foundation

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The system monospaced font, resolved to a family name libghostty's CoreText font discovery
/// can find.
enum TerminalFonts {
  /// The first installed family of: the platform's monospaced system font, SF Mono, Menlo.
  static let systemFamily: String? = {
    #if os(macOS)
      let system = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName
    #else
      let system: String? = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular).familyName
    #endif
    let candidates = [system, "SF Mono", "Menlo"].compactMap(\.self)
    return candidates.first { isInstalled($0) }
  }()

  /// Whether CoreText resolves `family` to itself rather than a fallback. Hidden system
  /// families (names starting with `.`) are excluded: they resolve, but discovery by name does
  /// not find them.
  nonisolated static func isInstalled(_ family: String) -> Bool {
    guard !family.hasPrefix(".") else { return false }
    let font = CTFontCreateWithName(family as CFString, 13, nil)
    let resolved = CTFontCopyFamilyName(font) as String
    return resolved.caseInsensitiveCompare(family) == .orderedSame
  }

  /// Installed fixed-pitch families discovery can find by name, sorted; empty where the
  /// platform does not list them (iOS).
  static func monospacedFamilies() -> [String] {
    #if os(macOS)
      let manager = NSFontManager.shared
      let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
      let families = Set(names.compactMap { NSFont(name: $0, size: 13)?.familyName })
      return families.filter { !$0.hasPrefix(".") }.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
    #else
      return []
    #endif
  }
}

extension TerminalAppearance {
  /// The default appearance for the current system: its light or dark mode, the system
  /// monospaced font at the platform's text size.
  public static func system() -> TerminalAppearance {
    #if os(macOS)
      let dark =
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return TerminalAppearance(fontSize: 13, colorScheme: dark ? .dark : .light)
    #else
      let dark = UITraitCollection.current.userInterfaceStyle == .dark
      let body = UIFont.preferredFont(forTextStyle: .body).pointSize
      return TerminalAppearance(
        fontSize: (body * 0.8).rounded(), colorScheme: dark ? .dark : .light, optionAsAlt: false)
    #endif
  }
}
