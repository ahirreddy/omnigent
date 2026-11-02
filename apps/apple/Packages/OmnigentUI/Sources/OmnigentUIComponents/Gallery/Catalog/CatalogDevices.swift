import SwiftUI

#if os(iOS)
  import UIKit
#endif

/// A device the gallery lays pages out for. Sizes are the real screens in points.
enum CatalogDevice: String, CaseIterable, Identifiable, Sendable {
  case mac
  /// iPhone 17 Pro: Dynamic Island and home indicator.
  case iPhone
  /// The small iPhone (SE size): home button, rectangular screen.
  case iPhoneSE
  case iPadPro13
  case iPadPro11
  /// iPad Pro 13" in landscape Split View, this app on a third.
  case iPadSplitThird
  /// iPad Pro 13" in landscape Split View, this app on half.
  case iPadSplitHalf
  /// iPad Pro 13" in landscape Split View, this app on two thirds.
  case iPadSplitTwoThirds
  /// iPhone Duo, a book-style foldable: the outer display folded, one continuous inner display
  /// with a crease down its middle unfolded.
  case duo

  /// How the frame is drawn.
  enum Family: Hashable, Sendable {
    case mac
    case phone
    case pad
    case split
    case duo
  }

  var id: Self { self }

  var family: Family {
    switch self {
    case .mac: .mac
    case .iPhone, .iPhoneSE: .phone
    case .iPadPro13, .iPadPro11: .pad
    case .iPadSplitThird, .iPadSplitHalf, .iPadSplitTwoThirds: .split
    case .duo: .duo
    }
  }

  var title: String {
    switch self {
    case .mac: "Mac window"
    case .iPhone: "iPhone 17 Pro"
    case .iPhoneSE: "iPhone SE"
    case .iPadPro13: "iPad Pro 13\u{2033}"
    case .iPadPro11: "iPad Pro 11\u{2033}"
    case .iPadSplitThird: "iPad Split View, \u{2153}"
    case .iPadSplitHalf: "iPad Split View, \u{00BD}"
    case .iPadSplitTwoThirds: "iPad Split View, \u{2154}"
    case .duo: "iPhone Duo"
    }
  }

  var systemImage: String {
    switch family {
    case .mac: "macwindow"
    case .phone: "iphone"
    case .pad: "ipad"
    case .split: "rectangle.split.3x1"
    case .duo: "book.closed"
    }
  }

  /// Phones rotate; iPads rotate; Split View is landscape and the fold folds instead.
  var canRotate: Bool { family == .phone || family == .pad }

  var canFold: Bool { family == .duo }

  /// The screen in portrait (Split View: the app's slice of the landscape screen; the Duo: its
  /// outer display).
  fileprivate var portraitSize: CGSize {
    switch self {
    case .mac: CGSize(width: 1_280, height: 820)
    case .iPhone: CGSize(width: 402, height: 874)
    case .iPhoneSE: CGSize(width: 375, height: 667)
    case .iPadPro13: CGSize(width: 1_032, height: 1_376)
    case .iPadPro11: CGSize(width: 834, height: 1_210)
    case .iPadSplitThird: CGSize(width: 375, height: 1_032)
    case .iPadSplitHalf: CGSize(width: 683, height: 1_032)
    case .iPadSplitTwoThirds: CGSize(width: 991, height: 1_032)
    case .duo: DuoDisplays.outer
    }
  }

  /// Devices with a regular-width screen (the Duo once unfolded), for pages that need room.
  static let largeScreens: [Self] = [
    .mac, .iPadPro13, .iPadPro11, .iPadSplitTwoThirds, .iPadSplitHalf, .duo,
  ]

  /// Devices with a phone-sized screen, for iPhone-only pages.
  static let phones: [Self] = [.iPhone, .iPhoneSE, .duo]

  /// The device the catalog starts on: the Mac on macOS, this device's family on iOS.
  static var platformDefault: Self {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .pad ? .iPadPro11 : .iPhone
    #else
      .mac
    #endif
  }
}

/// The iPhone Duo's two displays, from its simulator profile (`iPhone Duo.simdevicetype`,
/// model iPhone19,4) and, folded, as the running simulator reports them.
enum DuoDisplays {
  /// "LCD", 1398x2034 px @3x: the outer display, the only one on while folded.
  static let outer = CGSize(width: 466, height: 678)
  /// "LCD-1", 2007x2853 px @3x with a native rotation of 270: the inner display, landscape.
  static let inner = CGSize(width: 951, height: 669)
  /// Outer corners: 8 pt along the spine on the left, 59 pt on the right.
  static let outerCorners = RectangleCornerRadii(
    topLeading: 8, bottomLeading: 8, bottomTrailing: 59, topTrailing: 59)
  static let innerCorner: CGFloat = 55
  /// Folded, the status bar and Dynamic Island take a column on the right, not the top.
  static let outerSafeArea = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
  /// The Dynamic Island in the outer display's status column: screenshots do not draw it, so
  /// its frame is inferred from the column and where the system puts the time below it.
  static let outerIsland = CGRect(x: 466 - 42 - 18.5, y: 11, width: 37, height: 62)
}

/// A device in a posture: everything a page needs to lay out as it would on that screen.
struct CatalogScreen: Hashable, Sendable, Identifiable {
  let device: CatalogDevice
  let isLandscape: Bool
  let isUnfolded: Bool

