import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the screens sweep G added.
@MainActor
extension SweepLookFixtures {
  /// The schedule picker on RRULE text: a weekday business-hours rule with no phrase of its own,
  /// and a daily rule with its summary.
  static var rruleEditor: some View {
    let conversion = ScheduleRuleConversion(
      text: { _ in "" }, visual: { _ in nil },
      summary: { $0.hasPrefix("FREQ=DAILY") ? "Every day at 8:30 AM" : nil })
    let hours = ScheduleChoice(
      preset: .custom, frequency: .rule,
      rule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;BYHOUR=9,10,11,12,13,14,15,16,17;BYMINUTE=0")
    let daily = ScheduleChoice(
      preset: .custom, frequency: .rule, rule: "FREQ=DAILY;BYHOUR=8;BYMINUTE=30")
    return Form {
      Section("Schedule") {
        ScheduleFields(choice: .constant(hours), showsEnding: false, rules: conversion)
      }
      Section {
        ScheduleFields(choice: .constant(daily), showsEnding: false, rules: conversion)
      }
    }
    .formStyle(.grouped)
  }

  /// The floating New Agent panel's composer: the window is its card, its footer sits under a
  /// line, and Command-Return shows beside Send.
  static var floatingPanel: some View {
    var state = PreviewData.startComposer
    state.submitWithCommandReturn = true
    return ComposerView(
      draft: .constant("Summarize this week's open issues and propose a plan"), state: state,
      actions: ComposerActions(send: {})
    )
    .environment(\.composerFillsWindow, true)
    .padding(.horizontal, 12)
    .padding(.top, 24)
  }
}
