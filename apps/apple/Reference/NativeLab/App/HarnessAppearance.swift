import NativeLabCore
import SwiftUI

// Glyphs and brand colors mirror @lobehub/icons 5.10.0 (MIT); see HarnessBranding-NOTICE.md.
// Pi and Hermes reuse the existing web/src/components/icons vector geometry.
struct HarnessAppearance {
  let identifier: String
  let label: String

  init(harness: String?) {
    let canonical = SessionConfiguration.canonicalHarness(
      harness?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    switch canonical {
    case "codex", "codex-native", "codex-native-ui":
      identifier = "codex"
      label = "Codex"
    case "claude", "claude-code", "claude-native", "claude-code-native-ui", "claude-sdk":
      identifier = "claude"
      label = canonical == "claude-sdk" ? "Claude SDK" : "Claude Code"
    case "cursor", "cursor-native":
      identifier = "cursor"
      label = "Cursor"
    case "kiro", "kiro-native":
      identifier = "kiro"
      label = "Kiro"
    case "opencode", "opencode-native":
      identifier = "opencode"
      label = "OpenCode"
    case "kimi", "kimi-native", "native-kimi":
      identifier = "kimi"
      label = "Kimi"
    case "antigravity", "antigravity-native":
      identifier = "antigravity"
      label = "Antigravity"
    case "goose", "goose-native", "native-goose":
      identifier = "goose"
      label = "Goose"
    case "pi", "pi-native":
      identifier = "pi"
      label = "Pi"
    case "hermes", "hermes-native":
      identifier = "hermes"
      label = "Hermes"
    default:
      identifier = "fallback"
      label = SessionConfiguration.harnessLabel(harness)
    }
  }

  var color: Color {
    switch identifier {
    case "claude": return Color(red: 217.0 / 255, green: 119.0 / 255, blue: 87.0 / 255)
    case "kiro": return Color(red: 144.0 / 255, green: 70.0 / 255, blue: 1)
    default: return Color(uiColor: .label)
    }
  }

  var sendForegroundColor: Color {
    switch identifier {
    case "claude": return .black
    case "kiro": return .white
    default: return Color(uiColor: .systemBackground)
    }
  }

  fileprivate var path: Path? {
    switch identifier {
    case "codex": return HarnessPaths.codex
    case "claude": return HarnessPaths.claude
    case "cursor": return HarnessPaths.cursor
    case "kiro": return HarnessPaths.kiro
    case "opencode": return HarnessPaths.opencode
    case "kimi": return HarnessPaths.kimi
    case "antigravity": return HarnessPaths.antigravity
    case "goose": return HarnessPaths.goose
    case "pi": return HarnessPaths.pi
    case "hermes": return HarnessPaths.hermes
    default: return nil
    }
  }
}

struct HarnessLogo: View {
  let harness: String?

