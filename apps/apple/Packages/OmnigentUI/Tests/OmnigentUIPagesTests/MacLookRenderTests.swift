import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentWorkspaceUI

#if os(macOS)
  @testable import OmnigentUITestSupport
#elseif os(iOS)
  import UIKit
#endif

/// The screens ported from the web this week, drawn from generic data so their look can be
/// checked against the Mac's and iOS's conventions. Set `OMNIGENT_UI_RENDER_DIR`
/// (`TEST_RUNNER_OMNIGENT_UI_RENDER_DIR` for the simulator) to keep the PNGs, and
/// `OMNIGENT_LOOK_SCREENS` to a comma-separated list of name prefixes to draw only those.
enum LookScreen: String, CaseIterable, CustomTestStringConvertible {
  case decisionsQuestion = "decisions-question"
  /// The card under a window root's accent: the theme's, then the system's.
  case decisionsQuestionThemeAccent = "decisions-question-theme-accent"
  case decisionsQuestionSystemAccent = "decisions-question-system-accent"
  case decisionsForm = "decisions-form"
  case decisionsDates = "decisions-dates"
  case decisionsPage = "decisions-page"
  case decisionsSuggestion = "decisions-suggestion"
  case decisionsPlanModes = "decisions-plan-modes"
  case decisionsCodexQuestion = "decisions-codex-question"
  case decisionsOptionalFields = "decisions-optional-fields"
  case decisionsLongSelect = "decisions-long-select"
  case decisionsQuestionFallback = "decisions-question-fallback"
  case decisionsWorkflowQuestion = "decisions-workflow-question"
  case markersChat = "markers-chat"
  case composerRewind = "composer-rewind"
  case composerMcp = "composer-mcp"
  case composerEditResend = "composer-edit-resend"
  /// The composer context's details with Reconnect Host and Switch Host.
  case composerHostActions = "composer-host-actions"
  case prChanges = "pr-changes"
  case prFind = "pr-find"
  case prCommits = "pr-commits"
  case prThreads = "pr-threads"
  case prFileHeader = "pr-file-header"
  case inboxSuggestion = "inbox-suggestion"
  case inboxFailure = "inbox-failure"
  case settingsAgents = "settings-agents"
  case settingsSessions = "settings-sessions"
  case settingsHarness = "settings-harness"
  case settingsPlugin = "settings-plugin"
  case settingsAdminGeneral = "settings-admin-general"
  case sessionsDeleteAutomation = "sessions-delete-automation"
  case sessionsRecentSwitcher = "sessions-recent-switcher"
  case shareManaged = "share-managed"
  case composerReconnectThisMac = "composer-reconnect-this-mac"
  case transcriptPresence = "transcript-presence"
  case tasksPlan = "tasks-plan"
  case tasksStopping = "tasks-stopping"
  case tasksHistory = "tasks-history"
  case automationsLegacyShare = "automations-legacy-share"
  case automationsNew = "automations-new"
  /// Runs that follow a plan: tasks, the agent's last words and the plan's buttons.
  case automationsRunTasks = "automations-run-tasks"
  case automationsTriggerWorkflow = "automations-trigger-workflow"
  case automationsExamples = "automations-examples"
  case automationsRunHighlight = "automations-run-highlight"
  case automationsNewDefaults = "automations-new-defaults"
  case automationsSandboxNotice = "automations-sandbox-notice"
  case viewersPDF = "viewers-pdf"
  case viewersVideo = "viewers-video"
  /// Recording links in a reply: a workspace recording and a remote one.
  case viewersChatVideo = "viewers-chat-video"
  case projectsNewFolder = "projects-new-folder"
  case projectsNewRepository = "projects-new-repository"
  case viewersTable = "viewers-table"
  case viewersTableFiltered = "viewers-table-filtered"
  case projectBoard = "project-board"
  case projectBoardEmpty = "project-board-empty"
  case projectBoardQuickView = "project-board-quick-view"
  case projectBoardComposer = "project-board-composer"
  case workflowsList = "workflows-list"
  case workflowsEmpty = "workflows-empty"
  case workflowNew = "workflows-new"
  case workflowDetail = "workflows-detail"
  case workflowDetailProposal = "workflows-detail-proposal"
  case workflowDetailDraft = "workflows-detail-draft"
  case workflowDetailShared = "workflows-detail-shared"
  case workflowRunSheet = "workflows-run-sheet"
  case workflowTasks = "workflows-tasks"
  /// The connection line while the core restores the connection, once retrying stopped, the
  /// moment it is back, and the saved copy shown offline.
  case connectionReconnecting = "connection-reconnecting"
  case connectionUnreachable = "connection-unreachable"
  case connectionReconnected = "connection-reconnected"
  case connectionOffline = "connection-offline"

