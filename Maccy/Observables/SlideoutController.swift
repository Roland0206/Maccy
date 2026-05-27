import Defaults
import Logging
import Observation
import SwiftUI

enum SlideoutState {
  case opening
  case closing
  case open
  case closed

  var isAnimating: Bool {
    switch self {
    case .closed, .open:
      return false
    case .opening, .closing:
      return true
    }
  }

  var isOpen: Bool {
    switch self {
    case .open, .opening:
      return true
    case .closed, .closing:
      return false
    }
  }

  fileprivate func toggleWithAnimation() -> SlideoutState {
    switch self {
    case .open, .opening:
      return .closing
    case .closed, .closing:
      return .opening
    }
  }

  func animationDone() -> SlideoutState {
    switch self {
    case .open, .opening:
      return .open
    case .closed, .closing:
      return .closed
    }
  }
}

enum SlideoutPlacement {
  case left
  case right
}

enum SlideoutToggleTrigger {
  case autoOpen
  case manual
}

enum ResizingMode {
  case none
  case content
  case slideout
}

@Observable
class SlideoutController { // swiftlint:disable:this type_body_length
  let logger = Logger(label: "org.p0deje.Maccy")
  private static let animationDuration = 0.25

  let onContentResize: (CGFloat) -> Void
  let onSlideoutResize: (CGFloat) -> Void

  let minimumContentWidth: CGFloat = 200
  var contentResizeWidth: CGFloat = 0
  var contentAnimationWidth: CGFloat?

  let minimumSlideoutWidth: CGFloat = 200
  var slideoutResizeWidth: CGFloat = 0

  private var _contentWidth: CGFloat = 0
  var contentWidth: CGFloat {
    get { return _contentWidth }
    set {
      _contentWidth = max(minimumContentWidth, newValue).rounded()
      onContentResize(_contentWidth)
    }
  }
  private var _slideoutWidth: CGFloat = 400
  var slideoutWidth: CGFloat {
    get { return _slideoutWidth }
    set {
      _slideoutWidth = max(minimumSlideoutWidth, newValue).rounded()
      onSlideoutResize(_slideoutWidth)
    }
  }

  var placement: SlideoutPlacement = .right
  var state: SlideoutState = .closed
  var resizingMode: ResizingMode = .none

  var nswindow: NSWindow? {
    return AppState.shared.appDelegate?.panel
  }

  private var windowAnimationOrigin: CGPoint?
  private var windowAnimationOriginBaseState: SlideoutState = .closed

  private var autoOpenTask: Task<Void, Never>?
  private var autoOpenSuppressed = false
  private var autoOpenEnabled = true

  init(onContentResize: @escaping (CGFloat) -> Void, onSlideoutResize: @escaping (CGFloat) -> Void) {
    self.onContentResize = onContentResize
    self.onSlideoutResize = onSlideoutResize
  }

  private func togglePreviewStateWithAnimation(windowFrame: NSRect) {
    let newValue = state.toggleWithAnimation()
    if !state.isAnimating && newValue.isAnimating {
      contentAnimationWidth = contentWidth
      windowAnimationOrigin = windowFrame.origin
      windowAnimationOriginBaseState = state
    }
    state = newValue
  }

  func clampedWidths(
    contentWidth requestedContentWidth: CGFloat,
    slideoutWidth requestedSlideoutWidth: CGFloat,
    visibleWidth: CGFloat,
    state newState: SlideoutState
  ) -> (content: CGFloat, slideout: CGFloat) {
    var contentWidth = max(minimumContentWidth, requestedContentWidth)
    guard newState.isOpen else {
      return (min(contentWidth, visibleWidth).rounded(), 0)
    }

    var slideoutWidth = max(minimumSlideoutWidth, requestedSlideoutWidth)
    let maxSlideoutWidth = max(minimumSlideoutWidth, visibleWidth - contentWidth)
    slideoutWidth = min(slideoutWidth, maxSlideoutWidth)

    if contentWidth + slideoutWidth > visibleWidth {
      contentWidth = max(minimumContentWidth, visibleWidth - slideoutWidth)
    }

    return (contentWidth.rounded(), slideoutWidth.rounded())
  }

  func clampWidths(to visibleFrame: NSRect, state newState: SlideoutState) {
    let widths = clampedWidths(
      contentWidth: contentWidth,
      slideoutWidth: slideoutWidth,
      visibleWidth: visibleFrame.width,
      state: newState
    )
    contentWidth = widths.content
    if newState.isOpen {
      slideoutWidth = widths.slideout
    }
  }

  func clampedFrame(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
    var newFrame = frame
    newFrame.size.width = min(newFrame.width, visibleFrame.width)
    newFrame.size.height = min(newFrame.height, visibleFrame.height)

    if newFrame.maxX > visibleFrame.maxX {
      newFrame.origin.x = visibleFrame.maxX - newFrame.width
    }
    if newFrame.minX < visibleFrame.minX {
      newFrame.origin.x = visibleFrame.minX
    }
    if newFrame.maxY > visibleFrame.maxY {
      newFrame.origin.y = visibleFrame.maxY - newFrame.height
    }
    if newFrame.minY < visibleFrame.minY {
      newFrame.origin.y = visibleFrame.minY
    }

    return newFrame
  }

