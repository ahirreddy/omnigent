#if os(macOS)
  import AppKit
  import Darwin
  import Foundation
  import Testing

  @testable import OmnigentViewTesting

  @MainActor
  @Suite("Menu tracking lock", .serialized)
  struct MenuTrackingLockTests {
    @Test("the lock runs its body once and is free again after it, also when the body throws")
    func lockRunsAndReleases() throws {
      var runs = 0
      let value = try MenuTrackingLock.holding {
        runs += 1
        return "ran"
      }
      #expect(value == "ran" && runs == 1)
      #expect(throws: OffscreenWindowError.eventUnavailable) {
        try MenuTrackingLock.holding { throw OffscreenWindowError.eventUnavailable }
      }
      let descriptor = unsafe open(MenuTrackingLock.path, O_RDWR)
      defer { close(descriptor) }
      #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
      flock(descriptor, LOCK_UN)
    }

    @Test("held by another process, the lock waits for it")
    func lockWaitsForAnotherProcess() throws {
      let holder = Process()
      holder.executableURL = URL(filePath: "/usr/bin/perl")
      holder.arguments = [
        "-e",
        "use Fcntl ':flock'; $| = 1; open(my $f, '>>', '\(MenuTrackingLock.path)') or die;"
          + " flock($f, LOCK_EX) or die; print \"held\\n\"; select(undef, undef, undef, 0.5);",
      ]
      let output = Pipe()
      holder.standardOutput = output
      try holder.run()
      // The holder says when it has the lock.
      _ = output.fileHandleForReading.availableData
      let started = Date()
      try MenuTrackingLock.holding {}
      #expect(Date().timeIntervalSince(started) > 0.3)
      holder.waitUntilExit()
      #expect(holder.terminationStatus == 0)
    }

    @Test("a lock file that can't be opened is an error, not a pass")
    func unopenableLock() {
      #expect(throws: MenuTrackingLockError.unavailable(ENOENT)) {
        try MenuTrackingLock.holding(at: "/nonexistent-folder/lock") {}
      }
    }
  }
#endif
