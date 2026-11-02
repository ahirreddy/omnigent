import Foundation
import OmnigentAuthUI
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Gallery catalog")
struct GalleryCatalogTests {
  private let context = CatalogContext(
    screen: CatalogScreen(.mac),
    preferences: ThemePreferences(defaults: CatalogSettings.scratchDefaults))

  @Test("ids are unique and file-name safe, and every section has entries")
  func registry() {
    let entries = GalleryCatalog.entries
    #expect(Set(entries.map(\.id)).count == entries.count)
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
    for entry in entries {
      #expect(!entry.states.isEmpty, "\(entry.id) has no states")
      #expect(Set(entry.states.map(\.id)).count == entry.states.count, "\(entry.id)")
      for state in entry.states {
        #expect(state.id.unicodeScalars.allSatisfy(safe.contains), "\(entry.id)/\(state.id)")
        if let parent = state.branchesFrom {
          #expect(entry.states.contains { $0.id == parent }, "\(entry.id)/\(state.id)")
        }
      }
    }
    for section in CatalogSection.allCases {
      #expect(entries.contains { $0.section == section }, "\(section) is empty")
    }
  }

  @Test("the required flows are catalogued")
  func requiredFlows() {
    let flows = Set(GalleryCatalog.entries.filter { $0.section == .flows }.map(\.id))
    for id in [
      "flows.newSession.new-session", "flows.decisions.approval", "flows.transcript.subagent",
      "flows.inbox.triage", "flows.composer.queue-steer-stop", "flows.palette.palette-jump",
      "flows.tabs.tabs", "flows.signIn.first-launch",
    ] {
      #expect(flows.contains(id), "\(id) is missing")
    }
  }

  @Test("search matches every term in titles, keywords, areas and state titles")
  func search() {
    let entries = GalleryCatalog.entries
    #expect(GalleryCatalog.search(entries, query: "").count == entries.count)
    #expect(GalleryCatalog.search(entries, query: "  ").count == entries.count)
    let composer = GalleryCatalog.search(entries, query: "composer queue")
    #expect(composer.contains { $0.id == "components.composer.queue" })
    #expect(
      composer.allSatisfy { GalleryCatalog.searchText($0).localizedStandardContains("queue") })
    #expect(GalleryCatalog.search(entries, query: "CMD K").contains { $0.section == .flows })
    #expect(GalleryCatalog.search(entries, query: "Tell the agent instead").count >= 2)
    #expect(GalleryCatalog.search(entries, query: "no-such-thing-anywhere").isEmpty)
  }

  @Test("groups follow area order and export filters match ids or titles")
  func groupsAndFilters() {
    let entries = GalleryCatalog.entries
    let groups = GalleryCatalog.groups(entries, section: .components)
    let order = groups.map(\.area).compactMap { CatalogArea.allCases.firstIndex(of: $0) }
    #expect(order == order.sorted())
    #expect(groups.allSatisfy { group in group.entries.allSatisfy { $0.area == group.area } })
    #expect(GalleryCatalog.filtered(entries, by: []).count == entries.count)
    let filtered = GalleryCatalog.filtered(entries, by: ["components.composer", "Inbox Triage"])
    #expect(filtered.contains { $0.id == "flows.inbox.triage" })
    #expect(
      filtered.allSatisfy { $0.id.hasPrefix("components.composer") || $0.title == "Inbox Triage" })
  }
}

@Suite("Gallery flows")
struct GalleryFlowTests {
  private let context = CatalogContext(
    screen: CatalogScreen(.mac),
    preferences: ThemePreferences(defaults: CatalogSettings.scratchDefaults))

  @Test("Back and Next stay in bounds and jump to a step")
  func navigator() {
    var navigator = CatalogFlowNavigator(stepIDs: ["a", "b", "c"])
    #expect(navigator.currentID == "a")
    #expect(!navigator.canGoBack)
    navigator.back()
    #expect(navigator.currentID == "a")
    navigator.next()
    navigator.next()
    #expect(navigator.currentID == "c")
    #expect(!navigator.canGoNext)
    navigator.next()
    #expect(navigator.position == "Step 3 of 3")
    navigator.jump(to: "b")
    #expect(navigator.currentID == "b")
    navigator.jump(to: "missing")
    #expect(navigator.currentID == "b")
    #expect(CatalogFlowNavigator(stepIDs: ["a", "b"], current: "b").index == 1)
    #expect(CatalogFlowNavigator(stepIDs: [], current: nil).position == "No steps")
  }

