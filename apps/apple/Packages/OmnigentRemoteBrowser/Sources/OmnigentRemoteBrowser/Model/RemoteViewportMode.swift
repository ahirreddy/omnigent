public import CoreGraphics
public import Foundation
public import OmnigentCoreFFI
import os

/// A remote viewport size in CSS pixels and its device pixel ratio.
nonisolated public struct RemoteViewportSize: Hashable, Sendable, Codable {
  /// Width, CSS px.
  public var width: Int
  /// Height, CSS px.
  public var height: Int
  /// Device pixel ratio (1 or 2; 2 is "sharp text" and costs four times the pixels).
  public var dpr: Double

  /// Creates a size.
  /// - Parameters:
  ///   - width: Width, CSS px.
  ///   - height: Height, CSS px.
  ///   - dpr: Device pixel ratio.
  public init(width: Int, height: Int, dpr: Double = 1) {
    self.width = width
    self.height = height
    self.dpr = dpr
  }

  /// The core's viewport, clamped to the protocol's 200–3840 px and DPR 1–3.
  public var viewport: RemoteViewport {
    func edge(_ value: Int) -> UInt32 { UInt32(min(max(value, 200), 3840)) }
    return RemoteViewport(width: edge(width), height: edge(height), dpr: min(max(dpr, 1), 3))
  }

  /// "1280 × 800", with "@2x" for DPR 2.
  public var label: String {
    let base = "\(width) \u{00D7} \(height)"
    return dpr > 1 ? "\(base) @\(Int(min(dpr, 3)))x" : base
  }
}

/// How the remote viewport relates to this view while this client holds control (design doc
/// section 16.1). A per-device preference; it changes nothing while the agent has the tab.
nonisolated public enum RemoteViewportMode: Hashable, Sendable, Codable {
  /// The remote keeps its size (the agent's), letterboxed to fit.
  case keep
  /// The remote takes this view's size at DPR 1 (desktop layout), following resizes.
  case fitWindow
  /// The remote takes a chosen size.
  case fixed(RemoteViewportSize)
  /// The remote becomes exactly this view: CSS px = points, DPR = screen scale, mobile layout;
  /// `site` also requests mobile websites (a mobile user agent).
  case mobile(site: Bool)

  /// Sizes offered under "Set Remote Size".
  public static let presets: [RemoteViewportSize] = [
    RemoteViewportSize(width: 1280, height: 800),
    RemoteViewportSize(width: 1440, height: 900),
    RemoteViewportSize(width: 1920, height: 1080),
    RemoteViewportSize(width: 1024, height: 768),
    RemoteViewportSize(width: 390, height: 844),
  ]

  /// The viewport to ask the host for, or `nil` for the agent's.
  /// - Parameters:
  ///   - viewSize: The remote view's size in points.
  ///   - screenScale: The screen's pixels per point.
  /// - Returns: The request, or `nil` to keep (or restore) the agent's viewport.
  public func request(viewSize: CGSize, screenScale: Double) -> RemoteViewportRequest? {
    switch self {
    case .keep:
      return nil
    case .fitWindow:
      return remoteViewportFit(
        viewWidth: viewSize.width, viewHeight: viewSize.height, sharpText: false
      ).map { RemoteViewportRequest(viewport: $0, mobile: .off) }
    case .fixed(let size):
      return RemoteViewportRequest(viewport: size.viewport, mobile: .off)
    case .mobile(let site):
      return remoteViewportMobile(
        viewWidth: viewSize.width, viewHeight: viewSize.height, screenScale: screenScale
      ).map { RemoteViewportRequest(viewport: $0, mobile: site ? .site : .layout) }
    }
  }

  /// Whether the requested viewport depends on the view's size.
  public var followsView: Bool {
    switch self {
    case .fitWindow, .mobile: true
    case .keep, .fixed: false
    }
  }

  /// Whether this is Mobile Size.
  public var isMobile: Bool {
    if case .mobile = self { return true }
    return false
  }

  /// Whether Mobile Size also asks for mobile websites (a mobile user agent).
  public var requestsMobileSite: Bool {
    if case .mobile(let site) = self { return site }
    return false
  }

  /// Double-tap zooms in the desktop modes; mobile pages fit the view, so taps there have no
  /// double-tap delay (as Safari does for `width=device-width` pages).
  public var allowsDoubleTapZoom: Bool { !isMobile }

  /// Desktop pages draw classic scroll bars whose thumb can be dragged; mobile pages use
  /// overlay scroll bars, so the client draws its own indicator instead.
  public var hasPageScrollBars: Bool { !isMobile }

  /// A short name for menus and accessibility.
  public var title: String {
    switch self {
    case .keep: "Keep Remote Size"
    case .fitWindow: "Fit to Window"
    case .fixed(let size): size.label
    case .mobile: "Mobile Size"
    }
  }
}

/// Reads and writes the per-device viewport mode.
nonisolated public enum RemoteViewportModeDefaults {
  /// The defaults key; UI tests set it with `-remoteBrowser.viewportMode '"<json>"'` (quoted
  /// as a plist string, since the argument domain drops an unquoted `{...}`).
  public static let key = "remoteBrowser.viewportMode"

  /// The saved mode, or `keep`.
  /// - Parameter defaults: The store.
  /// - Returns: The mode.
  public static func load(_ defaults: UserDefaults = .standard) -> RemoteViewportMode {
    guard let text = defaults.string(forKey: key), let data = text.data(using: .utf8) else {
      return .keep
    }
    do {
      return try JSONDecoder().decode(RemoteViewportMode.self, from: data)
    } catch {
      // A value from another build: start over with the default.
      log.error("Ignoring an unreadable remote viewport mode \(text): \(error)")
      return .keep
    }
  }

  /// Saves the mode.
  /// - Parameters:
  ///   - mode: The mode.
  ///   - defaults: The store.
  /// - Throws: An encoding error.
  public static func save(_ mode: RemoteViewportMode, _ defaults: UserDefaults = .standard)
    throws
  {
    let data = try JSONEncoder().encode(mode)
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    defaults.set(text, forKey: key)
  }

  private static let log = Logger(subsystem: "ai.omnigent.remote-browser", category: "viewport")
}
