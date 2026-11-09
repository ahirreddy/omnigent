public import Foundation
public import Observation
public import SwiftUI

/// Settings › Appearance › Code typography, under the web's keys: the code font's size, family
/// and weight for code blocks, files and diffs. Views read ``font(size:)`` in their bodies, so a
/// change redraws them.
@Observable
public final class CodeTypography {
  /// `omnigent:code-font-size`: points.
  public static let sizeKey = "omnigent:code-font-size"
  /// `omnigent:code-font-family`: a font family name; empty for the system monospaced font.
  public static let familyKey = "omnigent:code-font-family"
  /// `omnigent:code-font-weight`: 400 or 500.
  public static let weightKey = "omnigent:code-font-weight"
  /// The web's default size, which every view's own size is relative to.
  public static let defaultSize: Double = 13
  /// Sizes Settings offers.
  public static let sizes: ClosedRange<Double> = 10...24

  /// The device's preferences.
  public static let shared = CodeTypography()

  /// The code font size, in points.
  public var size: Double {
    didSet { if size != oldValue, !isReloading { defaults.set(size, forKey: Self.sizeKey) } }
  }
  /// A font family; empty uses the system monospaced font.
  public var family: String {
    didSet {
      guard family != oldValue, !isReloading else { return }
      if family.isEmpty {
        defaults.removeObject(forKey: Self.familyKey)
      } else {
        defaults.set(family, forKey: Self.familyKey)
      }
    }
  }
  /// Medium instead of regular weight.
  public var isHeavier: Bool {
    didSet {
      if isHeavier != oldValue, !isReloading {
        defaults.set(isHeavier ? 500 : 400, forKey: Self.weightKey)
      }
    }
  }

  private let defaults: UserDefaults
  @ObservationIgnored private var isReloading = false

  /// Loads the preferences; values out of range read as the defaults.
  /// - Parameter defaults: The store.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let stored = defaults.double(forKey: Self.sizeKey)
    size = Self.sizes.contains(stored) ? stored : Self.defaultSize
    family = defaults.string(forKey: Self.familyKey)?.trimmingCharacters(in: .whitespaces) ?? ""
    isHeavier = defaults.integer(forKey: Self.weightKey) == 500
  }

  /// Rereads the store after its keys changed underneath (an import or reset), leaving an unset
  /// key unset.
  public func reload() {
    let stored = CodeTypography(defaults: defaults)
    isReloading = true
    defer { isReloading = false }
    if size != stored.size { size = stored.size }
    if family != stored.family { family = stored.family }
    if isHeavier != stored.isHeavier { isHeavier = stored.isHeavier }
  }

  /// How much larger than the default the code font is.
  public var scale: Double { size / Self.defaultSize }

  /// The code font for a view whose default size is `base` points.
  /// - Parameter base: The view's size at the default setting.
  /// - Returns: The font.
  public func font(size base: Double) -> Font {
    let points = (base * scale).rounded()
    let weight: Font.Weight = isHeavier ? .medium : .regular
    guard !family.isEmpty else { return .system(size: points, weight: weight, design: .monospaced) }
    return .custom(family, size: points).weight(weight)
  }
}
