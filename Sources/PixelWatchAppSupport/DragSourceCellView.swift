import AppKit
import SwiftUI

// MARK: - NSViewRepresentable entry point

struct DragSourceCellView: NSViewRepresentable {
  let onClick: @MainActor () -> Void

  func makeNSView(context: Context) -> DragSourceNSView {
    let v = DragSourceNSView()
    v.onClick = onClick
    return v
  }

  func updateNSView(_ nsView: DragSourceNSView, context: Context) {
    nsView.onClick = onClick
  }
}

// MARK: - AppKit plus control

@MainActor
final class DragSourceNSView: NSView {
  var onClick: @MainActor () -> Void = {}

  private var isPressed = false

  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
    NSColor.secondaryLabelColor.withAlphaComponent(isPressed ? 0.85 : 0.65).setStroke()
    path.lineWidth = 2
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(isPressed ? 0.95 : 0.85),
    ]
    let str = NSAttributedString(string: "+", attributes: attrs)
    let size = str.size()
    str.draw(
      at: NSPoint(
        x: (bounds.width - size.width) / 2,
        y: (bounds.height - size.height) / 2
      )
    )
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let shouldClick = bounds.contains(point)
    isPressed = false
    needsDisplay = true
    if shouldClick {
      onClick()
    }
  }
}
