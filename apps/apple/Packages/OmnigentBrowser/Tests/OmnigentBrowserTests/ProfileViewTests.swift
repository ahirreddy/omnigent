#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  @MainActor
  @Suite("Profile views, off screen", .serialized)
  struct ProfileViewTests {
    @Test("avatars and chips draw each kind of profile, and a deleted one")
    func avatarsAndChips() async throws {
      let fixture = try TabFixture()
      let initials = BrowserUserProfile(name: "Ada Lovelace", color: .teal)
      var symbol = BrowserUserProfile(name: "Work", color: .red)
      symbol.avatar = .symbol("briefcase.fill")
      var emoji = BrowserUserProfile(name: "Fun", color: .yellow)
      emoji.avatar = .emoji("🎉")
      let screen = OffscreenWindow(
        VStack {
          BrowserProfileAvatarView(profile: initials)
          BrowserProfileAvatarView(profile: symbol)
          BrowserProfileAvatarView(profile: emoji)
          BrowserProfileAvatarView(profile: nil)
          BrowserProfileChip(profile: initials)
          BrowserProfileChip(profile: initials, showsName: false)
          BrowserProfileChip(profile: nil)
        }, width: 300, height: 240)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows(initials.initials))
      #expect(try screen.shows("🎉"))
      #expect(try screen.shows("Ada Lovelace"))
      #expect(try screen.shows("Deleted"))
      #expect(fixture.environment.profiles.profiles.count == 1)
      for color in BrowserProfileColor.allCases {
        #expect(color.displayName == color.rawValue.capitalized)
        _ = color.color
      }
    }

    @Test("the picker lists each profile, marks the default, and picks")
    func picker() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      var picked: [UUID] = []
      let screen = OffscreenWindow(
        Menu("Profiles") {
          BrowserProfilePicker(store: store) { picked.append($0.id) }
        }.menuStyle(.borderlessButton), width: 200, height: 40)
      defer { screen.close() }
      await screen.catchUp()
      let menu = try screen.popupMenu()
      try screen.choose("Second", in: menu)
      #expect(picked == [second.id])
      #expect(menu.items.contains { $0.title.hasSuffix("(default)") })
    }

    @Test("the chip's popover opens a tab in any profile, or the manager")
    func profileMenuContent() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      var opened: [UUID] = []
      fixture.environment.onOpenTab = { model, _ in opened.append(model.profileID) }
      let recorder = SheetRecorder()
      var closed = 0
      let screen = OffscreenWindow(
        BrowserProfileMenuContent(
          model: fixture.model, environment: fixture.environment,
          sheet: Binding(get: { recorder.value }, set: { recorder.value = $0 }),
          close: { closed += 1 }), width: 280, height: 160)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("default"))
      // Each profile, then Manage Profiles….
      #expect(screen.controlFrames.count == 3)
      try screen.clickControl(at: 1)
      #expect(opened == [second.id])
      #expect(closed == 1)
      try screen.clickControl(at: 2)
      #expect(recorder.value == .profiles)
      #expect(closed == 2)
    }

    @Test("the chip itself opens its popover where nothing can see it")
    func profileChipOpensItsPopover() async throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        BrowserProfileMenu(
          model: fixture.model, environment: fixture.environment, sheet: .constant(nil)),
        width: 200, height: 50)
      defer { screen.close() }
      await screen.catchUp()
      let windowsBefore = NSApp.windows.count
      try screen.clickControl(at: 0)
      await screen.catchUp()
      #expect(NSApp.windows.count > windowsBefore)
      #expect(screen.nothingOnScreen)
    }

    @Test("the editor changes the name, color and avatar, and saves them")
    func editor() async throws {
      SystemSideEffects.install()
      var saved: [BrowserUserProfile] = []
      let original = BrowserUserProfile(name: "Ada", color: .blue)
      let screen = OffscreenWindow(
        BrowserProfileEditor(profile: original, isNew: false) { saved.append($0) }, width: 400,
        height: 420)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Save"))

      // Name, nine colors, initials and the symbols, emoji field, Cancel, Save.
      let controls = screen.controlFrames
      let colorCount = BrowserProfileColor.allCases.count
      #expect(controls.count == 1 + colorCount + 1 + BrowserProfileAvatar.symbols.count + 3)
      try screen.clickControl(at: 2)
      try screen.clickControl(at: 1 + colorCount + 1)
      try screen.clickControl(at: controls.count - 1)
      let first = try #require(saved.last)
      #expect(first.color == BrowserProfileColor.allCases[1])
      #expect(first.avatar == .symbol(BrowserProfileAvatar.symbols[0]))
      #expect(first.name == "Ada")

    }

    @Test("renaming replaces the old name, and initials can be chosen back")
    func editorRename() async throws {
      SystemSideEffects.install()
      var saved: [BrowserUserProfile] = []
      var original = BrowserUserProfile(name: "Ada", color: .blue)
      original.avatar = .emoji("🎉")
      let screen = OffscreenWindow(
        BrowserProfileEditor(profile: original, isNew: false) { saved.append($0) }, width: 400,
        height: 420)
      defer { screen.close() }
      await screen.catchUp()
      let initials = 1 + BrowserProfileColor.allCases.count
      try screen.clickControl(at: initials)
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("Grace")
      await screen.catchUp()
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      #expect(saved.last?.name == "Grace")
      #expect(saved.last?.avatar == .initials)
    }

    @Test("an emoji typed for the avatar is used; a blank name can't be saved")
    func editorEmojiAndBlankName() async throws {
      SystemSideEffects.install()
      var saved: [BrowserUserProfile] = []
      let screen = OffscreenWindow(
        BrowserProfileEditor(profile: BrowserUserProfile(name: "", color: .blue), isNew: true) {
          saved.append($0)
        }, width: 400, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Add"))
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      #expect(saved.isEmpty)

      try screen.focusField(at: 1)
      try screen.type("🎉")
      await screen.catchUp()
      try screen.focusField(at: 0)
      try screen.type("Fun")
      await screen.catchUp()
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      #expect(saved.last?.avatar == .emoji("🎉"))
      #expect(saved.last?.name == "Fun")
    }

    @Test("the manager makes a default, adds, edits and deletes through its sheets")
    func manager() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Default for new tabs"))
      #expect(try screen.shows("Second"))

      // Rows: Edit and Delete; then Make Default, Edit and Delete. Add Profile and Done below.
      try screen.clickDrawnButton(at: 2)
      await screen.catchUp()
      #expect(store.defaultProfileID == second.id)
      #expect(store.profiles.count == 2)

      // Add Profile opens the editor as a sheet, and it saves once it has a name.
      let addIndex = screen.drawnButtons.count - 2
      try screen.clickDrawnButton(at: addIndex)
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      try screen.focusField()
      try screen.type("Third")
      await screen.catchUp()
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      await screen.letSheetSettle()
      #expect(!screen.hasSheet)
      #expect(store.profiles.contains { $0.name == "Third" })
      #expect(screen.nothingOnScreen)
    }

    @Test("Edit reopens a profile; Delete asks, and removes it and its data")
    func managerEditAndDelete() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()

      // Second row's Edit.
      try screen.clickDrawnButton(at: 3)
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      try screen.focusField()
      screen.selectFieldText()
      try screen.type("Renamed")
      await screen.catchUp()
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      await screen.letSheetSettle()
      #expect(store.profile(id: second.id)?.name == "Renamed")

      // Second row's Delete, with the system's alert answering its first button.
      SystemSideEffects.reset()
      try screen.clickDrawnButton(at: 4)
      await screen.letSheetSettle()
      #expect(SystemSideEffects.record.alertMessages == ["Delete Renamed?"])
      #expect(store.profile(id: second.id) == nil)
    }

    @Test("data that can't be removed with a profile says why")
    func deleteFailure() async throws {
      let fixture = try TabFixture()
      let store = fixture.environment.profiles
      let second = try store.create(name: "Second", color: .green, avatar: .initials)
      store.cleanUp = { _ throws(BrowserError) in throw .storageFailed("The disk refused.") }
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      try screen.clickDrawnButton(at: 4)
      await screen.letSheetSettle()
      #expect(store.profile(id: second.id) == nil)
      #expect(try screen.shows("The disk refused."))
    }

    @Test("deleting the last profile isn't offered")
    func lastProfile() async throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        BrowserProfileManagerView(environment: fixture.environment), width: 520, height: 420)
      defer { screen.close() }
      await screen.catchUp()
      #expect(try screen.shows("Default for new tabs"))
      #expect(try !screen.shows("Make Default"))
      #expect(fixture.environment.profiles.profiles.count == 1)
    }
  }
#endif
