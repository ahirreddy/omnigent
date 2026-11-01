// Sparkle-backed updates for the Developer ID edition (`OmnigentMac`) only. The Mac App Store
// edition must never link Sparkle: the store updates it, and App Review rejects self-updaters.
//
// The `canImport` guard keeps this file inert in any target that does not depend on Sparkle, so
// the shared `OmnigentDesktop` target and the App Store edition build without it. See
// apps/apple/RELEASE.md ("Auto-update") for the package wiring and the Info.plist keys
// (`SUFeedURL`, `SUPublicEDKey`) this reads.
#if canImport(Sparkle)
  import Foundation
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

  /// Owns Sparkle's updater for the app's lifetime and backs Omnigent > Check for Updates....
  ///
  /// ```swift
  /// let updater = SparkleUpdater(reportIssue: log)
  /// try updater.start()   // in applicationDidFinishLaunching
  /// DesktopCommandActions(..., checkForUpdates: updater.checkForUpdates)
  /// ```
  public final class SparkleUpdater {
    // Sparkle holds its delegate weakly, so this strong reference keeps it alive.
    private let callbacks: Callbacks
    private let updater: SPUUpdater

    /// Creates the updater for the main bundle. It does nothing until `start()`.
    /// - Parameter reportIssue: Receives start failures and aborted update cycles.
    public init(reportIssue: @escaping SparkleUpdaterIssueReporter) {
      callbacks = Callbacks(reportIssue: reportIssue)
      updater = SPUUpdater(
        hostBundle: .main, applicationBundle: .main,
        userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil),
        delegate: callbacks)
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

    /// The `SPUUpdaterDelegate`; private so `Sparkle` stays an internal import.
    private final class Callbacks: NSObject, SPUUpdaterDelegate {
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
