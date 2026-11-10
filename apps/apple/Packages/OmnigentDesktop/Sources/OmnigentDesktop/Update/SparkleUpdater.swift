// Sparkle-backed updates for the Developer ID edition (`OmnigentMac`) only. The Mac App Store
// edition must never link Sparkle: the store updates it, and App Review rejects self-updaters.
//
// The `canImport` guard keeps this file inert in any target that does not depend on Sparkle, so
// the shared `OmnigentDesktop` target and the App Store edition build without it. See
// apps/apple/RELEASE.md ("Auto-update") for the package wiring and the Info.plist keys
// (`SUFeedURL`, `SUPublicEDKey`) this reads.
#if canImport(Sparkle)
  public import Foundation
  import Sparkle

  /// A problem the updater reported. Sparkle's standard UI has already shown it to the user when
  /// it came from a user-visible check; the app should still log it.
  public enum SparkleUpdaterIssue: Error {
    /// The updater could not start, usually a missing or invalid `SUFeedURL` or `SUPublicEDKey`.
    case startFailed(any Error)
    /// An update cycle stopped with an error (download, signature, extraction or install).
    case updateAborted(any Error)
  }

  /// Receives `SparkleUpdaterIssue`s. The app binds this to its logger.
  public typealias SparkleUpdaterIssueReporter = @MainActor (SparkleUpdaterIssue) -> Void

  /// What `SparkleUpdater` uses of Sparkle's `SPUUpdater`, so a test can stand in for it.
  protocol SparkleUpdaterDriver: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    func start() throws
    func checkForUpdates()
  }

  extension SPUUpdater: SparkleUpdaterDriver {}

  /// Owns Sparkle's updater for the app's lifetime and backs Omnigent > Check for Updates....
  ///
  /// ```swift
  /// let updater = SparkleUpdater(reportIssue: log)
  /// try updater.start()   // in applicationDidFinishLaunching
  /// DesktopCommandActions(..., checkForUpdates: updater.checkForUpdates)
  /// ```
  public final class SparkleUpdater {
    // Sparkle holds its delegate weakly, so this strong reference keeps it alive.
    let callbacks: Callbacks
    let updater: any SparkleUpdaterDriver

    /// Creates the updater for the main bundle. It does nothing until `start()`.
    /// - Parameter reportIssue: Receives start failures and aborted update cycles.
    public convenience init(reportIssue: @escaping SparkleUpdaterIssueReporter) {
      self.init(reportIssue: reportIssue) { callbacks in
        SPUUpdater(
          hostBundle: .main, applicationBundle: .main,
          userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil),
          delegate: callbacks)
      }
    }

    /// Creates the updater over the driver `makeUpdater` builds around these callbacks.
    /// - Parameters:
    ///   - reportIssue: Receives start failures and aborted update cycles.
    ///   - makeUpdater: Builds the driver, given the delegate it should report aborts to.
    init(
      reportIssue: @escaping SparkleUpdaterIssueReporter,
      makeUpdater: (Callbacks) -> any SparkleUpdaterDriver
    ) {
      callbacks = Callbacks(reportIssue: reportIssue)
      updater = makeUpdater(callbacks)
    }

    /// Starts scheduled background checks, honoring the user's Sparkle preferences.
    /// - Throws: `SparkleUpdaterIssue.startFailed` when the bundle's Sparkle configuration is
    ///   invalid. It is also passed to the issue reporter.
    public func start() throws(SparkleUpdaterIssue) {
      do {
        try updater.start()
      } catch {
        let issue = SparkleUpdaterIssue.startFailed(error)
        callbacks.reportIssue(issue)
        throw issue
      }
    }

    /// Whether a user-initiated check can run now; use it to enable the menu item.
    public var canCheckForUpdates: Bool {
      updater.canCheckForUpdates
    }

    /// A user-initiated check with Sparkle's standard UI. Bind to
    /// `DesktopCommandActions.checkForUpdates`.
    public func checkForUpdates() {
      updater.checkForUpdates()
    }

    /// Scheduled background checks (Sparkle keeps the choice in the app's defaults).
    public var automaticallyChecksForUpdates: Bool {
      get { updater.automaticallyChecksForUpdates }
      set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Found updates download in the background and install when the app quits.
    public var automaticallyDownloadsUpdates: Bool {
      get { updater.automaticallyDownloadsUpdates }
      set { updater.automaticallyDownloadsUpdates = newValue }
    }

    /// The feed and signing allow silent installs (``automaticallyDownloadsUpdates``).
    public var allowsAutomaticUpdates: Bool {
      updater.allowsAutomaticUpdates
    }

    /// When the last check ran, if one has.
    public var lastUpdateCheckDate: Date? {
      updater.lastUpdateCheckDate
    }

    /// The `SPUUpdaterDelegate`; not public, so `Sparkle` stays an internal import.
    final class Callbacks: NSObject, SPUUpdaterDelegate {
      let reportIssue: SparkleUpdaterIssueReporter

      init(reportIssue: @escaping SparkleUpdaterIssueReporter) {
        self.reportIssue = reportIssue
      }

      /// Forwards every abort except "no update available", which is the normal up-to-date
      /// outcome of a check and not an error.
      func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain,
          nsError.code == Int(SUError.noUpdateError.rawValue)
        {
          return
        }
        reportIssue(.updateAborted(error))
      }
    }
  }
#endif
