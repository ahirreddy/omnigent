#if DEBUG
  import CoreGraphics

  /// SplitMix64: a small seeded generator, so a seed replays the same choices.
  struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return mixed ^ (mixed >> 31)
    }

    /// A number in 0..<bound; 0 when `bound` is not positive.
    mutating func int(below bound: Int) -> Int {
      bound > 0 ? Int(next() % UInt64(bound)) : 0
    }

    /// A number in 0...1.
    var unit: CGFloat {
      mutating get { CGFloat(next() >> 11) / CGFloat(UInt64(1) << 53) }
    }
  }
#endif