  func computePlacement(window: NSWindow, for size: NSSize) -> SlideoutPlacement {
    guard let visibleFrame = window.screen?.visibleFrame else { return placement }
    let windowFrame = window.frame
    if windowFrame.minX + size.width > visibleFrame.maxX {
      return .left
    } else {
      return .right
    }
  }

  func computeSizeWithPreview(
    _ size: NSSize,
    state newState: SlideoutState,
    visibleFrame: NSRect? = nil
  ) -> NSSize {
    var newSize = size
    if newState.isOpen {
      if let visibleFrame {
        let widths = clampedWidths(
          contentWidth: newSize.width,
          slideoutWidth: slideoutWidth,
          visibleWidth: visibleFrame.width,
          state: newState
        )
        newSize.width = widths.content + widths.slideout
      } else {
        newSize.width += slideoutWidth
      }
    } else if let visibleFrame {
      newSize.width = min(max(minimumContentWidth, newSize.width), visibleFrame.width)
    }

    let popup = AppState.shared.popup
    newSize.height = popup.preferredHeight(for: popup.height)
    if let visibleFrame {
      newSize.height = min(newSize.height, visibleFrame.height)
    }
    return newSize
  }

  private func canTogglePreview() -> Bool {
    if state.isOpen {
      return true
    }

    let navigator = AppState.shared.navigator
    return navigator.leadHistoryItem != nil || navigator.pasteStackSelected
  }

  private func updateAutoOpenSuppression(trigger: SlideoutToggleTrigger) {
    guard trigger == .manual else { return }
    autoOpenSuppressed = state.isOpen
  }

  private func previewAnimationSize(window: NSWindow, visibleFrame: NSRect?) -> NSSize {
    togglePreviewStateWithAnimation(windowFrame: window.frame)
    if let visibleFrame {
      clampWidths(to: visibleFrame, state: state)
    }

    var newSize = window.frame.size
    newSize.width = contentWidth
    newSize = computeSizeWithPreview(newSize, state: state, visibleFrame: visibleFrame)
    if state.isOpen {
      placement = computePlacement(window: window, for: newSize)
    }
    return newSize
  }

  private func previewAnimationOrigin(window: NSWindow, newSize: NSSize) -> NSPoint {
    var newOrigin = windowAnimationOrigin ?? window.frame.origin
    newOrigin.y += (window.frame.height - newSize.height)

    guard placement == .left else { return newOrigin }
    if windowAnimationOriginBaseState == .closed && state.isOpen {
      newOrigin.x -= slideoutWidth
    } else if windowAnimationOriginBaseState == .open && !state.isOpen {
      newOrigin.x += slideoutWidth
    }
    return newOrigin
  }

  private func animatePreview(
    window: NSWindow,
    newSize: NSSize,
    visibleFrame: NSRect?,
    expectedAnimationState: SlideoutState
  ) {
    NSAnimationContext.runAnimationGroup { (context) in
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      context.completionHandler = {
        if self.state == expectedAnimationState {
          self.state = expectedAnimationState.animationDone()
        }
      }
      context.duration = Self.animationDuration

      var newFrame = NSRect(
        origin: previewAnimationOrigin(window: window, newSize: newSize),
        size: newSize
      )
      if let visibleFrame {
        newFrame = clampedFrame(newFrame, to: visibleFrame)
      }
      window.animator().setFrame(newFrame, display: true)
    }
  }

  func togglePreview(trigger: SlideoutToggleTrigger = .manual) {
    guard canTogglePreview() else { return }

    updateAutoOpenSuppression(trigger: trigger)
    cancelAutoOpen()
    withAnimation(.easeInOut(duration: Self.animationDuration), completionCriteria: .removed) {
      if let window = nswindow {
        let visibleFrame = window.screen?.visibleFrame
        let newSize = previewAnimationSize(window: window, visibleFrame: visibleFrame)
        animatePreview(
          window: window,
          newSize: newSize,
          visibleFrame: visibleFrame,
          expectedAnimationState: state
        )
      }
    } completion: {
    }
  }

  func startResize(mode: ResizingMode) {
    logger.info("Starting resize with mode \(mode)")
    resizingMode = mode
    contentWidth = contentResizeWidth
    slideoutWidth = slideoutResizeWidth
  }

  func endResize() {
    logger.info("Ended resize. Mode was \(resizingMode)")
    switch resizingMode {
    case .none:
      return
    case .content:
      contentWidth = contentResizeWidth
    case .slideout:
      slideoutWidth = slideoutResizeWidth
    }
    resizingMode = .none
  }

  func startAutoOpen() {
    cancelAutoOpen()

    guard autoOpenEnabled else { return }
    guard Defaults[.autoOpenPreview] else { return }
    guard !autoOpenSuppressed else { return }
    guard !state.isOpen else { return }

    autoOpenTask = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(Defaults[.previewDelay]))
      guard !Task.isCancelled else { return }
      guard Defaults[.autoOpenPreview] else { return }

      if !state.isOpen {
        togglePreview(trigger: .autoOpen)
      }
    }
  }

  func cancelAutoOpen() {
    autoOpenTask?.cancel()
    autoOpenTask = nil
  }

  func enableAutoOpen() {
    autoOpenEnabled = true
  }

  func disableAutoOpen() {
    autoOpenEnabled = false
    cancelAutoOpen()
  }

  func resetAutoOpenSuppression() {
    autoOpenSuppressed = false
  }
}
