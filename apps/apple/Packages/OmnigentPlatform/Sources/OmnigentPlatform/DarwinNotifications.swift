#if DEBUG
  import Dispatch
  public import SwiftUI
  import notify

  /// Darwin notifications that another process posts (`notifyutil -p <name>`), for debug-build
  /// measurement hooks driven from a script.
  @MainActor
  public enum DarwinNotifications {
    /// Calls `handler` on the main thread each time `name` is posted.
    /// - Parameters:
    ///   - name: The notification name.
    ///   - handler: Runs on the main thread.
    /// - Returns: The registration token, for ``cancel(_:)``.
    @discardableResult
    public static func observe(_ name: String, _ handler: @escaping @MainActor () -> Void) -> Int32
    {
      var token: Int32 = 0
      let status = unsafe notify_register_dispatch(name, &token, .main) { _ in
        MainActor.assumeIsolated { handler() }
      }
      precondition(
        status == NOTIFY_STATUS_OK, "notify_register_dispatch(\(name)) failed: \(status)")
      return token
    }

    /// Stops a registration.
    /// - Parameter token: What ``observe(_:_:)`` returned.
    public static func cancel(_ token: Int32) {
      notify_cancel(token)
    }
  }

  extension View {
    /// Runs `action` with the name's suffix after `ai.omnigent.perf.` whenever one of `names`
    /// is posted while the view is on screen (debug measurement hooks).
    /// - Parameters:
    ///   - names: Suffixes after `ai.omnigent.perf.`.
    ///   - action: Runs on the main thread with the posted suffix.
    /// - Returns: The view.
    public func perfHooks(_ names: [String], action: @escaping @MainActor (String) -> Void)
      -> some View
    {
      modifier(PerfHooks(names: names, action: action))
    }
  }

  private struct PerfHooks: ViewModifier {
    let names: [String]
    let action: @MainActor (String) -> Void
    @State private var tokens: [Int32] = []

    func body(content: Content) -> some View {
      content
        .onAppear {
          tokens = names.map { name in
            DarwinNotifications.observe("ai.omnigent.perf.\(name)") { action(name) }
          }
        }
        .onDisappear {
          tokens.forEach(DarwinNotifications.cancel)
          tokens = []
        }
    }
  }
#endif
