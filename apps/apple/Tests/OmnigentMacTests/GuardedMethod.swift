import Foundation
import ObjectiveC

/// A guard exchanges AppKit's method with its own, so its own selector now runs AppKit's. Replacing
/// that for one call lets a test run the guard without the real drag or window ordering behind it.
enum GuardedMethod {
  /// The guard's selector isn't on the class: the guard wasn't installed, or was renamed.
  struct Missing: Error {
    let name: String
  }

  /// Runs `body` with each named method replaced by its block, which takes the receiver first.
  /// - Parameters:
  ///   - replacements: Blocks by the selector the guard reaches AppKit's method through.
  ///   - owner: The class they are on.
  ///   - body: What to run meanwhile.
  /// - Returns: What `body` returned.
  /// - Throws: What `body` threw, or `Missing` when the class lacks a method.
  static func replacing<Result>(
    _ replacements: [String: Any], of owner: AnyClass, body: () throws -> Result
  ) throws -> Result {
    var originals: [(Method, IMP)] = unsafe []
    defer {
      for index in unsafe originals.indices {
        unsafe method_setImplementation(originals[index].0, originals[index].1)
      }
    }
    for (name, block) in replacements {
      guard let method = unsafe class_getInstanceMethod(owner, NSSelectorFromString(name)) else {
        throw Missing(name: name)
      }
      let original = unsafe method_setImplementation(method, imp_implementationWithBlock(block))
      unsafe originals.append((method, original))
    }
    return try body()
  }
}
