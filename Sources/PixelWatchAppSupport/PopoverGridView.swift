// Sources/PixelWatchAppSupport/PopoverGridView.swift
import SwiftUI

private let cellWidth: CGFloat = 120
private let cellHeight: CGFloat = 96
private let labelHeight: CGFloat = 18
private let borderWidth: CGFloat = 3
private let gridSpacing: CGFloat = 10

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onDelete: (WatcherID) -> Void
  let onDrop: @MainActor (CGPoint) -> Void
  let onDragStarted: @MainActor () -> Void
  let onQuit: () -> Void

  public init(
    model: PopoverModel,
    onDelete: @escaping (WatcherID) -> Void,
    onDrop: @escaping @MainActor (CGPoint) -> Void,
    onDragStarted: @escaping @MainActor () -> Void = {},
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.onDelete = onDelete
    self.onDrop = onDrop
    self.onDragStarted = onDragStarted
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: cellWidth), spacing: gridSpacing)],
          spacing: gridSpacing
        ) {
          ForEach(model.items) { item in
            ThumbnailCellView(item: item, onDelete: { onDelete(item.id) })
          }
          DragSourceCellView(
            onDrop: onDrop,
            onDragStarted: onDragStarted
          )
          .frame(width: cellWidth, height: cellHeight)
        }
        .padding(gridSpacing)
        if model.items.isEmpty {
          Text("No watchers yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.bottom, gridSpacing)
        }
      }

      Divider()

      HStack {
        Spacer()
        Menu {
          Button("Quit PixelWatch", action: onQuit)
        } label: {
          Image(systemName: "gearshape").imageScale(.medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(8)
      }
    }
    .frame(width: 380)
  }
}

private struct ThumbnailCellView: View {
  let item: WatcherThumbnailItem
  let onDelete: () -> Void

  var body: some View {
    ZStack(alignment: .topTrailing) {
      VStack(spacing: 0) {
        Text(OverlayAppearance.labelText(for: item.state))
          .font(.system(size: 11))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: labelHeight, maxHeight: labelHeight)
          .background(Color.black.opacity(0.65))

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

      Button(action: onDelete) {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.white)
          .shadow(radius: 1)
      }
      .buttonStyle(.plain)
      .padding(4)
    }
    .frame(width: cellWidth, height: cellHeight)
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }
}
