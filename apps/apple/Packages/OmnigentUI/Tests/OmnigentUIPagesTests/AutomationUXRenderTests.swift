import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  @testable import OmnigentUITestSupport
#elseif os(iOS)
  import UIKit
#endif

/// The Automations screens compared with the web's, each drawn from generic data. Set
/// `OMNIGENT_UI_RENDER_DIR` (`TEST_RUNNER_OMNIGENT_UI_RENDER_DIR` for the iOS simulator) to keep
/// the PNGs.
enum AutomationUXScreen: String, CaseIterable, CustomTestStringConvertible {
  case list, empty, templates, editorSchedule, editorTrigger, editorEdit, detail

  var testDescription: String { rawValue }
  var isSheet: Bool { [.editorSchedule, .editorTrigger, .editorEdit].contains(self) }

  @MainActor var view: AnyView {
    typealias Fixture = AutomationUXFixtures
    return switch self {
    case .list:
      AnyView(AutomationsView(state: Fixture.list, actions: Fixture.listActions))
    case .empty:
      AnyView(AutomationsView(state: Fixture.empty, actions: Fixture.listActions))
    case .templates:
      AnyView(
        AutomationsView(state: Fixture.list, actions: Fixture.listActions, initialTab: .templates))
    case .editorSchedule:
      AnyView(
        AutomationEditorSheet(
          draft: .constant(Fixture.scheduleDraft), context: Fixture.editorContext(), save: {},
          cancel: {}))
    case .editorTrigger:
      AnyView(
        AutomationEditorSheet(
          draft: .constant(Fixture.triggerDraft), context: Fixture.triggerContext, save: {},
          cancel: {}))
    case .editorEdit:
      AnyView(
        AutomationEditorSheet(
          draft: .constant(Fixture.editedDraft), context: Fixture.editorContext(editing: true),
          save: {}, cancel: {}))
    case .detail:
      AnyView(AutomationDetailView(state: Fixture.detail, actions: Fixture.detailActions))
    }
  }
}

#if os(macOS)
  /// Each screen at a Mac's width, the editor at the web dialog's.
  @Suite("Automations screens drawn on a Mac", .serialized)
  @MainActor
  struct AutomationUXRenderTests {
    @Test("draws the screen", arguments: AutomationUXScreen.allCases)
    func render(screen: AutomationUXScreen) throws {
      let rendered = try RenderSupport.render(
        screen.view, width: screen.isSheet ? 720 : 960, height: 900, scheme: .light,
        layout: .regular)
      #expect(RenderSupport.inkCoverage(rendered) > 0.005, "\(screen) is blank")
      try RenderSupport.write(rendered, name: "automations-\(screen.rawValue)-mac")
    }
  }
#endif

#if os(iOS)
  /// Each screen on an iPhone and an iPad, drawn by UIKit in the simulator: a form, menus and
  /// size classes as iOS draws them.
  @Suite("Automations screens drawn on iPhone and iPad", .serialized)
  @MainActor
  struct AutomationUXDeviceRenderTests {
    enum Device: String, CaseIterable, CustomTestStringConvertible {
      case iphone, ipad

      var testDescription: String { rawValue }

      /// The screen; the editor is a form sheet on an iPad.
      func size(sheet: Bool) -> CGSize {
        if self == .iphone { return CGSize(width: 390, height: 844) }
        if sheet { return CGSize(width: 700, height: 1_000) }
        return CGSize(width: 820, height: 1_180)
      }

      var sizeClass: UserInterfaceSizeClass { self == .iphone ? .compact : .regular }
    }

    @Test("draws the screen", arguments: AutomationUXScreen.allCases, Device.allCases)
    func render(screen: AutomationUXScreen, device: Device) throws {
      let size = device.size(sheet: screen.isSheet)
      let root = screen.view
        .environment(\.layoutWidth, device == .iphone ? .compact : .regular)
        .environment(\.horizontalSizeClass, device.sizeClass)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))
      let controller = UIHostingController(rootView: root)
      controller.traitOverrides.horizontalSizeClass = device == .iphone ? .compact : .regular
      let bounds = CGRect(origin: .zero, size: size)
      let window = Self.window(bounds)
      window.rootViewController = controller
      window.isHidden = false
      for _ in 0..<8 {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      var drew = false
      let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
        drew = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        if !drew { window.layer.render(in: context.cgContext) }
      }
      window.isHidden = true
      let colors = Self.colorCount(image)
      #expect(
        colors > 8,
        "\(screen) is blank on \(device): scene \(window.windowScene != nil), drew \(drew)")
      let data = try #require(image.pngData())
      guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_UI_RENDER_DIR"] else {
        return
      }
      let folder = URL(filePath: directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(
        to: folder.appending(path: "automations-\(screen.rawValue)-\(device.rawValue).png"))
    }

    /// A window in the test host's scene, or, where the host has none, one without a scene.
    /// `UIView`'s initializer makes it: the window's own is deprecated for scenes.
    private static func window(_ bounds: CGRect) -> UIWindow {
      let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
      if let scene = scene as? UIWindowScene {
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        return window
      }
      let type: UIView.Type = UIWindow.self
      guard let window = type.init(frame: bounds) as? UIWindow else {
        preconditionFailure("a window type makes a window")
      }
      return window
    }

    /// How many distinct colors a 32 x 32 sample of `image` has: a blank drawing has one.
    private static func colorCount(_ image: UIImage) -> Int {
      let side = 32
      var pixels = [UInt8](repeating: 0, count: side * side * 4)
      let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard
          let cgImage = image.cgImage,
          let context = unsafe CGContext(
            data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return true
      }
      guard drew else { return 0 }
      var seen = Set<UInt32>()
      for index in stride(from: 0, to: pixels.count, by: 4) {
        seen.insert(
          UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
      }
      return seen.count
    }
  }
#endif
