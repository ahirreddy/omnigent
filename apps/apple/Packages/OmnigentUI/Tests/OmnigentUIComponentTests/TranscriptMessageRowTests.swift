#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript messages", .serialized)
  @MainActor
  struct TranscriptMessageRowTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private var copied: String? { SystemSideEffects.pasteboard.string(forType: .string) }

    private func message(
      _ row: Row, decoration: MessageDecoration = MessageDecoration(),
      actions: ConversationActions = ConversationActions()
    ) -> OffscreenWindow<AnyView> {
      transcriptScreen(MessageRowView(row: row, decoration: decoration), actions: actions)
    }

    @Test("A reply still preparing, a streaming one and a settled one say where they are")
    func streamingStates() throws {
      let preparing = message(Row(id: "a", role: .assistant, isStreaming: true))
      defer { preparing.close() }
      #expect(try preparing.shows("Preparing a reply"))

      let streaming = message(Row(id: "a", role: .assistant, text: "Part", isStreaming: true))
      defer { streaming.close() }
      #expect(try streaming.shows("Part"))
      #expect(try streaming.shows("Responding"))

      let settled = message(Fixture.answer("a"))
      defer { settled.close() }
      #expect(try settled.shows("An answer"))
      #expect(try !settled.shows("Responding"))
    }

    @Test("An interrupted message says so, from either side")
    func interrupted() throws {
      for role in [RowRole.user, .assistant] {
        let view = message(Row(id: "m", role: role, text: "Cut off", interrupted: true))
        defer { view.close() }
        #expect(try view.shows("Interrupted"), "\(role)")
      }
    }

    @Test("A settled answer's footer names the work and keeps the actions beside it")
    func workedFooter() throws {
      var decoration = MessageDecoration()
      decoration.workedFor = 3
      decoration.showsActions = true
      decoration.timestamp = Date(timeIntervalSince1970: 0)
      var actions = ConversationActions()
      actions.forkFrom = { _ in }
      let view = message(Fixture.answer("a"), decoration: decoration, actions: actions)
      defer { view.close() }
      #expect(try view.shows("Worked for 3s"))
      #expect(view.controlFrames.count >= 2)
    }

    @Test("The last answer's Copy and Fork buttons act on that message")
    func pinnedActions() throws {
      var forked: [String] = []
      var actions = ConversationActions()
      actions.forkFrom = { forked.append($0.id) }
      var decoration = MessageDecoration()
      decoration.showsActions = true
      let view = message(Fixture.answer("a", "Copy me"), decoration: decoration, actions: actions)
      defer { view.close() }
      // The message itself takes focus first, then Copy, then Fork.
      let count = view.controlFrames.count
      try view.clickControl(at: count - 2)
      #expect(copied == "Copy me")
      try view.clickControl(at: count - 1)
      #expect(forked == ["a"])
    }

    @Test("An older message keeps its actions hidden until it's hovered or focused")
    func hiddenActions() throws {
      var actions = ConversationActions()
      actions.forkFrom = { _ in }
      let hidden = message(Fixture.answer("a"), actions: actions)
      defer { hidden.close() }
      var decoration = MessageDecoration()
      decoration.showsActions = true
      let pinned = message(Fixture.answer("a"), decoration: decoration, actions: actions)
      defer { pinned.close() }
      #expect(pinned.controlFrames.count > hidden.controlFrames.count)
    }

    @Test("The context menu runs each action, in order, with Copy Message ID last")
    func contextMenu() throws {
      var forked: [String] = []
      var actions = ConversationActions()
      actions.forkFrom = { forked.append($0.id) }
      actions.messageURL = { URL(string: "https://example.com/c?message=\($0.id)") }
      let view = message(Fixture.answer("a", "Body"), actions: actions)
      defer { view.close() }
      let menu = try #require(try view.firstContextMenu())
      #expect(
        menu.items.map(\.title).filter { !$0.isEmpty } == [
          "Copy", "Fork from Here\u{2026}", "Copy Link", "Share", "Copy Message ID",
        ])
      try view.choose("Copy", in: menu)
      #expect(copied == "Body")
      try view.choose("Fork from Here\u{2026}", in: menu)
      #expect(forked == ["a"])
      try view.choose("Copy Link", in: menu)
      #expect(copied == "https://example.com/c?message=a")
      try view.choose("Copy Message ID", in: menu)
      #expect(copied == "a")
    }

    @Test("A fork the session refuses stays in the menu, disabled")
    func forkRefused() throws {
      var actions = ConversationActions()
      actions.forkUnavailableReason = "Only the owner can fork"
      let view = message(Fixture.answer("a"), actions: actions)
      defer { view.close() }
      let menu = try #require(try view.firstContextMenu())
      let fork = try #require(menu.items.first { $0.title.hasPrefix("Fork from Here") })
      #expect(!fork.isEnabled)
    }

    @Test("A shared session's message shows its author's initials; yours doesn't")
    func avatars() throws {
      var decoration = MessageDecoration()
      decoration.showsAvatar = true
      let shared = message(
        Row(id: "u", role: .user, text: "Hi", author: "Ada Lovelace"), decoration: decoration)
      defer { shared.close() }
      #expect(try shared.shows("AL"))
      let own = message(Row(id: "u", role: .user, text: "Hi", author: "Ada Lovelace"))
      defer { own.close() }
      #expect(try !own.shows("AL"))
    }

    @Test("Initials and avatar colors hold up for any name")
    func avatarRules() {
      #expect(AuthorAvatar.initials("Ada Lovelace") == "AL")
      #expect(AuthorAvatar.initials("ada.lovelace@example.com") == "AL")
      #expect(AuthorAvatar.initials("") == "?")
      #expect(AuthorAvatar.initials(" ._@") == "?")
      for name in HostileData.samples + ["Ada"] {
        #expect(AuthorAvatar.palette.contains(AuthorAvatar.color(for: name)))
      }
      let color = AuthorAvatar.color(for: "Ada")
      #expect(AuthorAvatar.color(for: "Ada") == color)
    }

    @Test("Given initials are capped at two, and a blank one is a question mark")
    func avatarGivenInitials() throws {
      let long = transcriptScreen(AuthorAvatar(name: "Ada", initials: "abc", isIdle: true))
      defer { long.close() }
      #expect(try long.shows("AB"))
      let blank = transcriptScreen(AuthorAvatar(name: "Ada", initials: ""))
      defer { blank.close() }
      #expect(try blank.shows("?"))
    }

    @Test("Timestamps show the time today, the date otherwise and the year only when it differs")
    func timestamps() throws {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = .current
      let now = try #require(calendar.date(from: DateComponents(year: 2_026, month: 6, day: 15)))
      let today = now.addingTimeInterval(3_600)
      let time = today.formatted(date: .omitted, time: .shortened)
      #expect(MessageTimestamp.format(today, now: now, calendar: calendar) == time)

      let earlier = try #require(calendar.date(byAdding: .day, value: -3, to: now))
      let thisYear = MessageTimestamp.format(earlier, now: now, calendar: calendar)
      #expect(thisYear.contains(earlier.formatted(date: .omitted, time: .shortened)))
      #expect(!thisYear.contains("2026"))

      let lastYear = try #require(calendar.date(byAdding: .year, value: -1, to: now))
      #expect(MessageTimestamp.format(lastYear, now: now, calendar: calendar).hasSuffix("2025"))
    }
  }
#endif
