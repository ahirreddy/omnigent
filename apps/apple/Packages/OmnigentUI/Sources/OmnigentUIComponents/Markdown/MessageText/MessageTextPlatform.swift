import SwiftUI

#if os(macOS)
  import AppKit

  /// The platform's font and color, so a message's text builds the same on the Mac and on iOS.
  typealias PlatformFont = NSFont
  typealias PlatformColor = NSColor
#else
  import UIKit

  typealias PlatformFont = UIFont
  typealias PlatformColor = UIColor
#endif

/// What building a message's text needs from the platform's fonts, colors and symbols.
nonisolated enum MessageTextPlatform {
  /// `base` in its italic face, or `base` where it has none.
  static func italic(_ base: PlatformFont) -> PlatformFont {
    #if os(macOS)
      NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: base.pointSize)
        ?? base
    #else
      base.fontDescriptor.withSymbolicTraits(.traitItalic)
        .map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
    #endif
  }

  /// The system font's serif italic at `size`, which inline math is set in.
  static func serifItalic(size: CGFloat) -> PlatformFont {
    let base = PlatformFont.systemFont(ofSize: size)
    #if os(macOS)
      let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
      return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: size) ?? base
    #else
      let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
      return serif.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: size) }
        ?? base
    #endif
  }

  /// The font of `family` at `size` and `weight`, or `nil` where it isn't installed.
  static func font(family: String, size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont? {
    #if os(macOS)
      let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
        .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
      return NSFont(descriptor: descriptor, size: size)
    #else
      let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
        .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]])
      let font = UIFont(descriptor: descriptor, size: size)
      return font.familyName == family ? font : nil
    #endif
  }

  /// The size of the caption text style, which a code block's language label is set in.
  static var captionSize: CGFloat {
    PlatformFont.preferredFont(forTextStyle: .caption1).pointSize
  }

  /// The label colors, resolved for a light or dark appearance.
  struct LabelColors {
    var text: PlatformColor
    var secondary: PlatformColor
    var tertiary: PlatformColor
    var separator: PlatformColor
  }

  @MainActor static func labelColors(isDark: Bool) -> LabelColors {
    #if os(macOS)
      let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
      func resolved(_ color: NSColor) -> NSColor {
        var resolved = color
        appearance?.performAsCurrentDrawingAppearance {
          resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
      }
      return LabelColors(
        text: resolved(.labelColor), secondary: resolved(.secondaryLabelColor),
        tertiary: resolved(.tertiaryLabelColor), separator: resolved(.separatorColor))
    #else
      let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
      return LabelColors(
        text: .label.resolvedColor(with: traits),
        secondary: .secondaryLabel.resolvedColor(with: traits),
        tertiary: .tertiaryLabel.resolvedColor(with: traits),
        separator: .separator.resolvedColor(with: traits))
    #endif
  }

  /// A snapshot drawn in `color` where it isn't clear, as a template image is in SwiftUI;
  /// `nil` when no bitmap can be made.
  static func tinted(_ image: CGImage, color: PlatformColor) -> CGImage? {
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      // No buffer is passed: Core Graphics allocates and owns it.
      let context = unsafe CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: rect)
    context.setBlendMode(.sourceIn)
    context.setFillColor(color.cgColor)
    context.fill(rect)
    return context.makeImage()
  }

  /// A clear image `size` points large: room in a line for something drawn behind the text.
  static func clear(_ size: CGSize) -> PlatformImage {
    #if os(macOS)
      NSImage(size: size, flipped: false) { _ in true }
    #else
      UIGraphicsImageRenderer(size: size).image { _ in }
    #endif
  }

  /// A monochrome symbol at `size` in `color`, its cut-outs kept clear, as SwiftUI draws one.
  static func symbol(
    _ name: String, size: CGFloat, color: PlatformColor, description: String
  ) -> PlatformImage? {
    #if os(macOS)
      let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
      guard
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
          .withSymbolConfiguration(configuration)
      else { return nil }
      let image = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
      }
      image.accessibilityDescription = description
      return image
    #else
      let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
      guard let symbol = UIImage(systemName: name, withConfiguration: configuration) else {
        return nil
      }
      let image = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
      image.accessibilityLabel = description
      return image
    #endif
  }
}