  var testDescription: String { rawValue }

  /// Whether `OMNIGENT_LOOK_SCREENS` asks for this screen; all of them when it is unset.
  var isSelected: Bool {
    let environment = ProcessInfo.processInfo.environment
    guard let list = environment["OMNIGENT_LOOK_SCREENS"], !list.isEmpty else { return true }
    return list.split(separator: ",").contains { rawValue.hasPrefix($0) }
  }

  /// The width a Mac draws it at; the height follows the content unless ``macHeight`` says.
  var macWidth: CGFloat {
    switch self {
    case .prChanges, .prFind, .prCommits, .inboxSuggestion, .inboxFailure: 900
    case .viewersTable, .viewersTableFiltered: 820
    case .projectBoard, .projectBoardEmpty, .projectBoardQuickView, .projectBoardComposer: 1_360
    case .workflowDetailDraft: 1_240
    case .workflowsList, .workflowsEmpty, .workflowDetail, .workflowDetailProposal,
      .workflowDetailShared:
      960
    case .workflowNew, .workflowRunSheet: 560
    case .workflowTasks: 480
    case .composerMcp, .markersChat, .viewersPDF, .viewersVideo, .viewersChatVideo: 736
    case .composerRewind, .tasksPlan, .tasksStopping, .prFileHeader: 480
    case .tasksHistory: 420
    case .sessionsDeleteAutomation: 460
    case .automationsLegacyShare, .automationsRunTasks, .automationsExamples,
      .automationsRunHighlight:
      900
    case .automationsNew, .automationsTriggerWorkflow, .automationsNewDefaults,
      .automationsSandboxNotice:
      600
    case .shareManaged, .composerReconnectThisMac: 520
    case .transcriptPresence: 240
    case .projectsNewFolder, .projectsNewRepository: 460
    case .settingsAgents, .settingsSessions, .settingsHarness, .settingsPlugin,
      .settingsAdminGeneral:
      640
    default: 640
    }
  }

  /// A fixed height for screens that fill their space.
  var macHeight: CGFloat? {
    switch self {
    case .prChanges, .prFind, .prCommits: 560
    case .inboxSuggestion, .inboxFailure: 640
    case .composerRewind: 460
    case .tasksPlan: 620
    case .tasksStopping: 420
    case .automationsLegacyShare: 640
    case .automationsRunTasks, .automationsRunHighlight: 900
    case .automationsNew: 760
    case .automationsNewDefaults, .automationsSandboxNotice: 1_640
    case .shareManaged: 760
    case .composerReconnectThisMac: 820
    case .projectsNewFolder, .projectsNewRepository: 440
    case .settingsAgents, .settingsSessions, .settingsHarness, .settingsPlugin: 560
    case .viewersPDF: 520
    case .viewersTable, .viewersTableFiltered: 480
    case .projectBoard, .projectBoardEmpty, .projectBoardQuickView, .projectBoardComposer: 780
    case .workflowsList, .workflowsEmpty: 720
    case .workflowDetail, .workflowDetailProposal, .workflowDetailShared: 1_280
    case .workflowDetailDraft: 760
    case .workflowNew: 440
    case .workflowRunSheet: 480
    case .workflowTasks: 560
    default: nil
    }
  }

