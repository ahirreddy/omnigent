import Foundation
import Testing

@testable import OmnigentWorkspaceUI

@Suite("Code typography")
struct CodeTypographyTests {
  @Test("reads the web's keys, rejects out-of-range sizes and writes only changes")
  func preferences() throws {
    let defaults = try #require(UserDefaults(suiteName: "code-typography-\(UUID())"))
    defaults.set(99.0, forKey: CodeTypography.sizeKey)
    defaults.set(500, forKey: CodeTypography.weightKey)
    let typography = CodeTypography(defaults: defaults)
    #expect(typography.size == CodeTypography.defaultSize, "99 pt is out of range")
    #expect(typography.isHeavier && typography.family.isEmpty)
    typography.size = 13
    #expect(
      defaults.double(forKey: CodeTypography.sizeKey) == 99, "an unchanged size is not written")
    typography.size = 16
    #expect(typography.scale == 16.0 / 13)
    #expect(defaults.double(forKey: CodeTypography.sizeKey) == 16)
    typography.family = "Menlo"
    typography.family = ""
    #expect(defaults.object(forKey: CodeTypography.familyKey) == nil)
  }

  @Test("reloading follows the store without writing back, so a reset key stays unset")
  func reload() throws {
    let defaults = try #require(UserDefaults(suiteName: "code-typography-\(UUID())"))
    let typography = CodeTypography(defaults: defaults)
    typography.size = 18
    typography.family = "Menlo"
    typography.isHeavier = true
    for key in [CodeTypography.sizeKey, CodeTypography.familyKey, CodeTypography.weightKey] {
      defaults.removeObject(forKey: key)
    }
    typography.reload()
    #expect(typography.size == CodeTypography.defaultSize)
    #expect(typography.family.isEmpty)
    #expect(!typography.isHeavier)
    for key in [CodeTypography.sizeKey, CodeTypography.familyKey, CodeTypography.weightKey] {
      #expect(defaults.object(forKey: key) == nil, "\(key) came back")
    }
    defaults.set(20.0, forKey: CodeTypography.sizeKey)
    typography.reload()
    #expect(typography.size == 20)
    typography.size = 11
    #expect(defaults.double(forKey: CodeTypography.sizeKey) == 11, "writes resume afterwards")
  }
}
