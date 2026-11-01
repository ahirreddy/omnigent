import OmnigentTerminalUI
import SwiftUI

/// Launch arguments:
/// - `-page <echo|harnessTUI|recordedTUI|states|list|settings>` opens that gallery page.
/// - `-type <text>` types `text` and Return into the echo shell once it is attached, through the
///   same encoder a keyboard uses, to show input round-tripping.
/// - `-attach <ws-url>` attaches to a live terminal instead (a local Omnigent server), for
///   example `ws://127.0.0.1:6798/v1/sessions/<id>/resources/terminals/<tid>/attach`.
@main
struct TerminalGalleryApp: App {
  private let arguments = GalleryArguments(ProcessInfo.processInfo.arguments)

  var body: some Scene {
    WindowGroup {
      Group {
        if let url = arguments.attachURL {
          LiveTerminalScreen(url: url, typed: arguments.typed)
        } else if let typed = arguments.typed {
          TypedEchoScreen(text: typed)
        } else {
          TerminalGalleryView(initialPage: arguments.page)
        }
      }
      #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
      #endif
    }
  }
}

struct GalleryArguments {
  var page: TerminalGalleryView.Page = .echo
  var typed: String?
  var attachURL: URL?

  init(_ arguments: [String]) {
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "-page":
        page = iterator.next().flatMap(TerminalGalleryView.Page.init(rawValue:)) ?? .echo
      case "-type": typed = iterator.next()
      case "-attach": attachURL = iterator.next().flatMap(URL.init(string:))
      default: continue
      }
    }
  }
}

/// An echo shell that types `text` once attached.
struct TypedEchoScreen: View {
  let text: String
  @State private var controller: Result<TerminalSurfaceController, GhosttyError>?

  var body: some View {
    Group {
      switch controller {
      case .success(let controller): SessionTerminalView(controller: controller)
      case .failure(let error): Text(error.description)
      case nil: ProgressView()
      }
    }
    .task {
      do {
        let surface = try TerminalSurfaceController(connection: EchoTerminalConnection())
        controller = .success(surface)
        try await Task.sleep(for: .milliseconds(800))
        surface.focus()
        surface.type(text)
        surface.press(.enter)
        try await Task.sleep(for: .milliseconds(300))
        surface.type("colors")
        surface.press(.enter)
      } catch let error as GhosttyError {
        controller = .failure(error)
      } catch {
        // Task.sleep throws only CancellationError: the view went away, so there is nothing
        // left to type into.
        return
      }
    }
  }
}

/// A live terminal on a local server.
struct LiveTerminalScreen: View {
  let url: URL
  let typed: String?
  @State private var controller: Result<TerminalSurfaceController, GhosttyError>?

  var body: some View {
    Group {
      switch controller {
      case .success(let controller): SessionTerminalView(controller: controller)
      case .failure(let error): Text(error.description)
      case nil: ProgressView()
      }
    }
    .task {
      do {
        let surface = try TerminalSurfaceController(connection: LiveAttachConnection(url: url))
        controller = .success(surface)
        try await Task.sleep(for: .seconds(1))
        surface.focus()
        guard let typed else { return }
        try await Task.sleep(for: .seconds(1))
        surface.type(typed)
        surface.press(.enter)
      } catch let error as GhosttyError {
        controller = .failure(error)
      } catch {
        // Task.sleep throws only CancellationError: the view went away, so there is nothing
        // left to type into.
        return
      }
    }
  }
}
