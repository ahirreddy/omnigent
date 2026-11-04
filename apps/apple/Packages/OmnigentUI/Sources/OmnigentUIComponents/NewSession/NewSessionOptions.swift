import Foundation
public import SwiftUI

/// One existing git worktree offered on a new session.
nonisolated public struct NewSessionWorktreeOption: Hashable, Sendable, Identifiable {
  /// Absolute path.
  public var path: String
  /// Checked-out branch; `nil` when detached.
  public var branch: String?

  /// The path.
  public var id: String { path }

  /// Creates an option.
  /// - Parameters:
  ///   - path: Path.
  ///   - branch: Branch.
  public init(path: String, branch: String?) {
    self.path = path
    self.branch = branch
  }
}

/// Where a new session works in its folder's repository.
nonisolated public enum NewSessionWorktreeChoice: Hashable, Sendable {
  /// In the folder itself.
  case none
  /// A new worktree on a new branch, from `base` (empty for the repository default).
  case new(branch: String, base: String)
  /// An existing worktree.
  case existing(NewSessionWorktreeOption)
}

/// The new-session page's start options under the composer, as on the web: the folder (with
/// recents, a host folder browser and a typed path), the worktree, and a sandbox's repositories.
nonisolated public struct NewSessionOptions: Hashable, Sendable {
  /// The chosen folder; `nil` shows "Choose folder".
  public var folder: String?
  /// Folders offered as recents.
  public var recentFolders: [String]
  /// The session starts on a new sandbox: repositories replace the folder.
  public var isSandbox: Bool
  /// Repositories to clone into the sandbox, `<url>[#<branch>]`, comma or newline separated.
  public var repositories: String
  /// The folder is a git repository, so worktrees are offered.
  public var offersWorktrees: Bool
  /// Existing worktrees, main excluded.
  public var worktrees: [NewSessionWorktreeOption]
  /// The worktree choice.
  public var worktree: NewSessionWorktreeChoice

  /// Creates options.
  /// - Parameters:
  ///   - folder: Folder.
  ///   - recentFolders: Recents.
  ///   - isSandbox: New sandbox.
  ///   - repositories: Sandbox repositories.
  ///   - offersWorktrees: Git repository.
  ///   - worktrees: Existing worktrees.
  ///   - worktree: Worktree choice.
  public init(
    folder: String? = nil, recentFolders: [String] = [], isSandbox: Bool = false,
    repositories: String = "", offersWorktrees: Bool = false,
    worktrees: [NewSessionWorktreeOption] = [], worktree: NewSessionWorktreeChoice = .none
  ) {
    self.folder = folder
    self.recentFolders = recentFolders
    self.isSandbox = isSandbox
    self.repositories = repositories
    self.offersWorktrees = offersWorktrees
    self.worktrees = worktrees
    self.worktree = worktree
  }

  /// The worktree chip's title.
  public var worktreeTitle: String {
    switch worktree {
    case .none: "No worktree"
    case .new(let branch, _): "New branch: \(branch)"
    case .existing(let option): "Worktree: \(option.branch ?? option.path)"
    }
  }

  /// Repositories as separate `<url>[#<branch>]` entries.
  public static func repositoryList(_ text: String) -> [String] {
    text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " })
      .map(String.init).filter { !$0.isEmpty }
  }
}

/// The start options' actions. `nil` hides the control.
public struct NewSessionOptionActions {
  /// Choose a folder (absolute path).
  public var selectFolder: (@MainActor (String) -> Void)?
  /// Read a host folder for the browser: `nil` reads the home folder.
  public var browse: (@MainActor (String?) async -> Result<FolderListing, FolderBrowseError>)?
  /// Choose where in the repository the session works.
  public var selectWorktree: (@MainActor (NewSessionWorktreeChoice) -> Void)?
  /// Validate a new branch name.
  public var isValidBranch: (@MainActor (String) -> Bool)?
  /// Edit the sandbox repositories.
  public var setRepositories: (@MainActor (String) -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - selectFolder: Choose a folder.
  ///   - browse: Read a host folder.
  ///   - selectWorktree: Choose a worktree.
  ///   - isValidBranch: Branch validation.
  ///   - setRepositories: Sandbox repositories.
  public init(
    selectFolder: (@MainActor (String) -> Void)? = nil,
    browse: (@MainActor (String?) async -> Result<FolderListing, FolderBrowseError>)? = nil,
    selectWorktree: (@MainActor (NewSessionWorktreeChoice) -> Void)? = nil,
    isValidBranch: (@MainActor (String) -> Bool)? = nil,
    setRepositories: (@MainActor (String) -> Void)? = nil
  ) {
    self.selectFolder = selectFolder
    self.browse = browse
    self.selectWorktree = selectWorktree
    self.isValidBranch = isValidBranch
    self.setRepositories = setRepositories
  }
}

/// The folder, worktree and repository chips under the new-session composer.
struct NewSessionOptionsBar: View {
  let options: NewSessionOptions
  let actions: NewSessionOptionActions

