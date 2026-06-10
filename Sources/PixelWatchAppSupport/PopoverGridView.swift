// Sources/PixelWatchAppSupport/PopoverGridView.swift
import AppKit
import SwiftUI

private let cellWidth: CGFloat = 120
private let cellHeight: CGFloat = 96
private let labelHeight: CGFloat = 18
private let borderWidth: CGFloat = 3
private let gridSpacing: CGFloat = 10

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onAdd: () -> Void
  let onQuit: () -> Void

  public init(model: PopoverModel, onAdd: @escaping () -> Void, onQuit: @escaping () -> Void) {
    self.model = model
    self.onAdd = onAdd
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if model.items.isEmpty {
          Text("No watchers yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding()
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: cellWidth), spacing: gridSpacing)],
            spacing: gridSpacing
          ) {
            ForEach(model.items) { item in
              ThumbnailCellView(item: item)
            }
            AddCellView(onAdd: onAdd)
          }
          .padding(gridSpacing)
        }
      }

      Divider()

      HStack {
        Spacer()
        Button(action: showQuitMenu) {
          Image(systemName: "gearshape")
            .imageScale(.medium)
        }
        .buttonStyle(.plain)
        .padding(8)
      }
    }
    .frame(width: 380)
  }

  @MainActor
  private func showQuitMenu() {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(
      title: "Quit PixelWatch",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    ))
    if let event = NSApp.currentEvent {
      NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
    }
  }
}

private struct ThumbnailCellView: View {
  let item: WatcherThumbnailItem

  var body: some View {
    VStack(spacing: 0) {
      // Label strip
      Text(OverlayAppearance.labelText(for: item.state))
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: labelHeight, maxHeight: labelHeight)
        .background(Color.black.opacity(0.65))

      // Image area with border
      ZStack {
        Color.black
        if let nsImage = item.latestFrame?.displayImage {
          Image(nsImage: nsImage)
            .resizable()
            .scaledToFill()
            .clipped()
        }
      }
      .frame(width: cellWidth, height: cellHeight - labelHeight)
      .overlay(
        RoundedRectangle(cornerRadius: 0)
          .strokeBorder(
            Color(nsColor: OverlayAppearance.borderColor(for: item.state)),
            lineWidth: borderWidth
          )
      )
    }
    .frame(width: cellWidth, height: cellHeight)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}

private struct AddCellView: View {
  let onAdd: () -> Void

  var body: some View {
    Button(action: onAdd) {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(Color.secondary, lineWidth: borderWidth)
        Text("+")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
      }
      .frame(width: cellWidth, height: cellHeight)
    }
    .buttonStyle(.plain)
  }
}
