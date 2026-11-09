import Foundation
import Testing

@testable import OmnigentDesktop

@MainActor
struct ModalLoopTests {
  private final class Flag {
    var isSet = false
  }

  /// Spins a nested run loop, as a modal alert does, until a main-actor task has run.
  private func nestedLoopLetsATaskRun() -> Bool {
    let flag = Flag()
    Task { @MainActor in flag.isSet = true }
    let deadline = Date().addingTimeInterval(2)
    while !flag.isSet, Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return flag.isSet
  }

  @Test func otherTasksKeepRunningUnderAModalLoop() async {
    let loop = nestedLoopLetsATaskRun
    let ran = await ModalLoop.run { loop() }
    #expect(ran)
  }

  @Test func aLoopInsideTheTasksOwnJobHoldsThemBack() {
    #expect(!nestedLoopLetsATaskRun())
  }
}
