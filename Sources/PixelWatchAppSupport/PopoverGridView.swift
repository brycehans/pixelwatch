// Sources/PixelWatchAppSupport/PopoverGridView.swift
import SwiftUI

public struct PopoverGridView: View {
  @State var model: PopoverModel
  let onDelete: (WatcherID) -> Void
  let onArm: (WatcherID) -> Void
  let onNewWatcher: @MainActor () -> Void
  let onQuit: () -> Void

  public init(
    model: PopoverModel,
    onDelete: @escaping (WatcherID) -> Void,
    onArm: @escaping (WatcherID) -> Void,
    onNewWatcher: @escaping @MainActor () -> Void,
    onQuit: @escaping () -> Void
  ) {
    self.model = model
    self.onDelete = onDelete
    self.onArm = onArm
    self.onNewWatcher = onNewWatcher
    self.onQuit = onQuit
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        DragSourceCellView(onClick: onNewWatcher)
          .frame(width: 28, height: 28)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .shadow(color: .black.opacity(0.08), radius: 5, x: 0, y: 2)
        Spacer()
        Menu {
          Button("Quit PixelWatch", action: onQuit)
        } label: {
          Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.regularMaterial)

      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(height: 1)

      ScrollView(.vertical) {
        if model.items.isEmpty {
          EmptyPopoverView()
        } else {
          LazyVStack(spacing: 8) {
            ForEach(model.items) { item in
              WatcherRowView(
                item: item,
                onDelete: { onDelete(item.id) },
                onArm: { onArm(item.id) }
              )
            }
          }
          .padding(10)
        }
      }
      .scrollIndicators(.hidden)
    }
    .frame(width: 380)
    .background(
      LinearGradient(
        colors: [
          Color(nsColor: .windowBackgroundColor),
          Color(nsColor: .controlBackgroundColor),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    )
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
    case .idle, .armed: return false
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      ThumbnailView(buffer: item.baseline, label: "B")
        .frame(width: 50)

      StatusPillView(state: item.state)
      .frame(maxWidth: .infinity, alignment: .leading)

      ThumbnailView(buffer: item.latestFrame, label: "F")
        .frame(width: 50)

      HStack(spacing: 6) {
        if showRearm {
          Button(action: onArm) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 12, weight: .semibold))
          }
          .buttonStyle(IconButtonStyle(tint: .accentColor))
        }
        Button(action: onDelete) {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
        }
        .buttonStyle(IconButtonStyle(tint: .secondary))
      }
      .frame(width: 50, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    )
  }
}

// MARK: - Status

private struct StatusPillView: View {
  let state: WatcherState

  private var stateColor: Color {
    Color(nsColor: OverlayAppearance.borderColor(for: state))
  }

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(stateColor)
        .frame(width: 7, height: 7)
        .shadow(color: stateColor.opacity(0.35), radius: 3, x: 0, y: 0)
      Text(OverlayAppearance.labelText(for: state).uppercased())
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.primary.opacity(0.72))
        .lineLimit(1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(stateColor.opacity(0.10), in: Capsule())
    .overlay(
      Capsule()
        .strokeBorder(stateColor.opacity(0.18), lineWidth: 1)
    )
  }
}

// MARK: - Thumbnail

private struct ThumbnailView: View {
  let buffer: PixelBuffer?
  let label: String

  var body: some View {
    ZStack {
      if let nsImage = buffer?.displayImage {
        Image(nsImage: nsImage)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 50, height: 40)
          .clipped()
      } else {
        LinearGradient(
          colors: [
            Color.black.opacity(0.82),
            Color(nsColor: .controlAccentColor).opacity(0.12),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
        Image(systemName: "rectangle.dashed")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.white.opacity(0.28))
      }

      VStack {
        Spacer()
        HStack {
          Text(label)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.35), in: Capsule())
          Spacer()
        }
      }
      .padding(4)
    }
    .frame(width: 50, height: 40)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
  }
}

// MARK: - Empty

private struct EmptyPopoverView: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.3.group")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.secondary)
      Text("No watchers yet")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 30)
  }
}

// MARK: - Controls

private struct IconButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(tint)
      .frame(width: 22, height: 22)
      .background(
        tint.opacity(configuration.isPressed ? 0.18 : 0.09),
        in: Circle()
      )
      .overlay(
        Circle()
          .strokeBorder(tint.opacity(0.12), lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
  }
}