  var body: some View {
    let appearance = HarnessAppearance(harness: harness)
    Group {
      if let path = appearance.path {
        HarnessVector(path: path).fill(
          appearance.color, style: FillStyle(eoFill: appearance.identifier != "hermes"))
      } else {
        Image(systemName: "cpu").resizable().scaledToFit().foregroundStyle(appearance.color)
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityLabel(SessionConfiguration.harnessLabel(harness))
    .accessibilityValue(appearance.identifier)
    .accessibilityAddTraits(.isImage)
    .accessibilityIdentifier("harness-logo-\(appearance.identifier)")
  }
}

private struct HarnessVector: Shape {
  let path: Path

  func path(in rect: CGRect) -> Path {
    path.applying(
      CGAffineTransform(
        a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY))
  }
}

private enum HarnessPaths {

  static let codex: Path = {
    var path = Path()
    path.move(to: .init(x: 8.086, y: 0.457))
    path.addRelativeArc(
      center: .init(x: 10.40660814, y: 6.10375153), radius: 6.105,
      startAngle: .radians(-1.96071803), delta: .radians(0.50902238))
    path.addCurve(
      to: .init(x: 14.696, y: 1.742), control1: .init(x: 12.465, y: 0.195),
      control2: .init(x: 13.653, y: 0.762))
    path.addRelativeArc(
      center: .init(x: 14.77645335, y: 1.65705144), radius: 0.117, startAngle: .radians(2.32902365),
      delta: .radians(-0.9871151))
    path.addCurve(
      to: .init(x: 18.864, y: 2.137), control1: .init(x: 16.211, y: 1.425),
      control2: .init(x: 17.565, y: 1.547))
    path.addLine(to: .init(x: 18.927, y: 2.167))
    path.addLine(to: .init(x: 19.081, y: 2.243))
    path.addCurve(
      to: .init(x: 21.999, y: 5.441), control1: .init(x: 20.438, y: 2.946),
      control2: .init(x: 21.411, y: 4.013))
    path.addCurve(
      to: .init(x: 22.42, y: 7.567), control1: .init(x: 22.277, y: 6.12),
      control2: .init(x: 22.417, y: 6.829))
    path.addRelativeArc(
      center: .init(x: 16.76859944, y: 7.76873415), radius: 5.655,
      startAngle: .radians(-0.03568116), delta: .radians(0.29119618))
    path.addRelativeArc(
      center: .init(x: 22.40192036, y: 9.23887539), radius: 0.167,
      startAngle: .radians(-2.89431759), delta: .radians(-0.99965869))
    path.addRelativeArc(
      center: .init(x: 18.02115084, y: 13.55377706), radius: 5.982,
      startAngle: .radians(-0.77853365), delta: .radians(0.55779231))
    path.addCurve(
      to: .init(x: 22.675, y: 17.384), control1: .init(x: 24.243, y: 14.145),
      control2: .init(x: 23.848, y: 15.859))
    path.addLine(to: .init(x: 22.493, y: 17.604))
    path.addRelativeArc(
      center: .init(x: 17.92617763, y: 13.61600522), radius: 6.063,
      startAngle: .radians(0.71784012), delta: .radians(0.58028043))
    path.addRelativeArc(
      center: .init(x: 19.60385233, y: 19.61066717), radius: 0.162,
      startAngle: .radians(-1.85132764), delta: .radians(-0.95260638))
    path.addCurve(
      to: .init(x: 18.464, y: 21.549), control1: .init(x: 19.196, y: 20.293),
      control2: .init(x: 18.94, y: 20.921))
    path.addCurve(
      to: .init(x: 13.516, y: 24), control1: .init(x: 17.265, y: 23.131),
      control2: .init(x: 15.502, y: 24.011))
    path.addCurve(
      to: .init(x: 9.306, y: 22.264), control1: .init(x: 11.933, y: 23.992),
      control2: .init(x: 10.53, y: 23.413))
    path.addRelativeArc(
      center: .init(x: 9.20793027, y: 22.37080509), radius: 0.145,
      startAngle: .radians(-0.82800988), delta: .radians(-1.03615057))
    path.addCurve(
      to: .init(x: 7.562, y: 22.417), control1: .init(x: 8.648, y: 22.399),
      control2: .init(x: 8.126, y: 22.423))
    path.addRelativeArc(
      center: .init(x: 7.60984329, y: 16.4931932), radius: 5.924, startAngle: .radians(1.57887259),
      delta: .radians(0.4543544))
    path.addRelativeArc(
      center: .init(x: 7.65894869, y: 16.36795879), radius: 6.058, startAngle: .radians(2.03125897),
      delta: .radians(0.46451106))
    path.addCurve(
      to: .init(x: 2.27, y: 19.193), control1: .init(x: 2.618, y: 19.745),
      control2: .init(x: 2.417, y: 19.492))
    path.addRelativeArc(
      center: .init(x: 9.21513932, y: 15.77647548), radius: 7.74, startAngle: .radians(2.68442161),
      delta: .radians(0.17790608))
    path.addRelativeArc(
      center: .init(x: 7.6812212, y: 16.34518334), radius: 6.11, startAngle: .radians(2.88259944),
      delta: .radians(0.50688994))
    path.addRelativeArc(
      center: .init(x: 1.60116262, y: 14.79161217), radius: 0.166, startAngle: .radians(0.33380197),
      delta: .radians(-0.45222419))
    path.addRelativeArc(
      center: .init(x: 1.65322331, y: 14.79450371), radius: 0.115,
      startAngle: .radians(-0.19695537), delta: .radians(-0.65444853))
    path.addRelativeArc(
      center: .init(x: 5.96598814, y: 10.51924177), radius: 5.958, startAngle: .radians(2.36191854),
      delta: .radians(0.43970222))
    path.addRelativeArc(
      center: .init(x: 5.20558247, y: 10.65883388), radius: 5.196, startAngle: .radians(2.77814614),
      delta: .radians(0.3137405))
    path.addRelativeArc(
      center: .init(x: 6.91528647, y: 10.45109093), radius: 6.915, startAngle: .radians(3.07416499),
      delta: .radians(0.31076057))
    path.addCurve(
      to: .init(x: 2.781, y: 5.292), control1: .init(x: 0.654, y: 7.301),
      control2: .init(x: 1.513, y: 6.137))
    path.addCurve(
      to: .init(x: 3.583, y: 4.854), control1: .init(x: 3.063, y: 5.104),
      control2: .init(x: 3.331, y: 4.958))
    path.addCurve(
      to: .init(x: 4.444, y: 4.55), control1: .init(x: 3.869, y: 4.734),
      control2: .init(x: 4.156, y: 4.634))
    path.addRelativeArc(
      center: .init(x: 4.40732363, y: 4.42632363), radius: 0.129, startAngle: .radians(1.28250662),
      delta: .radians(-0.99421691))
    path.addRelativeArc(
      center: .init(x: 10.32689016, y: 6.07542464), radius: 6.016,
      startAngle: .radians(-2.87025259), delta: .radians(0.40494711))
    path.addCurve(
      to: .init(x: 8.086, y: 0.457), control1: .init(x: 6.315, y: 1.464),
      control2: .init(x: 7.132, y: 0.846))
    path.closeSubpath()
    path.move(to: .init(x: 7.282, y: 8.307))
    path.addRelativeArc(
      center: .init(x: 6.5455, y: 8.728), radius: 0.84833558, startAngle: .radians(-0.51929232),
      delta: .radians(-3.14159265))
    path.addLine(to: .init(x: 7.503, y: 12.114))
    path.addLine(to: .init(x: 5.815, y: 14.962))
    path.addRelativeArc(
      center: .init(x: 6.56319938, y: 15.36324642), radius: 0.849,
      startAngle: .radians(-2.64934188), delta: .radians(-3.05738607))
    path.addLine(to: .init(x: 9.215, y: 12.554))
    path.addRelativeArc(
      center: .init(x: 8.48472648, y: 12.12098546), radius: 0.849, startAngle: .radians(0.53521839),
      delta: .radians(-1.0540437))
    path.addLine(to: .init(x: 7.282, y: 8.307))
    path.closeSubpath()
    path.move(to: .init(x: 12.728, y: 14.547))
    path.addRelativeArc(
      center: .init(x: 12.77844552, y: 15.3945), radius: 0.849, startAngle: .radians(-1.63024891),
      delta: .radians(-3.02268748))
    path.addLine(to: .init(x: 17.576, y: 16.242))
    path.addRelativeArc(
      center: .init(x: 17.53480534, y: 15.394), radius: 0.849, startAngle: .radians(1.52225588),
      delta: .radians(-3.04451176))
    path.addLine(to: .init(x: 12.728, y: 14.546))
    path.closeSubpath()
    return path
  }()

  static let claude: Path = {
    var path = Path()
    path.move(to: .init(x: 20.998, y: 10.949))
    path.addLine(to: .init(x: 24, y: 10.949))
    path.addLine(to: .init(x: 24, y: 14.051))
    path.addLine(to: .init(x: 21, y: 14.051))
    path.addLine(to: .init(x: 21, y: 17.079))
    path.addLine(to: .init(x: 19.513, y: 17.079))
    path.addLine(to: .init(x: 19.513, y: 20))
    path.addLine(to: .init(x: 18, y: 20))
    path.addLine(to: .init(x: 18, y: 17.079))
    path.addLine(to: .init(x: 16.513, y: 17.079))
    path.addLine(to: .init(x: 16.513, y: 20))
    path.addLine(to: .init(x: 15, y: 20))
    path.addLine(to: .init(x: 15, y: 17.079))
    path.addLine(to: .init(x: 9, y: 17.079))
    path.addLine(to: .init(x: 9, y: 20))
    path.addLine(to: .init(x: 7.488, y: 20))
    path.addLine(to: .init(x: 7.488, y: 17.079))
    path.addLine(to: .init(x: 6, y: 17.079))
    path.addLine(to: .init(x: 6, y: 20))
    path.addLine(to: .init(x: 4.487, y: 20))
    path.addLine(to: .init(x: 4.487, y: 17.079))
    path.addLine(to: .init(x: 3, y: 17.079))
    path.addLine(to: .init(x: 3, y: 14.05))
    path.addLine(to: .init(x: 0, y: 14.05))
    path.addLine(to: .init(x: 0, y: 10.95))
    path.addLine(to: .init(x: 3, y: 10.95))
    path.addLine(to: .init(x: 3, y: 5))
    path.addLine(to: .init(x: 20.998, y: 5))
    path.addLine(to: .init(x: 20.998, y: 10.949))
    path.closeSubpath()
    path.move(to: .init(x: 6, y: 10.949))
    path.addLine(to: .init(x: 7.488, y: 10.949))
    path.addLine(to: .init(x: 7.488, y: 8.102))
    path.addLine(to: .init(x: 6, y: 8.102))
    path.addLine(to: .init(x: 6, y: 10.949))
    path.closeSubpath()
    path.move(to: .init(x: 16.51, y: 10.949))
    path.addLine(to: .init(x: 18, y: 10.949))
    path.addLine(to: .init(x: 18, y: 8.102))
    path.addLine(to: .init(x: 16.51, y: 8.102))
    path.addLine(to: .init(x: 16.51, y: 10.949))
    path.closeSubpath()
    return path
  }()

  static let cursor: Path = {
    var path = Path()
    path.move(to: .init(x: 22.106, y: 5.68))
    path.addLine(to: .init(x: 12.5, y: 0.135))
    path.addRelativeArc(
      center: .init(x: 12.001, y: 0.99929335), radius: 0.998, startAngle: .radians(-1.04719755),
      delta: .radians(-1.04719755))
    path.addLine(to: .init(x: 1.893, y: 5.68))
    path.addRelativeArc(
      center: .init(x: 2.31399954, y: 6.40688334), radius: 0.84, startAngle: .radians(-2.09576965),
      delta: .radians(-1.0447714))
    path.addLine(to: .init(x: 1.474, y: 17.592))
    path.addCurve(
      to: .init(x: 1.894, y: 18.319), control1: .init(x: 1.474, y: 17.892),
      control2: .init(x: 1.634, y: 18.169))
    path.addLine(to: .init(x: 11.501, y: 23.866))
    path.addRelativeArc(
      center: .init(x: 12, y: 23.00055214), radius: 0.999, startAngle: .radians(2.09381727),
      delta: .radians(-1.04604189))
    path.addLine(to: .init(x: 22.107, y: 18.319))
    path.addRelativeArc(
      center: .init(x: 21.68700013, y: 17.59153859), radius: 0.84, startAngle: .radians(1.04719773),
      delta: .radians(-1.04664842))
    path.addLine(to: .init(x: 22.527, y: 6.407))
    path.addRelativeArc(
      center: .init(x: 21.68700127, y: 6.40846207), radius: 0.84, startAngle: .radians(-0.00174056),
      delta: .radians(-1.04545874))
    path.closeSubpath()
    path.move(to: .init(x: 21.503, y: 6.856))
    path.addLine(to: .init(x: 12.228, y: 22.92))
    path.addCurve(
      to: .init(x: 12, y: 22.859), control1: .init(x: 12.165, y: 23.028),
      control2: .init(x: 12, y: 22.984))
    path.addLine(to: .init(x: 12, y: 12.34))
    path.addRelativeArc(
      center: .init(x: 11.41000077, y: 12.34095543), radius: 0.59,
      startAngle: .radians(-0.00161938), delta: .radians(-1.04557968))
    path.addLine(to: .init(x: 2.595, y: 6.57))
    path.addCurve(
      to: .init(x: 2.657, y: 6.342), control1: .init(x: 2.488, y: 6.508),
      control2: .init(x: 2.532, y: 6.342))
    path.addLine(to: .init(x: 21.207, y: 6.342))
    path.addCurve(
      to: .init(x: 21.503, y: 6.856), control1: .init(x: 21.471, y: 6.342),
      control2: .init(x: 21.635, y: 6.628))
    path.closeSubpath()
    return path
  }()

  static let kiro: Path = {
    var path = Path()
    path.move(to: .init(x: 4.594, y: 6.677))
    path.addCurve(
      to: .init(x: 21.16, y: 6.632), control1: .init(x: 6.67, y: -2.226),
      control2: .init(x: 18.746, y: -2.211))
    path.addCurve(
      to: .init(x: 19.487, y: 20.379), control1: .init(x: 21.513, y: 7.929),
      control2: .init(x: 22.885, y: 14.214))
    path.addCurve(
      to: .init(x: 12.497, y: 22.262), control1: .init(x: 17.942, y: 23.176),
      control2: .init(x: 13.646, y: 25.869))
    path.addCurve(
      to: .init(x: 5.789, y: 18.609), control1: .init(x: 8.6, y: 25.477),
      control2: .init(x: 3.315, y: 24.1))
    path.addLine(to: .init(x: 5.471, y: 18.752))
    path.addCurve(
      to: .init(x: 2.298, y: 16.239), control1: .init(x: 1.901, y: 20.057),
      control2: .init(x: 1.608, y: 17.544))
    path.addCurve(
      to: .init(x: 3.235, y: 14.342), control1: .init(x: 2.748, y: 15.399),
      control2: .init(x: 3.025, y: 14.904))
    path.addCurve(
      to: .init(x: 3.828, y: 11.844), control1: .init(x: 3.588, y: 13.367),
      control2: .init(x: 3.693, y: 12.774))
    path.addCurve(
      to: .init(x: 4.593, y: 6.677), control1: .init(x: 4.098, y: 10.007),
      control2: .init(x: 4.105, y: 8.237))
    path.closeSubpath()
    path.move(to: .init(x: 12.964, y: 6.687))
    path.addRelativeArc(
      center: .init(x: 12.93174811, y: 7.60643451), radius: 0.92, startAngle: .radians(-1.53573274),
      delta: .radians(-1.04233671))
    path.addCurve(
      to: .init(x: 11.824, y: 8.577), control1: .init(x: 11.937, y: 7.438),
      control2: .init(x: 11.824, y: 7.94))
    path.addCurve(
      to: .init(x: 12.964, y: 10.467), control1: .init(x: 11.824, y: 9.282),
      control2: .init(x: 11.974, y: 10.467))
    path.addLine(to: .init(x: 12.972, y: 10.467))
    path.addCurve(
      to: .init(x: 14.186, y: 8.577), control1: .init(x: 13.729, y: 10.467),
      control2: .init(x: 14.186, y: 9.762))
    path.addCurve(
      to: .init(x: 13.819, y: 7.122), control1: .init(x: 14.186, y: 7.955),
      control2: .init(x: 14.059, y: 7.452))
    path.addRelativeArc(
      center: .init(x: 12.98638893, y: 7.7007528), radius: 1.014, startAngle: .radians(-0.60743372),
      delta: .radians(-0.98544421))
    path.closeSubpath()
    path.move(to: .init(x: 17.044, y: 6.687))
    path.addRelativeArc(
      center: .init(x: 17.01174811, y: 7.60643451), radius: 0.92, startAngle: .radians(-1.53573274),
      delta: .radians(-1.04233671))
    path.addCurve(
      to: .init(x: 15.904, y: 8.577), control1: .init(x: 16.017, y: 7.438),
      control2: .init(x: 15.904, y: 7.94))
    path.addCurve(
      to: .init(x: 17.044, y: 10.467), control1: .init(x: 15.904, y: 9.282),
      control2: .init(x: 16.054, y: 10.467))
    path.addLine(to: .init(x: 17.052, y: 10.467))
    path.addCurve(
      to: .init(x: 18.267, y: 8.577), control1: .init(x: 17.809, y: 10.467),
      control2: .init(x: 18.267, y: 9.762))
    path.addCurve(
      to: .init(x: 17.899, y: 7.122), control1: .init(x: 18.267, y: 7.955),
      control2: .init(x: 18.139, y: 7.452))
    path.addRelativeArc(
      center: .init(x: 17.06638893, y: 7.7007528), radius: 1.014, startAngle: .radians(-0.60743372),
      delta: .radians(-0.98544421))
    path.closeSubpath()
    return path
  }()

  static let opencode: Path = {
    var path = Path()
    path.move(to: .init(x: 16, y: 6))
    path.addLine(to: .init(x: 8, y: 6))
    path.addLine(to: .init(x: 8, y: 18))
    path.addLine(to: .init(x: 16, y: 18))
    path.addLine(to: .init(x: 16, y: 6))
    path.closeSubpath()
    path.move(to: .init(x: 20, y: 22))
    path.addLine(to: .init(x: 4, y: 22))
    path.addLine(to: .init(x: 4, y: 2))
    path.addLine(to: .init(x: 20, y: 2))
    path.addLine(to: .init(x: 20, y: 22))
    path.closeSubpath()
    return path
  }()

  static let kimi: Path = {
    var path = Path()
    path.move(to: .init(x: 21.846, y: 0))
    path.addRelativeArc(
      center: .init(x: 21.846, y: 1.923), radius: 1.923, startAngle: .radians(-1.57079633),
      delta: .radians(3.14159265))
    path.addLine(to: .init(x: 20.15, y: 3.846))
    path.addRelativeArc(
      center: .init(x: 20.149, y: 3.62000221), radius: 0.226, startAngle: .radians(1.56637153),
      delta: .radians(1.57523091))
    path.addLine(to: .init(x: 19.923, y: 1.923))
    path.addCurve(
      to: .init(x: 21.846, y: 0), control1: .init(x: 19.923, y: 0.861),
      control2: .init(x: 20.784, y: 0))
    path.closeSubpath()
    path.move(to: .init(x: 11.065, y: 11.199))
    path.addLine(to: .init(x: 18.322, y: 3.999))
    path.addCurve(
      to: .init(x: 18.206, y: 3.589), control1: .init(x: 18.459, y: 3.863),
      control2: .init(x: 18.382, y: 3.589))
    path.addLine(to: .init(x: 14.3, y: 3.589))
    path.addRelativeArc(
      center: .init(x: 14.30186716, y: 3.75298937), radius: 0.164, startAngle: .radians(-1.5821817),
      delta: .radians(-0.79935834))
    path.addLine(to: .init(x: 6.363, y: 11.396))
    path.addCurve(
      to: .init(x: 6.061, y: 11.217), control1: .init(x: 6.241, y: 11.516),
      control2: .init(x: 6.061, y: 11.409))
    path.addLine(to: .init(x: 6.061, y: 3.82))
    path.addCurve(
      to: .init(x: 5.876, y: 3.59), control1: .init(x: 6.061, y: 3.693),
      control2: .init(x: 5.978, y: 3.59))
    path.addLine(to: .init(x: 3.186, y: 3.59))
    path.addCurve(
      to: .init(x: 3, y: 3.82), control1: .init(x: 3.083, y: 3.59), control2: .init(x: 3, y: 3.693))
    path.addLine(to: .init(x: 3, y: 19.77))
    path.addCurve(
      to: .init(x: 3.186, y: 20), control1: .init(x: 3, y: 19.898), control2: .init(x: 3.083, y: 20)
    )
    path.addLine(to: .init(x: 5.876, y: 20))
    path.addCurve(
      to: .init(x: 6.062, y: 19.77), control1: .init(x: 5.979, y: 20),
      control2: .init(x: 6.062, y: 19.898))
    path.addLine(to: .init(x: 6.062, y: 16.52))
    path.addCurve(
      to: .init(x: 6.131, y: 16.342), control1: .init(x: 6.062, y: 16.451),
      control2: .init(x: 6.087, y: 16.385))
    path.addLine(to: .init(x: 8.555, y: 13.936))
    path.addRelativeArc(
      center: .init(x: 8.67084481, y: 14.04344291), radius: 0.158, startAngle: .radians(-2.3938049),
      delta: .radians(1.42256137))
    path.addLine(to: .init(x: 15.244, y: 18.685))
    path.addRelativeArc(
      center: .init(x: 19.5662721, y: 12.34037291), radius: 7.677, startAngle: .radians(2.1688267),
      delta: .radians(-0.4845563))
    path.addCurve(
      to: .init(x: 18.897, y: 19.738), control1: .init(x: 18.805, y: 19.98),
      control2: .init(x: 18.897, y: 19.873))
    path.addLine(to: .init(x: 18.897, y: 16.678))
    path.addCurve(
      to: .init(x: 18.733, y: 16.451), control1: .init(x: 18.897, y: 16.561),
      control2: .init(x: 18.827, y: 16.466))
    path.addRelativeArc(
      center: .init(x: 19.53500136, y: 11.48737453), radius: 5.028, startAngle: .radians(1.7309876),
      delta: .radians(0.4373959))
    path.addLine(to: .init(x: 11.093, y: 11.58))
    path.addCurve(
      to: .init(x: 11.065, y: 11.199), control1: .init(x: 10.976, y: 11.502),
      control2: .init(x: 10.961, y: 11.301))
    path.closeSubpath()
    return path
  }()

  static let antigravity: Path = {
    var path = Path()
    path.move(to: .init(x: 21.751, y: 22.607))
    path.addCurve(
      to: .init(x: 23.259, y: 21.099), control1: .init(x: 23.091, y: 23.612),
      control2: .init(x: 25.101, y: 22.942))
    path.addCurve(
      to: .init(x: 12.037, y: 1), control1: .init(x: 17.73, y: 15.74),
      control2: .init(x: 18.904, y: 1))
    path.addCurve(
      to: .init(x: 0.815, y: 21.1), control1: .init(x: 5.17, y: 1),
      control2: .init(x: 6.342, y: 15.74))
    path.addCurve(
      to: .init(x: 2.322, y: 22.606), control1: .init(x: -1.195, y: 23.109),
      control2: .init(x: 0.982, y: 23.611))
    path.addCurve(
      to: .init(x: 12.037, y: 12.892), control1: .init(x: 7.514, y: 19.089),
      control2: .init(x: 7.179, y: 12.892))
    path.addCurve(
      to: .init(x: 21.751, y: 22.607), control1: .init(x: 16.894, y: 12.892),
      control2: .init(x: 16.559, y: 19.089))
    path.closeSubpath()
    return path
  }()

  static let goose: Path = {
    var path = Path()
    path.move(to: .init(x: 21.595, y: 23.61))
    path.addCurve(
      to: .init(x: 24, y: 22.666), control1: .init(x: 22.762, y: 23.356),
      control2: .init(x: 24, y: 22.666))
    path.addLine(to: .init(x: 21.833, y: 20.882))
    path.addRelativeArc(
      center: .init(x: 29.54000258, y: 11.52286076), radius: 12.124,
      startAngle: .radians(2.25968736), delta: .radians(0.34240965))
    path.addRelativeArc(
      center: .init(x: 8.73384678, y: 23.9813872), radius: 12.127,
      startAngle: .radians(-0.53956358), delta: .radians(-0.4719666))
    path.addLine(to: .init(x: 14.374, y: 13.24))
    path.addRelativeArc(
      center: .init(x: 14.99548802, y: 12.31426913), radius: 1.115, startAngle: .radians(2.1620332),
      delta: .radians(0.88008529))
    path.addRelativeArc(
      center: .init(x: 14.72589133, y: 12.3418222), radius: 0.844, startAngle: .radians(3.04288053),
      delta: .radians(0.7207933))
    path.addCurve(
      to: .init(x: 16.98, y: 8.41), control1: .init(x: 14.453, y: 11.268),
      control2: .init(x: 16.588, y: 8.735))
    path.addCurve(
      to: .init(x: 18.566, y: 7.251), control1: .init(x: 17.483, y: 7.994),
      control2: .init(x: 18.045, y: 7.648))
    path.addCurve(
      to: .init(x: 18.787, y: 7.081), control1: .init(x: 18.64, y: 7.195),
      control2: .init(x: 18.714, y: 7.139))
    path.addCurve(
      to: .init(x: 18.796, y: 7.074), control1: .init(x: 18.79, y: 7.079),
      control2: .init(x: 18.794, y: 7.077))
    path.addCurve(
      to: .init(x: 19.246, y: 6.636), control1: .init(x: 18.963, y: 6.943),
      control2: .init(x: 19.121, y: 6.802))
    path.addCurve(
      to: .init(x: 19.836, y: 5.443), control1: .init(x: 19.699, y: 6.112),
      control2: .init(x: 19.809, y: 5.648))
    path.addCurve(
      to: .init(x: 19.083, y: 4.295), control1: .init(x: 19.775, y: 5.246),
      control2: .init(x: 19.592, y: 4.804))
    path.addCurve(
      to: .init(x: 20.139, y: 4.864), control1: .init(x: 19.402, y: 4.315),
      control2: .init(x: 19.788, y: 4.567))
    path.addCurve(
      to: .init(x: 20.866, y: 3.693), control1: .init(x: 20.374, y: 4.488),
      control2: .init(x: 20.62, y: 4.091))
    path.addCurve(
      to: .init(x: 20.78, y: 3.222), control1: .init(x: 21.031, y: 3.427),
      control2: .init(x: 20.786, y: 3.228))
    path.addLine(to: .init(x: 20.779, y: 3.222))
    path.addLine(to: .init(x: 20.779, y: 3.22))
    path.addCurve(
      to: .init(x: 20.308, y: 3.134), control1: .init(x: 20.772, y: 3.213),
      control2: .init(x: 20.573, y: 2.97))
    path.addCurve(
      to: .init(x: 18.669, y: 4.155), control1: .init(x: 19.741, y: 3.484),
      control2: .init(x: 19.174, y: 3.836))
    path.addCurve(
      to: .init(x: 17.364, y: 4.754), control1: .init(x: 18.669, y: 4.155),
      control2: .init(x: 18.072, y: 4.143))
    path.addRelativeArc(
      center: .init(x: 18.89630025, y: 6.68359891), radius: 2.464,
      startAngle: .radians(-2.24193117), delta: .radians(-0.25555202))
    path.addLine(to: .init(x: 16.919, y: 5.213))
    path.addCurve(
      to: .init(x: 16.749, y: 5.434), control1: .init(x: 16.861, y: 5.285),
      control2: .init(x: 16.805, y: 5.36))
    path.addCurve(
      to: .init(x: 15.589, y: 7.021), control1: .init(x: 16.352, y: 5.955),
      control2: .init(x: 16.006, y: 6.517))
    path.addCurve(
      to: .init(x: 12.149, y: 9.961), control1: .init(x: 15.266, y: 7.412),
      control2: .init(x: 12.732, y: 9.547))
    path.addRelativeArc(
      center: .init(x: 11.65907729, y: 9.27620825), radius: 0.842, startAngle: .radians(0.94978747),
      delta: .radians(0.72102981))
    path.addRelativeArc(
      center: .init(x: 11.68573087, y: 9.00451198), radius: 1.115, startAngle: .radians(1.67027049),
      delta: .radians(0.88008529))
    path.addLine(to: .init(x: 10.298, y: 8.832))
    path.addRelativeArc(
      center: .init(x: 0.02149308, y: 15.26321563), radius: 12.123,
      startAngle: .radians(-0.55918681), delta: .radians(-0.47212528))
    path.addRelativeArc(
      center: .init(x: 12.48507137, y: -5.54574245), radius: 12.133,
      startAngle: .radians(2.11060986), delta: .radians(0.34208976))
    path.addLine(to: .init(x: 1.332, y: 0))
    path.addCurve(
      to: .init(x: 0.39, y: 2.405), control1: .init(x: 1.332, y: 0),
      control2: .init(x: 0.643, y: 1.238))
    path.addCurve(
      to: .init(x: 2.73, y: 4.707), control1: .init(x: 0.742, y: 2.833),
      control2: .init(x: 1.66, y: 3.895))
    path.addCurve(
      to: .init(x: 0.06, y: 3.4), control1: .init(x: 1.58, y: 4.167),
      control2: .init(x: 0.73, y: 3.75))
    path.addCurve(
      to: .init(x: 0.103, y: 6.216), control1: .init(x: -0.043, y: 4.165),
      control2: .init(x: -0.003, y: 5.32))
    path.addCurve(
      to: .init(x: 3.322, y: 7.282), control1: .init(x: 0.829, y: 6.533),
      control2: .init(x: 2.064, y: 7.022))
    path.addCurve(
      to: .init(x: 0.361, y: 7.544), control1: .init(x: 2.316, y: 7.518),
      control2: .init(x: 1.212, y: 7.56))
    path.addCurve(
      to: .init(x: 1.001, y: 9.232), control1: .init(x: 0.511, y: 8.098),
      control2: .init(x: 0.719, y: 8.663))
    path.addCurve(
      to: .init(x: 1.391, y: 10.002), control1: .init(x: 1.12, y: 9.495),
      control2: .init(x: 1.251, y: 9.752))
    path.addCurve(
      to: .init(x: 4.555, y: 10.173), control1: .init(x: 1.843, y: 10.127),
      control2: .init(x: 3.613, y: 10.385))
    path.addLine(to: .init(x: 2.045, y: 11.07))
    path.addRelativeArc(
      center: .init(x: 23.57798777, y: -6.47527325), radius: 27.776,
      startAngle: .radians(2.45788681), delta: .radians(-0.13434187))
    path.addCurve(
      to: .init(x: 8.607, y: 11.558), control1: .init(x: 6.62, y: 12.704),
      control2: .init(x: 7.083, y: 12.555))
    path.addCurve(
      to: .init(x: 4.807, y: 15.228), control1: .init(x: 6.14, y: 13.566),
      control2: .init(x: 5.499, y: 14.386))
    path.addLine(to: .init(x: 4.324, y: 15.906))
    path.addCurve(
      to: .init(x: 3.674, y: 17.023), control1: .init(x: 4.074, y: 16.257),
      control2: .init(x: 3.855, y: 16.631))
    path.addCurve(
      to: .init(x: 2.204, y: 21.123), control1: .init(x: 3.064, y: 18.333),
      control2: .init(x: 2.204, y: 21.123))
    path.addCurve(
      to: .init(x: 2.878, y: 21.797), control1: .init(x: 2.05, y: 21.609),
      control2: .init(x: 2.406, y: 21.965))
    path.addCurve(
      to: .init(x: 6.978, y: 20.327), control1: .init(x: 2.878, y: 21.797),
      control2: .init(x: 5.668, y: 20.936))
    path.addCurve(
      to: .init(x: 8.096, y: 19.677), control1: .init(x: 7.37, y: 20.145),
      control2: .init(x: 7.744, y: 19.927))
    path.addLine(to: .init(x: 8.773, y: 19.194))
    path.addCurve(
      to: .init(x: 9.474, y: 18.608), control1: .init(x: 9, y: 19.007),
      control2: .init(x: 9.226, y: 18.824))
    path.addCurve(
      to: .init(x: 12.932, y: 21.957), control1: .init(x: 9.474, y: 18.608),
      control2: .init(x: 11.179, y: 20.628))
    path.addLine(to: .init(x: 13.828, y: 19.446))
    path.addCurve(
      to: .init(x: 13.998, y: 22.609), control1: .init(x: 13.617, y: 20.388),
      control2: .init(x: 13.874, y: 22.158))
    path.addCurve(
      to: .init(x: 14.77, y: 23.001), control1: .init(x: 14.25, y: 22.751),
      control2: .init(x: 14.507, y: 22.881))
    path.addCurve(
      to: .init(x: 16.458, y: 23.641), control1: .init(x: 15.339, y: 23.281),
      control2: .init(x: 15.904, y: 23.491))
    path.addCurve(
      to: .init(x: 16.719, y: 20.679), control1: .init(x: 16.442, y: 22.788),
      control2: .init(x: 16.484, y: 21.685))
    path.addCurve(
      to: .init(x: 17.786, y: 23.898), control1: .init(x: 16.979, y: 21.937),
      control2: .init(x: 17.469, y: 23.172))
    path.addCurve(
      to: .init(x: 20.602, y: 23.941), control1: .init(x: 18.681, y: 24.004),
      control2: .init(x: 19.837, y: 24.044))
    path.addRelativeArc(
      center: .init(x: 86.27205409, y: -9.88533436), radius: 73.87,
      startAngle: .radians(2.66594188), delta: .radians(0.04025145))
    path.addCurve(
      to: .init(x: 21.596, y: 23.611), control1: .init(x: 20.105, y: 22.341),
      control2: .init(x: 21.168, y: 23.259))
    path.addLine(to: .init(x: 21.595, y: 23.611))
    path.closeSubpath()
    return path
  }()

  static let pi: Path = {
    var path = Path()
    path.move(to: .init(x: 165.29, y: 165.29))
    path.addLine(to: .init(x: 517.36, y: 165.29))
    path.addLine(to: .init(x: 517.36, y: 400))
    path.addLine(to: .init(x: 400, y: 400))
    path.addLine(to: .init(x: 400, y: 517.36))
    path.addLine(to: .init(x: 282.65, y: 517.36))
    path.addLine(to: .init(x: 282.65, y: 634.72))
    path.addLine(to: .init(x: 165.29, y: 634.72))
    path.closeSubpath()
    path.move(to: .init(x: 282.65, y: 282.65))
    path.addLine(to: .init(x: 282.65, y: 400))
    path.addLine(to: .init(x: 400, y: 400))
    path.addLine(to: .init(x: 400, y: 282.65))
    path.closeSubpath()
    path.move(to: .init(x: 517.36, y: 400))
    path.addLine(to: .init(x: 634.72, y: 400))
    path.addLine(to: .init(x: 634.72, y: 634.72))
    path.addLine(to: .init(x: 517.36, y: 634.72))
    path.closeSubpath()
    let scale = 24.0 / 516.37
    return path.applying(
      CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: -141.82 * scale, ty: -141.82 * scale))
  }()

  static let hermes: Path = {
    var path = Path()
    path.move(to: .init(x: 11.5, y: 5.9))
    path.addCurve(
      to: .init(x: 4.8, y: 5.7), control1: .init(x: 9, y: 4.7), control2: .init(x: 6.4, y: 4.7))
    path.move(to: .init(x: 11.5, y: 7.3))
    path.addCurve(
      to: .init(x: 5.8, y: 7.9), control1: .init(x: 9.4, y: 6.6), control2: .init(x: 7.2, y: 6.8))
    path.move(to: .init(x: 12, y: 8.2))
    path.addCurve(
      to: .init(x: 12, y: 12), control1: .init(x: 8.9, y: 9), control2: .init(x: 8.6, y: 11))
    path.addCurve(
      to: .init(x: 12, y: 16), control1: .init(x: 15.4, y: 13), control2: .init(x: 15.1, y: 15))
    path.addCurve(
      to: .init(x: 12, y: 18.2), control1: .init(x: 9.9, y: 16.7), control2: .init(x: 9.6, y: 17.6))
    let mirrored = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0))
    path.addPath(mirrored)
    path.move(to: .init(x: 12, y: 5))
    path.addLine(to: .init(x: 12, y: 20))
    return path.strokedPath(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
  }()
}