  @Test("a branch replays from its parent, not from the step before it")
  func branchPaths() {
    let script = ConversationFlowCatalog.approval
    let ids = script.steps.map(\.id)
    func path(_ id: String) -> [String] {
      script.path(to: ids.firstIndex(of: id) ?? -1).map { ids[$0] }
    }
    #expect(path("review") == ["working", "arrives", "review"])
    #expect(path("reject") == ["working", "arrives", "review", "reject"])
    #expect(path("tell-sent") == ["working", "arrives", "review", "tell", "tell-sent"])
    #expect(script.path(to: 99).isEmpty)
  }

  @Test("approval steps answer the request through the same response the app sends")
  func approval() {
    let script = ConversationFlowCatalog.approval
    let card = PreviewData.claudeBash
    func model(_ id: String) -> DecisionFlowModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    #expect(model("working").conversation.decisions.isEmpty)
    #expect(model("arrives").conversation.header.status == .needsResponse)
    #expect(model("review").isDockExpanded)
    #expect(model("approve").conversation.decisionPhases[card.id] == .answered(summary: "Approved"))
    #expect(model("reject").conversation.decisionPhases[card.id] == .answered(summary: "Rejected"))
    #expect(model("tell").drafts.drafts[card.id]?.isComposingFeedback == true)
    let feedback = DecisionResponse.declineWithFeedback(
      feedback: DecisionSamples.feedbackDraft.feedback)
    #expect(
      model("tell-sent").conversation.decisionPhases[card.id]
        == .answered(summary: feedback.summary))
  }

  @Test("steering queues in order, stops, and sends a queued message now")
  func steering() {
    let script = ConversationFlowCatalog.steering
    func model(_ id: String) -> SteeringFlowModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    let initialRows = model("running").conversation.rows.count
    #expect(model("steer").conversation.rows.count == initialRows + 1)
    #expect(model("steer").draft.isEmpty)
    #expect(
      model("queue-more").composer.queue.map(\.text) == [
        "Then update the changelog", "And open a pull request",
      ])
    #expect(!model("stop").composer.isRunning)
    #expect(model("stop").composer.queue.count == 2)
    let sent = model("send-queued")
    #expect(sent.composer.isRunning)
    #expect(sent.composer.queue.map(\.text) == ["And open a pull request"])
  }

  @Test("the sub-agent is answered from the parent and the child routes back")
  func subagent() {
    let script = ConversationFlowCatalog.subagent
    func model(_ id: String) -> SubagentFlowModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    #expect(SubagentGroup(state: model("running").parent)?.count(.needsYou) == 0)
    #expect(SubagentGroup(state: model("blocked").parent)?.count(.needsYou) == 1)
    #expect(SubagentGroup(state: model("answer").parent)?.count(.needsYou) == 0)
    #expect(model("open-child").child?.header.id == "sess_c1")
    #expect(model("back").child == nil)
  }

  @Test("tabs open, close and reopen through the tab model's own actions")
  func tabs() {
    let script = NavigationFlowCatalog.tabs
    func kinds(_ id: String) -> [TabKind] {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context).tabs.map(
        \.kind)
    }
    #expect(kinds("one") == [.chat])
    #expect(kinds("side-chat") == [.chat, .terminal, .browser, .sideChat])
    #expect(kinds("remote").last == .remoteBrowser)
    #expect(!kinds("close").contains(.browser))
    #expect(kinds("close").contains(.remoteBrowser))
    #expect(kinds("reopen").contains(.browser))
  }

  @Test("triage answers in place and a failure leaves the request answerable")
  func triage() {
    let script = NavigationFlowCatalog.triage
    func state(_ id: String) -> InboxViewState {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    let start = state("open").needsYouCount ?? 0
    #expect(state("approve").items[0].phase == .answered(summary: "Approved"))
    #expect((state("answer").needsYouCount ?? 0) < start)
    #expect(state("failed").items[0].isUnresolved)
  }

  @Test("the new-session flow starts a session and finishes its turn")
  func newSession() {
    let script = ConversationFlowCatalog.newSession
    func model(_ id: String) -> PlaygroundModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    #expect(model("page").selection == .newSession)
    #expect(!model("draft").startDraft.isEmpty)
    let sent = model("send")
    #expect(sent.selection != .newSession)
    #expect(sent.conversation.header.status == .running)
    let finished = model("finished")
    #expect(finished.conversation.header.status == .idle)
    #expect(finished.conversation.rows.allSatisfy { !$0.isStreaming })
  }

  @Test("first launch connects, signs in and lands on the session list")
  func firstLaunch() {
    let script = SignInCatalog.firstLaunch
    func model(_ id: String) -> SignInFlowModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    #expect(model("picker").auth.phase == .disconnected)
    #expect(model("connect").auth.phase == .discovering(serverUrl: AuthSamples.accountsUrl))
    for id in ["password", "password-submitting", "password-error", "connecting"] {
      #expect(AuthSamples.sample(id) != nil, "\(id) is not an auth sample")
    }
    #expect(model("wrong-password").auth == AuthSamples.sample("password-error")?.state)
    #expect(!model("confirming").isSignedIn)
    #expect(model("sessions").isSignedIn)
  }

  @Test("the palette jump opens the chosen session and closes the palette")
  func paletteJump() {
    let script = NavigationFlowCatalog.paletteJump
    func model(_ id: String) -> PaletteFlowModel {
      script.model(at: script.steps.firstIndex { $0.id == id } ?? 0, context: context)
    }
    #expect(model("open").isOpen)
    let typed = model("type").results
    #expect(typed.state.sessions.contains { $0.id == "sess_a2" })
    #expect(typed.state.sessions.count < model("open").results.state.sessions.count)
    let jumped = model("jump")
    #expect(!jumped.isOpen)
    #expect(jumped.page.selection == .session("sess_a2"))
  }
}

