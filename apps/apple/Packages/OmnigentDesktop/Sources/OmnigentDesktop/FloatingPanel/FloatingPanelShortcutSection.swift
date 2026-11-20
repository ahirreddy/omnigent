import AppKit
import SwiftUI

/// Settings › General › Desktop app: "Open New Agent from anywhere", on or off, and the chord
/// that opens the floating New Agent panel. Shown only while a signed-in server turns the panel
/// on, as on the desktop app.
struct FloatingPanelShortcutSection: View {
  @Bindable var shortcut: FloatingPanelShortcut

  var body: some View {
    if shortcut.isAvailable {
      Section {
        Toggle(isOn: isOn) {
          Text("Open New Agent from anywhere")
          Text("A system-wide shortcut opens a New Agent panel over the app you're in.")
        }
        .accessibilityIdentifier("settings.floating-panel")
        .id("settings.floating-panel")
        if case .chord(let chord) = shortcut.setting {
          LabeledContent("Shortcut") {
            HotKeyRecorder(shortcut: shortcut, chord: chord)
          }
        }
        if let problem = shortcut.problem {
          Label(problem, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.floating-panel.problem")
        }
      } header: {
        Text("Desktop app")
      }
    }
  }

  private var isOn: Binding<Bool> {
    Binding(
      get: {
        if case .chord = shortcut.setting { return true }
        return false
      },
      set: { isOn in
        shortcut.setting = isOn ? .chord(.newAgentPanelDefault) : .off
      })
  }
}

/// The chord as a button; clicking it records the next chord typed. Escape cancels.
struct HotKeyRecorder: View {
  let shortcut: FloatingPanelShortcut
  let chord: HotKeyChord
  @State private var monitor = HotKeyRecordingMonitor()
  @State private var refusal: String?

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Button(shortcut.isRecording ? "Type a Shortcut\u{2026}" : chord.displayText) {
        if shortcut.isRecording { stop() } else { start() }
      }
      .monospacedDigit()
      .help(shortcut.isRecording ? "Press Escape to cancel" : "Click to record another shortcut")
      .accessibilityLabel(
        shortcut.isRecording ? "Recording a shortcut" : "Shortcut \(chord.displayText)"
      )
      .accessibilityIdentifier("settings.floating-panel.shortcut")
      if let refusal {
        Text(refusal).font(.caption).foregroundStyle(.secondary)
      }
    }
    .onDisappear { stop() }
  }

  private func start() {
    refusal = nil
    shortcut.isRecording = true
    monitor.start { keyCode, flags, characters in
      // Escape alone cancels.
      if keyCode == 53, flags.isDisjoint(with: [.command, .control, .option, .shift]) {
        stop()
        return
      }
      guard let recorded = HotKeyChord(keyCode: keyCode, flags: flags, characters: characters)
      else {
        refusal = "Include Command, Control or Option."
        return
      }
      stop()
      shortcut.setting = .chord(recorded)
    }
  }

  private func stop() {
    monitor.stop()
    shortcut.isRecording = false
  }
}

/// Takes this app's next key presses while recording, ahead of the window's own keys. A local
/// monitor sees only this app's events and needs no permission.
@MainActor
final class HotKeyRecordingMonitor {
  private var token: Any?

  /// Calls `record` with each key press until ``stop()``.
  func start(_ record: @escaping @MainActor (UInt16, NSEvent.ModifierFlags, String?) -> Void) {
    stop()
    token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      record(event.keyCode, event.modifierFlags, event.charactersIgnoringModifiers)
      return nil
    }
  }

  /// Stops taking key presses.
  func stop() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }
}
