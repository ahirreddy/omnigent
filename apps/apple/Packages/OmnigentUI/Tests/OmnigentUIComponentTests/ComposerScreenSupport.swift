#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// The composer's inputs, which a test changes between events as the app's store would.
  @MainActor @Observable
  final class ComposerScreenModel {
    var draft: String
    var state: ComposerViewState
    var focusRequest = 0

    init(draft: String = "", state: ComposerViewState) {
      self.draft = draft
      self.state = state
    }
  }

  /// Records every action the composer calls, in order, as one readable word each.
  @MainActor
  final class ComposerActionLog {
    var events: [String] = []
    var attachments: [ComposerAttachmentInput] = []
    /// What Up pulls back from the queue.
    var lastQueued: String?
    /// Earlier prompts, oldest first; `nil` until a test wires them through `history`.
    var prompts: [String] = []

    private func recorder(_ name: String) -> @MainActor () -> Void {
      { [self] in events.append(name) }
    }

    private func recorder<Value>(_ name: String) -> @MainActor (Value) -> Void {
      { [self] value in events.append("\(name):\(value)") }
    }

    /// Every action wired to this log; a test sets the ones it needs absent back to `nil`.
    var actions: ComposerActions {
      var extras = ComposerExtraActions(
        selectHost: { [self] in events.append("host:\($0.id)") },
        connectHost: recorder("connectHost"),
        selectApprovalMode: { [self] in events.append("mode:\($0.id)") },
        dictate: recorder("dictate"),
        selectDirectory: recorder("directory"),
        openFolder: recorder("openFolder"),
        selectWorktree: { [self] in events.append("worktree:\($0 ?? "none")") },
        newSideChat: recorder("sideChat"),
        setGoal: recorder("goal"),
        togglePlan: recorder("plan"),
        editQueued: { [self] message, text in events.append("edit:\(message.id):\(text)") },
        sendQueuedNow: { [self] in events.append("sendNow:\($0.id)") },
        removeQueued: { [self] in events.append("remove:\($0.id)") },
        moveQueued: { [self] from, to in events.append("move:\(Array(from)):\(to)") },
        recallPrevious: { [self] in
          events.append("recallPrevious")
          return prompts.last
        },
        queueDraft: recorder("queueDraft"),
        reconnect: recorder("reconnect"),
        dismissCommandNotice: recorder("dismissNotice"),
        createAgent: recorder("createAgent"),
        importAgentBundle: recorder("importBundle"))
      extras.indicators = ComposerIndicatorActions(
        openPullRequests: recorder("pullRequests"), openSubagent: recorder("subagent"),
        openGoal: recorder("openGoal"))
      extras.attachMention = recorder("attachMention")
      extras.removeMention = recorder("removeMention")
      extras.quotes = ComposerQuoteActions(
        remove: recorder("removeQuote"),
        editLead: { [self] index, text in events.append("lead:\(index):\(text)") })
      extras.setSmartRouting = recorder("smartRouting")
      extras.restoreUnsent = recorder("restoreUnsent")
      return ComposerActions(
        send: recorder("send"), interrupt: recorder("stop"),
        addAttachments: { [self] in attachments.append(contentsOf: $0) },
        removeAttachment: { [self] in events.append("removeAttachment:\($0.id)") },
        selectModel: { [self] in events.append("model:\($0 ?? "default")") },
        selectEffort: { [self] in events.append("effort:\($0 ?? "default")") },
        selectAgent: recorder("agent"),
        acknowledgeUncertainDelivery: recorder("acknowledge"),
        dismissDeliveryError: recorder("dismissDelivery"), extras: extras)
    }

    /// The history actions, reading `prompts` and `lastQueued` on the key press.
    var history: ComposerHistoryActions {
      ComposerHistoryActions(
        prompts: { [self] in prompts },
        takeLastQueued: { [self] in
          defer { lastQueued = nil }
          return lastQueued
        },
        sendAllQueued: recorder("sendAll"))
    }
  }

  /// The composer over a test's model, as a screen hosts it.
  struct ComposerScreen: View {
    @Bindable var model: ComposerScreenModel
    let actions: ComposerActions
    var owner: CommandReturnOwner?
    var layout = ComposerLayoutStyle.platformDefault
    var layoutWidth = LayoutWidth.regular

    var body: some View {
      ComposerView(
        draft: $model.draft, state: model.state, actions: actions,
        focusRequest: model.focusRequest
      )
      .environment(\.commandReturnOwner, owner)
      .environment(\.composerLayoutStyle, layout)
      .environment(\.layoutWidth, layoutWidth)
      // A fixed size, so the window keeps its frame as the composer grows.
      .frame(width: 800, height: 600, alignment: .bottom)
    }
  }

  /// Opens the composer offscreen with the editor focused.
  @MainActor
  func openComposer(
    _ model: ComposerScreenModel, _ actions: ComposerActions, owner: CommandReturnOwner? = nil
  ) -> OffscreenWindow<ComposerScreen> {
    let screen = OffscreenWindow(ComposerScreen(model: model, actions: actions, owner: owner))
    screen.focusEditor()
    // Lets the first layout reach the focus proxies, or the first click can miss.
    screen.settle()
    return screen
  }

  /// Presents a sheet over an empty window, so its toolbar's buttons exist as they do in the app.
  struct ComposerSheetHost<Sheet: View>: View {
    let sheet: Sheet

    var body: some View {
      Color.clear.sheet(isPresented: .constant(true)) { sheet }
    }
  }

  /// Key codes the composer's editor reads.
  enum ComposerKey {
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
  }

  extension OffscreenWindow {
    /// The composer's editor, which takes the keyboard when it comes on screen.
    var textView: NSTextView? {
      allViews.lazy.compactMap { $0 as? NSTextView }.first
    }

    /// Gives the editor the keyboard, as a click on it does.
    func focusEditor() {
      if let textView { _ = window.makeFirstResponder(textView) }
      settle(0.05)
    }

    /// Every control in reading order, on the current state of the view.
    private var freshControls: [CGRect] {
      // SwiftUI rebuilds its focus proxies with the key loop, not when the view changes.
      activeWindow.recalculateKeyViewLoop()
      return controlFrames
    }

    /// The buttons and fields in reading order, without the borderless menus. A disabled plain
    /// button has no proxy, so it isn't listed.
    var buttons: [CGRect] {
      let menus = menus
      return freshControls.filter { control in
        !menus.contains { $0.intersects(control) }
      }
    }

    /// The borderless menus in reading order. Open them with `menu(at:)`, never a plain click:
    /// nothing else ends a menu's tracking loop.
    var menus: [CGRect] {
      let root = activeWindow.contentView
      return allViews.filter { $0 is NSPopUpButton }.map { $0.convert($0.bounds, to: root) }
        .sorted { first, second in
          abs(first.midY - second.midY) > 8 ? first.midY < second.midY : first.minX < second.minX
        }
    }

    /// The row under the pill, in reading order: its chips are plain menus, so a disabled chip
    /// isn't listed. Open them with `chip(_:)`, never a plain click.
    var chips: [CGRect] {
      guard let editor = textView?.enclosingScrollView else { return [] }
      let bottom = editor.convert(editor.bounds, to: activeWindow.contentView).maxY
      let appKitMenus = menus.filter { menu in !freshControls.contains { $0.intersects(menu) } }
      return (freshControls + appKitMenus).filter { $0.minY > bottom + 6 }
        .sorted { $0.minX < $1.minX }
    }

    /// Opens a chip by its position in `chips`, and returns the menu closed.
    func chip(_ index: Int) throws -> NSMenu {
      let frames = chips
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("chip \(index) of \(frames.count)")
      }
      // After a menu closes, the first click on a different plain menu opens nothing, however long
      // the wait. The next click works. A VM flow checks whether a real click does the same.
      if let menu = try? openMenu(clickPoint(frames[index])) { return menu }
      return try openMenu(clickPoint(frames[index]))
    }

    /// The editable text fields in reading order.
    var fields: [NSTextField] {
      let root = activeWindow.contentView
      return allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable).sorted {
        $0.convert($0.bounds, to: root).minY < $1.convert($1.bounds, to: root).minY
      }
    }

    /// Gives a field the keyboard, as a click on it does, and types into it.
    func type(_ text: String, intoField index: Int) throws {
      let found = fields
      guard found.indices.contains(index) else {
        throw OffscreenWindowError.notFound("field \(index) of \(found.count)")
      }
      _ = activeWindow.makeFirstResponder(found[index])
      settle(0.05)
      try type(text)
    }

    /// Lets `Task`s a view started run: they queue on the main actor, which a test holds until it
    /// suspends, so `settle` alone doesn't reach them.
    func drainTasks() async {
      for _ in 0..<4 {
        await Task.yield()
        settle(0.03)
      }
    }

    /// Clicks a button counting back from the last, as a sheet's own buttons come last.
    func tapButton(fromEnd offset: Int) throws {
      let frames = buttons
      guard frames.count > offset else {
        throw OffscreenWindowError.notFound("button \(offset) from the end of \(frames.count)")
      }
      try click(clickPoint(frames[frames.count - 1 - offset]))
    }

    /// Clicks a button by its position in `buttons`.
    func tapButton(_ index: Int) throws {
      let frames = buttons
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("button \(index) of \(frames.count)")
      }
      try click(clickPoint(frames[index]))
    }

    /// Scrolls the longest scroll view to its end, as a user would to reach a form's last row.
    func scrollToEnd() {
      let scrollViews = allViews.compactMap { $0 as? NSScrollView }
      guard let scrollView = scrollViews.max(by: { contentHeight($0) < contentHeight($1) }) else {
        return
      }
      let clip = scrollView.contentView
      clip.scroll(to: NSPoint(x: 0, y: max(0, contentHeight(scrollView) - clip.bounds.height)))
      scrollView.reflectScrolledClipView(clip)
      settle(0.1)
    }

    private func contentHeight(_ scrollView: NSScrollView) -> CGFloat {
      scrollView.documentView?.frame.height ?? 0
    }

    /// Clicks each listed button, for a screen where none should do anything.
    func clickEveryButton() throws {
      for frame in buttons { try click(clickPoint(frame)) }
    }

    /// Just off a control's center: a row's exact middle can fall on the seam between two lines of
    /// text beside it, and SwiftUI's hit test misses on that one line of points.
    func clickPoint(_ frame: CGRect) -> CGPoint {
      CGPoint(x: frame.midX, y: frame.midY + 0.5)
    }

    /// Opens a `Menu` by its position in `menus`, and returns it closed.
    func menu(at index: Int) throws -> NSMenu {
      let frames = menus
      guard frames.indices.contains(index) else {
        throw OffscreenWindowError.notFound("menu \(index) of \(frames.count)")
      }
      return try openMenu(clickPoint(frames[index]))
    }

    /// Runs a key equivalent as the app's main menu pass does before any view sees the key.
    func pressShortcut(
      keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags
    ) throws -> Bool {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      let handled = window.performKeyEquivalent(with: event)
      settle(0.05)
      return handled
    }

    func pressReturn(_ modifiers: NSEvent.ModifierFlags = []) throws {
      try press(keyCode: ComposerKey.returnKey, characters: "\r", modifiers: modifiers)
    }

    func pressTab(_ modifiers: NSEvent.ModifierFlags = []) throws {
      try press(keyCode: ComposerKey.tab, characters: "\t", modifiers: modifiers)
    }

    func pressEscape() throws {
      try press(keyCode: ComposerKey.escape, characters: "\u{1B}")
    }

    func pressUp(_ modifiers: NSEvent.ModifierFlags = []) throws {
      try press(
        keyCode: ComposerKey.upArrow, characters: "\u{F700}", modifiers: modifiers.union(.function))
    }

    func pressDown(_ modifiers: NSEvent.ModifierFlags = []) throws {
      try press(
        keyCode: ComposerKey.downArrow, characters: "\u{F701}",
        modifiers: modifiers.union(.function))
    }
  }

  /// One menu's item titles at every depth, in order, with `>` before a submenu's items.
  @MainActor
  func menuTitles(_ menu: NSMenu) -> [String] {
    menu.items.flatMap { item -> [String] in
      guard let submenu = item.submenu else { return item.isSeparatorItem ? [] : [item.title] }
      return (item.title.isEmpty ? [] : [item.title]) + menuTitles(submenu)
    }
  }
#endif
