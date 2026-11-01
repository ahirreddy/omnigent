import Foundation

struct FixtureError: Error, CustomStringConvertible {
  let description: String
}

/// A URL fixture; throws instead of force-unwrapping.
func url(_ string: String) throws -> URL {
  guard let url = URL(string: string) else { throw FixtureError(description: "bad URL \(string)") }
  return url
}