  @State private var isBrowsing = false
  @State private var isNamingBranch = false
  @State private var branch = ""
  @State private var base = ""

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      if options.isSandbox {
        repositoriesField
      } else {
        folderMenu
        if options.offersWorktrees, actions.selectWorktree != nil {
          worktreeMenu
        }
      }
      Spacer(minLength: 0)
    }
    .font(.callout)
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .sheet(isPresented: $isBrowsing) {
      if let browse = actions.browse {
        FolderBrowserView(
          initialPath: options.folder, load: browse,
          choose: { path in
            actions.selectFolder?(path)
            isBrowsing = false
          },
          cancel: { isBrowsing = false })
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-session-options")
  }

  private var folderMenu: some View {
    Menu {
      if !options.recentFolders.isEmpty {
        Section("Folders") {
          ForEach(options.recentFolders, id: \.self) { path in
            Button(path) { actions.selectFolder?(path) }
          }
        }
      }
      if actions.browse != nil {
        Button("Browse Folders\u{2026}", systemImage: "folder.badge.gearshape") {
          isBrowsing = true
        }
        .accessibilityIdentifier("new-session-browse-folders")
      }
    } label: {
      Label(
        options.folder.map { URL(filePath: $0).lastPathComponent } ?? "Choose folder",
        systemImage: "folder")
    }
    .fixedSize()
    .help(options.folder ?? "Choose the folder the session works in")
    .accessibilityLabel("Folder, \(options.folder ?? "none")")
    .accessibilityIdentifier("new-session-folder")
  }

  private var worktreeMenu: some View {
    Menu {
      Button("No worktree") { actions.selectWorktree?(.none) }
      Button("New Worktree\u{2026}", systemImage: "plus") {
        if case .new(let current, let currentBase) = options.worktree {
          branch = current
          base = currentBase
        }
        isNamingBranch = true
      }
      if !options.worktrees.isEmpty {
        Section("Existing worktrees") {
          ForEach(options.worktrees) { option in
            Button(option.branch ?? URL(filePath: option.path).lastPathComponent) {
              actions.selectWorktree?(.existing(option))
            }
          }
        }
      }
    } label: {
      Label(options.worktreeTitle, systemImage: "arrow.triangle.branch")
    }
    .fixedSize()
    .help("Work in the folder, a new worktree branch, or an existing worktree")
    .accessibilityIdentifier("new-session-worktree")
    .popover(isPresented: $isNamingBranch) { branchForm }
  }

  private var isBranchValid: Bool {
    let name = branch.trimmingCharacters(in: .whitespaces)
    return actions.isValidBranch?(name) ?? !name.isEmpty
  }

  private var branchForm: some View {
    Form {
      TextField("Branch", text: $branch, prompt: Text("feature/my-change"))
        .accessibilityIdentifier("new-session-branch")
      TextField("From", text: $base, prompt: Text("Default branch"))
        .accessibilityIdentifier("new-session-base-branch")
      HStack {
        Spacer()
        Button("Cancel") { isNamingBranch = false }
        Button("Use Branch") {
          actions.selectWorktree?(
            .new(
              branch: branch.trimmingCharacters(in: .whitespaces),
              base: base.trimmingCharacters(in: .whitespaces)))
          isNamingBranch = false
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!isBranchValid)
      }
    }
    .padding()
    .frame(width: 320)
  }

  private var repositoriesField: some View {
    Label {
      TextField(
        "Repositories",
        text: Binding(
          get: { options.repositories }, set: { actions.setRepositories?($0) }),
        prompt: Text("Repositories to clone (https://github.com/org/repo#branch)")
      )
      .textFieldStyle(.plain)
      .frame(minWidth: 280)
    } icon: {
      Image(systemName: "shippingbox")
    }
    .accessibilityIdentifier("new-session-repositories")
  }
}
