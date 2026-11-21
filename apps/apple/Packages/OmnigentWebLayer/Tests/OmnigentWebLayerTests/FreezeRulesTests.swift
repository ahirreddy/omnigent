import Foundation
import OWLProtocol
import Testing

/// The rules both sides judge a freeze by (owl_freeze.h): when a view owes a frame, how often
/// a stall is written down, how input is classed, and how a health record reads as a line.
@Suite("Freeze rules")
struct FreezeRulesTests {
  private let second: UInt64 = 1_000_000_000

  private func advance(
    _ episode: inout owl_stall_episode, at seconds: Double, since: UInt64, first: Double = 2,
    activity: UInt64 = 0, needsActivity: Bool = false
  ) -> owl_stall_step {
    let step = owl_stall_advance(
      episode, UInt64(seconds * 1e9), since, first, activity, needsActivity)
    episode = step.episode
    return step
  }

  @Test func theWireNumbersAreStable() {
    #expect(OWL_PROTOCOL_MINOR_HEALTH == 5)
    #expect(OWL_PROTOCOL_MINOR >= OWL_PROTOCOL_MINOR_HEALTH)
    #expect(OWLField.healthKind.rawValue == 129)
    #expect(OWLMessageKind.healthReport.rawValue == 131)
    #expect(OWLHealthKind.viewStall.rawValue == 1)
    #expect(OWLHealthKind.rendererProbe.rawValue == 3)
    #expect(OWLHealthKind.hostStall.rawValue == 6)
    #expect(OWLHealthKind.channelDrained.rawValue == 9)
    #expect(OWL_INPUT_CLASS_COUNT == 7)
  }

  @Test("a stall is due a line at 2 s, 10 s, 30 s, then every minute")
  func schedule() {
    let due = [0, 1.9, 2, 9.9, 10, 29, 30, 59, 60, 119, 120, 600].map {
      owl_stall_lines_due($0, 2)
    }
    #expect(due == [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 13])
    #expect(owl_stall_lines_due(.nan, 2) == 0)
    #expect(owl_stall_lines_due(1, 1) == 1)
    #expect(owl_stall_lines_due(0, 0) == 1, "a threshold of zero reports at once")
    #expect(owl_stall_lines_due(.infinity, 2) == 1_000_003)
  }

  @Test("one line per stage, then how long it lasted")
  func episode() {
    var episode = owl_stall_episode()
    let since = 100 * second
    #expect(advance(&episode, at: 101, since: since).action == .none)
    let first = advance(&episode, at: 102, since: since)
    #expect(first.action == .report && first.line == 1 && first.since_nanos == since)
    #expect(advance(&episode, at: 103, since: since).action == .none)
    #expect(advance(&episode, at: 110, since: since).line == 2)
    #expect(advance(&episode, at: 130, since: since).line == 3)
    let ended = advance(&episode, at: 131, since: 0)
    #expect(ended.action == .ended && ended.since_nanos == since)
    #expect(advance(&episode, at: 132, since: 0).action == .none)
  }

  @Test("a stall that never reached its first line ends silently")
  func shortStall() {
    var episode = owl_stall_episode()
    #expect(advance(&episode, at: 101, since: 100 * second).action == .none)
    #expect(advance(&episode, at: 101.5, since: 0).action == .none)
    #expect(episode.since_nanos == 0)
  }

  @Test("the first lines of two stalls are at least five seconds apart")
  func quietGap() {
    var episode = owl_stall_episode()
    #expect(advance(&episode, at: 102, since: 100 * second).action == .report)
    #expect(advance(&episode, at: 102.5, since: 0).action == .ended)
    // A second stall whose two seconds are up before the gap is: it waits, then reports.
    #expect(advance(&episode, at: 105, since: 103 * second).action == .none)
    #expect(advance(&episode, at: 106, since: 103 * second).action == .none)
    let late = advance(&episode, at: 107.1, since: 103 * second)
    #expect(late.action == .report && late.line == 1)
  }

