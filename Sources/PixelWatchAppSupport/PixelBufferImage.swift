import Accelerate
import AppKit
import PixelWatchCore

extension PixelBuffer {
  /// Converts the linear-light float buffer back to a display-ready NSImage.
  /// Returns nil if the buffer has no pixel data.
  public var displayImage: NSImage? {
    guard !linearRGB.isEmpty, width > 0, height > 0 else { return nil }
    let pixelCount = width * height

    // Step 1: apply sRGB gamma (linear -> display)
    var exponent: Float = 1.0 / 2.2
    var srgb = [Float](repeating: 0, count: pixelCount * 3)
    var n = Int32(pixelCount * 3)
    vvpowsf(&srgb, &exponent, linearRGB, &n)

    // Step 2: clamp to [0, 1]
    var lo: Float = 0, hi: Float = 1
    var clamped = [Float](repeating: 0, count: pixelCount * 3)
    vDSP_vclip(&srgb, 1, &lo, &hi, &clamped, 1, vDSP_Length(pixelCount * 3))

    // Step 3: pack as RGBA bytes (alpha = 255)
    var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
    for i in 0..<pixelCount {
      rgba[i * 4 + 0] = UInt8(clamped[i * 3 + 0] * 255)
      rgba[i * 4 + 1] = UInt8(clamped[i * 3 + 1] * 255)
      rgba[i * 4 + 2] = UInt8(clamped[i * 3 + 2] * 255)
    }

    // Step 4: create CGImage
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
          )
    else { return nil }

    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
  }
}
