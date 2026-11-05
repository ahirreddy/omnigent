#if os(iOS)
  import Foundation
  import OmnigentWorkspaceUI
  import QuickLook
  import UIKit

  /// Shares or previews a workspace file on iPhone and iPad: reads it through the workspace
  /// source, copies it locally (``WorkspaceFileExport``), then shows the share sheet or Quick
  /// Look over the foreground window. Context menus cannot present SwiftUI sheets, so this
  /// presents from UIKit.
  enum WorkspaceFilePresenter {
    /// What to show once the file is local.
    enum Presentation {
      case share
      case quickLook
    }

    /// The Quick Look controller's data source; the controller holds it weakly.
    private static var previewSource: PreviewSource?

    /// Reads `path` and presents it.
    /// - Parameters:
    ///   - path: The environment-relative file.
    ///   - source: The session's workspace.
    ///   - presentation: Share sheet or Quick Look.
    ///   - report: Shows a failure.
    static func present(
      _ path: String, from source: any WorkspaceDataSource, as presentation: Presentation,
      report: @escaping @MainActor (String) -> Void
    ) async {
      let file: URL
      do {
        file = try WorkspaceFileExport.temporary.write(try await source.fileContents(path))
      } catch let failure as WorkspaceFailure {
        report(failure.message)
        return
      } catch {
        report(String(describing: error))
        return
      }
      guard let presenter = topViewController() else {
        report("No window is showing to share \(WorkspacePaths.name(of: path)) from.")
        return
      }
      let controller: UIViewController
      switch presentation {
      case .share:
        controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
      case .quickLook:
        let preview = QLPreviewController()
        let dataSource = PreviewSource(file: file)
        previewSource = dataSource
        preview.dataSource = dataSource
        controller = preview
      }
      if let popover = controller.popoverPresentationController {
        // iPad: anchored to the window's centre, since the menu that asked is gone.
        let bounds = presenter.view.bounds
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      presenter.present(controller, animated: true)
    }

    /// The front-most view controller of the foreground window.
    private static func topViewController() -> UIViewController? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      let scene =
        scenes.first { $0.activationState == .foregroundActive }
        ?? scenes.first { $0.activationState == .foregroundInactive }
      var top = scene?.keyWindow?.rootViewController
      while let presented = top?.presentedViewController, !presented.isBeingDismissed {
        top = presented
      }
      return top
    }

    /// One file for Quick Look.
    private final class PreviewSource: NSObject, QLPreviewControllerDataSource {
      let file: URL

      init(file: URL) {
        self.file = file
      }

      nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

      nonisolated func previewController(
        _ controller: QLPreviewController, previewItemAt index: Int
      ) -> any QLPreviewItem {
        // QLPreviewItem is an Objective-C protocol that only NSURL adopts.
        file as NSURL  // swiftlint:disable:this legacy_objc_type
      }
    }
  }
#endif
