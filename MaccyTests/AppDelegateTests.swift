import XCTest
import AppKit
import Defaults
@testable import Maccy

@MainActor
class AppDelegateTerminationTests: XCTestCase {
  let savedClearOnQuit = Defaults[.clearOnQuit]

  override func tearDown() {
    Defaults[.clearOnQuit] = savedClearOnQuit
    super.tearDown()
  }

  func testClearOnQuitClearsHistoryOnNormalQuit() {
    Defaults[.clearOnQuit] = true
    let delegate = AppDelegate()

    XCTAssertTrue(delegate.shouldClearHistoryOnTerminate)
  }

  func testClearOnQuitDoesNotClearHistoryDuringSystemPowerOff() {
    Defaults[.clearOnQuit] = true
    let delegate = AppDelegate()

    delegate.workspaceWillPowerOff(Notification(name: NSWorkspace.willPowerOffNotification))

    XCTAssertFalse(delegate.shouldClearHistoryOnTerminate)
  }
}
