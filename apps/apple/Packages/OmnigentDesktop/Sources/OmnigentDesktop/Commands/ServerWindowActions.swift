public import SwiftUI

/// Menu actions the key window supports. A `nil` action disables its menu item.
///
/// The app builds this per window from its stores and passes it to
/// `View.serverWindow(_:desktop:...)`, which publishes it as a focused scene value.
public struct ServerWindowActions {
  /// Find actions; `nil` falls back to the first responder's text finder.
  public struct Find {
    /// Show the find bar (Find..., Command-F).
    public var show: () -> Void
    /// Next match (Command-G).
    public var next: () -> Void
    /// Previous match (Shift-Command-G).
    public var previous: () -> Void
    /// Search for the selection (Command-E).
    public var useSelection: (() -> Void)?

    /// Creates find actions.
    /// - Parameters:
    ///   - show: Show the find bar.
    ///   - next: Next match.
    ///   - previous: Previous match.
    ///   - useSelection: Search for the selection.
    public init(
      show: @escaping () -> Void, next: @escaping () -> Void,
      previous: @escaping () -> Void, useSelection: (() -> Void)? = nil
    ) {
      self.show = show
      self.next = next
      self.previous = previous
      self.useSelection = useSelection
    }
  }

  /// Content zoom (View menu).
  public struct Zoom {
    /// Actual Size (Command-0).
    public var reset: () -> Void
    /// Zoom In (Command-+).
    public var zoomIn: () -> Void
    /// Zoom Out (Command-minus).
    public var zoomOut: () -> Void

    /// Creates zoom actions.
    /// - Parameters:
    ///   - reset: Actual Size.
    ///   - zoomIn: Zoom In.
    ///   - zoomOut: Zoom Out.
    public init(
      reset: @escaping () -> Void, zoomIn: @escaping () -> Void, zoomOut: @escaping () -> Void
    ) {
      self.reset = reset
      self.zoomIn = zoomIn
      self.zoomOut = zoomOut
    }
  }

  /// Start a conversation on this window's server (Command-N).
  public var newSession: (() -> Void)?
  /// Return this window to the connect screen.
  public var changeServer: (() -> Void)?
  /// Sign out of this window's server. `nil` while signed out or for no-auth servers.
  public var signOut: (() -> Void)?
  /// Reconnect streams now (Shift-Option-Command-R).
  public var reconnect: (() -> Void)?
  /// Find in the transcript or browser pane.
  public var find: Find?
  /// Content zoom.
  public var zoom: Zoom?

  /// Creates window actions.
  /// - Parameters:
  ///   - newSession: New Session.
  ///   - changeServer: Change Server.
  ///   - signOut: Sign Out of Server.
  ///   - reconnect: Reconnect.
  ///   - find: Find actions.
  ///   - zoom: Zoom actions.
  public init(
    newSession: (() -> Void)? = nil,
    changeServer: (() -> Void)? = nil,
    signOut: (() -> Void)? = nil,
    reconnect: (() -> Void)? = nil,
    find: Find? = nil,
    zoom: Zoom? = nil
  ) {
    self.newSession = newSession
    self.changeServer = changeServer
    self.signOut = signOut
    self.reconnect = reconnect
    self.find = find
    self.zoom = zoom
  }
}

/// The key server window as seen by menu commands.
public struct FocusedServerWindow {
  /// The window's value.
  public var id: ServerWindowID
  /// What it supports.
  public var actions: ServerWindowActions
}

extension FocusedValues {
  /// The key server window, published by `View.serverWindow(_:desktop:...)`.
  @Entry public var serverWindow: FocusedServerWindow?
}