  @Test("a later line needs somebody still trying, when asked to")
  func repeatsNeedActivity() {
    var episode = owl_stall_episode()
    let since = 100 * second
    #expect(
      advance(&episode, at: 102, since: since, activity: 1, needsActivity: true).action == .report)
    #expect(
      advance(&episode, at: 110, since: since, activity: 1, needsActivity: true).action == .none)
    #expect(
      advance(&episode, at: 111, since: since, activity: 2, needsActivity: true).action == .none,
      "the ten-second line was passed over, not postponed")
    let third = advance(&episode, at: 130, since: since, activity: 2, needsActivity: true)
    #expect(third.action == .report && third.line == 3)
    #expect(advance(&episode, at: 131, since: 0, needsActivity: true).action == .ended)
  }

  @Test("a different stall ends the one being followed")
  func replacedStall() {
    var episode = owl_stall_episode()
    #expect(advance(&episode, at: 102, since: 100 * second).action == .report)
    #expect(advance(&episode, at: 103, since: 102 * second).action == .ended)
    #expect(advance(&episode, at: 104, since: 102 * second).action == .none, "the quiet gap")
    #expect(advance(&episode, at: 108, since: 102 * second).action == .report)
  }

  @Test("what a view is waiting for")
  func viewStalls() {
    var activity = owl_view_activity()
    activity.visible = true
    #expect(owl_view_stall_since(activity).reason == .none)

    activity.last_frame_nanos = 50 * second
    activity.unanswered_input_nanos = 60 * second
    activity.last_input_nanos = 63 * second
    var stall = owl_view_stall_since(activity)
    #expect(stall.reason == .input && stall.since_nanos == 60 * second)

    activity.visible = false
    stall = owl_view_stall_since(activity)
    #expect(stall.reason == .inputWhileHidden && stall.since_nanos == 60 * second)
    activity.unanswered_input_nanos = 0
    #expect(owl_view_stall_since(activity).reason == .none, "a hidden view owes nothing")

    activity.visible = true
    activity.loading = true
    activity.loading_since_nanos = 70 * second
    stall = owl_view_stall_since(activity)
    #expect(stall.reason == .loading && stall.since_nanos == 70 * second)
    activity.last_frame_nanos = 72 * second
    #expect(owl_view_stall_since(activity).since_nanos == 72 * second)
    #expect(owl_stall_first_seconds(.loading) == 5)
    #expect(owl_stall_first_seconds(.input) == 2)
  }

  @Test("steady frames that stop with the renderer's animation frames are a stall; a scroll is not")
  func framesStopped() {
    var activity = owl_view_activity()
    activity.visible = true
    activity.steady_since_nanos = 10 * second
    activity.last_frame_nanos = 14 * second
    activity.frames_stopped_after_nanos = 14 * second
    let stall = owl_view_stall_since(activity)
    #expect(stall.reason == .framesStopped && stall.since_nanos == 14 * second)

    activity.last_input_nanos = 13 * second + second / 2
    #expect(owl_view_stall_since(activity).reason == .none, "input was driving the frames")
    activity.last_input_nanos = 5 * second
    #expect(owl_view_stall_since(activity).reason == .framesStopped)

    activity.steady_since_nanos = 12 * second
    #expect(owl_view_stall_since(activity).reason == .none, "two seconds is not a steady run")
  }

  @Test("a page that animates and then goes static is no stall while its animation frames run")
  func animationThatEnds() {
    var activity = owl_view_activity()
    activity.visible = true
    // Four seconds of animation, then nothing more to draw.
    activity.steady_since_nanos = 10 * second
    activity.last_frame_nanos = 14 * second
    #expect(owl_view_stall_since(activity).reason == .none, "stopping is not a stall by itself")
    #expect(!owl_view_wants_frames_probe(activity, 15 * second), "one second is not a stop yet")
    #expect(owl_view_wants_frames_probe(activity, 16 * second), "the renderer is asked")
    // The probe's animation frame ran, so nothing was recorded: still no stall.
    #expect(owl_view_stall_since(activity).reason == .none)

    activity.frames_stopped_after_nanos = 14 * second
    let stall = owl_view_stall_since(activity)
    #expect(stall.reason == .framesStopped && stall.since_nanos == 14 * second)
    #expect(!owl_view_wants_frames_probe(activity, 16 * second), "answered already")

    activity.last_frame_nanos = 14 * second + second / 10
    #expect(owl_view_stall_since(activity).reason == .none, "a later frame outdates the answer")
    #expect(owl_view_wants_frames_probe(activity, 17 * second))
    activity.unanswered_input_nanos = 15 * second
    #expect(!owl_view_wants_frames_probe(activity, 17 * second), "waiting input is its own stall")
    activity.unanswered_input_nanos = 0
    activity.visible = false
    #expect(!owl_view_wants_frames_probe(activity, 17 * second), "a hidden view draws nothing")
  }

  @Test("a click on a frozen page continues its stall")
  func followedStall() {
    let frames = owl_view_stall(reason: .framesStopped, since_nanos: 14 * second)
    let input = owl_view_stall(reason: .input, since_nanos: 17 * second)
    let none = owl_view_stall(reason: .none, since_nanos: 0)
    #expect(owl_stall_followed_since(0, false, frames) == 14 * second)
    #expect(owl_stall_followed_since(14 * second, false, input) == 14 * second)
    #expect(owl_stall_followed_since(14 * second, true, input) == 17 * second)
    #expect(owl_stall_followed_since(14 * second, false, none) == 0)
  }

  @Test("input is classed by what a page usually answers with a frame")
  func inputClasses() {
    let mouse = OWLMessageKind.inputMouse.rawValue
    let key = OWLMessageKind.inputKey.rawValue
    #expect(owl_input_class(mouse, OWLMouseKind.down.rawValue, 0, 0) == .click)
    #expect(owl_input_class(mouse, OWLMouseKind.up.rawValue, 0, 0) == .click)
    #expect(owl_input_class(mouse, OWLMouseKind.wheel.rawValue, 0, 0) == .wheel)
    #expect(owl_input_class(mouse, OWLMouseKind.move.rawValue, 0, 0) == .move)
    #expect(owl_input_class(mouse, OWLMouseKind.leave.rawValue, 0, 0) == .move)
    #expect(owl_input_class(key, 0, OWLKeyKind.rawKeyDown.rawValue, 0) == .key)
    #expect(owl_input_class(key, 0, OWLKeyKind.char.rawValue, 0) == .key)
    #expect(owl_input_class(key, 0, OWLKeyKind.keyUp.rawValue, 0) == .keyOther)
    #expect(owl_input_class(key, 0, OWLKeyKind.rawKeyDown.rawValue, 56) == .keyOther, "Shift")
    #expect(owl_input_class(OWLMessageKind.imeCommitText.rawValue, 0, 0, 0) == .text)
    #expect(owl_input_class(OWLMessageKind.imeCancelComposition.rawValue, 0, 0, 0) == .text)
    #expect(owl_input_class(OWLMessageKind.dragDrop.rawValue, 0, 0, 0) == .drag)
    let expectant: [OWLInputClass] = [.click, .wheel, .key, .text, .drag]
    #expect(expectant.allSatisfy { owl_input_expects_frame($0) })
    #expect(!owl_input_expects_frame(.move) && !owl_input_expects_frame(.keyOther))
  }
}

