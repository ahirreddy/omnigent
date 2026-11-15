#if os(macOS)
  import Darwin

  /// Lets one test process at a time track a click, and so a menu. The window server tracks one
  /// menu for the whole machine: a menu opening in another process closes this one, so test
  /// processes running side by side would close each other's menus.
  enum MenuTrackingLock {
    /// The file every test process of this user locks; the same path in every process.
    static let path = "/tmp/omnigent-offscreen-menu-tracking.lock"

    /// Runs `body` holding the lock, waiting for another process to release it first.
    /// - Parameters:
    ///   - file: The lock file.
    ///   - body: What runs while the lock is held.
    /// - Throws: `MenuTrackingLockError` when the lock file can't be opened or locked, or
    ///   what `body` throws.
    static func holding<Result>(at file: String = path, _ body: () throws -> Result) throws
      -> Result
    {
      let descriptor = unsafe open(file, O_CREAT | O_RDWR | O_CLOEXEC, 0o666)
      guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else {
        let failure = errno
        if descriptor >= 0 { close(descriptor) }
        throw MenuTrackingLockError.unavailable(failure)
      }
      // Closing the file releases the lock.
      defer { close(descriptor) }
      return try body()
    }
  }

  /// The lock file could not be used.
  enum MenuTrackingLockError: Error, Equatable {
    /// The system call failed with this error number.
    case unavailable(Int32)
  }
#endif
