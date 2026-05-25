import Foundation
import XCTest
@testable import Maccy

final class ArchiveDatabaseTests: XCTestCase {
  private var tempDirectory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDirectory = FileManager.default.temporaryDirectory
      .appending(path: "MaccyArchiveDatabaseTests")
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDirectory {
      try? FileManager.default.removeItem(at: tempDirectory)
    }
    tempDirectory = nil
    try super.tearDownWithError()
  }

  func testOpenMigratesTempDatabaseAndReportsHealthyPragmas() throws {
    let databaseURL = tempDirectory.appending(path: "Archive.sqlite")
    let database = try ArchiveDatabase.open(at: databaseURL)

    let health = try database.healthCheck()

    XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    XCTAssertEqual(health.journalMode, "wal")
    XCTAssertEqual(health.synchronousMode, 1)
    XCTAssertTrue(health.foreignKeysEnabled)
    XCTAssertEqual(health.busyTimeoutMilliseconds, 1000)
    XCTAssertEqual(health.autoVacuumMode, 2)
    XCTAssertTrue(health.canReadSchema)
  }

  func testInitialSchemaUsesAppOwnedTables() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let health = try database.healthCheck()

    XCTAssertTrue(health.schemaTables.contains("source_apps"))
    XCTAssertTrue(health.schemaTables.contains("clipboard_items"))
    XCTAssertTrue(health.schemaTables.contains("clipboard_representations"))
    XCTAssertTrue(health.schemaTables.contains("clipboard_search_docs"))
    XCTAssertTrue(health.schemaTables.contains("pins"))
    XCTAssertTrue(health.schemaTables.contains("tombstones"))
    XCTAssertTrue(health.schemaTables.contains("grdb_migrations"))
    XCTAssertFalse(health.schemaTables.contains { $0.hasPrefix("Z") })
  }

  func testFTS5CapabilitySmokeTest() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let health = try database.healthCheck()

    XCTAssertTrue(health.fts5Available)
  }
}
