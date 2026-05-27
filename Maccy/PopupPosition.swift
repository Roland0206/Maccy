import AppKit.NSEvent
import Defaults
import Foundation

enum PopupDisplayMode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case dialog
  case sidebar

  var id: Self { self }

  var description: String {
    switch self {
    case .dialog:
      return NSLocalizedString("DisplayModeDialog", tableName: "AppearanceSettings", comment: "")
    case .sidebar:
      return NSLocalizedString("DisplayModeSidebar", tableName: "AppearanceSettings", comment: "")
    }
  }
}

enum SidebarPosition: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case left
  case right
  case top
  case bottom

  var id: Self { self }

  var description: String {
    switch self {
    case .left:
      return NSLocalizedString("SidebarPositionLeft", tableName: "AppearanceSettings", comment: "")
    case .right:
      return NSLocalizedString("SidebarPositionRight", tableName: "AppearanceSettings", comment: "")
    case .top:
      return NSLocalizedString("SidebarPositionTop", tableName: "AppearanceSettings", comment: "")
    case .bottom:
      return NSLocalizedString("SidebarPositionBottom", tableName: "AppearanceSettings", comment: "")
    }
  }

  func frame(contentSize: NSSize, visibleFrame: NSRect, size: SidebarSize) -> NSRect {
    let width = min(contentSize.width, visibleFrame.width)
    let height = min(contentSize.height, visibleFrame.height)

    switch self {
    case .left:
      let frameHeight = size == .fillAvailableSpace ? visibleFrame.height : height
      return NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: width, height: frameHeight)
    case .right:
      let frameHeight = size == .fillAvailableSpace ? visibleFrame.height : height
      return NSRect(x: visibleFrame.maxX - width, y: visibleFrame.minY, width: width, height: frameHeight)
    case .top:
      let frameWidth = size == .fillAvailableSpace ? visibleFrame.width : width
      return NSRect(x: visibleFrame.minX, y: visibleFrame.maxY - height, width: frameWidth, height: height)
    case .bottom:
      let frameWidth = size == .fillAvailableSpace ? visibleFrame.width : width
      return NSRect(x: visibleFrame.minX, y: visibleFrame.minY, width: frameWidth, height: height)
    }
  }
}

enum SidebarSize: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case fitContent
  case fillAvailableSpace

  var id: Self { self }

  var description: String {
    switch self {
    case .fitContent:
      return NSLocalizedString("SidebarSizeFitContent", tableName: "AppearanceSettings", comment: "")
    case .fillAvailableSpace:
      return NSLocalizedString("SidebarSizeFillAvailableSpace", tableName: "AppearanceSettings", comment: "")
    }
  }
}

enum PopupPosition: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case cursor
  case statusItem
  case window
  case center
  case lastPosition

  var id: Self { self }

  var description: String {
    switch self {
    case .cursor:
      return NSLocalizedString("PopupAtCursor", tableName: "AppearanceSettings", comment: "")
    case .statusItem:
      return NSLocalizedString("PopupAtMenuBarIcon", tableName: "AppearanceSettings", comment: "")
    case .window:
      return NSLocalizedString("PopupAtWindowCenter", tableName: "AppearanceSettings", comment: "")
    case .center:
      return NSLocalizedString("PopupAtScreenCenter", tableName: "AppearanceSettings", comment: "")
    case .lastPosition:
      return NSLocalizedString("PopupAtLastPosition", tableName: "AppearanceSettings", comment: "")
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func origin(size: NSSize, statusBarButton: NSStatusBarButton?) -> NSPoint {
    switch self {
    case .center:
      if let frame = NSScreen.forPopup?.visibleFrame {
        return NSRect.centered(ofSize: size, in: frame).origin
      }
    case .window:
      if let frame = NSWorkspace.shared.frontmostApplication?.windowFrame {
        return NSRect.centered(ofSize: size, in: frame).origin
      }
    case .statusItem:
      if let statusBarButton, let screen = NSScreen.main {
        let rectInWindow = statusBarButton.convert(statusBarButton.bounds, to: nil)
        if let screenRect = statusBarButton.window?.convertToScreen(rectInWindow) {
          var topLeftPoint = NSPoint(x: screenRect.minX, y: screenRect.minY - size.height)
          // Ensure that window doesn't spill over to the right screen.
          if (topLeftPoint.x + size.width) > screen.frame.maxX {
            topLeftPoint.x = screen.frame.maxX - size.width
          }

          return topLeftPoint
        }
      }
    case .lastPosition:
      if let frame = NSScreen.forPopup?.visibleFrame {
        let relativePos = Defaults[.windowPosition]
        let anchorX = frame.minX + frame.width * relativePos.x
        let anchorY = frame.minY + frame.height * relativePos.y
        // Anchor is top middle of frame
        return NSPoint(x: anchorX - size.width / 2, y: anchorY - size.height)
      }
    default:
      break
    }

    var point = NSEvent.mouseLocation
    point.y -= size.height
    return point
  }
}
