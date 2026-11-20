import Carbon.HIToolbox
import Foundation

/// Why a system-wide shortcut could not be registered.
nonisolated public enum SystemHotKeyError: Error, Equatable, CustomStringConvertible {
  /// Another app already registered the chord.
  case inUse(String)
  /// The system refused for another reason, with its status code.
  case failed(String, Int32)

  /// What went wrong, for Settings.
  public var description: String {
    switch self {
    case .inUse(let chord): "Another app already uses \(chord)."
    case .failed(let step, let status): "Couldn\u{2019}t \(step) (error \(status))."
    }
  }
}

/// One system-wide shortcut, registered with the Carbon hot-key API. It needs no Accessibility
/// permission: the system hands this app only this chord, and only while it is registered.
/// Safe to use: the Carbon reference it keeps is released exactly once and never handed out.
@safe public final class SystemHotKey {
  /// Four characters that mark this app's hot keys ("OMNI").
  private static let signature: OSType = 0x4F4D_4E49
  private static var actions: [UInt32: @MainActor () -> Void] = [:]
  private static var nextID: UInt32 = 1
  private static var handlerInstalled = false

  private let id: UInt32
  private let reference: EventHotKeyRef
  private let chord: HotKeyChord
  private let reportIssue: DesktopIssueReporter
  private var isRegistered = true

  /// Registers `chord`, system-wide, to run `action` on the main actor.
  /// - Parameters:
  ///   - chord: The keys.
  ///   - reportIssue: Where a failure to release the chord goes.
  ///   - action: What pressing them does.
  /// - Throws: `.inUse` when another app holds the chord, `.failed` for any other refusal.
  public init(
    chord: HotKeyChord, reportIssue: @escaping DesktopIssueReporter,
    action: @escaping @MainActor () -> Void
  ) throws(SystemHotKeyError) {
    try Self.installHandler()
    let id = Self.nextID
    Self.nextID += 1
    var reference: EventHotKeyRef?
    let status = unsafe RegisterEventHotKey(
      UInt32(chord.keyCode), Self.carbonModifiers(chord.modifiers),
      EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0,
      &reference)
    guard status == noErr, let reference = unsafe reference else {
      if status == OSStatus(eventHotKeyExistsErr) { throw .inUse(chord.displayText) }
      throw .failed("register \(chord.displayText)", status)
    }
    self.id = id
    self.chord = chord
    self.reportIssue = reportIssue
    unsafe self.reference = reference
    Self.actions[id] = action
  }

  /// Releases the chord; pressing it reaches other apps again. Owners call it before letting go.
  public func unregister() {
    guard isRegistered else { return }
    isRegistered = false
    Self.actions[id] = nil
    let status = unsafe UnregisterEventHotKey(reference)
    if status != noErr {
      reportIssue(.systemShortcut(.failed("release \(chord.displayText)", status)))
    }
  }

  /// Runs the action registered under `id`.
  static func fire(_ id: UInt32) {
    actions[id]?()
  }

  /// Carbon's modifier mask for `modifiers`.
  static func carbonModifiers(_ modifiers: HotKeyChord.Modifiers) -> UInt32 {
    var mask = 0
    if modifiers.contains(.command) { mask |= cmdKey }
    if modifiers.contains(.shift) { mask |= shiftKey }
    if modifiers.contains(.option) { mask |= optionKey }
    if modifiers.contains(.control) { mask |= controlKey }
    return UInt32(mask)
  }

  /// Listens for hot-key presses on the application's event target, once.
  private static func installHandler() throws(SystemHotKeyError) {
    guard !handlerInstalled else { return }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = unsafe InstallEventHandler(
      GetApplicationEventTarget(), handleHotKey, 1, &eventType, nil, nil)
    guard status == noErr else { throw .failed("listen for system-wide shortcuts", status) }
    handlerInstalled = true
  }
}

/// Carbon's callback for a pressed hot key, on the main thread's event loop.
private nonisolated func handleHotKey(
  _ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event = unsafe event else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = unsafe GetEventParameter(
    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
  guard status == noErr, hotKeyID.signature == 0x4F4D_4E49 else { return status }
  let id = hotKeyID.id
  MainActor.assumeIsolated { SystemHotKey.fire(id) }
  return noErr
}
