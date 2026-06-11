// Sources/PixelWatchAppSupport/DragSourceCellView.swift
import AppKit
import SwiftUI

private let dragThreshold: CGFloat = 5
private let dropSquareSize = CGSize(width: 120, height: 96)

// MARK: - NSViewRepresentable entry point

struct DragSourceCellView: NSViewRepresentable {
  let onDrop: @MainActor (CGPoint) -> Void
  let onDragStarted: @MainActor () -> Void

  func makeNSView(context: Context) -> DragSourceNSView {
    let v = DragSourceNSView()
    v.onDrop = onDrop
    v.onDragStarted = onDragStarted
    return v
  }

  func updateNSView(_ nsView: DragSourceNSView, context: Context) {
    nsView.onDrop = onDrop
    nsView.onDragStarted = onDragStarted
  }
}

// MARK: - AppKit drag source view

@MainActor
final class DragSourceNSView: NSView {
  var onDrop: @MainActor (CGPoint) -> Void = { _ in }
  var onDragStarted: @MainActor () -> Void = {}

  private var dragStartPoint: CGPoint?
  private var isDragging = false
  private var floatingPanel: NSPanel?
  private var trackingTimer: Timer?
  private var mouseUpMonitor: Any?

  override var acceptsFirstResponder: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    // Hide in-grid visual while dragging — the floating panel IS the square.
    guard !isDragging else { return }

    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
    NSColor.secondaryLabelColor.setStroke()
    path.lineWidth = 3
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28),
      .foregroundColor: NSColor.secondaryLabelColor,
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
    dragStartPoint = convert(event.locationInWindow, from: nil)
    isDragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = dragStartPoint, !isDragging else { return }
    let current = convert(event.locationInWindow, from: nil)
    let dx = current.x - start.x
    let dy = current.y - start.y
    guard sqrt(dx * dx + dy * dy) >= dragThreshold else { return }
    startDrag()
  }

  override func mouseUp(with event: NSEvent) {
    NSLog("[DRAG] mouseUp isDragging=%d loc=%@", isDragging ? 1 : 0, NSStringFromPoint(NSEvent.mouseLocation))
    if isDragging {
      endDrag(at: NSEvent.mouseLocation)
    }
    dragStartPoint = nil
  }

  private func startDrag() {
    isDragging = true
    needsDisplay = true  // blank the in-grid cell; floating panel becomes the square
    onDragStarted()
    showFloatingPanel(at: NSEvent.mouseLocation)

    trackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isDragging else { return }
        self.floatingPanel?.setFrameOrigin(
          NSPoint(
            x: NSEvent.mouseLocation.x - dropSquareSize.width / 2,
            y: NSEvent.mouseLocation.y - dropSquareSize.height / 2
          )
        )
      }
    }

    mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
      MainActor.assumeIsolated {
        NSLog("[DRAG] globalMonitor leftMouseUp isDragging=%d loc=%@",
              self?.isDragging == true ? 1 : 0, NSStringFromPoint(NSEvent.mouseLocation))
        guard let self, self.isDragging else { return }
        self.endDrag(at: NSEvent.mouseLocation)
      }
    }
  }

  private func endDrag(at screenPoint: CGPoint) {
    // Guard de-dups: mouseUp (local) and the global .leftMouseUp monitor can both
    // fire for the same release event when the cursor leaves our window during drag.
    NSLog("[DRAG] endDrag called screenPoint=%@ isDragging=%d", NSStringFromPoint(screenPoint), isDragging ? 1 : 0)
    guard isDragging else {
      NSLog("[DRAG] endDrag: already not dragging, returning")
      return
    }
    isDragging = false
    dragStartPoint = nil

    trackingTimer?.invalidate()
    trackingTimer = nil

    if let monitor = mouseUpMonitor {
      NSEvent.removeMonitor(monitor)
      mouseUpMonitor = nil
    }

    NSLog("[DRAG] closing floatingPanel, then calling onDrop at %@", NSStringFromPoint(screenPoint))
    floatingPanel?.close()
    floatingPanel = nil

    needsDisplay = true  // restore the in-grid cell
    onDrop(screenPoint)
    NSLog("[DRAG] onDrop returned")
  }

  private func showFloatingPanel(at origin: CGPoint) {
    let panel = NSPanel(
      contentRect: NSRect(
        x: origin.x - dropSquareSize.width / 2,
        y: origin.y - dropSquareSize.height / 2,
        width: dropSquareSize.width,
        height: dropSquareSize.height
      ),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false

    let contentView = DragFloatVisualView(frame: NSRect(origin: .zero, size: dropSquareSize))
    panel.contentView = contentView
    panel.orderFront(nil)
    floatingPanel = panel
  }
}

// MARK: - Floating panel visual

@MainActor
private final class DragFloatVisualView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let inset = bounds.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 4, yRadius: 4)
    NSColor.secondaryLabelColor.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 3
    path.stroke()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.85),
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
}
