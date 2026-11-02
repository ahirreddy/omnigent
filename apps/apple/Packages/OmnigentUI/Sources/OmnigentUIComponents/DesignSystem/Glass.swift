public import SwiftUI

/// Liquid Glass for custom controls that float over the transcript: the composer card, the jump
/// pill, HUDs and transient lists. Content (transcript rows, code, approval payloads and the
/// decision dock) stays on opaque surfaces, and system bars bring their own glass.
///
/// The glass takes a little of the theme's canvas, so it reads as part of the palette. Under
/// Reduce Transparency it becomes the theme's opaque surface. Under Increase Contrast it is
/// tinted nearly opaque and gains a border, so text on it keeps its contrast minimum whatever
/// scrolls beneath.
public struct GlassSurface<SurfaceShape: InsettableShape>: ViewModifier {
  let shape: SurfaceShape
  let isInteractive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.flattensGlass) private var flattensGlass
  @Environment(\.self) private var environment

  /// Creates the modifier.
  /// - Parameters:
  ///   - shape: The glass's shape.
  ///   - isInteractive: Whether the glass responds to touch and pointer, as a control.
  public init(shape: SurfaceShape, isInteractive: Bool = false) {
    self.shape = shape
    self.isInteractive = isInteractive
  }

  /// The glass, or the solid surface.
  public func body(content: Content) -> some View {
    let increased = contrast == .increased
    if reduceTransparency {
      content
        .background(ThemeColor.surface, in: shape)
        .overlay { shape.strokeBorder(ThemeColor.border, lineWidth: increased ? 1.5 : 0.5) }
    } else if flattensGlass {
      content
        .background {
          let tint = GlassStyle.tintOpacity(increased: increased)
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(ThemeColor.surface.opacity(tint))
          }
        }
        .overlay { shape.strokeBorder(ThemeColor.border, lineWidth: increased ? 1.5 : 0.5) }
    } else {
      content
        .glassEffect(GlassStyle.glass(in: environment, isInteractive: isInteractive), in: shape)
        .overlay {
          if increased { shape.strokeBorder(ThemeColor.border, lineWidth: 1.5) }
        }
    }
  }
}

/// The glass the components use, from the environment's theme and accessibility settings.
nonisolated enum GlassStyle {
  /// How much of the theme's surface tints the glass. Increase Contrast tints it nearly opaque;
  /// ``contrastBackgrounds(canvas:surface:foreground:increased:)`` checks text against the result.
  static func tintOpacity(increased: Bool) -> Double {
    increased ? 0.85 : 0.4
  }

  /// The regular glass with the theme's surface as its tint.
  @MainActor static func glass(in environment: EnvironmentValues, isInteractive: Bool) -> Glass {
    let increased = environment.colorSchemeContrast == .increased
    let tint = ThemeColor.surface.resolve(in: environment).opacity(tintOpacity(increased: increased))
    return Glass.regular.tint(tint).interactive(isInteractive)
  }

  /// What text on tinted glass sits on: the tint over the bare canvas, and over dense content
  /// (glass blurs text beneath into about a quarter of its color over the canvas).
  static func contrastBackgrounds(
    canvas: SRGB, surface: SRGB, foreground: SRGB, increased: Bool
  ) -> [SRGB] {
    let opacity = tintOpacity(increased: increased)
    return [canvas, canvas.mixed(with: foreground, by: denseContent)].map {
      $0.mixed(with: surface, by: opacity)
    }
  }

  /// How much of the text color a blurred, densely written transcript averages to.
  static let denseContent = 0.25
}

extension View {
  /// Liquid Glass in `shape`, themed, and solid under Reduce Transparency.
  /// - Parameters:
  ///   - shape: The glass's shape.
  ///   - isInteractive: Whether it responds to touch and pointer, as a control.
  /// - Returns: The view on glass.
  public func glassSurface(
    in shape: some InsettableShape = Capsule(), isInteractive: Bool = false
  ) -> some View {
    modifier(GlassSurface(shape: shape, isInteractive: isInteractive))
  }

  /// How glass appears and disappears: materializing, or at once under Reduce Motion.
  /// - Returns: The view with its glass transition.
  public func glassTransition() -> some View {
    modifier(GlassTransition())
  }
}

private struct GlassTransition: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.glassEffectTransition(reduceMotion ? .identity : .materialize)
  }
}

extension EnvironmentValues {
  /// Draws ``GlassSurface`` as a material instead of Liquid Glass. Offscreen renders that bypass
  /// the window server (`cacheDisplay`) draw neither glass nor the content inside it.
  @Entry var flattensGlass = false
}
