import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  @testable import OmnigentUITestSupport
#elseif os(iOS)
  import UIKit
#endif

/// The screens the parity sweep changed, drawn from generic data to check their look against
/// the Mac's and iOS's conventions. `OMNIGENT_UI_RENDER_DIR` keeps the PNGs and
/// `OMNIGENT_LOOK_SCREENS` picks screens by name prefix, as for ``LookScreen``.
enum SweepLookScreen: String, CaseIterable, CustomTestStringConvertible {
  case prList = "sweep-pr-list"
  case prListAsleep = "sweep-pr-list-asleep"
  case prSummary = "sweep-pr-summary"
  case prComments = "sweep-pr-comments"
  case prSuggestion = "sweep-pr-suggestion"
  case prUnresolved = "sweep-pr-unresolved"
  case prRemote = "sweep-pr-remote"
  case toolFields = "sweep-tool-fields"

  var testDescription: String { rawValue }

  var isSelected: Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let list = environment["OMNIGENT_LOOK_SCREENS"], !list.isEmpty else { return true }
    return list.split(separator: ",").contains { rawValue.hasPrefix($0) }
  }

  var macWidth: CGFloat { 480 }

  var macHeight: CGFloat? {
    switch self {
    case .prList, .prListAsleep: 320
    case .prComments: 560
    case .prUnresolved, .prRemote: 420
    case .prSummary, .prSuggestion, .toolFields: nil
    }
  }

  var fillsScreen: Bool { macHeight != nil }

  @MainActor var view: AnyView {
    typealias Fixture = SweepLookFixtures
    switch self {
    case .prList: return AnyView(Fixture.list(offline: false))
    case .prListAsleep: return AnyView(Fixture.list(offline: true))
    case .prSummary: return AnyView(Fixture.summaryTab)
    case .prComments: return AnyView(Fixture.commentsTab)
    case .prSuggestion: return AnyView(Fixture.suggestion)
    case .prUnresolved: return AnyView(Fixture.unresolved)
    case .prRemote: return AnyView(Fixture.remote)
    case .toolFields: return AnyView(Fixture.toolFields)
    }
  }
}

#if os(macOS)
  /// Each sweep screen at a Mac's width, light and dark.
  @Suite("Sweep screens drawn on a Mac", .serialized)
  @MainActor
  struct SweepMacLookRenderTests {
    @Test("draws the screen", arguments: SweepLookScreen.allCases)
    func render(screen: SweepLookScreen) throws {
      guard screen.isSelected else { return }
      for scheme in [ColorScheme.light, .dark] {
        let rendered = try RenderSupport.render(
          screen.view, width: screen.macWidth, height: screen.macHeight, scheme: scheme,
          layout: .regular)
        #expect(RenderSupport.inkCoverage(rendered) > 0.002, "\(screen) is blank")
        let suffix = scheme == .dark ? "-dark" : ""
        try RenderSupport.write(rendered, name: "\(screen.rawValue)-mac\(suffix)")
      }
    }
  }
#endif

#if os(iOS)
  /// Each sweep screen on an iPhone and an iPad, drawn by UIKit in the simulator.
  @Suite("Sweep screens drawn on iPhone and iPad", .serialized)
  @MainActor
  struct SweepIOSLookRenderTests {
    @Test("draws the screen", arguments: SweepLookScreen.allCases, [false, true])
    func render(screen: SweepLookScreen, pad: Bool) throws {
      guard screen.isSelected else { return }
      let size = pad ? CGSize(width: 820, height: 1_180) : CGSize(width: 390, height: 844)
      let content =
        screen.fillsScreen
        ? AnyView(screen.view)
        : AnyView(ScrollView { screen.view.frame(maxWidth: .infinity, alignment: .top) })
      let root =
        content
        .environment(\.layoutWidth, pad ? .regular : .compact)
        .environment(\.horizontalSizeClass, pad ? .regular : .compact)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))
      let controller = UIHostingController(rootView: root)
      controller.traitOverrides.horizontalSizeClass = pad ? .regular : .compact
      let bounds = CGRect(origin: .zero, size: size)
      let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene }
      let window = (scene as? UIWindowScene).map { UIWindow(windowScene: $0) } ?? UIWindow()
      window.frame = bounds
      window.rootViewController = controller
      window.isHidden = false
      for _ in 0..<8 {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
        if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
          window.layer.render(in: context.cgContext)
        }
      }
      window.isHidden = true
      let data = try #require(image.pngData())
      guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_UI_RENDER_DIR"] else {
        return
      }
      let folder = URL(filePath: directory, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let device = pad ? "ipad" : "iphone"
      try data.write(to: folder.appending(path: "\(screen.rawValue)-\(device).png"))
    }
  }
#endif
