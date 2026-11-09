#if os(macOS)
  import AppKit
  import Foundation
  import OWLProtocol
  import OmnigentBrowser
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  /// Printing and context menus need a window; this one is never ordered in.
  @MainActor
  @Suite("A Chromium tab in a window", .serialized)
  struct ChromiumWindowedTabTests {
    private func window(for fixture: ChromiumTabFixture) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.contentView?.addSubview(fixture.tab.platformView)
      return window
    }

    /// Runs Print and answers the PDF request with `reply`.
    private func printing(
      _ fixture: ChromiumTabFixture, reply: WireEncoder
    ) async throws -> BrowserError? {
      try fixture.connect()
      defer { fixture.session.tearDownConnection() }
      let tab = fixture.tab
      let printing = Task { () -> BrowserError? in
        do throws(BrowserError) {
          try await tab.printPage()
          return nil
        } catch {
          return error
        }
      }
      try await fixture.answer(reply)
      return await printing.value
    }

    private func success(_ json: String) -> WireEncoder {
      WireEncoder().bool(.success, true).string(.JSON, json)
    }

    @Test("Print reports a host that refuses or answers with something that isn't a PDF")
    func printFailures() async throws {
      let cases: [(reply: WireEncoder, message: String)] = [
        (WireEncoder().string(.JSON, #"{"message":"nope"}"#), "nope"),
        (success("not json"), "malformed"),
        (success(#"{"data":"%%%"}"#), "not base64"),
        (success(#"{"data":"\#(Data("not a pdf".utf8).base64EncodedString())"}"#), "could not be"),
      ]
      for (reply, message) in cases {
        let fixture = try ChromiumTabFixture()
        let window = window(for: fixture)
        defer { window.close() }
        let error = try await printing(fixture, reply: reply)
        let description = error?.localizedDescription ?? ""
        #expect(description.contains(message), "\(message): \(description)")
      }
    }

    @Test("a right-click in a window shows the menu and answers the page when it closes")
    func contextMenuInAWindow() async throws {
      SystemSideEffects.reset()
      let fixture = try ChromiumTabFixture()
      let window = window(for: fixture)
      defer { window.close() }
      try fixture.receive(
        .contextMenu,
        WireEncoder().u64(.promptID, 6).string(.menuItems, "[]").string(
          .menuParams,
          #"{"x":1,"y":1,"linkURL":"https://link.test/","sourceURL":"","pageURL":"","frameURL":"","selectionText":"","isEditable":false,"mediaType":0,"editFlags":0}"#
        ))
      #expect(await fixture.eventually { SystemSideEffects.record.poppedUpMenuCount == 1 })
      #expect(await fixture.eventually { fixture.last(.contextMenuReply) != nil })
    }

    @Test("a link's menu items open it in a new tab or copy it; no link, no items")
    func linkItems() throws {
      let fixture = try ChromiumTabFixture()
      let link = try #require(URL(string: "https://link.test/"))
      #expect(
        fixture.tab.linkItems(
          BrowserContextMenuContext(linkURL: nil, selectionText: "", isEditable: false)
        ).isEmpty)
      let items = fixture.tab.linkItems(
        BrowserContextMenuContext(linkURL: link, selectionText: "", isEditable: false))
      #expect(items.map(\.title) == ["Open Link in New Tab", "Copy Link"])
      items[0].action()
      #expect(fixture.recorder.popups.first?.targetURL == link)
      items[1].action()
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == link.absoluteString)
    }

    @Test("cancelling a download when the host has gone says it couldn't")
    func cancelAfterHostGone() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(.downloadRequest, WireEncoder().u64(.promptID, 1).u64(.downloadID, 1))
      guard case .download(let prompt)? = fixture.recorder.requested.last else {
        Issue.record("expected a download")
        return
      }
      prompt.save(to: URL(filePath: "/tmp/never-written"))
      let download = try #require(fixture.recorder.downloads.first)
      fixture.session.outgoingTap = nil
      #expect(throws: BrowserError.self) { try download.cancel() }
    }

    @Test("a persistent profile whose folder can't go yet is retried until it's given up on")
    func persistentDeleteRetries() async throws {
      let fixture = try ChromiumTabFixture()
      let profile = BrowserProfile(identifier: "stuck", persistence: .persistent)
      let folder = fixture.root.appending(path: "Profile-\(Profile.storageKey(for: "stuck"))")
      let inner = folder.appending(path: "Default")
      let manager = FileManager.default
      try manager.createDirectory(at: inner, withIntermediateDirectories: true)
      try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
      defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
      let engine = fixture.engine
      let deletion = Task { try await engine.deleteProfileData(profile) }
      try await Task.sleep(for: .milliseconds(50))
      #expect(manager.fileExists(atPath: fixture.session.pendingDeletionsURL.path))
      deletion.cancel()
      await #expect(throws: BrowserError.self) { try await deletion.value }
      #expect(manager.fileExists(atPath: folder.path))
    }

    @Test("a damaged list of profiles to delete is reported rather than guessed at")
    func damagedDeletionList() async throws {
      let fixture = try ChromiumTabFixture()
      let manager = FileManager.default
      try manager.createDirectory(at: fixture.root, withIntermediateDirectories: true)
      try Data("not json".utf8).write(to: fixture.session.pendingDeletionsURL)
      await #expect(throws: BrowserError.self) {
        try await fixture.engine.deleteProfileData(
          BrowserProfile(identifier: "any", persistence: .persistent))
      }
    }

    @Test("the tab's history comes from what the host reports when it reports one")
    func reportedHistory() throws {
      let fixture = try ChromiumTabFixture()
      let first = try #require(URL(string: "https://a.test/"))
      let second = try #require(URL(string: "https://b.test/"))
      fixture.webView.navigationHistory = WebNavigationHistory(
        entries: [
          WebNavigationEntry(url: first, title: "A"), WebNavigationEntry(url: second, title: "B"),
        ], currentIndex: 1)
      let history = fixture.tab.navigationHistory
      #expect(history.entries.map(\.url) == [first, second])
      #expect(history.entries.map(\.title) == ["A", "B"])
      #expect(history.currentIndex == 1)
    }
  }
#endif
