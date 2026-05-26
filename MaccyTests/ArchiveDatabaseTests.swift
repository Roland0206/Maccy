import AppKit
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

  @MainActor
  func testImportsLegacyTextItemWithMetadataPinHashesAndSearchDocument() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let item = historyItem(
      title: "Pinned note",
      contents: [content(.string, "hello archive".data(using: .utf8)!)]
    )
    item.application = "com.example.TextEditor"
    item.firstCopiedAt = Date(timeIntervalSince1970: 100)
    item.lastCopiedAt = Date(timeIntervalSince1970: 200)
    item.numberOfCopies = 7
    item.pin = "f"
    let store = RecordingLegacyHistoryStore(items: [item])

    let report = try database.importLegacyHistory(from: store)
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.itemsSeen, 1)
    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 1)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(report.pinsImported, 1)
    XCTAssertEqual(report.searchDocumentsImported, 1)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(store.loadAllCallCount, 1)
    XCTAssertEqual(store.deleteCallCount, 0)
    XCTAssertEqual(store.deleteAllCallCount, 0)

    let archivedItem = try XCTUnwrap(snapshot.items.first)
    XCTAssertEqual(archivedItem.sourceAppBundleIdentifier, "com.example.TextEditor")
    XCTAssertEqual(archivedItem.sourceAppName, "com.example.TextEditor")
    XCTAssertEqual(archivedItem.title, "Pinned note")
    XCTAssertEqual(archivedItem.firstSeenAt, "1970-01-01T00:01:40.000Z")
    XCTAssertEqual(archivedItem.lastSeenAt, "1970-01-01T00:03:20.000Z")
    XCTAssertEqual(archivedItem.changeCount, 7)
    XCTAssertEqual(archivedItem.pinPosition, 0)
    XCTAssertEqual(archivedItem.pinKey, "f")
    XCTAssertEqual(archivedItem.pinTitle, "Pinned note")
    XCTAssertEqual(archivedItem.searchTitle, "Pinned note")
    XCTAssertEqual(archivedItem.searchText, "hello archive")
    XCTAssertNotNil(archivedItem.itemHash)

    let representation = try XCTUnwrap(archivedItem.representations.first)
    XCTAssertEqual(representation.type, NSPasteboard.PasteboardType.string.rawValue)
    XCTAssertEqual(representation.value, "hello archive".data(using: .utf8))
    XCTAssertEqual(representation.size, 13)
    XCTAssertNotNil(representation.payloadHash)
  }

  @MainActor
  func testImportsRTFHTMLImageAndFileURLRepresentations() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let rtfData = try XCTUnwrap(NSAttributedString(string: "rich text").rtf(
      from: NSRange(location: 0, length: 9),
      documentAttributes: [:]
    ))
    let htmlData = try XCTUnwrap("<strong>web text</strong>".data(using: .utf8))
    let imageData = try XCTUnwrap(imageData())
    let fileURLData = URL(fileURLWithPath: "/tmp/archive.txt").dataRepresentation
    let item = historyItem(
      title: "Mixed item",
      contents: [
        content(.rtf, rtfData),
        content(.html, htmlData),
        content(.png, imageData),
        content(.fileURL, fileURLData),
      ]
    )

    let report = try database.importLegacyHistoryItems([item])
    let archivedItem = try XCTUnwrap(database.archiveSnapshot().items.first)

    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsImported, 4)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(Set(archivedItem.representations.map(\.type)), Set([
      NSPasteboard.PasteboardType.rtf.rawValue,
      NSPasteboard.PasteboardType.html.rawValue,
      NSPasteboard.PasteboardType.png.rawValue,
      NSPasteboard.PasteboardType.fileURL.rawValue,
    ]))
    XCTAssertEqual(representation(.rtf, in: archivedItem)?.value, rtfData)
    XCTAssertEqual(representation(.html, in: archivedItem)?.value, htmlData)
    XCTAssertEqual(representation(.png, in: archivedItem)?.value, imageData)
    XCTAssertEqual(representation(.fileURL, in: archivedItem)?.value, fileURLData)
    XCTAssertTrue(archivedItem.representations.allSatisfy { $0.payloadHash != nil })
  }

  @MainActor
  func testImportReportsNilContentErrorsWithoutDroppingLegacyRows() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let item = historyItem(
      title: "Partial item",
      contents: [
        HistoryItemContent(type: NSPasteboard.PasteboardType.string.rawValue, value: nil),
        content(.html, "<p>kept</p>".data(using: .utf8)!),
      ]
    )
    let store = RecordingLegacyHistoryStore(items: [item])

    let report = try database.importLegacyHistory(from: store)
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.itemsSeen, 1)
    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 2)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(report.errorCount, 1)
    XCTAssertEqual(report.errors.first?.contentIndex, 0)
    XCTAssertEqual(snapshot.itemCount, 1)
    XCTAssertEqual(snapshot.representationCount, 1)
    XCTAssertEqual(store.items.count, 1)
    XCTAssertEqual(store.deleteCallCount, 0)
    XCTAssertEqual(store.deleteAllCallCount, 0)
  }

  @MainActor
  func testRecentPagesUseStableKeysetCursorWhileNewRowsExist() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Oldest", text: "oldest", lastCopiedAt: 100),
      historyItem(title: "Middle", text: "middle", lastCopiedAt: 200),
      historyItem(title: "Newest", text: "newest", lastCopiedAt: 300),
    ])

    let firstPage = try database.firstRecentPage(limit: 2)
    let cursor = try XCTUnwrap(firstPage.nextCursor)
    try database.importLegacyHistoryItems([
      historyItem(title: "Newer", text: "newer", lastCopiedAt: 400),
      historyItem(title: "Same Time New ID", text: "same", lastCopiedAt: 200),
    ])

    let nextPage = try database.recentPage(after: cursor, limit: 2)

    XCTAssertEqual(itemTitles(firstPage.items), ["Newest", "Middle"])
    XCTAssertTrue(firstPage.hasMore)
    XCTAssertEqual(itemTitles(nextPage.items), ["Oldest"])
    XCTAssertFalse(nextPage.hasMore)
    XCTAssertEqual(nextPage.items.first?.representations.count, 1)
  }

  @MainActor
  func testPinnedItemsAreLoadedSeparatelyFromRecentUnpinnedItems() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Pinned", text: "pinned", lastCopiedAt: 300, pin: "p"),
      historyItem(title: "Recent", text: "recent", lastCopiedAt: 200),
      historyItem(title: "Deleted Recent", text: "deleted", lastCopiedAt: 500),
      historyItem(title: "Deleted Pinned", text: "deleted pinned", lastCopiedAt: 400, pin: "r"),
    ])
    let snapshot = try database.archiveSnapshot()
    try database.softDeleteItem(id: itemID(titled: "Deleted Recent", in: snapshot))
    try database.softDeleteItem(id: itemID(titled: "Deleted Pinned", in: snapshot))

    let pinnedItems = try database.pinnedItems()
    let recentPage = try database.firstRecentPage(limit: 10)

    XCTAssertEqual(itemTitles(pinnedItems), ["Pinned"])
    XCTAssertEqual(pinnedItems.first?.pinKey, "p")
    XCTAssertEqual(itemTitles(recentPage.items), ["Recent"])
    XCTAssertFalse(recentPage.hasMore)
  }

  func testRecentPageQueryPlanUsesRecentIndex() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))

    let plan = try database.recentPageQueryPlan()

    XCTAssertTrue(
      plan.contains { $0.contains("clipboard_items_recent_not_deleted_index") },
      plan.joined(separator: "\n")
    )
  }

  @MainActor
  func testArchivePopupHistoryStoreLoadsPinnedAndFirstRecentPage() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Pinned", text: "pinned", lastCopiedAt: 300, pin: "p"),
      historyItem(title: "Older", text: "older", lastCopiedAt: 100),
      historyItem(title: "Newest", text: "newest", lastCopiedAt: 200),
    ])
    let store = ArchivePopupHistoryStore(database: database)

    let page = try store.loadInitialRows(recentLimit: 1)

    XCTAssertEqual(page.pinnedRows.map(\.title), ["Pinned"])
    XCTAssertEqual(page.recentRows.map(\.title), ["Newest"])
    XCTAssertEqual(page.rows.count, 2)
    XCTAssertEqual(page.pinnedRows.first?.source, .archive(id: 1))
    XCTAssertEqual(page.pinnedRows.first?.pin, "p")
    XCTAssertEqual(page.recentRows.first?.contents, [
      PopupHistoryRowContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        size: 6,
        hasPayload: true
      )
    ])
  }

  @MainActor
  func testArchivePopupHistoryStoreLoadsMoreRecentRowsAfterInitialCursor() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Oldest", text: "oldest", lastCopiedAt: 100),
      historyItem(title: "Middle", text: "middle", lastCopiedAt: 200),
      historyItem(title: "Newest", text: "newest", lastCopiedAt: 300),
    ])
    let store = ArchivePopupHistoryStore(database: database)
    let firstPage = try store.loadInitialRows(recentLimit: 2)
    let cursor = try XCTUnwrap(firstPage.nextRecentCursor)

    let nextPage = try store.loadMoreRecentRows(after: cursor, limit: 2)

    XCTAssertEqual(firstPage.recentRows.map(\.title), ["Newest", "Middle"])
    XCTAssertEqual(nextPage.rows.map(\.title), ["Oldest"])
    XCTAssertNil(nextPage.nextCursor)
  }

  @MainActor
  func testArchivePopupHistoryStoreMaterializesPayloadForSelection() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Materialized", text: "payload", lastCopiedAt: 200, pin: "m"),
    ])
    let store = ArchivePopupHistoryStore(database: database)
    let row = try XCTUnwrap(store.loadInitialRows(recentLimit: 1).pinnedRows.first)

    let item = try store.materialize(row)

    XCTAssertEqual(item.title, "Materialized")
    XCTAssertEqual(item.text, "payload")
    XCTAssertEqual(item.pin, "m")
    XCTAssertEqual(item.numberOfCopies, 1)
    XCTAssertEqual(item.firstCopiedAt, Date(timeIntervalSince1970: 199))
    XCTAssertEqual(item.lastCopiedAt, Date(timeIntervalSince1970: 200))
  }

  @MainActor
  func testArchivePopupHistoryStoreDeletesVisibleRows() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Delete me", text: "delete", lastCopiedAt: 200),
      historyItem(title: "Keep me", text: "keep", lastCopiedAt: 100),
    ])
    let store = ArchivePopupHistoryStore(database: database)
    let row = try XCTUnwrap(store.loadInitialRows(recentLimit: 10).recentRows.first)

    try store.delete(row)

    XCTAssertEqual(try database.firstRecentPage(limit: 10).items.map(\.title), ["Keep me"])
    XCTAssertNotNil(try database.archiveSnapshot().items.first { $0.title == "Delete me" }?.deletedAt)
  }

  @MainActor
  func testArchivePopupHistoryStorePinsAndUnpinsVisibleRows() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Pin me", text: "pin", lastCopiedAt: 200),
    ])
    let store = ArchivePopupHistoryStore(database: database)
    let row = try XCTUnwrap(store.loadInitialRows(recentLimit: 10).recentRows.first)

    try store.setPin(row, pin: "p")
    XCTAssertEqual(try database.pinnedItems().compactMap(\.pinKey), ["p"])
    XCTAssertEqual(try database.firstRecentPage(limit: 10).items, [])

    try store.setPin(row, pin: nil)
    XCTAssertEqual(try database.pinnedItems(), [])
    XCTAssertEqual(try database.firstRecentPage(limit: 10).items.map(\.title), ["Pin me"])
  }

  private func historyItem(title: String, contents: [HistoryItemContent]) -> HistoryItem {
    let item = HistoryItem(contents: contents)
    item.title = title
    return item
  }

  private func historyItem(
    title: String,
    text: String,
    lastCopiedAt: TimeInterval,
    pin: String? = nil
  ) -> HistoryItem {
    let item = historyItem(
      title: title,
      contents: [content(.string, Data(text.utf8))]
    )
    item.firstCopiedAt = Date(timeIntervalSince1970: lastCopiedAt - 1)
    item.lastCopiedAt = Date(timeIntervalSince1970: lastCopiedAt)
    item.pin = pin
    return item
  }

  private func itemTitles(_ items: [ArchiveItemSnapshot]) -> [String] {
    items.map { $0.title ?? "" }
  }

  private func itemID(titled title: String, in snapshot: ArchiveSnapshot) throws -> Int64 {
    try XCTUnwrap(snapshot.items.first { $0.title == title }?.id)
  }

  private func content(_ type: NSPasteboard.PasteboardType, _ value: Data) -> HistoryItemContent {
    HistoryItemContent(type: type.rawValue, value: value)
  }

  private func imageData() -> Data? {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 2,
      pixelsHigh: 2,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
    return rep?.representation(using: .png, properties: [:])
  }

  private func representation(
    _ type: NSPasteboard.PasteboardType,
    in item: ArchiveItemSnapshot
  ) -> ArchiveRepresentationSnapshot? {
    item.representations.first { $0.type == type.rawValue }
  }
}

@MainActor
private final class RecordingLegacyHistoryStore: LegacyHistoryStore {
  private(set) var items: [HistoryItem]
  private(set) var loadAllCallCount = 0
  private(set) var deleteCallCount = 0
  private(set) var deleteAllCallCount = 0

  init(items: [HistoryItem]) {
    self.items = items
  }

  func loadAll() throws -> [HistoryItem] {
    loadAllCallCount += 1
    return items
  }

  func loadDuplicateCandidates(for item: HistoryItem) throws -> [HistoryItem] {
    items.filter { $0 !== item }
  }

  func insert(_ item: HistoryItem) throws {
    items.append(item)
  }

  func delete(_ item: HistoryItem) throws {
    deleteCallCount += 1
    items.removeAll { $0 === item }
  }

  func deleteUnpinned() throws {
    items.removeAll { $0.pin == nil }
  }

  func deleteAll() throws {
    deleteAllCallCount += 1
    items.removeAll()
  }

  func countItems() throws -> Int {
    items.count
  }

  func countContents() throws -> Int {
    items.reduce(0) { $0 + $1.contents.count }
  }
}
