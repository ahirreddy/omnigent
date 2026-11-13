#if os(iOS)
  import Foundation
  import OmnigentViewTesting
  import UIKit

  @testable import OmnigentTerminalUI

  /// A surface on a window of the test process, fed by an echo shell, with an edit menu that
  /// records instead of showing.
  @MainActor
  struct TouchSurface {
    let connection: EchoTerminalConnection
    let controller: TerminalSurfaceController
    let screen: InProcessWindow
    let editMenu: RecordingEditMenu

    var view: TerminalSurfaceUIView { controller.view }

    init(
      connection: EchoTerminalConnection = EchoTerminalConnection(prompt: "$ ", banner: "ready"),
      width: CGFloat = 480, height: CGFloat = 240
    ) throws {
      self.connection = connection
      controller = try TerminalSurfaceController(connection: connection)
      editMenu = RecordingEditMenu(delegate: controller.view)
      controller.view.editMenu = editMenu
      screen = try InProcessWindow(view: controller.view, width: width, height: height)
    }

    func close() {
      view.stopMomentum()
      screen.close()
    }

    /// Whether the banner has reached the screen.
    func ready() async -> Bool {
      await eventually { controller.visibleText().contains("ready") }
    }

    /// What the program has been sent, as text.
    var sent: String { lossyUTF8(connection.received) }

    /// Whether the program was sent exactly `text`, soon.
    func receives(_ text: String) async -> Bool {
      await eventually { connection.received == Array(text.utf8) }
    }

    /// Sends the program's own output and lets libghostty parse it.
    func programPrints(_ text: String) async throws {
      connection.emit(Array(text.utf8))
      try await Task.sleep(for: .milliseconds(120))
    }

    /// The accessory row's button with this accessibility label.
    func accessoryButton(_ label: String) -> UIButton? {
      var pending: [UIView] = [view.accessoryBar]
      while let next = pending.popLast() {
        if let button = next as? UIButton, button.accessibilityLabel == label { return button }
        pending.append(contentsOf: next.subviews)
      }
      return nil
    }

    /// Presses an accessory button the way a touch up inside it does.
    func pressAccessory(_ label: String) -> Bool {
      guard let button = accessoryButton(label) else { return false }
      button.sendActions(for: .touchUpInside)
      return true
    }
  }
#endif
