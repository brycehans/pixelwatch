import Foundation
import CoreGraphics
import Accelerate

struct PixelBuffer {
  let width: Int
  let height: Int
  let linearRGB: [Float]   // length = width * height * 3
}

enum Diff {

  static func makeBuffer(from image: CGImage, maxLongEdge: Int = 256) -> PixelBuffer {
    // 1. Compute target dims preserving aspect.
    let srcW = image.width, srcH = image.height
    let long = max(srcW, srcH)
    let scale = long > maxLongEdge ? Double(maxLongEdge) / Double(long) : 1.0
    let dstW = max(1, Int((Double(srcW) * scale).rounded()))
    let dstH = max(1, Int((Double(srcH) * scale).rounded()))

    // 2. Draw into an RGBA8 sRGB context at dstW × dstH (bilinear via CG).
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = dstW * 4
    var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
    let ctx = CGContext(
      data: &rgba, width: dstW, height: dstH,
      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

    // 3. Convert sRGB-encoded UInt8 → linear-RGB Float per channel.
    //    Strip the alpha and normalise into an interleaved RGB Float buffer.
    //    This unpacking step is memory-bound, so left scalar for readability.
    let pixelCount = dstW * dstH
    var rgbNormalised = [Float](repeating: 0, count: pixelCount * 3)
    for p in 0..<pixelCount {
      rgbNormalised[p*3 + 0] = Float(rgba[p*4 + 0]) / 255
      rgbNormalised[p*3 + 1] = Float(rgba[p*4 + 1]) / 255
      rgbNormalised[p*3 + 2] = Float(rgba[p*4 + 2]) / 255
    }
    // Apply gamma 2.2 to all channels in one vectorised pass via vForce.
    // Gamma 2.2 is an approximation of the sRGB EOTF (which is piecewise near 0).
    // Safe here because we only compare deltas between buffers — the same
    // nonlinearity is applied to both baseline and current.
    var linear = [Float](repeating: 0, count: pixelCount * 3)
    var exponent: Float = 2.2
    var count = Int32(pixelCount * 3)
    vvpowsf(&linear, &exponent, rgbNormalised, &count)
    return PixelBuffer(width: dstW, height: dstH, linearRGB: linear)
  }

  static func score(baseline: PixelBuffer, current: PixelBuffer, epsilon: Float = 0.03) -> Double {
    precondition(baseline.width == current.width && baseline.height == current.height,
                 "score: buffer dimensions must match")
    let pixelCount = baseline.width * baseline.height
    var changed = 0
    let eps2 = epsilon * epsilon
    baseline.linearRGB.withUnsafeBufferPointer { bp in
      current.linearRGB.withUnsafeBufferPointer { cp in
        for p in 0..<pixelCount {
          let dr = cp[p*3 + 0] - bp[p*3 + 0]
          let dg = cp[p*3 + 1] - bp[p*3 + 1]
          let db = cp[p*3 + 2] - bp[p*3 + 2]
          if dr*dr + dg*dg + db*db > eps2 { changed += 1 }
        }
      }
    }
    return Double(changed) / Double(pixelCount)
  }
}
