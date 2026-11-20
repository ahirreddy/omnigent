#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import OmnigentDesktop

  /// Stands in for the system's hot keys.
  @MainActor
  final class FakeHotKeys {
    var registered: [HotKeyChord] = []
    var released: [HotKeyChord] = []
    var refuse: SystemHotKeyError?
    var actions: [@MainActor () -> Void] = []
    var presses = 0
    var issues: [String] = []

    final class Registration: HotKeyRegistration {
      let release: () -> Void
      init(release: @escaping () -> Void) { self.release = release }
      func unregister() { release() }
    }

    var registrar: HotKeyRegistrar {
      { chord, action throws(SystemHotKeyError) in
        if let refuse = self.refuse { throw refuse }
        self.registered.append(chord)
        self.actions.append(action)
        return Registration { self.released.append(chord) }
      }
    }
  }

  @Suite("Floating New Agent panel: its system-wide shortcut")
  @MainActor
  struct FloatingPanelShortcutTests {
    private func defaults() throws -> UserDefaults {
      let name = "floating-panel-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: name))
      defaults.removePersistentDomain(forName: name)
      return defaults
    }

    @Test("A chord reads as the menu bar writes it and needs Command, Control or Option")
    func chords() {
      #expect(HotKeyChord.newAgentPanelDefault.displayText == "⇧⌘Space")
      let recorded = HotKeyChord(keyCode: 49, flags: [.control, .option], characters: " ")
      #expect(recorded?.displayText == "⌃⌥Space")
      #expect(HotKeyChord(keyCode: 40, flags: [.command, .shift], characters: "k")?.keyName == "K")
      #expect(HotKeyChord(keyCode: 40, flags: [.shift], characters: "k") == nil)
      #expect(HotKeyChord(keyCode: 40, flags: [], characters: "k") == nil)
      #expect(SystemHotKey.carbonModifiers([.command, .shift]) == 256 | 512)
    }

    @Test("Registered only while a server offers the panel, ⇧⌘Space unless changed")
    func registersWhileAvailable() throws {
      let keys = FakeHotKeys()
      let shortcut = FloatingPanelShortcut(
        defaults: try defaults(), reportIssue: { _ in }, register: keys.registrar)
      shortcut.onPress = { keys.presses += 1 }
      #expect(keys.registered.isEmpty)
      shortcut.isAvailable = true
      #expect(keys.registered == [.newAgentPanelDefault])
      keys.actions.first?()
      #expect(keys.presses == 1)
      shortcut.isAvailable = false
      #expect(keys.released == [.newAgentPanelDefault])
      #expect(shortcut.activeChord == nil)
    }

    @Test("Recording releases the chord; a new chord and off are saved")
    func recordAndSave() throws {
      let store = try defaults()
      let keys = FakeHotKeys()
      let shortcut = FloatingPanelShortcut(
        defaults: store, reportIssue: { _ in }, register: keys.registrar)
      shortcut.isAvailable = true
      shortcut.isRecording = true
      #expect(keys.released == [.newAgentPanelDefault])
      let other = try #require(
        HotKeyChord(keyCode: 49, flags: [.control, .option], characters: " "))
      shortcut.setting = .chord(other)
      shortcut.isRecording = false
      #expect(keys.registered.last == other)
      #expect(FloatingPanelShortcut.load(store).setting == .chord(other))
      shortcut.setting = .off
      #expect(keys.released.last == other)
      #expect(FloatingPanelShortcut.load(store).setting == .off)
    }

    @Test("A chord the system refuses says why and is reported")
    func refused() throws {
      let keys = FakeHotKeys()
      keys.refuse = .inUse("⇧⌘Space")
      let shortcut = FloatingPanelShortcut(
        defaults: try defaults(), reportIssue: { keys.issues.append("\($0)") },
        register: keys.registrar)
      shortcut.isAvailable = true
      #expect(shortcut.problem == "Another app already uses ⇧⌘Space.")
      #expect(keys.issues.count == 1)
      #expect(shortcut.activeChord == nil)
    }

    @Test("The panel sits centred a fifth of the way down; Omnigent's windows hide it")
    func placementAndHiding() {
      let origin = FloatingPanelController.origin(
        size: CGSize(width: 680, height: 200), in: CGRect(x: 0, y: 0, width: 1440, height: 900))
      #expect(origin == CGPoint(x: 380, y: 520))
      let panel = NSPanel()
      let window = NSWindow()
      #expect(!FloatingPanelController.hidesFor(panel, panel: panel))
      #expect(FloatingPanelController.hidesFor(window, panel: panel))
      #expect(!FloatingPanelController.hidesFor(NSOpenPanel(), panel: panel))
      #expect(FloatingPanelController.isBareEscape(keyCode: 53, modifiers: []))
      #expect(!FloatingPanelController.isBareEscape(keyCode: 53, modifiers: .command))
    }
  }
#endif
