import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int
  var shouldLoadMoreRecentRowsOnAppear = false

  private var visualIndex: Int? {
    if appState.navigator.isMultiSelectInProgress && item.selectionIndex >= 0 {
      return item.selectionIndex
    }
    return nil
  }

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.autoOpenPreview) private var autoOpenPreview
  @Environment(AppState.self) private var appState

  private var inlinePinVisible: Bool {
    return item.isSelected && !autoOpenPreview
  }

  private var inlinePinAction: AnyView? {
    guard inlinePinVisible else { return nil }

    return AnyView(
      ToolbarButton {
        withAnimation {
          appState.history.togglePin(item)
        }
      } label: {
        Image(systemName: item.isPinned ? "pin.slash" : "pin")
      }
      .shortcutKeyHelp(
        name: .pin,
        key: item.isPinned ? "UnpinKey" : "PinKey",
        tableName: "PreviewItemView",
        replacementKey: "pinKey"
      )
    )
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : ColorImage.from(item.title),
      attributedTitle: item.attributedTitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: visualIndex,
      selectionAppearance: selectionAppearance,
      trailingAction: inlinePinAction
    ) {
      Text(verbatim: item.title)
    }
    .onAppear {
      item.ensureThumbnailImage()
      guard shouldLoadMoreRecentRowsOnAppear else { return }

      Task {
        await appState.history.loadMoreRecentRowsIfNeeded(after: item)
      }
    }
    .onTapGesture {
      if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
        appState.navigator.addToSelection(item: item)
      } else {
        Task {
          appState.history.select(item)
        }
      }
    }
  }
}
