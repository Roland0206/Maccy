import XCTest
import AppKit
@testable import Maccy

class ColorImageTests: XCTestCase {
  func testColorImageFromShortHex() {
    XCTAssertNotNil(ColorImage.from("fff"))
  }

  func testColorFromFullHex() {
    XCTAssertNotNil(ColorImage.from("#ff8942"))
  }

  func testColorFromNotHex() {
    XCTAssertNil(ColorImage.from("foo"))
  }
}

class SlideoutControllerLayoutTests: XCTestCase {
  func testClampedWidthsShrinksSlideoutBeforeContent() {
    let controller = SlideoutController(onContentResize: { _ in }, onSlideoutResize: { _ in })

    let widths = controller.clampedWidths(
      contentWidth: 300,
      slideoutWidth: 700,
      visibleWidth: 800,
      state: .open
    )

    XCTAssertEqual(widths.content, 300)
    XCTAssertEqual(widths.slideout, 500)
    XCTAssertEqual(widths.content + widths.slideout, 800)
  }

  func testClampedWidthsKeepsContentAboveMinimumWhenBothWidthsAreTooLarge() {
    let controller = SlideoutController(onContentResize: { _ in }, onSlideoutResize: { _ in })

    let widths = controller.clampedWidths(
      contentWidth: 450,
      slideoutWidth: 400,
      visibleWidth: 500,
      state: .open
    )

    XCTAssertGreaterThanOrEqual(widths.content, controller.minimumContentWidth)
    XCTAssertEqual(widths.content + widths.slideout, 500)
  }

  func testClampedFrameStaysInsideVisibleFrame() {
    let controller = SlideoutController(onContentResize: { _ in }, onSlideoutResize: { _ in })
    let visibleFrame = NSRect(x: 10, y: 20, width: 1000, height: 800)
    let frame = NSRect(x: 800, y: 700, width: 300, height: 200)

    XCTAssertEqual(
      controller.clampedFrame(frame, to: visibleFrame),
      NSRect(x: 710, y: 620, width: 300, height: 200)
    )
  }
}

class SidebarPositionTests: XCTestCase {
  let visibleFrame = NSRect(x: 10, y: 20, width: 1000, height: 800)
  let contentSize = NSSize(width: 300, height: 200)

  func testLeftSidebarFrameFitsContent() {
    XCTAssertEqual(
      SidebarPosition.left.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fitContent),
      NSRect(x: 10, y: 20, width: 300, height: 200)
    )
  }

  func testRightSidebarFrameFitsContent() {
    XCTAssertEqual(
      SidebarPosition.right.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fitContent),
      NSRect(x: 710, y: 20, width: 300, height: 200)
    )
  }

  func testTopSidebarFrameFitsContent() {
    XCTAssertEqual(
      SidebarPosition.top.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fitContent),
      NSRect(x: 10, y: 620, width: 300, height: 200)
    )
  }

  func testBottomSidebarFrameFitsContent() {
    XCTAssertEqual(
      SidebarPosition.bottom.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fitContent),
      NSRect(x: 10, y: 20, width: 300, height: 200)
    )
  }

  func testLeftSidebarFrameFillsVisibleHeight() {
    XCTAssertEqual(
      SidebarPosition.left.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fillAvailableSpace),
      NSRect(x: 10, y: 20, width: 300, height: 800)
    )
  }

  func testRightSidebarFrameFillsVisibleHeight() {
    XCTAssertEqual(
      SidebarPosition.right.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fillAvailableSpace),
      NSRect(x: 710, y: 20, width: 300, height: 800)
    )
  }

  func testTopSidebarFrameFillsVisibleWidth() {
    XCTAssertEqual(
      SidebarPosition.top.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fillAvailableSpace),
      NSRect(x: 10, y: 620, width: 1000, height: 200)
    )
  }

  func testBottomSidebarFrameFillsVisibleWidth() {
    XCTAssertEqual(
      SidebarPosition.bottom.frame(contentSize: contentSize, visibleFrame: visibleFrame, size: .fillAvailableSpace),
      NSRect(x: 10, y: 20, width: 1000, height: 200)
    )
  }
}
