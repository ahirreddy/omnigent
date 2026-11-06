import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Gallery devices")
struct GalleryDeviceTests {
  @Test("every device and posture has a screen, a unique id that round-trips, and a frame")
  func devices() {
    let screens = CatalogScreen.all
    #expect(Set(screens.map(\.id)).count == screens.count)
    for screen in screens {
      #expect(CatalogScreen(id: screen.id) == screen, "\(screen.id)")
      #expect(screen.size.width > 0 && screen.size.height > 0)
      #expect(screen.framedSize.width >= screen.displaySize.width)
      #expect(screen.framedSize.height >= screen.displaySize.height)
    }
    #expect(CatalogScreen(id: "duo-landscape") == nil)
    #expect(CatalogScreen(id: "iPhone-unfolded") == nil)
    #expect(CatalogScreen(id: "watch") == nil)
    #expect(CatalogScreen(.iPhone).size == CGSize(width: 402, height: 874))
    #expect(CatalogScreen(.iPhone, landscape: true).size == CGSize(width: 874, height: 402))
    #expect(CatalogScreen(.iPhoneSE).size == CGSize(width: 375, height: 667))
    #expect(CatalogScreen(.iPadPro13).size == CGSize(width: 1_032, height: 1_376))
    #expect(CatalogScreen(.iPadPro11, landscape: true).size == CGSize(width: 1_210, height: 834))
    // Split View slices and the divider fill the landscape 13-inch screen.
    let third = CatalogScreen(.iPadSplitThird).size.width
    let twoThirds = CatalogScreen(.iPadSplitTwoThirds).size.width
    let half = CatalogScreen(.iPadSplitHalf).size.width
    #expect(third + CatalogScreen.splitDivider + twoThirds == 1_376)
    #expect(half * 2 + CatalogScreen.splitDivider == 1_376)
    #expect(CatalogScreen(.iPadSplitHalf).displaySize == CGSize(width: 1_376, height: 1_032))
    // A landscape posture only exists where the device rotates.
    #expect(!CatalogScreen(.iPadSplitHalf, landscape: true).isLandscape)
    #expect(!CatalogScreen(.mac, unfolded: true).isUnfolded)
  }

