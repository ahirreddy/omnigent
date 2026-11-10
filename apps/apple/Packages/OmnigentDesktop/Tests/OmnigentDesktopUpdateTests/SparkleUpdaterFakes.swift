#if os(macOS)
  import Foundation

  @testable import OmnigentDesktopUpdate

  /// Stands in for Sparkle's `SPUUpdater`: answers from its fields and records what it was asked.
  @MainActor
  final class FakeSparkleDriver: SparkleUpdaterDriver {
    /// A setting the wrapper wrote through.
    enum Write: Equatable {
      case automaticChecks(Bool)
      case automaticDownloads(Bool)
    }

    /// Sparkle's stored choice for scheduled checks; set it to change it outside the wrapper.
    var storedChecks: Bool
    /// Sparkle's stored choice for silent installs; set it to change it outside the wrapper.
    var storedDownloads: Bool
    var canCheckForUpdates = true
    var allowsAutomaticUpdates = true
    var lastUpdateCheckDate: Date?
    /// What `start()` throws, if anything.
    var startError: (any Error)?
    private(set) var writes: [Write] = []
    private(set) var startCount = 0
    private(set) var checkCount = 0

    init(checks: Bool = true, downloads: Bool = false) {
      storedChecks = checks
      storedDownloads = downloads
    }

    var automaticallyChecksForUpdates: Bool {
      get { storedChecks }
      set {
        storedChecks = newValue
        writes.append(.automaticChecks(newValue))
      }
    }

    var automaticallyDownloadsUpdates: Bool {
      get { storedDownloads }
      set {
        storedDownloads = newValue
        writes.append(.automaticDownloads(newValue))
      }
    }

    func start() throws {
      startCount += 1
      if let startError { throw startError }
    }

    func checkForUpdates() {
      checkCount += 1
    }
  }

  /// The issues an updater reported.
  @MainActor
  final class IssueLog {
    var issues: [SparkleUpdaterIssue] = []

    /// Each issue as its case and its error's domain and code, so a test can compare them.
    var summaries: [String] { issues.map(Self.summary) }

    /// An updater over `driver` that reports here.
    func updater(_ driver: FakeSparkleDriver) -> SparkleUpdater {
      SparkleUpdater(reportIssue: { self.issues.append($0) }, makeUpdater: { _ in driver })
    }

    /// An issue as a test compares it.
    static func summary(_ issue: SparkleUpdaterIssue) -> String {
      switch issue {
      case .startFailed(let error): "start failed: \(describe(error))"
      case .updateAborted(let error): "update aborted: \(describe(error))"
      }
    }

    /// An error's domain and code.
    static func describe(_ error: any Error) -> String {
      let nsError = error as NSError
      return "\(nsError.domain) \(nsError.code)"
    }
  }
#endif
