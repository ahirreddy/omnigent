/// How a page's renderer process ended, as the host reports it, put into words.
nonisolated struct RendererTermination {
  /// Chromium's termination status (`cef_termination_status_t`).
  let status: Int64
  /// The process's wait status: the signal that ended it, or its exit code in the next byte.
  let code: Int64
  /// The host's own text, which is usually only the code again.
  let hostMessage: String

  /// One or two sentences naming how the process ended.
  var summary: String {
    let sentence =
      switch status {
      case 0: "It exited unexpectedly (\(ending))."
      case 1: "It was killed (\(ending))."
      case 2: "It crashed (\(ending))."
      case 3: "It ran out of memory."
      case 4: "It could not be launched (error \(code))."
      case 5: "It failed a code integrity check."
      default: "It ended with unrecognised status \(status) (code \(code))."
      }
    let addsNothing = hostMessage.isEmpty || hostMessage == "\(code)"
    return addsNothing ? sentence : "\(sentence) \(hostMessage)"
  }

  /// The wait status in words: the signal that ended the process, or its exit code.
  private var ending: String {
    let signal = code & 0x7f
    guard signal != 0 else { return "exit code \((code >> 8) & 0xff)" }
    guard let meaning = Self.signalMeanings[signal] else { return "signal \(signal)" }
    return "signal \(signal): \(meaning)"
  }

  /// What the signals a renderer usually dies of mean for the person reading the error.
  private static let signalMeanings: [Int64: String] = [
    4: "an illegal instruction",
    5: "out of memory or a failed internal check",
    6: "an abort",
    9: "a forced kill",
    10: "an invalid memory access",
    11: "an invalid memory access",
    15: "a request to quit",
  ]
}
