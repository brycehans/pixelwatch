// Sources/PixelWatchAppSupport/PopoverGridView.swift
import SwiftUI

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onDelete: (WatcherID) -> Void
  let onArm: (WatcherID) -> Void
  let onDrop: @MainActor (CGPoint) -> Void
  let onDragStarted: @MainActor () -> Void
  let onQuit: () -> Void

  public init(
    model: PopoverModel,
    onDelete: @escaping (WatcherID) -> Void,
    onArm: @escaping (WatcherID) -> Void,
    onDrop: @escaping @MainActor (CGPoint) -> Void,
    onDragStarted: @escaping @MainActor () -> Void = {},
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.onDelete = onDelete
    self.onArm = onArm
    self.onDrop = onDrop
    self.onDragStarted = onDragStarted
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        if model.items.isEmpty {
          Text("No watchers yet")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else {
          LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
              WatcherRowView(
                item: item,
                onDelete: { onDelete(item.id) },
                onArm: { onArm(item.id) }
              )
              if item.id != model.items.last?.id {
                Divider()
                  .padding(.leading, 12)
              }
            }
          }
        }
      }

      Divider()

      HStack {
        DragSourceCellView(onDrop: onDrop, onDragStarted: onDragStarted)
          .frame(width: 28, height: 28)
          .padding(.leading, 8)
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

// MARK: - Row

private struct WatcherRowView: View {
  let item: WatcherThumbnailItem
  let onDelete: () -> Void
  let onArm: () -> Void

  var showRearm: Bool {
    switch item.state {
    case .triggered, .errored: return true
    default: return false
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      // Col 1: baseline thumbnail
      ThumbnailView(buffer: item.baseline)
        .frame(width: 50)

      // Col 2: status dot + state label
      HStack(spacing: 6) {
        Circle()
          .fill(Color(nsColor: OverlayAppearance.borderColor(for: item.state)))
          .frame(width: 8, height: 8)
        Text(OverlayAppearance.labelText(for: item.state))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)

      // Col 3: latest-frame thumbnail
      ThumbnailView(buffer: item.latestFrame)
        .frame(width: 50)

      // Col 4: action icons
      HStack(spacing: 4) {
        if showRearm {
          Button(action: onArm) {
            Image(systemName: "arrow.clockwise")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
        Button(action: onDelete) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
      .frame(width: 44)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
  }
}

// MARK: - Thumbnail

private struct ThumbnailView: View {
  let buffer: PixelBuffer?

  var body: some View {
    ZStack {
      Color.black
      if let nsImage = buffer?.displayImage {
        Image(nsImage: nsImage)
          .resizable()
          .scaledToFill()
      }
    }
    .frame(width: 50, height: 40)
    .clipped()
    .cornerRadius(3)
    .overlay(
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
    )
  }
}
