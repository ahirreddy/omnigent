#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  /// The composer's smaller parts, each driven the way the screen drives it.
  @Suite("Composer: edges", .serialized)
  @MainActor
  struct ComposerEdgeTests {
    private let log = ComposerActionLog()

    private static let configuration = ComposerConfiguration(
      agentName: "Reviewer",
      modelOptions: [
        ModelOption(
          id: "m", displayName: "Model M", supportedReasoningEfforts: ["low", "high"],
          isDefault: true)
      ], selectedModelId: "m", selectedEffort: "high")

    private func menu(
      _ configuration: ComposerConfiguration, layout: ComposerLayoutStyle, showsAgent: Bool = false
    ) -> OffscreenWindow<some View> {
      let screen = OffscreenWindow(
        ConfigurationMenu(
          configuration: configuration, actions: log.actions, showsAgent: showsAgent
        )
        .environment(\.composerLayoutStyle, layout))
      screen.settle()
      return screen
    }

    @Test("the session's liveness shows under the composer, unless the connection is down")
    func liveness() throws {
      let notice = SessionLivenessNotice(
        liveness: .asleep, sessionID: "s", serverURL: "http://127.0.0.1:6767", wrapper: nil,
        harness: "codex-native")
      var state = ComposerViewState()
      state.liveness = notice
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(try screen.shows("Agent is asleep"))
    }

    @Test("the card's menu names the agent only when asked, then the model and effort")
    func cardLabel() throws {
      let named = menu(Self.configuration, layout: .card, showsAgent: true)
      defer { named.close() }
      #expect(try named.shows("Reviewer"))
      #expect(try named.shows("Model M"))
      #expect(try named.shows("High"))
      let plain = menu(Self.configuration, layout: .card)
      defer { plain.close() }
      #expect(try !plain.shows("Reviewer"))
      #expect(try plain.shows("Model M"))
    }

    @Test("the touch menu spins while applying and says why the model list is missing")
    func touchLabel() throws {
      var applying = Self.configuration
      applying.isApplying = true
      let busy = menu(applying, layout: .touch)
      defer { busy.close() }
      #expect(try busy.shows("Model M"))
      #expect(busy.allViews.contains { $0 is NSProgressIndicator })

      var failed = Self.configuration
      failed.errorMessage = "Models unavailable"
      let broken = menu(failed, layout: .touch)
      defer { broken.close() }
      #expect(!broken.allViews.contains { $0 is NSProgressIndicator })
      let chip = try #require(broken.controlFrames.first)
      let list = try broken.openMenu(broken.clickPoint(chip))
      #expect(menuTitles(list).contains("Models unavailable"))
    }

    @Test("A busy session's menu says why first, and its choices take no click until it is free")
    func busyMenu() throws {
      var working = Self.configuration
      working.busyReason = "The agent is working."
      #expect(!working.acceptsChanges)
      let busy = menu(working, layout: .touch)
      defer { busy.close() }
      let refused = try busy.openMenu(busy.clickPoint(try #require(busy.controlFrames.first)))
      #expect(menuTitles(refused).first == "The agent is working.")
      #expect(refused.item(named: "High")?.isEnabled == false)

      #expect(Self.configuration.acceptsChanges)
      let idle = menu(Self.configuration, layout: .touch)
      defer { idle.close() }
      let offered = try idle.openMenu(idle.clickPoint(try #require(idle.controlFrames.first)))
      #expect(menuTitles(offered).first != "The agent is working.")
      #expect(offered.item(named: "High")?.isEnabled == true)
    }

    private struct ExpandHost: View {
      @State private var isExpanded = false

      var body: some View {
        VStack {
          ComposerEditorButtons(
            dictate: nil, isEditable: true, showsExpand: true, isExpanded: $isExpanded)
          Text(isExpanded ? "expanded" : "collapsed")
        }
      }
    }

    @Test("Expand opens the editor and collapses it again")
    func expandButton() throws {
      let screen = OffscreenWindow(ExpandHost())
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("collapsed"))
      // The last one, as a nil dictate action's Mic must never be clicked.
      let expand = try #require(screen.buttons.last)
      try screen.click(screen.clickPoint(expand))
      #expect(try screen.shows("expanded"))
      let collapse = try #require(screen.buttons.last)
      try screen.click(screen.clickPoint(collapse))
      #expect(try screen.shows("collapsed"))
    }

    @Test("Shift-Tab's note about the new mode goes away after a moment")
    func modeNoteClears() async throws {
      let detail = try #require(
        ComposerSamples.codexModes().options.first { $0.id == "full-access" }?.detail)
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressTab(.shift)
      #expect(try screen.shows(detail))
      screen.settle(1.8)
      await screen.drainTasks()
      screen.settle(0.3)
      #expect(try !screen.shows(detail))
    }

    @Test("a dragged message lands before its target, or after it when dragged down")
    func queueReorder() {
      let queue = [
        QueuedMessage(id: "one", text: "1"), QueuedMessage(id: "two", text: "2"),
        QueuedMessage(id: "three", text: "3"),
        QueuedMessage(id: "sending", text: "4", state: .sending),
      ]
      let down = QueueStrip.reorder(queue, moving: "one", before: "three")
      #expect(down?.from == 0)
      #expect(down?.to == 3)
      let upward = QueueStrip.reorder(queue, moving: "three", before: "one")
      #expect(upward?.from == 2)
      #expect(upward?.to == 0)
      #expect(QueueStrip.reorder(queue, moving: "one", before: "one") == nil)
      #expect(QueueStrip.reorder(queue, moving: "gone", before: "one") == nil)
      #expect(QueueStrip.reorder(queue, moving: "one", before: "gone") == nil)
      #expect(QueueStrip.reorder(queue, moving: "sending", before: "one") == nil)
    }

    @Test("a drag over the chat is told where to let go")
    func dropHighlight() throws {
      let screen = OffscreenWindow(ChatDropHighlight())
      defer { screen.close() }
      #expect(try screen.shows("Drop files here"))
    }

    @Test("the tray shows the running work beside its chips")
    func trayIndicators() throws {
      var tray = ComposerTray()
      tray.indicators = ComposerTaskIndicators(backgroundTasks: 3)
      let screen = OffscreenWindow(
        ComposerTrayView(tray: tray, context: nil, actions: log.actions.extras))
      defer { screen.close() }
      #expect(try screen.shows("3"))
    }

    @Test("the host chip names the host unless told not to")
    func hostName() throws {
      let hosts = ComposerHosts(
        hosts: [ComposerHost(id: "mac", name: "Mac mini", kind: .machine, isOnline: true)],
        selectedID: "mac")
      let screen = OffscreenWindow(HostChip(hosts: hosts, actions: log.actions.extras))
      defer { screen.close() }
      #expect(try screen.shows("Mac mini"))
    }

    @Test("quotes can be removed unless the composer says they can't")
    func quotesByDefault() throws {
      var removed: [Int] = []
      let quote = ComposerQuote(text: "Quoted words")
      let screen = OffscreenWindow(
        QuoteBlocks(
          quotes: [quote],
          actions: ComposerQuoteActions(remove: { removed.append($0) })))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("Quoted words"))
      let remove = try #require(screen.buttons.last)
      try screen.click(screen.clickPoint(remove))
      #expect(removed == [0])
    }

    @Test("the paste watcher never takes a click from what's beneath it")
    func watcherTakesNoClicks() {
      #expect(ImagePasteWatcher.WatcherView().hitTest(.zero) == nil)
    }

    @Test("a promised image the pasteboard then doesn't give fails, naming its format")
    func promisedImage() async throws {
      SystemSideEffects.reset()
      let item = NSPasteboardItem()
      let promise = EmptyPromise()
      #expect(item.setDataProvider(promise, forTypes: [.png]))
      SystemSideEffects.pasteboard.clearContents()
      SystemSideEffects.pasteboard.writeObjects([item])
      let providers = PasteboardImages.providers(SystemSideEffects.pasteboard)
      let result = await AttachmentLoading.providers(providers)
      #expect(result.inputs.isEmpty)
      #expect(result.failures.joined().contains("public.png"))
    }

    private final class EmptyPromise: NSObject, NSPasteboardItemDataProvider {
      func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
      ) {}
    }

    @Test("a file item whose data isn't a URL, or a type that gives nothing, says it's empty")
    func emptyItems() async {
      let notURL = NSItemProvider()
      notURL.suggestedName = "Link"
      notURL.registerDataRepresentation(for: .fileURL, visibility: .all) { done in
        done(Data(), nil)
        return nil
      }
      await #expect(throws: ItemProviderLoader.LoadError.self) {
        _ = try await ItemProviderLoader.load(notURL, index: 0)
      }
      let nothing = NSItemProvider()
      nothing.registerDataRepresentation(for: .fileURL, visibility: .all) { done in
        done(nil, nil)
        return nil
      }
      await #expect(throws: (any Error).self) {
        _ = try await ItemProviderLoader.load(nothing, index: 0)
      }
    }

    @Test("an image object is attached as a PNG")
    func imageObject() throws {
      let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
        NSColor.red.setFill()
        rect.fill()
        return true
      }
      let pasted = try PastedImage.png(image)
      #expect(pasted.type == .png)
      #expect(pasted.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
  }
#endif
