public import CoreVideo

/// The colour along the top edge of the page, for tinting the status bar area and the address
/// pill as Safari does with a page's theme colour. Sampled from the decoded video on the client,
/// so it needs nothing from the host.
nonisolated public struct RemoteEdgeColor: Hashable, Sendable {
  /// sRGB components, 0–1.
  public var red: Double
  /// sRGB components, 0–1.
  public var green: Double
  /// sRGB components, 0–1.
  public var blue: Double

  /// Creates a colour.
  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  /// Relative luminance (Rec. 709 weights on the encoded values, close enough to pick a text
  /// colour).
  public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

  /// Whether light text reads better on it.
  public var isDark: Bool { luminance < 0.5 }

  /// Whether two samples are close enough that the tint should not change.
  /// - Parameter other: The other colour.
  /// - Returns: Whether they differ by less than 2% on every channel.
  public func isClose(to other: Self) -> Bool {
    abs(red - other.red) < 0.02 && abs(green - other.green) < 0.02 && abs(blue - other.blue) < 0.02
  }

  /// The top edge's colour, when most of the top rows share one colour; `nil` for a busy edge
  /// (an image, a gradient), where the bars keep their own material.
  /// - Parameters:
  ///   - pixelBuffer: A decoded frame (biplanar 4:2:0 YCbCr or 32-bit BGRA).
  ///   - rows: How many pixel rows from the top to read.
  /// - Returns: The colour.
  public static func sample(_ pixelBuffer: CVPixelBuffer, rows: Int = 4) -> Self? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    guard width > 0, height > 0 else { return nil }
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
      return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let reader: PixelReader
    switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      reader = .yCbCr(fullRange: false, bt601: isBT601(pixelBuffer))
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      reader = .yCbCr(fullRange: true, bt601: isBT601(pixelBuffer))
    case kCVPixelFormatType_32BGRA:
      reader = .bgra
    default:
      return nil
    }
    let step = max(1, width / 64)
    var samples: [Self] = []
    for row in 0..<min(rows, height) {
      for column in stride(from: 0, to: width, by: step) {
        if let color = reader.read(pixelBuffer, column: column, row: row) { samples.append(color) }
      }
    }
    return dominant(samples)
  }

  /// The mean of `samples` when at least 85% of them are within 6% of it.
  static func dominant(_ samples: [Self]) -> Self? {
    guard !samples.isEmpty else { return nil }
    let count = Double(samples.count)
    let mean = Self(
      red: samples.map(\.red).reduce(0, +) / count,
      green: samples.map(\.green).reduce(0, +) / count,
      blue: samples.map(\.blue).reduce(0, +) / count)
    let near = samples.filter {
      abs($0.red - mean.red) < 0.06 && abs($0.green - mean.green) < 0.06
        && abs($0.blue - mean.blue) < 0.06
    }
    return Double(near.count) >= count * 0.85 ? mean : nil
  }

  private static func isBT601(_ pixelBuffer: CVPixelBuffer) -> Bool {
    guard
      let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)
        as? String
    else { return false }
    return matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
  }

  private enum PixelReader {
    case yCbCr(fullRange: Bool, bt601: Bool)
    case bgra

    func read(_ buffer: CVPixelBuffer, column: Int, row: Int) -> RemoteEdgeColor? {
      switch self {
      case .bgra:
        let pixel = bytes(buffer, plane: nil, column: column * 4, row: row, count: 3)
        guard pixel.count == 3 else { return nil }
        return RemoteEdgeColor(red: pixel[2], green: pixel[1], blue: pixel[0])
      case .yCbCr(let fullRange, let bt601):
        let luma = bytes(buffer, plane: 0, column: column, row: row, count: 1)
        let chroma = bytes(buffer, plane: 1, column: (column / 2) * 2, row: row / 2, count: 2)
        guard luma.count == 1, chroma.count == 2 else { return nil }
        return Self.convert(
          luma: luma[0], blueChroma: chroma[0], redChroma: chroma[1], fullRange: fullRange,
          bt601: bt601)
      }
    }

    /// YCbCr (0–1 code values) to sRGB-encoded RGB.
    static func convert(
      luma: Double, blueChroma: Double, redChroma: Double, fullRange: Bool, bt601: Bool
    ) -> RemoteEdgeColor {
      let lumaValue = fullRange ? luma : (luma * 255 - 16) / 219
      let blueDiff = fullRange ? blueChroma - 0.5 : (blueChroma * 255 - 128) / 224
      let redDiff = fullRange ? redChroma - 0.5 : (redChroma * 255 - 128) / 224
      let (redWeight, blueWeight) = bt601 ? (0.299, 0.114) : (0.2126, 0.0722)
      let greenWeight = 1 - redWeight - blueWeight
      let red = lumaValue + 2 * (1 - redWeight) * redDiff
      let blue = lumaValue + 2 * (1 - blueWeight) * blueDiff
      let green = (lumaValue - redWeight * red - blueWeight * blue) / greenWeight
      func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
      return RemoteEdgeColor(red: clamp(red), green: clamp(green), blue: clamp(blue))
    }

    /// `count` bytes at a byte column and row of a plane, as 0–1 values; empty outside it.
    private func bytes(_ buffer: CVPixelBuffer, plane: Int?, column: Int, row: Int, count: Int)
      -> [Double]
    {
      let rowBytes =
        plane.map { CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) }
        ?? CVPixelBufferGetBytesPerRow(buffer)
      let rows =
        plane.map { CVPixelBufferGetHeightOfPlane(buffer, $0) } ?? CVPixelBufferGetHeight(buffer)
      guard row < rows, column + count <= rowBytes,
        let base = unsafe baseAddress(buffer, plane: plane)
      else { return [] }
      return (0..<count).map { offset in
        Double(unsafe base.load(fromByteOffset: row * rowBytes + column + offset, as: UInt8.self))
          / 255
      }
    }

    private func baseAddress(_ buffer: CVPixelBuffer, plane: Int?) -> UnsafeMutableRawPointer? {
      if let plane {
        return unsafe CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
      }
      return unsafe CVPixelBufferGetBaseAddress(buffer)
    }
  }
}