  /// Screens that fill the window rather than sit in a column.
  var fillsScreen: Bool { macHeight != nil }

  @MainActor var view: AnyView {
    typealias Fixture = LookFixtures
    switch self {
    case .decisionsQuestion:
      return AnyView(Fixture.card(PreviewData.claudeQuestion, draft: Fixture.questionDraft))
    case .decisionsQuestionThemeAccent, .decisionsQuestionSystemAccent:
      // As `omnigentAppearance` sets a window's root.
      return AnyView(
        Fixture.card(PreviewData.claudeQuestion, draft: Fixture.questionDraft)
          .tint(ThemeColor.controlTint)
          .omnigentTheme(.omni, systemAccent: self == .decisionsQuestionSystemAccent))
    case .decisionsForm: return AnyView(Fixture.card(PreviewData.form, draft: Fixture.formDraft))
    case .decisionsDates: return AnyView(Fixture.card(Fixture.dates, draft: Fixture.datesDraft))
    case .decisionsPage: return AnyView(Fixture.card(PreviewData.externalPage))
    case .decisionsSuggestion: return AnyView(Fixture.card(PreviewData.claudeSuggestion))
    case .decisionsPlanModes: return AnyView(Fixture.card(PreviewData.planReviewModes))
    case .decisionsCodexQuestion:
      return AnyView(
        Fixture.card(Fixture.codexQuestion, draft: Fixture.codexQuestionDraft, context: "Codex"))
    case .decisionsOptionalFields:
      return AnyView(
        Fixture.card(
          Fixture.optionalFields, draft: Fixture.optionalFieldsDraft, context: "Release notes"))
    case .decisionsLongSelect:
      return AnyView(
        Fixture.card(Fixture.longSelect, draft: Fixture.longSelectDraft, context: "Pi"))
    case .decisionsQuestionFallback: return AnyView(Fixture.card(Fixture.questionFallback))
    case .decisionsWorkflowQuestion:
      return AnyView(Fixture.card(Fixture.workflowQuestion, context: "Omnigent"))
    case .markersChat: return AnyView(LookMarkers())
    case .composerRewind: return AnyView(Fixture.rewind)
    case .composerMcp: return AnyView(Fixture.mcpBar)
    case .composerEditResend: return AnyView(LookEditResend())
    case .composerHostActions:
      return AnyView(
        ExecutionContextDetails(
          context: ComposerSamples.context,
          hostActions: ExecutionHostActions(reconnect: {}, switchHost: {})
        )
        .omnigentAppearance(.omni))
    case .prChanges: return AnyView(Fixture.changes(find: false))
    case .prFind: return AnyView(Fixture.changes(find: true))
    case .prCommits: return AnyView(Fixture.commits)
    case .prThreads: return AnyView(Fixture.threads)
    case .prFileHeader: return AnyView(Fixture.fileHeader)
    case .inboxSuggestion: return AnyView(Fixture.inbox([Fixture.suggestion, Fixture.failure]))
    case .inboxFailure: return AnyView(Fixture.inbox([Fixture.failure]))
    case .settingsAgents: return AnyView(Fixture.settings { Fixture.agents })
    case .settingsSessions: return AnyView(Fixture.settings { Fixture.sessions })
    case .settingsHarness: return AnyView(Fixture.settings { Fixture.harness })
    case .settingsPlugin: return AnyView(Fixture.settings { Fixture.pluginPage })
    case .settingsAdminGeneral: return AnyView(Fixture.settings { Fixture.adminGeneral })
    case .sessionsDeleteAutomation: return AnyView(Fixture.deleteAutomationSource)
    case .sessionsRecentSwitcher: return AnyView(Fixture.recentSwitcher)
    case .shareManaged: return AnyView(Fixture.shareManaged)
    case .composerReconnectThisMac: return AnyView(Fixture.reconnectThisMac)
    case .transcriptPresence: return AnyView(Fixture.presence)
    case .tasksPlan: return AnyView(Fixture.tasks)
    case .tasksStopping: return AnyView(Fixture.tasksStopping)
    case .tasksHistory: return AnyView(Fixture.taskHistory)
    case .automationsLegacyShare: return AnyView(Fixture.legacyShareDetail)
    case .automationsNew: return AnyView(Fixture.newAutomation)
    case .automationsRunTasks: return AnyView(Fixture.automationRunTasks())
    case .automationsRunHighlight: return AnyView(Fixture.automationRunTasks(highlighted: "r1"))
    case .automationsNewDefaults:
      return AnyView(Fixture.newAutomationDefaults.omnigentAppearance(.omni))
    case .automationsSandboxNotice:
      return AnyView(Fixture.sandboxNotice.omnigentAppearance(.omni))
    case .automationsExamples:
      return AnyView(AutomationExamplesView(back: {}, done: {}).omnigentAppearance(.omni))
    case .automationsTriggerWorkflow: return AnyView(Fixture.triggerWorkflow)
    case .viewersPDF: return AnyView(PDFPreviewView(data: Fixture.pdf, truncated: false))
    case .viewersVideo: return AnyView(Fixture.video)
    case .viewersChatVideo: return AnyView(Fixture.chatVideo)
    case .projectsNewFolder: return AnyView(Fixture.newProjectFolder)
    case .projectsNewRepository: return AnyView(Fixture.newProjectRepository)
    case .viewersTable: return AnyView(Fixture.dataTableViewer)
    case .viewersTableFiltered: return AnyView(Fixture.dataTableFiltered)
    case .projectBoard, .projectBoardEmpty, .projectBoardQuickView, .projectBoardComposer:
      return AnyView(LookFixtures.board(self))
    case .workflowsList, .workflowsEmpty, .workflowNew, .workflowDetail, .workflowDetailProposal,
      .workflowDetailDraft, .workflowDetailShared, .workflowRunSheet, .workflowTasks:
      return LookFixtures.workflows(self)
    case .connectionReconnecting, .connectionUnreachable, .connectionReconnected,
      .connectionOffline:
      return AnyView(LookFixtures.connection(self))
    }
  }
}

