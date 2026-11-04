import Foundation
public import SwiftUI

/// A folder on a host and the folders in it.
nonisolated public struct FolderListing: Hashable, Sendable {
  /// One folder.
  public struct Entry: Hashable, Sendable, Identifiable {
    /// Absolute path.
    public var path: String
    /// Display name.
    public var name: String
    /// The path.
    public var id: String { path }

    /// Creates an entry.
    /// - Parameters:
    ///   - path: Path.
    ///   - name: Name.
    public init(path: String, name: String) {
      self.path = path
      self.name = name
    }
  }

  /// The listed folder, when known.
  public var path: String?
  /// Its parent; `nil` at `/`.
  public var parent: String?
  /// Folders in it.
  public var folders: [Entry]

  /// Creates a listing.
  /// - Parameters:
  ///   - path: Folder.
  ///   - parent: Parent.
  ///   - folders: Folders in it.
  public init(path: String?, parent: String?, folders: [Entry]) {
    self.path = path
    self.parent = parent
    self.folders = folders
  }
}

/// Why a host folder could not be read; shown as is.
nonisolated public struct FolderBrowseError: Error, Hashable, Sendable {
  /// The message.
  public var message: String

  /// Creates an error.
  /// - Parameter message: The message.
  public init(message: String) { self.message = message }
}

/// The web's workspace picker: browse the host's folders from its home or a typed path, then
/// choose one. The host's filesystem, not this Mac's.
struct FolderBrowserView: View {
  let initialPath: String?
  let load: @MainActor (String?) async -> Result<FolderListing, FolderBrowseError>
  let choose: @MainActor (String) -> Void
  let cancel: @MainActor () -> Void

  @State private var listing: FolderListing?
  @State private var error: String?
  @State private var isLoading = false
  @State private var typedPath = ""
  @State private var selection: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text("Choose a Folder").font(Theme.Typography.title)
      HStack {
        Button("Up", systemImage: "chevron.up") {
          if let parent = listing?.parent { open(parent) }
        }
        .labelStyle(.iconOnly)
        .disabled(listing?.parent == nil || isLoading)
        .help("Enclosing folder")
        .accessibilityIdentifier("folder-browser-up")
        TextField("Path", text: $typedPath, prompt: Text("/path/on/the/host"))
          .textFieldStyle(.roundedBorder)
          .onSubmit { open(typedPath) }
          .accessibilityIdentifier("folder-browser-path")
        Button("Go") { open(typedPath) }
          .disabled(!typedPath.hasPrefix("/") || isLoading)
      }
      List(selection: $selection) {
        ForEach(listing?.folders ?? []) { entry in
          Label(entry.name, systemImage: "folder")
            .tag(entry.path)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open(entry.path) }
            .accessibilityIdentifier("folder-browser-row-\(entry.name)")
        }
      }
      .overlay {
        if isLoading {
          ProgressView()
        } else if let error {
          ContentUnavailableView(
            "Cannot Read Folder", systemImage: "exclamationmark.triangle",
            description: Text(error))
        } else if listing?.folders.isEmpty == true {
          ContentUnavailableView("No Folders", systemImage: "folder")
        }
      }
      .frame(minHeight: 280)
      HStack {
        Text(chosenPath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        Button("Choose") { if let chosenPath { choose(chosenPath) } }
          .keyboardShortcut(.defaultAction)
          .disabled(chosenPath == nil)
          .accessibilityIdentifier("folder-browser-choose")
      }
    }
    .padding(Theme.Spacing.extraLarge)
    .frame(minWidth: 520, minHeight: 440)
    .task { open(initialPath) }
  }

  /// The selected folder, else the one being shown.
  private var chosenPath: String? { selection ?? listing?.path }

  private func open(_ path: String?) {
    let trimmed = path?.trimmingCharacters(in: .whitespaces)
    let target = (trimmed?.isEmpty ?? true) ? nil : trimmed
    isLoading = true
    error = nil
    Task {
      let result = await load(target)
      isLoading = false
      switch result {
      case .success(let value):
        listing = value
        selection = nil
        typedPath = value.path ?? ""
      case .failure(let failure):
        error = failure.message
      }
    }
  }
}