/// How a view's health record reads in the log.
@Suite("Freeze health lines")
struct FreezeHealthLineTests {
  private func line(_ health: owl_view_health, capacity: Int = 640) -> String {
    var health = health
    var buffer = [CChar](repeating: 0x7f, count: capacity)
    let length = unsafe owl_view_health_format(&health, &buffer, capacity)
    #expect(length < capacity && buffer[length] == 0, "always terminated")
    return String(bytes: buffer.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8)
      ?? "not UTF-8"
  }

  private func site(_ name: String) -> String {
    var health = owl_view_health()
    withUnsafeMutableBytes(of: &health.site) { bytes in
      let site = unsafe bytes.bindMemory(to: CChar.self)
      unsafe owl_site_copy(site.baseAddress, site.count, name)
    }
    return line(health).split(separator: " ").first { $0.hasPrefix("site=") }.map(String.init)
      ?? ""
  }

  @Test("a record is one line of key=value pairs")
  func encoding() {
    var health = owl_view_health()
    health.now_nanos = 10_000_000_000
    health.has_browser = true
    health.visible = true
    health.loading = true
    health.width = 1280
    health.height = 800.4
    health.scale = 2
    health.paints = 120
    health.frames = 118
    health.dropped = 2
    health.frames_last_second = 60
    health.last_paint_nanos = 9_990_000_000
    health.last_frame_nanos = 7_900_000_000
    health.inputs = 40
    health.last_input_nanos = 8_000_000_000
    health.keys_returned = 3
    health.unanswered.0 = 2
    health.unanswered.6 = 1
    #expect(
      line(health)
        == "browser=1 visible=1 focused=0 loading=1 popup=0 unresponsive=0 size=1280x800@2 site=-"
        + " paints=120 frames=118 dropped=2 errors=0 fps=60 paint_age_ms=10 frame_age_ms=2100"
        + " drop_age_ms=-1 waiting=click:2,wheel:0,key:0,move:0,text:0,drag:0,keyup:1"
        + " inputs=40 input_failures=0 input_age_ms=2000 keys_returned=3")
  }

  @Test("a line that does not fit is cut, never overrun")
  func truncation() {
    var health = owl_view_health()
    health.paints = .max
    health.frames = .max
    let short = line(health, capacity: 48)
    #expect(short.utf8.count == 47)
    #expect(short.hasPrefix("browser=0 visible=0"))
    #expect(line(health, capacity: 1).isEmpty)
  }

  @Test("only a host name reaches the line")
  func siteIsAHostName() {
    #expect(site("example.com") == "site=example.com")
    #expect(site("[::1]:8080") == "site=[::1]:8080")
    #expect(site("data:") == "site=data:")
    #expect(site("example.com/secret?token=abc") == "site=example.com")
    #expect(site("user@example.com") == "site=user")
    #expect(site("a b\nc") == "site=a")
    #expect(site(String(repeating: "x", count: 200)) == "site=" + String(repeating: "x", count: 63))
    #expect(owl_age_milliseconds(5, 0) == -1 && owl_age_milliseconds(5, 9) == 0)
  }
}
