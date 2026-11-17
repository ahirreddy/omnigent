#if os(macOS)
  import AppKit
  import CoreGraphics
  import Darwin
  import Foundation
  import OmnigentGhosttyKit
  import OmnigentViewTesting
  import Synchronization
  import Testing

  @testable import OmnigentTerminalUI

  /// The CVDisplayLink that paces a focused terminal's frames. Focus, visibility and display
  /// changes start, stop and rebind it, and CoreVideo stops and restarts it on the main thread
  /// while the display reconfigures. A start during a stop on another thread leaves that stop
  /// waiting forever, and freeing the surface then waits forever for its renderer. A hang never
  /// ends, so the scenario runs in a process of its own that a watchdog ends.
  @MainActor
  @Suite("The display link pacing a terminal", .serialized)
  struct DisplayLinkTests {
    private enum Failure: Int32 {
      case changeHung = 71
      case freeHung = 72
      case surfaceKept = 73
      case displayKept = 74
      case noPrompt = 75
    }

    /// What the scenario's process writes before it ends early.
    private nonisolated static let prefix = "display link: "

    @Test("focus, visibility and display changes while frames draw leave the surface free to go")
    func changesThenFree() async throws {
      let result = await #expect(
        processExitsWith: .success, observing: [\.standardErrorContent]
      ) {
        try await DisplayLinkTests.changeThenFree()
      }
      let output = String(bytes: try #require(result).standardErrorContent, encoding: .utf8) ?? ""
      let reported = output.split(separator: "\n").filter { $0.hasPrefix(Self.prefix) }
      print(reported.joined(separator: "\n"))
      #expect(
        !reported.contains(where: { $0.contains("hung") || $0.contains("kept") }), "\(reported)")
    }

    private nonisolated static func end(_ failure: Failure, _ reason: String) -> Never {
      FileHandle.standardError.write(Data("\(prefix)\(reason)\n".utf8))
      _exit(failure.rawValue)
    }

    private static func changeThenFree() async throws {
      SystemSideEffects.install()
      let watchdog = Watchdog()
      // Only these optionals hold the controller, so clearing them frees the surface.
      var controller: TerminalSurfaceController?
      var host: SurfaceHost?
      weak var freed: TerminalSurfaceController?
      do {
        let created = try TerminalSurfaceController(
          connection: EchoTerminalConnection(prompt: "$ ", banner: "ready"))
        controller = created
        freed = created
        host = try SurfaceHost(controller: created, width: 640, height: 400)
      }
      guard await eventually({ controller?.visibleText().contains("ready") == true }) else {
        end(.noPrompt, "the surface drew no prompt")
      }

      watchdog.arm(seconds: 40) { end(.changeHung, "a focus, visibility or display change hung") }
      if let controller { change(controller) }

      watchdog.arm(seconds: 20) { end(.freeHung, "ghostty_surface_free hung") }
      host?.window.orderOut(nil)
      host?.window.contentView = nil
      host = nil
      // The last reference: the controller's deinit frees the surface here.
      controller = nil
      watchdog.disarm()
      if freed != nil { end(.surfaceKept, "the controller was kept, so the surface was not freed") }
      // The display link's main-thread work still queued after the free runs now.
      MainLoop.run(for: 0.3)
    }

    /// Changes focus, visibility and the display every few milliseconds for a few seconds while
    /// output draws, as clicks, window moves and occlusion do, with the display's mode switching
    /// meanwhile in a virtual machine.
    private static func change(_ controller: TerminalSurfaceController) {
      guard let surface = unsafe controller.surface else { return }
      let reconfiguration = DisplayReconfiguration()
      let display = CGMainDisplayID()
      let clock = ContinuousClock()
      let stopAt = clock.now + .seconds(reconfiguration == nil ? 3 : 8)
      reconfiguration?.start(every: 0.1)
      var visible = true
      var step = 0
      while clock.now < stopAt {
        unsafe ghostty_surface_set_focus(surface, step.isMultiple(of: 2))
        if step.isMultiple(of: 7) {
          visible.toggle()
          unsafe ghostty_surface_set_occlusion(surface, visible)
        }
        if step.isMultiple(of: 5) { unsafe ghostty_surface_set_display_id(surface, display) }
        controller.feed(Array("step \(step)\r\n".utf8))
        MainLoop.run(for: 0.003)
        step += 1
      }
      unsafe ghostty_surface_set_occlusion(surface, true)
      reconfiguration?.stop()
      _ = MainLoop.settle(until: { reconfiguration?.isRestored ?? true }, timeout: 10)
      MainLoop.run(for: 0.2)
      let switches = reconfiguration?.switches ?? 0
      FileHandle.standardError.write(
        Data("\(prefix)\(step) changes, \(switches) display mode switches\n".utf8))
      if reconfiguration != nil, switches == 0 {
        end(.displayKept, "the display kept its mode, so CoreVideo never restarted the link")
      }
    }
  }

  /// Runs its handler unless disarmed in time, on a thread of its own: a hang stops the main
  /// thread, not this timer.
  private nonisolated final class Watchdog: Sendable {
    private let generation = Atomic<Int>(0)

    func arm(seconds: Double, _ expired: @escaping @Sendable () -> Void) {
      let armed = generation.add(1, ordering: .sequentiallyConsistent).newValue
      DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
        if generation.load(ordering: .sequentiallyConsistent) == armed { expired() }
      }
    }

    func disarm() {
      generation.add(1, ordering: .sequentiallyConsistent)
    }
  }

  /// Switches the main display between two of its modes for this process, on a thread of its
  /// own, as display sleep, wake or a resolution change would: CoreVideo then stops and restarts
  /// every display link on the display from the main thread while that thread keeps changing
  /// the terminal. Only in a virtual machine, whose display no one watches.
  private nonisolated final class DisplayReconfiguration: Sendable {
    private let display = CGMainDisplayID()
    /// The display's mode, then the one it switches to.
    private let modeIDs: [Int32]
    private let switching = Atomic<Bool>(false)
    private let restored = Atomic<Bool>(false)
    private let switchCount = Atomic<Int>(0)

    /// How many times the mode changed.
    var switches: Int { switchCount.load(ordering: .sequentiallyConsistent) }
    /// Whether the switching ended with the display's own mode back.
    var isRestored: Bool { restored.load(ordering: .sequentiallyConsistent) }

    init?() {
      guard Self.inVirtualMachine, let original = CGDisplayCopyDisplayMode(display) else {
        return nil
      }
      let others = Self.modes(of: display).filter {
        $0.ioDisplayModeID != original.ioDisplayModeID && $0.isUsableForDesktopGUI()
      }
      // The same size in points keeps the window where it is; only the scale changes.
      guard
        let other = others.first(where: {
          $0.width == original.width && $0.height == original.height
        }) ?? others.first
      else { return nil }
      modeIDs = [original.ioDisplayModeID, other.ioDisplayModeID]
    }

    /// Switches the mode every `interval` seconds until `stop`.
    func start(every interval: TimeInterval) {
      switching.store(true, ordering: .sequentiallyConsistent)
      Thread { [self] in
        var current = 0
        while switching.load(ordering: .sequentiallyConsistent) {
          if apply(modeIDs[1 - current]) {
            current = 1 - current
            switchCount.add(1, ordering: .sequentiallyConsistent)
          }
          Thread.sleep(forTimeInterval: interval)
        }
        if current == 0 || apply(modeIDs[0]) {
          restored.store(true, ordering: .sequentiallyConsistent)
        }
      }.start()
    }

    /// Ends the switching; `isRestored` turns true once the display's mode is back.
    func stop() {
      switching.store(false, ordering: .sequentiallyConsistent)
    }

    private static func modes(of display: CGDirectDisplayID) -> [CGDisplayMode] {
      let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
      return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    private func apply(_ modeID: Int32) -> Bool {
      guard let mode = Self.modes(of: display).first(where: { $0.ioDisplayModeID == modeID })
      else { return false }
      var config: CGDisplayConfigRef?
      guard unsafe CGBeginDisplayConfiguration(&config) == .success else { return false }
      guard unsafe CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
        unsafe CGCancelDisplayConfiguration(config)
        return false
      }
      return unsafe CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    private static var inVirtualMachine: Bool {
      var present: Int32 = 0
      var size = MemoryLayout<Int32>.size
      return unsafe sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0
        && present == 1
    }
  }
#endif
