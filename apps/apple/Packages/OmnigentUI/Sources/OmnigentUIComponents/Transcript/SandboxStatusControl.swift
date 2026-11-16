import Observation
import SwiftUI

/// The titlebar's sandbox status: a box with a small state mark. Resting the pointer on it,
/// clicking it, or activating it from the keyboard opens ``SandboxStatusPanel``.
struct SandboxStatusControl: View {
  let state: SandboxStatusState
  let actions: SandboxStatusActions

  @State private var model = SandboxPanelModel()

  var body: some View {
    Button {
      model.toggle()
    } label: {
      Label(state.title, systemImage: "shippingbox").labelStyle(.iconOnly)
    }
    // On the button itself, so the mark below stays an element of its own.
    .accessibilityLabel(state.title)
    .accessibilityValue(state.statusLine)
    .accessibilityHint("Shows the sandbox\u{2019}s state and what it can do")
    .accessibilityIdentifier("header-sandbox")
    .overlay(alignment: .bottomTrailing) {
      SandboxStatusMark(mark: state.mark).allowsHitTesting(false)
    }
    .onHover { model.pointerChanged(overControl: $0) }
    .onChange(of: state.mark) { model.sandboxChanged() }
    .popover(isPresented: Bindable(model).isPresented, arrowEdge: .bottom) {
      SandboxStatusPanel(state: state, actions: actions, model: model)
        .onHover { model.pointerChanged(overPanel: $0) }
    }
  }
}

/// The state mark on the sandbox icon: a spinner while it is on its way, else a shape and color.
struct SandboxStatusMark: View {
  let mark: SandboxStatusState.Mark

  var body: some View {
    Group {
      if mark == .progress {
        ProgressView().controlSize(.mini).scaleEffect(0.7)
      } else {
        Image(systemName: symbol)
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(color)
      }
    }
    .frame(width: 10, height: 10)
    .accessibilityElement()
    .accessibilityLabel(mark.label)
    .accessibilityIdentifier("sandbox-mark-\(mark.rawValue)")
  }

  private var symbol: String {
    switch mark {
    case .attention: "exclamationmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .resting: "moon.circle.fill"
    case .running, .progress: "circle.fill"
    }
  }

  private var color: AnyShapeStyle {
    switch mark {
    case .attention: AnyShapeStyle(Theme.attention)
    case .failed: AnyShapeStyle(Theme.failure)
    case .resting: AnyShapeStyle(.tertiary)
    case .running, .progress: AnyShapeStyle(Theme.success)
    }
  }
}

/// Whether the sandbox panel shows, and the operation it is asking the server for.
@MainActor
@Observable
final class SandboxPanelModel {
  /// How long the pointer rests on the control before the panel opens.
  let openDelay: Duration
  /// How long the pointer may be off the control and the panel before the panel closes: time
  /// to cross from one to the other.
  let closeDelay: Duration

  /// The panel shows.
  var isPresented = false {
    didSet {
      guard !isPresented else { return }
      isPinned = false
      confirmingID = nil
    }
  }
  /// A click, the keyboard or a request opened the panel: the pointer leaving does not close it.
  private(set) var isPinned = false
  /// The operation whose request is in flight.
  private(set) var runningID: String?
  /// The destructive operation waiting for the user to confirm it.
  private(set) var confirmingID: String?
  /// Why the last operation failed.
  private(set) var failure: String?

  @ObservationIgnored private var isOverControl = false
  @ObservationIgnored private var isOverPanel = false
  /// The wait before the panel follows the pointer; `nil` when the pointer asks for nothing.
  @ObservationIgnored private(set) var pending: Task<Void, Never>?
  /// The request in flight.
  @ObservationIgnored private(set) var inFlight: Task<Void, Never>?

  /// Creates the model.
  /// - Parameters:
  ///   - openDelay: How long the pointer rests before the panel opens.
  ///   - closeDelay: How long the pointer may be away before the panel closes.
  init(openDelay: Duration = .milliseconds(350), closeDelay: Duration = .milliseconds(400)) {
    self.openDelay = openDelay
    self.closeDelay = closeDelay
  }

  /// The control was clicked or activated: opens the panel to stay, or closes one that stays.
  func toggle() {
    pending?.cancel()
    pending = nil
    if isPresented, isPinned {
      isPresented = false
    } else {
      isPinned = true
      isPresented = true
    }
  }

  /// The pointer entered or left the control.
  func pointerChanged(overControl inside: Bool) {
    isOverControl = inside
    followPointer()
  }

  /// The pointer entered or left the open panel.
  func pointerChanged(overPanel inside: Bool) {
    isOverPanel = inside
    followPointer()
  }

  /// The sandbox moved on, so the last failure no longer describes it.
  func sandboxChanged() {
    failure = nil
  }

  /// Opens the panel once the pointer has rested on the control, and closes an unpinned one
  /// once the pointer has left both.
  private func followPointer() {
    pending?.cancel()
    pending = nil
    let wantsOpen = isOverControl || isOverPanel
    guard wantsOpen != isPresented, wantsOpen || !isPinned else { return }
    let delay = wantsOpen ? openDelay : closeDelay
    pending = Task { [weak self] in
      do {
        try await Task.sleep(for: Theme.Timing.pause(delay))
      } catch {
        // The pointer moved on before the delay ended.
        return
      }
      self?.isPresented = wantsOpen
    }
  }

  /// A button was pressed: runs `operation`, after a confirmation when it would end a turn.
  func request(
    _ operation: SandboxStatusState.Operation, isTurnRunning: Bool,
    perform: @escaping @MainActor (String) async -> String?
  ) {
    if operation.isDestructive, isTurnRunning, confirmingID != operation.id {
      confirmingID = operation.id
      return
    }
    confirmingID = nil
    failure = nil
    runningID = operation.id
    isPinned = true
    inFlight = Task {
      let reason = await perform(operation.id)
      runningID = nil
      failure = reason.map { "\(operation.title) failed: \($0)" }
    }
  }

  /// The user backed out of a confirmation.
  func cancelConfirmation() {
    confirmingID = nil
  }
}
