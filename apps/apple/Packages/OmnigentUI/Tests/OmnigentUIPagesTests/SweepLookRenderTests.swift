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
  case smartRouting = "sweep-smart-routing"
  case mcpPanel = "sweep-mcp-panel"
  case quickAnswer = "sweep-quick-answer"
  case markdownContents = "sweep-markdown-toc"
  case sideChatSettings = "sweep-side-chat-model"
  case advisorInbox = "sweep-advisor-inbox"
  case advisorInboxEmpty = "sweep-advisor-inbox-empty"
  case advisorSettings = "sweep-advisor-settings"
  case advisorAdmin = "sweep-advisor-admin"
  case approvalLink = "sweep-approval-link"
  case approvalLinkResolved = "sweep-approval-link-resolved"
  case staleProfile = "sweep-sandbox-profile-changed"
  case brandedNewSession = "sweep-branded-new-session"
  case adminView = "sweep-admin-view"
  case mcpSwitches = "sweep-mcp-switches"
  case extensionFailed = "sweep-extension-failed"
  case extensionNotFound = "sweep-extension-not-found"
  case extensionSidebar = "sweep-extension-sidebar"
  case switchHostSandbox = "sweep-c-switch-host-sandbox"
  case executionStream = "sweep-c-execution-stream"
  case sessionOverview = "sweep-c-session-overview"
  case agentCosts = "sweep-c-agent-costs"
  case canvasQuickView = "sweep-c-canvas-quick-view"
  case importReview = "sweep-c-import-review"
  case questionSubmitBlocked = "sweep-e-question-submit-blocked"
  case mutedRows = "sweep-e-muted-rows"
  case shellComposer = "sweep-e-shell-composer"
  case automationsSorted = "sweep-e-automations-sorted"
  case terminalSplit = "sweep-f-terminal-split"
  case composerTints = "sweep-f-composer-tints"
  case overviewChanges = "sweep-f-overview-changes"
  case spreadsheetSheets = "sweep-f-spreadsheet-sheets"
  case spreadsheetUnreadable = "sweep-f-spreadsheet-unreadable"
  case designRequests = "sweep-f-design-requests"
  case designOutbox = "sweep-f-design-outbox"
  case rruleEditor = "sweep-g-rrule-editor"
  case floatingPanel = "sweep-g-floating-panel"

  var testDescription: String { rawValue }

  var isSelected: Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let list = environment["OMNIGENT_LOOK_SCREENS"], !list.isEmpty else { return true }
    return list.split(separator: ",").contains { rawValue.hasPrefix($0) }
  }

  var macWidth: CGFloat {
    switch self {
    case .canvasQuickView: 960
    case .automationsSorted, .terminalSplit, .spreadsheetSheets: 760
    case .shellComposer, .composerTints, .designRequests, .designOutbox, .floatingPanel: 680
    case .rruleEditor: 560
    default: 480
    }
  }

  var macHeight: CGFloat? {
    switch self {
    case .prList, .prListAsleep: 320
    case .prComments: 560
    case .prUnresolved, .prRemote, .markdownContents: 420
    case .sideChatSettings: 520
    case .advisorInbox, .advisorInboxEmpty: 520
    case .advisorSettings: 300
    case .advisorAdmin: 760
    case .approvalLink: 460
    case .approvalLinkResolved: 300
    case .brandedNewSession: 620
    case .adminView: 260
    case .mcpSwitches: 300
    case .extensionFailed, .extensionNotFound: 360
    case .extensionSidebar: 620
    case .switchHostSandbox, .executionStream: 460
    case .sessionOverview: 360
    case .agentCosts: 300
    case .canvasQuickView: 420
    case .importReview: 480
    case .mutedRows: 160
    case .automationsSorted: 640
    case .terminalSplit: 420
    case .spreadsheetSheets: 440
    case .spreadsheetUnreadable: 320
    case .prSummary, .prSuggestion, .toolFields, .smartRouting, .mcpPanel,
      .quickAnswer, .staleProfile, .questionSubmitBlocked, .shellComposer, .composerTints,
      .overviewChanges, .designRequests, .designOutbox, .rruleEditor, .floatingPanel:
      nil
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
    case .smartRouting: return AnyView(Fixture.smartRouting)
    case .mcpPanel: return AnyView(Fixture.mcpPanel)
    case .quickAnswer: return AnyView(Fixture.quickAnswer)
    case .markdownContents: return AnyView(Fixture.markdownContents)
    case .sideChatSettings: return AnyView(Fixture.sideChatSettings)
    case .advisorInbox: return AnyView(Fixture.advisorInbox(empty: false))
    case .advisorInboxEmpty: return AnyView(Fixture.advisorInbox(empty: true))
    case .advisorSettings: return AnyView(Fixture.advisorSettings)
    case .advisorAdmin: return AnyView(Fixture.advisorAdmin)
    case .approvalLink: return AnyView(Fixture.approvalLink(pending: true))
    case .approvalLinkResolved: return AnyView(Fixture.approvalLink(pending: false))
    case .staleProfile: return AnyView(Fixture.staleProfile)
    case .brandedNewSession: return AnyView(Fixture.brandedNewSession)
    case .adminView: return AnyView(Fixture.adminView)
    case .mcpSwitches: return AnyView(Fixture.mcpSwitches)
    case .extensionFailed: return AnyView(Fixture.extensionPage(found: true))
    case .extensionNotFound: return AnyView(Fixture.extensionPage(found: false))
    case .extensionSidebar: return AnyView(Fixture.extensionSidebar)
    case .switchHostSandbox: return AnyView(Fixture.switchHostSandbox)
    case .executionStream: return AnyView(Fixture.executionStream)
    case .sessionOverview: return AnyView(Fixture.sessionOverview)
    case .agentCosts: return AnyView(Fixture.agentCosts)
    case .canvasQuickView: return AnyView(Fixture.canvasQuickView)
    case .importReview: return AnyView(Fixture.importReview)
    case .questionSubmitBlocked: return AnyView(Fixture.questionSubmitBlocked)
    case .mutedRows: return AnyView(Fixture.mutedRows)
    case .shellComposer: return AnyView(Fixture.shellComposer)
    case .automationsSorted: return AnyView(Fixture.automationsSorted)
    case .terminalSplit: return AnyView(Fixture.terminalSplit)
    case .composerTints: return AnyView(Fixture.composerTints)
    case .overviewChanges: return AnyView(Fixture.overviewChanges)
    case .spreadsheetSheets: return AnyView(Fixture.spreadsheetSheets)
    case .spreadsheetUnreadable: return AnyView(Fixture.spreadsheetUnreadable)
    case .designRequests: return AnyView(Fixture.designRequests)
    case .designOutbox: return AnyView(Fixture.designOutbox)
    case .rruleEditor: return AnyView(Fixture.rruleEditor)
    case .floatingPanel: return AnyView(Fixture.floatingPanel)
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
      let window = Self.window(bounds)
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
  }
#endif
