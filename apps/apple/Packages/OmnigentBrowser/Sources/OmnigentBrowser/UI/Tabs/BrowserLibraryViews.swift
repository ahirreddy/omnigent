public import SwiftUI

#if os(macOS)
  internal import AppKit
  internal import UniformTypeIdentifiers
#endif

/// One profile's history, grouped by day, with search and removal. `open` loads a page (in the
/// current tab, or a new one when `newTab` is true).
public struct BrowserHistoryView: View {
  private let store: BrowserHistoryStore
  private let open: (URL, _ newTab: Bool) -> Void
  private let clearData: (() -> Void)?
  @State private var query = ""
  @State private var selection: Set<UUID> = []
  @Environment(\.dismiss) private var dismiss

  /// Creates the view.
  public init(
    store: BrowserHistoryStore, open: @escaping (URL, Bool) -> Void,
    clearData: (() -> Void)? = nil
  ) {
    self.store = store
    self.open = open
    self.clearData = clearData
  }

  /// The view body.
  public var body: some View {
    let visits = store.visits(matching: query)
    let days = Dictionary(grouping: visits) { Calendar.current.startOfDay(for: $0.date) }
    VStack(spacing: 0) {
      HStack {
        Text("History").font(.title2.bold())
        Spacer()
        TextField("Search history", text: $query)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
          .accessibilityIdentifier("browser.history.search")
      }
      .padding(14)
      if visits.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No History" : "No Matches", systemImage: "clock.arrow.circlepath")
      } else {
        List(selection: $selection) {
          ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Section(day.formatted(date: .complete, time: .omitted)) {
              ForEach(days[day] ?? []) { visit in
                HStack {
                  Text(visit.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(
                      visit.title.isEmpty
                        ? BrowserHistoryStore.displayAddress(visit.url) : visit.title
                    )
                    .lineLimit(1)
                    Text(BrowserHistoryStore.displayAddress(visit.url))
                      .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                  open(visit.url, false)
                  dismiss()
                }
                .contextMenu {
                  Button("Open") {
                    open(visit.url, false)
                    dismiss()
                  }
                  Button("Open in New Tab") { open(visit.url, true) }
                  Button("Remove from History") { store.remove(visitIDs: [visit.id]) }
                }
                .tag(visit.id)
              }
            }
          }
        }
        .accessibilityIdentifier("browser.history.list")
      }
      Divider()
      HStack {
        Button("Remove Selected") { store.remove(visitIDs: selection) }
          .disabled(selection.isEmpty)
        if let clearData {
          Button("Clear Browsing Data…", action: clearData)
            .accessibilityIdentifier("browser.history.clear")
        }
        if let error = store.lastError {
          Text(error.localizedDescription).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .browserSheetFrame(minWidth: 560, minHeight: 440)
    .accessibilityIdentifier("browser.history")
  }
}

/// The bookmarks bar: one button per bookmark, menus for folders.
struct BrowserBookmarksBar: View {
  let store: BrowserBookmarkStore
  let open: (URL, Bool) -> Void
  let report: (BrowserError) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 2) {
        ForEach(store.bar.children ?? []) { item in
          BrowserBookmarkBarItem(item: item, store: store, open: open, report: report)
        }
      }
      .padding(.horizontal, 8)
    }
    .frame(height: 26)
    .buttonStyle(.borderless)
    .font(.callout)
    .accessibilityIdentifier("browser.bookmarksBar")
  }
}

struct BrowserBookmarkBarItem: View {
  let item: BrowserBookmark
  let store: BrowserBookmarkStore
  let open: (URL, Bool) -> Void
  let report: (BrowserError) -> Void

  var body: some View {
    if item.isFolder {
      Menu {
        BrowserBookmarkMenuItems(items: item.children ?? [], open: open)
      } label: {
        Label(item.title, systemImage: "folder")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    } else if let url = item.url {
      Button {
        open(url, false)
      } label: {
        Text(item.title).lineLimit(1).frame(maxWidth: 160)
      }
      .help(url.absoluteString)
      .contextMenu {
        Button("Open in New Tab") { open(url, true) }
        Button("Delete") {
          do throws(BrowserError) {
            try store.remove(id: item.id)
          } catch {
            report(error)
          }
        }
      }
      .padding(.horizontal, 4)
    }
  }
}

/// Nested menu items for bookmark folders.
struct BrowserBookmarkMenuItems: View {
  let items: [BrowserBookmark]
  let open: (URL, Bool) -> Void

  var body: some View {
    ForEach(items) { item in
      if item.isFolder {
        Menu(item.title) {
          Self(items: item.children ?? [], open: open)
        }
      } else if let url = item.url {
        Button(item.title) { open(url, false) }
      }
    }
  }
}

/// Bookmarks of one profile: the bar and Other Bookmarks, with rename, delete and HTML import.
public struct BrowserBookmarksManagerView: View {
  private let store: BrowserBookmarkStore
  private let open: (URL, Bool) -> Void
  @State private var renaming: BrowserBookmark?
  @State private var newTitle = ""
  @State private var message: String?
  @State private var error: BrowserError?
  @Environment(\.dismiss) private var dismiss

  /// Creates the manager.
  public init(store: BrowserBookmarkStore, open: @escaping (URL, Bool) -> Void) {
    self.store = store
    self.open = open
  }

  /// The view body.
  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Bookmarks").font(.title2.bold())
        Spacer()
        #if os(macOS)
          Button("Import from HTML…", systemImage: "square.and.arrow.down") { importHTML() }
            .accessibilityIdentifier("browser.bookmarks.import")
        #endif
      }
      .padding(14)
      List {
        ForEach([store.bar, store.other]) { root in
          Section(root.title) {
            OutlineGroup(root.children ?? [], children: \.children) { item in
              row(item)
            }
          }
        }
      }
      Divider()
      HStack {
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        if let error = error ?? store.lastError {
          Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .browserSheetFrame(minWidth: 520, minHeight: 420)
    .alert("Rename", isPresented: .constant(renaming != nil)) {
      TextField("Title", text: $newTitle)
      Button("Save") {
        if let item = renaming {
          run { () throws(BrowserError) in try store.update(id: item.id, title: newTitle) }
        }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    }
    .accessibilityIdentifier("browser.bookmarks")
  }

  private func row(_ item: BrowserBookmark) -> some View {
    HStack {
      Image(systemName: item.isFolder ? "folder" : "bookmark")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.title).lineLimit(1)
        if let url = item.url {
          Text(BrowserHistoryStore.displayAddress(url)).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .contextMenu {
      if let url = item.url {
        Button("Open") {
          open(url, false)
          dismiss()
        }
        Button("Open in New Tab") { open(url, true) }
      }
      Button("Rename…") {
        newTitle = item.title
        renaming = item
      }
      Button("Delete") { run { () throws(BrowserError) in try store.remove(id: item.id) } }
    }
  }

  private func run(_ change: () throws(BrowserError) -> Void) {
    do {
      try change()
      error = nil
    } catch let failure {
      error = failure
    }
  }

  #if os(macOS)
    private func importHTML() {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.html]
      panel.message = "Choose a bookmarks file exported from Chrome, Safari or Firefox."
      guard panel.runModal() == .OK, let url = panel.url else { return }
      do {
        let data = try Data(contentsOf: url)
        let count = try store.importHTML(data)
        message = "Imported \(count) bookmarks."
        error = nil
      } catch let failure as BrowserError {
        error = failure
      } catch let failure {
        error = .storageFailed(
          "Could not read \(url.lastPathComponent): \(failure.localizedDescription)")
      }
    }
  #endif
}
