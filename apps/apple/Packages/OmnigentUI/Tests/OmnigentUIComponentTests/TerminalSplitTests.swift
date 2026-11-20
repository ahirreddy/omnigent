import CoreGraphics
import Foundation
import Testing

@testable import OmnigentUIComponents

/// The split Terminal view's tree, as the web's `terminalSplitLayout`: splitting, closing,
/// resizing within 25-75%, pane cycling, following the terminal list, and what is kept.
@Suite("Terminal split")
struct TerminalSplitTests {
  private func defaults() throws -> UserDefaults {
    let name = "terminal-split-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("Splitting puts the new shell right of or below the focused pane, and focuses it")
  func splitting() throws {
    let right = try #require(TerminalSplitState.splitting(nil, with: "zsh_1", axis: .columns))
    #expect(
      right.layout
        == .split(
          axis: .columns, ratio: 0.5, first: .pane(.agent), second: .pane(.shell("zsh_1"))))
    #expect(right.focused == .shell("zsh_1"))
    let down = try #require(TerminalSplitState.splitting(right, with: "bash_2", axis: .rows))
    #expect(down.layout.keys == [.agent, .shell("zsh_1"), .shell("bash_2")])
    guard case .split(_, _, let first, let second) = down.layout else {
      Issue.record("not a split")
      return
    }
    #expect(first == .pane(.agent))
    #expect(
      second
        == .split(
          axis: .rows, ratio: 0.5, first: .pane(.shell("zsh_1")), second: .pane(.shell("bash_2"))))
    // A shell already shown is not split in again.
    #expect(TerminalSplitState.splitting(down, with: "zsh_1", axis: .rows) == down)
  }

  @Test("Closing a pane gives its space to its sibling; one pane left is the unsplit view")
  func removing() throws {
    var state = try #require(TerminalSplitState.splitting(nil, with: "a", axis: .columns))
    state = try #require(TerminalSplitState.splitting(state, with: "b", axis: .rows))
    let closed = try #require(state.removing(.shell("b")))
    #expect(closed.layout.keys == [.agent, .shell("a")])
    #expect(closed.focused == .agent, "the focus moves to the first pane left")
    #expect(closed.removing(.shell("a")) == nil)
  }

  @Test("A divider keeps each side within a quarter and three quarters of its split")
  func resizing() throws {
    let state = try #require(TerminalSplitState.splitting(nil, with: "a", axis: .columns))
    #expect(state.resizing(at: [], to: 0.9).layout.ratio == 0.75)
    #expect(state.resizing(at: [], to: 0.1).layout.ratio == 0.25)
    #expect(state.resizing(at: [], to: 0.6).layout.ratio == 0.6)
    #expect(TerminalSplitLayout.clamped(.nan) == 0.5)
    let geometry = state.layout.geometry(in: CGRect(x: 0, y: 0, width: 400, height: 300))
    #expect(geometry.panes.map(\.frame.width) == [200, 200])
    let divider = try #require(geometry.dividers.first)
    #expect(divider.offset == 200)
    #expect(divider.ratio(at: CGPoint(x: 300, y: 10)) == 0.75)
    #expect(divider.ratio(at: CGPoint(x: 390, y: 10)) == 0.75)
  }

  @Test("Pane cycling wraps in reading order")
  func cycling() throws {
    var state = try #require(TerminalSplitState.splitting(nil, with: "a", axis: .columns))
    state = try #require(TerminalSplitState.splitting(state, with: "b", axis: .rows))
    #expect(state.focused == .shell("b"))
    #expect(state.cycling(by: 1).focused == .agent)
    #expect(state.cycling(by: -1).focused == .shell("a"))
    #expect(state.focusing(.shell("gone")) == state)
  }

  @Test("A saved split comes back for the session; a malformed one restores unsplit")
  func persistence() throws {
    let defaults = try defaults()
    let panes = TerminalSplitPanes(sessionID: "conv_a", defaults: defaults)
    #expect(panes.state == nil)
    panes.split(with: "a", axis: .rows)
    panes.resize(at: [], to: 0.3)
    let restored = TerminalSplitPanes(sessionID: "conv_a", defaults: defaults)
    #expect(restored.state == panes.state)
    #expect(TerminalSplitPanes(sessionID: "conv_b", defaults: defaults).state == nil)
    defaults.set(Data("{}".utf8), forKey: TerminalSplitPanes.keyPrefix + "conv_c")
    #expect(TerminalSplitPanes(sessionID: "conv_c", defaults: defaults).state == nil)
    panes.remove(.shell("a"))
    #expect(defaults.data(forKey: TerminalSplitPanes.keyPrefix + "conv_a") == nil)
  }

  @Test("A shell pane goes when its terminal leaves the list, not before it is ever listed")
  func followingTheList() throws {
    let panes = TerminalSplitPanes(sessionID: "conv_a", defaults: try defaults())
    panes.split(with: "a", axis: .columns)
    panes.split(with: "b", axis: .columns)
    // A shell just split off is not listed yet, so it stays.
    let restored = TerminalSplitPanes(sessionID: "conv_a", defaults: try defaults())
    restored.split(with: "x", axis: .columns)
    restored.follow(listedTerminalIDs: ["agent"])
    #expect(restored.state?.layout.keys.contains(.shell("x")) == true, "a split's own shell")
    panes.follow(listedTerminalIDs: ["agent", "a", "b"])
    panes.follow(listedTerminalIDs: ["agent", "a"])
    #expect(panes.state?.layout.keys == [.agent, .shell("a")])
    // An emptied list refills a terminal at a time.
    panes.follow(listedTerminalIDs: [])
    panes.follow(listedTerminalIDs: ["agent"])
    #expect(panes.state?.layout.keys == [.agent, .shell("a")])
    panes.prune(keeping: ["agent"])
    #expect(panes.state == nil)
  }

  @Test("The menu lists the split items for the session, enabled while the Terminal view shows")
  func commands() throws {
    let panes = TerminalSplitPanes(sessionID: "conv_a", defaults: try defaults())
    var splits: [(TerminalSplitAxis, String)] = []
    var closed: [TerminalPaneKey] = []
    let controls = TerminalSplitControls(
      panes: panes, shells: ["zsh", "bash"], isBusy: false,
      split: { splits.append(($0, $1)) }, close: { closed.append($0) })
    var hidden = SessionCommandActions()
    controls.addCommands(to: &hidden, isShown: false)
    #expect(hidden.offersTerminalSplit && hidden.splitTerminalRight == nil)
    var shown = SessionCommandActions()
    controls.addCommands(to: &shown, isShown: true)
    shown.splitTerminalDown?()
    #expect(splits.map(\.0) == [.rows] && splits.map(\.1) == ["zsh"])
    #expect(shown.closeTerminalPane == nil && shown.nextTerminalPane == nil, "unsplit")
    panes.split(with: "a", axis: .columns)
    var split = SessionCommandActions()
    controls.addCommands(to: &split, isShown: true)
    split.closeTerminalPane?()
    #expect(closed == [.shell("a")])
    split.nextTerminalPane?()
    #expect(panes.state?.focused == .agent)
  }
}

extension TerminalSplitLayout {
  /// The root split's ratio, for tests.
  fileprivate var ratio: Double? {
    if case .split(_, let ratio, _, _) = self { return ratio }
    return nil
  }
}
