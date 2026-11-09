import Testing

@testable import OmnigentUIComponents

@Suite("Dot folders stay out of the way")
struct DotFolderTests {
  private func listing(at path: String?) -> FolderListing {
    FolderListing(
      path: path, parent: nil,
      folders: [
        .init(path: "/home/me/.config", name: ".config"), .init(path: "/home/me/src", name: "src"),
      ])
  }

  @Test("a listing hides them unless it is inside one")
  func listings() {
    #expect(listing(at: "/home/me").visibleFolders.map(\.name) == ["src"])
    #expect(listing(at: nil).visibleFolders.map(\.name) == ["src"])
    #expect(listing(at: "/home/me/.config").visibleFolders.map(\.name) == [".config", "src"])
  }

  @Test("recents hide them unless the session's folder is inside one")
  func recents() {
    let recents = ["/home/me/src", "/home/me/.claude/worktrees/x"]
    #expect(NewSessionOptions(recentFolders: recents).offeredFolders == ["/home/me/src"])
    #expect(
      NewSessionOptions(folder: "/home/me/src", recentFolders: recents).offeredFolders
        == ["/home/me/src"])
    #expect(
      NewSessionOptions(folder: "/home/me/.claude/worktrees/x", recentFolders: recents)
        .offeredFolders == recents)
  }

  @Test("only whole path components count as dot folders")
  func components() {
    #expect(FolderListing.isInDotFolder("/a/.b/c"))
    #expect(!FolderListing.isInDotFolder("/a/b.c/d"))
    #expect(!FolderListing.isInDotFolder("/a/../b"))
    #expect(!FolderListing.isInDotFolder("/"))
  }
}