  @Test("safe areas follow the hardware: island, home indicator, home button, status bar")
  func safeAreas() {
    #expect(
      CatalogScreen(.iPhone).safeArea == EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
    #expect(
      CatalogScreen(.iPhone, landscape: true).safeArea
        == EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62))
    #expect(
      CatalogScreen(.iPhoneSE).safeArea == EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0))
    #expect(CatalogScreen(.iPhoneSE, landscape: true).safeArea == EdgeInsets())
    #expect(
      CatalogScreen(.iPadPro13).safeArea == EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)
    )
    #expect(CatalogScreen(.iPadSplitThird).safeArea.top == 24)
    #expect(CatalogScreen(.mac).safeArea == EdgeInsets())
    // Measured on the iPhone Duo simulator, folded: the status bar is a column on the right.
    #expect(
      CatalogScreen(.duo).safeArea == EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))
  }

  @Test("the Duo matches its profile: outer display folded, one continuous inner display open")
  func duo() {
    // iPhone Duo.simdevicetype: "LCD" 1398x2034 px and "LCD-1" 2007x2853 px (rotated 270), @3x.
    let folded = CatalogScreen(.duo)
    #expect(folded.size == CGSize(width: 466, height: 678))
    #expect(folded.displayScale == 3)
    #expect(
      folded.cornerRadii
        == RectangleCornerRadii(
          topLeading: 8, bottomLeading: 8, bottomTrailing: 59, topTrailing: 59))
    #expect(folded.crease == nil)
    #expect(!folded.showsSidebar)
    let unfolded = CatalogScreen(.duo, unfolded: true)
    #expect(unfolded.size == CGSize(width: 951, height: 669))
    #expect(unfolded.cornerRadii.topLeading == 55 && unfolded.cornerRadii.bottomTrailing == 55)
    // One display that folds down its middle: a crease, not a gap between two screens.
    #expect(unfolded.crease == CGRect(x: 475.5, y: 0, width: 0, height: 669))
    #expect(unfolded.showsSidebar)
    // The status column holds the island and clears the time below it.
    #expect(DuoDisplays.outerIsland.minX >= folded.size.width - folded.safeArea.trailing)
    #expect(DuoDisplays.outerIsland.maxX <= folded.size.width)
  }

  @Test("size classes, layout width and hinge posture match the device and posture")
  func sizeClasses() {
    func classes(_ screen: CatalogScreen) -> [UserInterfaceSizeClass] {
      [screen.horizontalSizeClass, screen.verticalSizeClass]
    }
    #expect(classes(CatalogScreen(.iPhone)) == [.compact, .regular])
    #expect(classes(CatalogScreen(.iPhone, landscape: true)) == [.compact, .compact])
    #expect(classes(CatalogScreen(.iPadPro11)) == [.regular, .regular])
    #expect(classes(CatalogScreen(.iPadPro13, landscape: true)) == [.regular, .regular])
    #expect(classes(CatalogScreen(.iPadSplitThird)) == [.compact, .regular])
    #expect(classes(CatalogScreen(.iPadSplitHalf)) == [.regular, .regular])
    #expect(classes(CatalogScreen(.duo)) == [.compact, .regular])
    #expect(classes(CatalogScreen(.duo, unfolded: true)) == [.regular, .regular])
    #expect(CatalogScreen(.iPhone).layoutWidth == .compact)
    #expect(CatalogScreen(.iPhone).displayScale == 3)
    #expect(CatalogScreen(.iPadPro13).displayScale == 2)
    // Folded, `onHingeChange` reports `closed` at 0 degrees.
    #expect(CatalogScreen(.duo).hingePosture == .closed)
    #expect(CatalogScreen(.duo, unfolded: true).hingePosture == .fullyOpen)
    #expect(!CatalogScreen(.iPadPro13).showsSidebar)
    #expect(CatalogScreen(.iPadPro13, landscape: true).showsSidebar)
  }

  @Test("a framed page takes the whole device; frames off and the Mac take the screen")
  func layouts() {
    let page = CatalogCanvas.anyDevice
    let phone = CatalogScreen(.iPhone)
    let framed = CatalogLayout(canvas: page, screen: phone)
    #expect(framed.isFramed)
    #expect(CGSize(width: framed.width, height: framed.height ?? 0) == phone.framedSize)
    let bare = CatalogLayout(canvas: page, screen: phone, framed: false)
    #expect(CGSize(width: bare.width, height: bare.height ?? 0) == phone.size)
    #expect(!CatalogLayout(canvas: page, screen: CatalogScreen(.mac)).isFramed)
    let column = CatalogLayout(canvas: .column(width: 760), screen: phone)
    #expect(column.width == phone.size.width)
    #expect(!column.isFramed)
  }

  @Test("launch options take device ids and the frame setting")
  func launchDevices() throws {
    let options = try GalleryLaunchOptions(
      arguments: ["app", "--gallery-devices", "iPhone,duo-unfolded", "--gallery-frames", "off"],
      environment: ["OMNIGENT_GALLERY_DEVICE": "iPadPro13-landscape"])
    #expect(!options.frames)
    #expect(options.devices.compactMap(CatalogScreen.init(id:)).count == 2)
    #expect(CatalogScreen(id: options.device ?? "") == CatalogScreen(.iPadPro13, landscape: true))
    #expect(throws: GalleryLaunchOptions.ParseError.self) {
      try GalleryLaunchOptions(arguments: ["app", "--gallery-frames", "maybe"], environment: [:])
    }
    #expect(throws: GalleryLaunchOptions.ParseError.self) {
      try GalleryLaunchOptions(
        arguments: ["app", "--gallery-devices", "duo-landscape"], environment: [:])
    }
  }
}
