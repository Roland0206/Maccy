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
