import AppKit
import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  func body(content: Content) -> some View {
    content
      .onHover { hovering in
        guard hovering else { return }
        selectIfHoverIsUserDriven()
      }
      .onContinuousHover { phase in
        guard case .active = phase else { return }
        selectIfHoverIsUserDriven()
      }
  }

  private func selectIfHoverIsUserDriven() {
    guard shouldUpdateSelectionFromCurrentEvent else { return }

    let navigator = appState.navigator
    if !navigator.isKeyboardNavigating && !navigator.isMultiSelectInProgress {
      navigator.selectWithoutScrolling(id: id)
    } else if navigator.hoverSelectionWhileKeyboardNavigating != id {
      navigator.hoverSelectionWhileKeyboardNavigating = id
    }
  }

  private var shouldUpdateSelectionFromCurrentEvent: Bool {
    guard let event = NSApp.currentEvent else {
      return true
    }

    switch event.type {
    case .scrollWheel, .gesture, .magnify, .smartMagnify, .rotate, .swipe:
      return false
    default:
      return true
    }
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