@Suite("Gallery launch and export plan")
struct GalleryLaunchTests {
  @Test("arguments win over the environment, and anything else is the host's")
  func parse() throws {
    let options = try GalleryLaunchOptions(
      arguments: [
        "OmnigentPlayground", "-NSDocumentRevisionsDebugMode", "YES", "--export-gallery",
        "/tmp/out", "--gallery-filter", "composer, inbox", "--gallery-theme", "nord",
      ],
      environment: ["OMNIGENT_GALLERY_THEME": "dracula", "OMNIGENT_GALLERY_DEVICES": "iPhone"])
    #expect(options.showsGallery)
    #expect(options.exports)
    #expect(options.exportDirectory?.path == "/tmp/out")
    #expect(options.filters == ["composer", "inbox"])
    #expect(options.themeID == "nord")
    #expect(options.devices == ["iPhone"])
    #expect(
      try GalleryLaunchOptions(arguments: ["app", "-OmnigentGallery"], environment: [:])
        .showsGallery)
    #expect(try !GalleryLaunchOptions(arguments: ["app"], environment: [:]).showsGallery)
  }

  @Test("bad values are reported, not ignored")
  func parseErrors() {
    #expect(throws: GalleryLaunchOptions.ParseError.missingValue("--export-gallery")) {
      try GalleryLaunchOptions(arguments: ["app", "--export-gallery"], environment: [:])
    }
    #expect(throws: GalleryLaunchOptions.ParseError.self) {
      try GalleryLaunchOptions(arguments: ["app", "--gallery-theme", "neon"], environment: [:])
    }
    #expect(throws: GalleryLaunchOptions.ParseError.self) {
      try GalleryLaunchOptions(arguments: ["app"], environment: ["OMNIGENT_GALLERY_DEVICES": "tv"])
    }
  }

  @Test("the plan names every render uniquely, on the devices each entry supports")
  func plan() {
    let job = CatalogExportJob(
      entries: GalleryCatalog.entries, directory: URL(filePath: "/tmp/plan"),
      preferences: ThemePreferences(defaults: CatalogSettings.scratchDefaults))
    let items = CatalogExporter.plan(job)
    #expect(Set(items.map(\.fileName)).count == items.count)
    let phone = GalleryCatalog.entries.first { $0.id == "pages.decisions.phone-decisions" }
    #expect(phone.map { CatalogExporter.screens(for: $0, job: job) } == [CatalogScreen(.iPhone)])
    let canvas = GalleryCatalog.entries.first { $0.id == "pages.inbox.canvas" }
    #expect(canvas.map { CatalogExporter.screens(for: $0, job: job) } == [CatalogScreen(.mac)])
    let conversation = items.filter { $0.entryID == "pages.transcript.conversation" }
    #expect(Set(conversation.map(\.screen)) == [CatalogScreen(.mac), CatalogScreen(.iPhone)])
    #expect(
      items.contains { $0.fileName == "flows.decisions.approval--03-review--mac--omni-dark.png" })
  }
}