#if os(macOS)
  /// Each screen at a Mac's width, light and dark.
  @Suite("Ported screens drawn on a Mac", .serialized)
  @MainActor
  struct MacLookRenderTests {
    @Test("draws the screen", arguments: LookScreen.allCases)
    func render(screen: LookScreen) throws {
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
  /// Each screen on an iPhone and an iPad, drawn by UIKit in the simulator.
  @Suite("Ported screens drawn on iPhone and iPad", .serialized)
  @MainActor
  struct IOSLookRenderTests {
    enum Device: String, CaseIterable, CustomTestStringConvertible {
      case iphone, ipad

      var testDescription: String { rawValue }
      var size: CGSize {
        self == .iphone ? CGSize(width: 390, height: 844) : CGSize(width: 820, height: 1_180)
      }
    }

    @Test("draws the screen", arguments: LookScreen.allCases, Device.allCases)
    func render(screen: LookScreen, device: Device) throws {
      guard screen.isSelected else { return }
      let size = device.size
      let content =
        screen.fillsScreen
        ? AnyView(screen.view)
        : AnyView(ScrollView { screen.view.frame(maxWidth: .infinity, alignment: .top) })
      let root =
        content
        .environment(\.layoutWidth, device == .iphone ? .compact : .regular)
        .environment(\.horizontalSizeClass, device == .iphone ? .compact : .regular)
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
      try data.write(to: folder.appending(path: "\(screen.rawValue)-\(device.rawValue).png"))
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
