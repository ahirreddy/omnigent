public import SwiftUI

/// Two-pane container for foldable iPhones. On iOS 27.1+ it is an `ArrangementView`, which the
/// system lays out across the hinge when unfolded and stacks when folded; elsewhere it falls
/// back to showing only the primary pane.
public struct DuoLayout<Primary: View, Secondary: View>: View {
  private let primary: Primary
  private let secondary: Secondary

  /// Creates the layout.
  /// - Parameters:
  ///   - primary: The leading (or top, when folded) pane.
  ///   - secondary: The trailing pane, shown across the hinge when unfolded.
  public init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
    self.primary = primary()
    self.secondary = secondary()
  }

  /// The arrangement.
  public var body: some View {
    #if os(iOS)
      if #available(iOS 27.1, *) {
        HingeAwareArrangement(primary: primary, secondary: secondary)
      } else {
        primary
      }
    #else
      primary
    #endif
  }
}

/// Fold state of the device hinge, from `onHingeChange`.
nonisolated public enum HingePosture: Equatable, Sendable {
  /// The device has no hinge, or the OS does not report it.
  case unavailable
  /// Folded shut.
  case closed
  /// Partly open, for example tent or laptop posture.
  case partiallyOpen
  /// Flat.
  case fullyOpen
}

extension EnvironmentValues {
  /// The posture reported to the nearest ``DuoLayout``.
  @Entry public var hingePosture: HingePosture = .unavailable
}

#if os(iOS)
  @available(iOS 27.1, *)
  private struct HingeAwareArrangement<Primary: View, Secondary: View>: View {
    let primary: Primary
    let secondary: Secondary
    @State private var posture: HingePosture = .unavailable

    var body: some View {
      ArrangementView {
        primary
      } secondary: {
        secondary
      }
      .arrangementViewStyle(.automatic)
      .environment(\.hingePosture, posture)
      .onHingeChange { _, newContext in
        posture = HingePosture(newContext.hinge)
      }
    }
  }

  @available(iOS 27.1, *)
  extension HingePosture {
    init(_ hinge: DeviceHinge?) {
      guard let hinge else {
        self = .unavailable
        return
      }
      switch hinge.status {
      case .closed: self = .closed
      case .partiallyOpen: self = .partiallyOpen
      case .fullyOpen: self = .fullyOpen
      default: self = .unavailable
      }
    }
  }

  @available(iOS 27.1, *)
  extension View {
    /// Insets content so it stays clear of the hinge (`ReservedRegion.Kind.division`).
    /// - Returns: The inset view.
    public func avoidingHinge() -> some View {
      modifier(HingeAvoidingModifier())
    }
  }

  @available(iOS 27.1, *)
  private struct HingeAvoidingModifier: ViewModifier {
    func body(content: Content) -> some View {
      GeometryReader { proxy in
        let margins = proxy.reservedRegions(kind: .division)
          .filter(\.isActive)
          .reduce(into: EdgeInsets()) { result, region in
            result.top = max(result.top, region.margins.top)
            result.leading = max(result.leading, region.margins.leading)
            result.bottom = max(result.bottom, region.margins.bottom)
            result.trailing = max(result.trailing, region.margins.trailing)
          }
        content
          .padding(margins)
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
  }
#endif
