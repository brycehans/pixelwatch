import CoreGraphics

public enum DrawSelection {
  public static let minimumSize = CGSize(width: 8, height: 8)

  public static func rect(from start: CGPoint, to end: CGPoint, clampedTo bounds: CGRect) -> CGRect {
    let raw = CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
    let minX = max(bounds.minX, raw.minX)
    let minY = max(bounds.minY, raw.minY)
    let maxX = min(bounds.maxX, raw.maxX)
    let maxY = min(bounds.maxY, raw.maxY)
    return CGRect(
      x: minX,
      y: minY,
      width: max(0, maxX - minX),
      height: max(0, maxY - minY)
    )
  }

  public static func isValid(_ rect: CGRect) -> Bool {
    rect.width >= minimumSize.width && rect.height >= minimumSize.height
  }
}
