import AppKit
import Defaults
import Foundation
import XCTest
@testable import Maccy

final class ArchiveDatabaseTests: XCTestCase {
  private var tempDirectory: URL!
  private let savedEnabledPasteboardTypes = Defaults[.enabledPasteboardTypes]
  private let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
  private let savedIgnoredApps = Defaults[.ignoredApps]
  private let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]
  private let savedIgnoreRegexp = Defaults[.ignoreRegexp]

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
    Defaults[.enabledPasteboardTypes] = savedEnabledPasteboardTypes
    Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
    Defaults[.ignoredApps] = savedIgnoredApps
    Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
    Defaults[.ignoreRegexp] = savedIgnoreRegexp
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
    XCTAssertTrue(health.schemaTables.contains("clipboard_search_documents"))
    XCTAssertTrue(health.schemaTables.contains("clipboard_search_docs"))
    XCTAssertTrue(health.schemaTables.contains("pins"))
    XCTAssertTrue(health.schemaTables.contains("tombstones"))
    XCTAssertTrue(health.schemaTables.contains("grdb_migrations"))
    XCTAssertFalse(health.schemaTables.contains { $0.hasPrefix("Z") })
  }

  func testRepresentationSchemaIncludesHybridPayloadMetadata() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let columns = try database.representationColumnNames()

    XCTAssertTrue(columns.contains("payload_hash"))
    XCTAssertTrue(columns.contains("storage_kind"))
    XCTAssertTrue(columns.contains("relative_path"))
  }

  func testPayloadStoreWritesContentAddressedFilesByHash() throws {
    let store = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let data = Data("external payload seam".utf8)

    let firstPayload = try store.write(data)
    let secondPayload = try store.write(data)
    let fileURL = store.fileURL(forRelativePath: firstPayload.relativePath)

    XCTAssertEqual(firstPayload, secondPayload)
    XCTAssertEqual(firstPayload.byteCount, data.count)
    XCTAssertEqual(firstPayload.relativePath, "\(firstPayload.hash.prefix(2))/\(firstPayload.hash)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertEqual(try store.read(relativePath: firstPayload.relativePath), data)
  }

  @MainActor
  func testImportsSmallPayloadInlineWhenWithinThreshold() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 10
    )
    let data = Data("small".utf8)

    let report = try database.importLegacyHistoryItems([
      historyItem(title: "Small", contents: [content(.string, data)]),
    ])
    let representation = try XCTUnwrap(database.archiveSnapshot().items.first?.representations.first)

    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(representation.storageKind, .inline)
    XCTAssertEqual(representation.value, data)
    XCTAssertEqual(representation.size, data.count)
    XCTAssertNil(representation.relativePath)
    XCTAssertEqual(try payloadFileCount(in: payloadStore.rootDirectory), 0)
  }

  @MainActor
  func testImportsLargePayloadExternallyWhenAboveThreshold() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 4
    )
    let data = Data("large payload".utf8)

    let report = try database.importLegacyHistoryItems([
      historyItem(title: "Large", contents: [content(.string, data)]),
    ])
    let representation = try XCTUnwrap(database.archiveSnapshot().items.first?.representations.first)
    let relativePath = try XCTUnwrap(representation.relativePath)

    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(representation.storageKind, .external)
    XCTAssertEqual(representation.value, data)
    XCTAssertEqual(representation.size, data.count)
    XCTAssertEqual(representation.payloadHash, ArchivePayloadStore.payloadHash(for: data))
    XCTAssertEqual(relativePath, ArchivePayloadStore.relativePath(forHash: ArchivePayloadStore.payloadHash(for: data)))
    XCTAssertEqual(try payloadStore.read(relativePath: relativePath), data)
  }

  @MainActor
  func testListQueriesLoadRepresentationMetadataWithoutPayloadBytes() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 10
    )
    let smallData = Data("small".utf8)
    let largeData = Data("large payload".utf8)

    try database.importLegacyHistoryItems([
      historyItem(title: "Pinned Large", contents: [content(.string, largeData)], pin: "p"),
      historyItem(title: "Recent Small", contents: [content(.string, smallData)]),
    ])

    let pinnedRepresentation = try XCTUnwrap(database.pinnedItems().first?.representations.first)
    let recentRepresentation = try XCTUnwrap(database.firstRecentPage(limit: 10).items.first?.representations.first)

    XCTAssertEqual(pinnedRepresentation.storageKind, .external)
    XCTAssertEqual(pinnedRepresentation.value, Data())
    XCTAssertEqual(pinnedRepresentation.size, largeData.count)
    XCTAssertTrue(pinnedRepresentation.hasPayload)
    XCTAssertEqual(recentRepresentation.storageKind, .inline)
    XCTAssertEqual(recentRepresentation.value, Data())
    XCTAssertEqual(recentRepresentation.size, smallData.count)
    XCTAssertTrue(recentRepresentation.hasPayload)
  }

  @MainActor
  func testArchivePopupHistoryStoreMaterializesExternalPayloadForSelection() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let data = Data("materialized external payload".utf8)
    try database.importLegacyHistoryItems([
      historyItem(title: "External", contents: [content(.string, data)]),
    ])
    let store = ArchivePopupHistoryStore(database: database)
    let row = try XCTUnwrap(store.loadInitialRows(recentLimit: 1).recentRows.first)

    let item = try store.materialize(row)

    XCTAssertEqual(item.contents.first?.value, data)
    XCTAssertEqual(item.text, String(data: data, encoding: .utf8))
  }

  @MainActor
  func testMissingExternalPayloadFileThrowsExplicitError() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let data = Data("missing external payload".utf8)
    try database.importLegacyHistoryItems([
      historyItem(title: "Missing", contents: [content(.string, data)]),
    ])
    let snapshot = try database.archiveSnapshot()
    let itemID = try XCTUnwrap(snapshot.items.first?.id)
    let relativePath = try XCTUnwrap(snapshot.items.first?.representations.first?.relativePath)
    try FileManager.default.removeItem(at: payloadStore.fileURL(forRelativePath: relativePath))

    XCTAssertThrowsError(try database.item(id: itemID)) { error in
      XCTAssertEqual(error as? ArchivePayloadStoreError, .missingExternalFile(relativePath: relativePath))
    }
  }

  @MainActor
  func testImportDeduplicatesExternalPayloadFilesByHash() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let data = Data("shared large payload".utf8)

    let report = try database.importLegacyHistoryItems([
      historyItem(title: "First", contents: [content(.string, data)]),
      historyItem(title: "Second", contents: [content(.string, data)]),
    ])
    let representations = try database.archiveSnapshot().items.flatMap(\.representations)

    XCTAssertEqual(report.representationsImported, 2)
    XCTAssertEqual(Set(representations.map(\.storageKind)), [.external])
    XCTAssertEqual(Set(representations.compactMap(\.relativePath)).count, 1)
    XCTAssertEqual(try payloadFileCount(in: payloadStore.rootDirectory), 1)
  }

  @MainActor
  func testFindsExternalPayloadFilesNotReferencedByArchive() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    _ = try database.importLegacyHistoryItems([
      historyItem(
        title: "Referenced",
        contents: [content(.string, Data("referenced payload".utf8))]
      ),
    ])
    let orphanData = Data("orphan payload".utf8)
    let orphan = try payloadStore.write(orphanData)

    let orphans = try database.orphanedExternalPayloadFiles()

    XCTAssertEqual(orphans, [
      ArchivePayloadFile(relativePath: orphan.relativePath, byteCount: orphanData.count),
    ])
  }

  @MainActor
  func testCleanupRemovesOnlyUnreferencedExternalPayloadFiles() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let referencedData = Data("referenced payload".utf8)
    _ = try database.importLegacyHistoryItems([
      historyItem(title: "Referenced", contents: [content(.string, referencedData)]),
    ])
    let referencedPath = try XCTUnwrap(database.archiveSnapshot().items.first?.representations.first?.relativePath)
    let orphanData = Data("orphan payload".utf8)
    let orphan = try payloadStore.write(orphanData)

    let deleted = try database.cleanupOrphanedExternalPayloadFiles()

    XCTAssertEqual(deleted, [
      ArchivePayloadFile(relativePath: orphan.relativePath, byteCount: orphanData.count),
    ])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: payloadStore.fileURL(forRelativePath: orphan.relativePath).path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: payloadStore.fileURL(forRelativePath: referencedPath).path
    ))
    XCTAssertEqual(try database.orphanedExternalPayloadFiles(), [])
  }

  @MainActor
  func testPermanentDeleteCleansExternalPayloadAfterLastReferenceIsRemoved() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let sharedData = Data("shared delete payload".utf8)
    _ = try database.importLegacyHistoryItems([
      historyItem(title: "First", contents: [content(.string, sharedData)]),
      historyItem(title: "Second", contents: [content(.string, sharedData)]),
    ])
    let snapshot = try database.archiveSnapshot()
    let firstID = try itemID(titled: "First", in: snapshot)
    let secondID = try itemID(titled: "Second", in: snapshot)
    let relativePath = try XCTUnwrap(snapshot.items.first?.representations.first?.relativePath)

    XCTAssertEqual(try database.deleteItemPermanently(id: firstID), [])
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: payloadStore.fileURL(forRelativePath: relativePath).path
    ))

    let deleted = try database.deleteItemPermanently(id: secondID)

    XCTAssertEqual(deleted, [ArchivePayloadFile(relativePath: relativePath, byteCount: sharedData.count)])
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: payloadStore.fileURL(forRelativePath: relativePath).path
    ))
  }

  @MainActor
  func testRetentionDeletesExpiredRepresentationsButKeepsRetainedText() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let imagePayload = Data("expired image payload".utf8)
    try database.importLegacyHistoryItems([
      historyItem(
        title: "Mixed",
        contents: [
          content(.string, Data("kept text".utf8)),
          content(.png, imagePayload),
        ],
        lastCopiedAt: 100
      ),
    ])
    let imagePath = try XCTUnwrap(database.archiveSnapshot().items.first?.representations.first {
      $0.type == NSPasteboard.PasteboardType.png.rawValue
    }?.relativePath)

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        plainText: .forever,
        images: .sevenDays,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60),
      batchLimit: 10
    )
    let item = try XCTUnwrap(database.archiveSnapshot().items.first)

    XCTAssertEqual(report.expiredRepresentationsDeleted, 1)
    XCTAssertEqual(report.expiredItemsSoftDeleted, 0)
    XCTAssertNil(item.deletedAt)
    XCTAssertEqual(item.representations.map(\.type), [NSPasteboard.PasteboardType.string.rawValue])
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "kept"), [item.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: payloadStore.fileURL(forRelativePath: imagePath).path))
  }

  @MainActor
  func testRetentionPurgesExpiredRepresentationSearchDocumentsAndRebuildsIndex() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(
        title: "Binary Holder",
        contents: [
          content(.string, Data("secret token".utf8)),
          content(.png, Data("retained image".utf8)),
        ],
        lastCopiedAt: 100
      ),
    ])
    let itemID = try XCTUnwrap(database.archiveSnapshot().items.first?.id)
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "secret"), [itemID])

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        plainText: .sevenDays,
        images: .forever,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60),
      batchLimit: 10
    )
    let item = try XCTUnwrap(database.archiveSnapshot().items.first)

    XCTAssertEqual(report.expiredRepresentationsDeleted, 1)
    XCTAssertEqual(report.expiredItemsSoftDeleted, 0)
    XCTAssertNil(item.deletedAt)
    XCTAssertEqual(item.representations.map(\.type), [NSPasteboard.PasteboardType.png.rawValue])
    XCTAssertNil(item.searchTitle)
    XCTAssertNil(item.searchText)
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "secret"), [])
  }

  @MainActor
  func testRetentionSoftDeletesItemsWhenAllRepresentationsExpireAndWritesTombstone() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Expired", text: "expired", lastCopiedAt: 100),
    ])

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        plainText: .sevenDays,
        tombstones: .forever,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60),
      batchLimit: 10
    )
    let item = try XCTUnwrap(database.archiveSnapshot().items.first)
    let tombstone = try XCTUnwrap(database.tombstones().first)

    XCTAssertEqual(report.expiredRepresentationsDeleted, 1)
    XCTAssertEqual(report.expiredItemsSoftDeleted, 1)
    XCTAssertNotNil(item.deletedAt)
    XCTAssertEqual(tombstone.entityKind, "clipboard_item")
    XCTAssertEqual(tombstone.entityID, String(item.id))
    XCTAssertEqual(tombstone.reason, "retention_expired")
  }

  @MainActor
  func testRetentionExemptsPinnedItems() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Pinned", text: "pinned", lastCopiedAt: 100, pin: "p"),
    ])

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        plainText: .sevenDays,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60),
      batchLimit: 10
    )
    let item = try XCTUnwrap(database.archiveSnapshot().items.first)

    XCTAssertEqual(report.expiredRepresentationsDeleted, 0)
    XCTAssertEqual(report.expiredItemsSoftDeleted, 0)
    XCTAssertNil(item.deletedAt)
    XCTAssertEqual(item.representations.count, 1)
  }

  @MainActor
  func testRetentionSoftDeletesItemsOverMaximumCount() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Oldest", text: "oldest", lastCopiedAt: 100),
      historyItem(title: "Pinned Old", text: "pinned", lastCopiedAt: 150, pin: "p"),
      historyItem(title: "Middle", text: "middle", lastCopiedAt: 200),
      historyItem(title: "Newest", text: "newest", lastCopiedAt: 300),
    ])

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        maximumItemCount: 2,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 400),
      batchLimit: 10
    )
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.countLimitedItemsSoftDeleted, 1)
    XCTAssertNotNil(snapshot.items.first { $0.title == "Oldest" }?.deletedAt)
    XCTAssertNil(snapshot.items.first { $0.title == "Middle" }?.deletedAt)
    XCTAssertNil(snapshot.items.first { $0.title == "Newest" }?.deletedAt)
    XCTAssertNil(snapshot.items.first { $0.title == "Pinned Old" }?.deletedAt)
  }

  @MainActor
  func testRetentionPhysicallyDeletesExpiredTombstonesAndCleansPayloads() throws {
    let payloadStore = ArchivePayloadStore(rootDirectory: tempDirectory.appending(path: "Payloads"))
    let database = try ArchiveDatabase.open(
      at: tempDirectory.appending(path: "Archive.sqlite"),
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: 1
    )
    let payload = Data("deleted external payload".utf8)
    try database.importLegacyHistoryItems([
      historyItem(title: "Deleted", contents: [content(.string, payload)]),
    ])
    let snapshot = try database.archiveSnapshot()
    let itemID = try XCTUnwrap(snapshot.items.first?.id)
    let relativePath = try XCTUnwrap(snapshot.items.first?.representations.first?.relativePath)
    try database.softDeleteItem(id: itemID, at: Date(timeIntervalSince1970: 100))

    let report = try database.performRetentionMaintenance(
      configuration: ArchiveRetentionConfiguration(
        tombstones: .sevenDays,
        vacuumPageCount: 0
      ),
      now: Date(timeIntervalSince1970: 100 + 8 * 24 * 60 * 60),
      batchLimit: 10
    )

    XCTAssertEqual(report.tombstonedItemsPhysicallyDeleted, 1)
    XCTAssertEqual(report.externalPayloadsDeleted, [ArchivePayloadFile(relativePath: relativePath, byteCount: payload.count)])
    XCTAssertEqual(try database.archiveSnapshot().items, [])
    XCTAssertEqual(try database.tombstones(), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: payloadStore.fileURL(forRelativePath: relativePath).path))
  }

  func testArchiveMaintenanceSchedulerInstallsRecurringTimer() {
    let scheduler = ArchiveMaintenanceScheduler()

    XCTAssertFalse(scheduler.isScheduled)
    scheduler.start(interval: 60) {}
    XCTAssertTrue(scheduler.isScheduled)
    scheduler.stop()
    XCTAssertFalse(scheduler.isScheduled)
  }

  func testArchiveMaintenanceSchedulerSkipsOverlappingRuns() {
    let scheduler = ArchiveMaintenanceScheduler()
    var reentrantWasSkipped = false

    let outerRan = scheduler.runOnceIfIdle {
      reentrantWasSkipped = !scheduler.runOnceIfIdle {}
    }
    let laterRan = scheduler.runOnceIfIdle {}

    XCTAssertTrue(outerRan)
    XCTAssertTrue(reentrantWasSkipped)
    XCTAssertTrue(laterRan)
  }

  func testFTS5CapabilitySmokeTest() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let health = try database.healthCheck()

    XCTAssertTrue(health.fts5Available)
  }

  func testSearchIndexUsesExternalContentUnicodeAndPrefixOptions() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let health = try database.healthCheck()
    let definition = try XCTUnwrap(database.searchIndexDefinition())

    XCTAssertTrue(health.schemaTables.contains("clipboard_search_documents"))
    XCTAssertTrue(definition.contains("content='clipboard_search_documents'"), definition)
    XCTAssertTrue(definition.contains("content_rowid='item_id'"), definition)
    XCTAssertTrue(definition.contains("unicode61 remove_diacritics 1"), definition)
    XCTAssertTrue(definition.contains("prefix='2 3 4'"), definition)
  }

  @MainActor
  func testSearchIndexMatchesInsertedDocumentsWithPrefixAndDiacriticFolding() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Café Archive", text: "résumé searchable", lastCopiedAt: 100),
      historyItem(title: "Other", text: "unrelated", lastCopiedAt: 200),
    ])
    let itemID = try itemID(titled: "Café Archive", in: database.archiveSnapshot())

    XCTAssertEqual(try database.searchIndexItemIDs(matching: "cafe"), [itemID])
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "arch*"), [itemID])
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "resume"), [itemID])
  }

  @MainActor
  func testSearchIndexUpdateDeleteAndRebuildStayInSync() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Original", text: "oldtoken", lastCopiedAt: 100),
    ])
    let itemID = try itemID(titled: "Original", in: database.archiveSnapshot())

    try database.replaceSearchDocument(itemID: itemID, title: "Updated", text: "newtoken")
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "oldtoken"), [])
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "newtoken"), [itemID])

    try database.deleteSearchDocument(itemID: itemID)
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "newtoken"), [])

    try database.replaceSearchDocument(itemID: itemID, title: "Rebuilt", text: "rebuiltneedle")
    try database.rebuildSearchIndex()
    XCTAssertEqual(try database.searchIndexItemIDs(matching: "rebuiltneedle"), [itemID])
  }

  @MainActor
  func testArchiveSearchExactAndPrefixReturnBoundedPages() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Alpha Archive", text: "common token", lastCopiedAt: 100),
      historyItem(title: "Beta Archive", text: "common token", lastCopiedAt: 200),
      historyItem(title: "Gamma Archive", text: "common token", lastCopiedAt: 300),
      historyItem(title: "Deleted Archive", text: "common token", lastCopiedAt: 400),
      historyItem(title: "Alphabet Soup", text: "prefix token", lastCopiedAt: 500),
    ])
    let deletedID = try itemID(titled: "Deleted Archive", in: database.archiveSnapshot())
    try database.softDeleteItem(id: deletedID)

    let firstPage = try database.search(ArchiveSearchRequest(query: "archive", mode: .exact, limit: 2))
    let nextOffset = try XCTUnwrap(firstPage.nextOffset)
    let secondPage = try database.search(ArchiveSearchRequest(
      query: "archive",
      mode: .exact,
      limit: 2,
      offset: nextOffset
    ))
    let exactPrefixPage = try database.search(ArchiveSearchRequest(query: "alph", mode: .exact, limit: 10))
    let prefixPage = try database.search(ArchiveSearchRequest(query: "alph", mode: .prefix, limit: 10))

    XCTAssertEqual(itemTitles(firstPage.items), ["Gamma Archive", "Beta Archive"])
    XCTAssertTrue(firstPage.hasMore)
    XCTAssertEqual(itemTitles(secondPage.items), ["Alpha Archive"])
    XCTAssertFalse(secondPage.hasMore)
    XCTAssertEqual(exactPrefixPage.items, [])
    XCTAssertEqual(itemTitles(prefixPage.items), ["Alphabet Soup", "Alpha Archive"])
    XCTAssertTrue(firstPage.items.allSatisfy { $0.representations.isEmpty })
  }

  @MainActor
  func testArchiveSearchFuzzyAndRegexPostFilterBoundedCandidates() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    try database.importLegacyHistoryItems([
      historyItem(title: "Regex Match Target", text: "older", lastCopiedAt: 100),
      historyItem(title: "Archive Cancellation", text: "middle", lastCopiedAt: 200),
      historyItem(title: "Recent Noise", text: "newer", lastCopiedAt: 300),
    ])

    let fuzzyPage = try database.search(ArchiveSearchRequest(
      query: "Arcive",
      mode: .fuzzy,
      limit: 10,
      candidateLimit: 2
    ))
    let boundedFuzzyPage = try database.search(ArchiveSearchRequest(
      query: "Arcive",
      mode: .fuzzy,
      limit: 10,
      candidateLimit: 1
    ))
    let regexPage = try database.search(ArchiveSearchRequest(
      query: "Regex.*Target",
      mode: .regexp,
      limit: 10,
      candidateLimit: 3
    ))
    let boundedRegexPage = try database.search(ArchiveSearchRequest(
      query: "Regex.*Target",
      mode: .regexp,
      limit: 10,
      candidateLimit: 2
    ))
    let invalidRegexPage = try database.search(ArchiveSearchRequest(
      query: "[",
      mode: .regexp,
      limit: 10,
      candidateLimit: 3
    ))

    XCTAssertEqual(itemTitles(fuzzyPage.items), ["Archive Cancellation"])
    XCTAssertEqual(boundedFuzzyPage.items, [])
    XCTAssertEqual(itemTitles(regexPage.items), ["Regex Match Target"])
    XCTAssertEqual(boundedRegexPage.items, [])
    XCTAssertEqual(invalidRegexPage.items, [])
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
    XCTAssertEqual(representation.storageKind, .inline)
    XCTAssertNil(representation.relativePath)
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
  func testImportSkipsLegacyItemsWithPrivacyPasteboardMarkers() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let markerItems = NSPasteboard.PasteboardType.privacyMarkerTypes.enumerated().map { index, type in
      historyItem(
        title: "Ignored marker \(index)",
        contents: [
          content(.string, Data("secret \(index)".utf8)),
          content(type, Data()),
        ]
      )
    }
    let keptItem = historyItem(title: "Kept", contents: [content(.string, Data("kept".utf8))])

    let report = try database.importLegacyHistoryItems(markerItems + [keptItem])
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.itemsSeen, 4)
    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 7)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(itemTitles(snapshot.items), ["Kept"])
    XCTAssertTrue(snapshot.items.flatMap(\.representations).allSatisfy { representation in
      !NSPasteboard.PasteboardType.privacyMarkerTypes.contains(NSPasteboard.PasteboardType(representation.type))
    })
  }

  @MainActor
  func testImportSkipsLegacyItemsFromIgnoredApplications() throws {
    Defaults[.ignoredApps] = ["com.example.SecretApp"]
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let ignoredItem = historyItem(title: "Secret", contents: [content(.string, Data("secret".utf8))])
    ignoredItem.application = "com.example.SecretApp"
    let keptItem = historyItem(title: "Kept", contents: [content(.string, Data("kept".utf8))])
    keptItem.application = "com.example.Editor"

    let report = try database.importLegacyHistoryItems([ignoredItem, keptItem])
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.itemsSeen, 2)
    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 2)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(itemTitles(snapshot.items), ["Kept"])
  }

  @MainActor
  func testImportSkipsLegacyItemsWithIgnoredPasteboardTypes() throws {
    let ignoredType = NSPasteboard.PasteboardType(rawValue: "org.maccy.SecretType")
    Defaults[.ignoredPasteboardTypes] = [ignoredType.rawValue]
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let ignoredItem = historyItem(
      title: "Ignored type",
      contents: [
        content(.string, Data("secret".utf8)),
        content(ignoredType, Data("marker".utf8)),
      ]
    )
    let keptItem = historyItem(title: "Kept", contents: [content(.string, Data("kept".utf8))])

    let report = try database.importLegacyHistoryItems([ignoredItem, keptItem])
    let snapshot = try database.archiveSnapshot()

    XCTAssertEqual(report.itemsSeen, 2)
    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 3)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(itemTitles(snapshot.items), ["Kept"])
  }

  @MainActor
  func testImportDropsDisabledRepresentationsBeforeArchiving() throws {
    Defaults[.enabledPasteboardTypes] = [.string]
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    let item = historyItem(
      title: "Mixed",
      contents: [
        content(.string, Data("kept".utf8)),
        content(.png, Data("image".utf8)),
      ]
    )

    let report = try database.importLegacyHistoryItems([item])
    let archivedItem = try XCTUnwrap(database.archiveSnapshot().items.first)

    XCTAssertEqual(report.itemsImported, 1)
    XCTAssertEqual(report.representationsSeen, 2)
    XCTAssertEqual(report.representationsImported, 1)
    XCTAssertEqual(archivedItem.representations.map(\.type), [NSPasteboard.PasteboardType.string.rawValue])
    XCTAssertEqual(archivedItem.searchText, "kept")
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

  @MainActor
  func testArchivePopupHistoryStoreDeletesUnpinnedRowsForClear() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    _ = try database.importLegacyHistoryItems([
      historyItem(title: "Pinned", text: "pinned", lastCopiedAt: 300, pin: "p"),
      historyItem(title: "Recent", text: "recent", lastCopiedAt: 200),
      historyItem(title: "Older", text: "older", lastCopiedAt: 100),
    ])
    let store = ArchivePopupHistoryStore(database: database)

    try store.deleteUnpinned()

    XCTAssertEqual(try database.pinnedItems().map(\.title), ["Pinned"])
    XCTAssertEqual(try database.firstRecentPage(limit: 10).items, [])
    let snapshot = try database.archiveSnapshot()
    XCTAssertNil(snapshot.items.first { $0.title == "Pinned" }?.deletedAt)
    XCTAssertNotNil(snapshot.items.first { $0.title == "Recent" }?.deletedAt)
    XCTAssertNotNil(snapshot.items.first { $0.title == "Older" }?.deletedAt)
  }

  @MainActor
  func testArchivePopupHistoryStoreDeletesAllRowsForClearAll() throws {
    let database = try ArchiveDatabase.open(at: tempDirectory.appending(path: "Archive.sqlite"))
    _ = try database.importLegacyHistoryItems([
      historyItem(title: "Pinned", text: "pinned", lastCopiedAt: 300, pin: "p"),
      historyItem(title: "Recent", text: "recent", lastCopiedAt: 200),
    ])
    let store = ArchivePopupHistoryStore(database: database)

    try store.deleteAll()

    XCTAssertEqual(try database.pinnedItems(), [])
    XCTAssertEqual(try database.firstRecentPage(limit: 10).items, [])
    XCTAssertTrue(try database.archiveSnapshot().items.allSatisfy { $0.deletedAt != nil })
  }

  private func historyItem(
    title: String,
    contents: [HistoryItemContent],
    lastCopiedAt: TimeInterval? = nil,
    pin: String? = nil
  ) -> HistoryItem {
    let item = HistoryItem(contents: contents)
    item.title = title
    if let lastCopiedAt {
      item.firstCopiedAt = Date(timeIntervalSince1970: lastCopiedAt - 1)
      item.lastCopiedAt = Date(timeIntervalSince1970: lastCopiedAt)
    }
    item.pin = pin
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

  private func payloadFileCount(in directory: URL) throws -> Int {
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
      return 0
    }

    var count = 0
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == false {
        count += 1
      }
    }
    return count
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
