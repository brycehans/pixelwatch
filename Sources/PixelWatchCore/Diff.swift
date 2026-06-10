import Accelerate
import CoreGraphics
import Foundation

public struct PixelBuffer: Equatable, Sendable {
  public let width: Int
  public let height: Int
  public let linearRGB: [Float]

  public init(width: Int, height: Int, linearRGB: [Float]) {
    self.width = width
    self.height = height
    self.linearRGB = linearRGB
  }
}

public enum Diff {
  public static func makeBuffer(from image: CGImage, maxLongEdge: Int = 256) -> PixelBuffer {
    let srcW = image.width
    let srcH = image.height
    let long = max(srcW, srcH)
    let scale = long > maxLongEdge ? Double(maxLongEdge) / Double(long) : 1.0
    let dstW = max(1, Int((Double(srcW) * scale).rounded()))
    let dstH = max(1, Int((Double(srcH) * scale).rounded()))

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bytesPerRow = dstW * 4
    var rgba = [UInt8](repeating: 0, count: dstW * dstH * 4)
    let context = CGContext(
      data: &rgba,
      width: dstW,
      height: dstH,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

    let pixelCount = dstW * dstH
    var rgbNormalised = [Float](repeating: 0, count: pixelCount * 3)
    for pixel in 0..<pixelCount {
      rgbNormalised[pixel * 3 + 0] = Float(rgba[pixel * 4 + 0]) / 255
      rgbNormalised[pixel * 3 + 1] = Float(rgba[pixel * 4 + 1]) / 255
      rgbNormalised[pixel * 3 + 2] = Float(rgba[pixel * 4 + 2]) / 255
    }

    var linear = [Float](repeating: 0, count: pixelCount * 3)
    var exponent: Float = 2.2
    var count = Int32(pixelCount * 3)
    vvpowsf(&linear, &exponent, rgbNormalised, &count)
    return PixelBuffer(width: dstW, height: dstH, linearRGB: linear)
  }

  public static func score(
    baseline: PixelBuffer,
    current: PixelBuffer,
    epsilon: Float = 0.03
  ) -> Double {
    precondition(
      baseline.width == current.width && baseline.height == current.height,
      "score: buffer dimensions must match"
    )
    let pixelCount = baseline.width * baseline.height
    var changed = 0
    let eps2 = epsilon * epsilon
    baseline.linearRGB.withUnsafeBufferPointer { baselinePointer in
      current.linearRGB.withUnsafeBufferPointer { currentPointer in
        for pixel in 0..<pixelCount {
          let redDelta = currentPointer[pixel * 3 + 0] - baselinePointer[pixel * 3 + 0]
          let greenDelta = currentPointer[pixel * 3 + 1] - baselinePointer[pixel * 3 + 1]
          let blueDelta = currentPointer[pixel * 3 + 2] - baselinePointer[pixel * 3 + 2]
          if redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta > eps2 {
            changed += 1
          }
        }
      }
    }
    return Double(changed) / Double(pixelCount)
  }
}
