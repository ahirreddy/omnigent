import Foundation

/// Draws TeX as plain Unicode text: Greek letters and operators as symbols, `^`/`_` as
/// superscript and subscript characters where Unicode has them, `\frac{a}{b}` as `a/b`,
/// `\sqrt{x}` as `√x`. Commands it does not know stay as written.
nonisolated struct MathText {
  private let characters: [Character]
  private var index = 0

  /// `tex` as Unicode text.
  static func unicode(_ tex: String) -> String {
    var parser = Self(characters: Array(tex))
    return parser.sequence(until: nil).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private init(characters: [Character]) {
    self.characters = characters
  }

  /// Text until `closer` (consumed) or the end.
  private mutating func sequence(until closer: Character?) -> String {
    var output = ""
    while index < characters.count {
      let character = characters[index]
      if character == closer {
        index += 1
        return output
      }
      output += element()
    }
    return output
  }

  /// One element: a group, command, script or character.
  private mutating func element() -> String {
    let character = characters[index]
    index += 1
    switch character {
    case "{": return sequence(until: "}")
    case "\\": return command()
    case "^": return Self.script(argument(), map: Self.superscripts, marker: "^")
    case "_": return Self.script(argument(), map: Self.subscripts, marker: "_")
    case "&": return " "
    case "~": return "\u{00A0}"
    default: return String(character)
    }
  }

  /// The next element as an argument (a group or one character or command).
  private mutating func argument() -> String {
    while index < characters.count, characters[index] == " " { index += 1 }
    guard index < characters.count else { return "" }
    return element()
  }

  private mutating func command() -> String {
    guard index < characters.count else { return "\\" }
    let first = characters[index]
    guard first.isLetter else {
      index += 1
      return Self.spacing[first] ?? String(first)
    }
    var name = ""
    while index < characters.count, characters[index].isLetter {
      name.append(characters[index])
      index += 1
    }
    switch name {
    case "frac", "dfrac", "tfrac":
      let numerator = argument()
      let denominator = argument()
      return Self.grouped(numerator) + "/" + Self.grouped(denominator)
    case "sqrt": return "√" + Self.grouped(argument())
    case "text", "textrm", "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "operatorname",
      "boldsymbol", "mathcal", "textbf", "textit", "mathbb":
      let content = argument()
      return name == "mathbb" ? String(content.map { Self.doubleStruck[$0] ?? $0 }) : content
    case "begin", "end":
      _ = argument()
      return ""
    case "left", "right", "big", "Big", "bigl", "bigr", "Bigl", "Bigr", "displaystyle":
      return ""
    default:
      return Self.symbols[name] ?? "\\" + name
    }
  }

  private static func grouped(_ text: String) -> String {
    text.count > 1 && text.contains(where: { "+-−*/ =".contains($0) }) ? "(\(text))" : text
  }

  private static func script(_ text: String, map: [Character: Character], marker: String)
    -> String
  {
    let mapped = text.compactMap { map[$0] }
    if mapped.count == text.count { return String(mapped) }
    return marker + (text.count == 1 ? text : "(\(text))")
  }

  private static let spacing: [Character: String] = [
    ",": "\u{2009}", ";": " ", ":": " ", "!": "", " ": " ", "\\": "\n", "{": "{", "}": "}",
    "%": "%", "$": "$", "#": "#", "&": "&", "_": "_", "|": "‖",
  ]

  private static let superscripts: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸",
    "9": "⁹", "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "j": "ʲ",
    "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
    "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "T": "ᵀ", "′": "′", "*": "*",
  ]

  private static let subscripts: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈",
    "9": "₉", "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ",
    "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ",
    "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
  ]

  private static let doubleStruck: [Character: Character] = [
    "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "E": "𝔼",
  ]

  // A symbol table reads best as one literal.
  // swiftlint:disable:next closure_body_length
  private static let symbols: [String: String] = {
    let greek: [String: String] = [
      "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
      "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
      "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
      "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ",
      "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
      "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]
    let operators: [String: String] = [
      "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "circ": "∘",
      "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
      "equiv": "≡", "sim": "∼", "simeq": "≃", "propto": "∝", "ll": "≪", "gg": "≫",
      "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫",
      "oint": "∮", "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆",
      "supset": "⊃", "supseteq": "⊇", "cup": "∪", "cap": "∩", "emptyset": "∅",
      "varnothing": "∅", "forall": "∀", "exists": "∃", "neg": "¬", "lnot": "¬", "land": "∧",
      "wedge": "∧", "lor": "∨", "vee": "∨", "oplus": "⊕", "otimes": "⊗", "perp": "⊥",
      "parallel": "∥", "angle": "∠", "degree": "°", "prime": "′", "ldots": "…", "dots": "…",
      "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ",
      "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
      "leftrightarrow": "↔", "Leftrightarrow": "⇔", "iff": "⇔", "implies": "⇒", "mapsto": "↦",
      "uparrow": "↑", "downarrow": "↓", "langle": "⟨", "rangle": "⟩", "lceil": "⌈",
      "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋", "mid": "∣", "quad": "\u{2003}",
      "qquad": "\u{2003}\u{2003}", "log": "log", "ln": "ln", "exp": "exp", "sin": "sin",
      "cos": "cos", "tan": "tan", "lim": "lim", "max": "max", "min": "min", "det": "det",
      "therefore": "∴", "because": "∵", "star": "⋆", "bullet": "•", "checkmark": "✓",
    ]
    return greek.merging(operators) { first, _ in first }
  }()
}

/// Marks inline math, which draws in the serif math face.
nonisolated enum MathSpanAttribute: AttributedStringKey {
  typealias Value = Bool
  static let name = "omnigent.math"
}