  /// Width of the Split View divider.
  static let splitDivider: CGFloat = 10

  init(_ device: CatalogDevice, landscape: Bool = false, unfolded: Bool = false) {
    self.device = device
    isLandscape = landscape && device.canRotate
    isUnfolded = unfolded && device.canFold
  }

  /// A file-name-safe id: the device, then `-landscape` or `-unfolded`.
  var id: String {
    if isLandscape { return "\(device.rawValue)-landscape" }
    if isUnfolded { return "\(device.rawValue)-unfolded" }
    return device.rawValue
  }

  /// Parses an ``id``; `nil` for an unknown device or a posture the device does not have.
  init?(id: String) {
    let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
    guard let device = CatalogDevice(rawValue: parts[0]) else { return nil }
    switch parts.count > 1 ? parts[1] : nil {
    case nil: self.init(device)
    case "landscape" where device.canRotate: self.init(device, landscape: true)
    case "unfolded" where device.canFold: self.init(device, unfolded: true)
    default: return nil
    }
  }

  /// Every device in every posture it has.
  static var all: [Self] {
    CatalogDevice.allCases.flatMap { device in
      [Self(device)] + (device.canRotate ? [Self(device, landscape: true)] : [])
        + (device.canFold ? [Self(device, unfolded: true)] : [])
    }
  }

  var title: String {
    if isLandscape { return "\(device.title), landscape" }
    if isUnfolded { return "\(device.title), unfolded" }
    return device.family == .duo ? "\(device.title), folded" : device.title
  }

  /// The app's area in points.
  var size: CGSize {
    let portrait = device.portraitSize
    if isLandscape { return CGSize(width: portrait.height, height: portrait.width) }
    if isUnfolded { return DuoDisplays.inner }
    return portrait
  }

  /// The whole display in points: the app's area, or for Split View the landscape iPad.
  var displaySize: CGSize {
    device.family == .split ? CGSize(width: 1_376, height: 1_032) : size
  }

  /// The hardware's safe-area insets: status bar, Dynamic Island, home indicator.
  var safeArea: EdgeInsets {
    switch (device, isLandscape) {
    case (.mac, _): EdgeInsets()
    case (.iPhone, false): EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
    case (.iPhone, true): EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
    case (.iPhoneSE, false): EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)
    case (.iPhoneSE, true): EdgeInsets()
    case (.duo, _) where !isUnfolded: DuoDisplays.outerSafeArea
    // iPads, and the unfolded Duo (iPad-like: the simulator cannot unfold to measure it).
    default: EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    }
  }

  var horizontalSizeClass: UserInterfaceSizeClass {
    switch device.family {
    case .mac, .pad: .regular
    case .phone: .compact
    case .split: device == .iPadSplitThird ? .compact : .regular
    case .duo: isUnfolded ? .regular : .compact
    }
  }

  var verticalSizeClass: UserInterfaceSizeClass {
    device.family == .phone && isLandscape ? .compact : .regular
  }

  var displayScale: CGFloat {
    switch device {
    case .iPhone, .duo: 3
    default: 2
    }
  }

  var layoutWidth: LayoutWidth { horizontalSizeClass == .compact ? .compact : .regular }

  var composerStyle: ComposerLayoutStyle { device == .mac ? .card : .touch }

  var hingePosture: HingePosture {
    guard device.canFold else { return .unavailable }
    return isUnfolded ? .fullyOpen : .closed
  }

  /// The unfolded Duo's crease, a zero-width line down the middle of its one continuous display.
  /// `nil` when folded and on other devices.
  var crease: CGRect? {
    guard isUnfolded else { return nil }
    return CGRect(x: size.width / 2, y: 0, width: 0, height: size.height)
  }

  /// Whether the session list shows beside the detail, as the app's split view would at this
  /// size. Unfolded, it keeps its own width: the shell is not split at the crease.
  var showsSidebar: Bool {
    switch device.family {
    case .mac: true
    case .pad: isLandscape
    case .split: false
    case .duo: isUnfolded
    case .phone: false
    }
  }

  /// The display's corner radii; only the folded Duo's differ, small along its spine.
  var cornerRadii: RectangleCornerRadii {
    let radius: CGFloat
    switch device {
    case .mac: radius = 10
    case .iPhone: radius = 55
    case .iPhoneSE: radius = 0
    case .duo:
      guard isUnfolded else { return DuoDisplays.outerCorners }
      radius = DuoDisplays.innerCorner
    default: radius = 18
    }
    return RectangleCornerRadii(
      topLeading: radius, bottomLeading: radius, bottomTrailing: radius, topTrailing: radius)
  }

  /// The display's outline.
  var displayShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
  }

  /// Bezel around the display: top, sides, bottom (the SE keeps its forehead and chin).
  var bezel: EdgeInsets {
    switch (device, isLandscape) {
    case (.mac, _): EdgeInsets()
    case (.iPhoneSE, false): EdgeInsets(top: 92, leading: 18, bottom: 92, trailing: 18)
    case (.iPhoneSE, true): EdgeInsets(top: 18, leading: 92, bottom: 18, trailing: 92)
    case (.iPhone, _), (.duo, _): EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    default: EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
    }
  }

  /// The whole drawn device, bezel included.
  var framedSize: CGSize {
    let display = displaySize
    return CGSize(
      width: display.width + bezel.leading + bezel.trailing,
      height: display.height + bezel.top + bezel.bottom)
  }
}
