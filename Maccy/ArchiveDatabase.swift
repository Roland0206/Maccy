import AppKit
import CryptoKit
import Foundation
import GRDB

struct ArchiveDatabaseHealth: Equatable {
  let journalMode: String
  let synchronousMode: Int
  let foreignKeysEnabled: Bool
  let busyTimeoutMilliseconds: Int
  let autoVacuumMode: Int
  let fts5Available: Bool
  let schemaTables: [String]

  var canReadSchema: Bool {
    let requiredTables = [
      "source_apps",
      "clipboard_items",
      "clipboard_representations",
      "clipboard_search_docs",
      "pins",
      "tombstones",
    ]

    return requiredTables.allSatisfy(schemaTables.contains)
  }
}

struct ArchiveImportError: Equatable {
  let itemIndex: Int
  let contentIndex: Int?
  let reason: String
}

struct ArchiveImportReport: Equatable {
  var itemsSeen: Int
  var itemsImported = 0
  var representationsSeen = 0
  var representationsImported = 0
  var pinsImported = 0
  var searchDocumentsImported = 0
  var errors: [ArchiveImportError] = []

  var errorCount: Int { errors.count }
}

struct ArchiveRecentPageCursor: Equatable {
  let lastCopiedAt: String
  let id: Int64
}

struct ArchiveRecentPage: Equatable {
  let items: [ArchiveItemSnapshot]
  let nextCursor: ArchiveRecentPageCursor?

  var hasMore: Bool { nextCursor != nil }
}

struct ArchiveSnapshot: Equatable {
  let items: [ArchiveItemSnapshot]

  var itemCount: Int { items.count }
  var representationCount: Int { items.reduce(0) { $0 + $1.representations.count } }
  var pinCount: Int { items.filter { $0.pinKey != nil }.count }
  var searchDocumentCount: Int { items.filter { $0.searchTitle != nil || $0.searchText != nil }.count }
}

struct ArchiveItemSnapshot: Equatable, FetchableRecord {
  let id: Int64
  let sourceAppBundleIdentifier: String?
  let sourceAppName: String?
  let itemHash: String?
  let title: String?
  let firstSeenAt: String
  let lastSeenAt: String
  let changeCount: Int
  let deletedAt: String?
  let pinPosition: Int?
  let pinKey: String?
  let pinTitle: String?
  let searchTitle: String?
  let searchText: String?
  var representations: [ArchiveRepresentationSnapshot]

  init(row: Row) throws {
    id = row["id"]
    sourceAppBundleIdentifier = row["source_app_bundle_identifier"]
    sourceAppName = row["source_app_name"]
    itemHash = row["item_hash"]
    title = row["title"]
    firstSeenAt = row["first_seen_at"]
    lastSeenAt = row["last_seen_at"]
    changeCount = row["change_count"]
    deletedAt = row["deleted_at"]
    pinPosition = row["pin_position"]
    pinKey = row["pin_key"]
    pinTitle = row["pin_title"]
    searchTitle = row["search_title"]
    searchText = row["search_text"]
    representations = []
  }
}

struct ArchiveRepresentationSnapshot: Equatable, FetchableRecord {
  let itemID: Int64
  let type: String
  let value: Data
  let size: Int
  let payloadHash: String?

  init(row: Row) throws {
    itemID = row["item_id"]
    type = row["type"]
    value = row["value"]
    size = row["size"]
    payloadHash = row["payload_hash"]
  }
}

enum ArchiveDatabaseFeature {
  static let launchArgument = "--enable-archive-database"
  static let environmentVariable = "MACCY_ARCHIVE_DATABASE_ENABLED"

  static var isEnabled: Bool {
    CommandLine.arguments.contains(launchArgument) ||
      ProcessInfo.processInfo.environment[environmentVariable] == "1"
  }
}

final class ArchiveDatabase {
  static let defaultURL = URL.applicationSupportDirectory.appending(path: "Maccy/Archive.sqlite")

  private let pool: DatabasePool

  private init(pool: DatabasePool) {
    self.pool = pool
  }

  static func open(at url: URL = defaultURL) throws -> ArchiveDatabase {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
    try pool.writeWithoutTransaction { db in
      let hasSchema = try (Int.fetchOne(db, sql: Self.schemaTableCountSQL) ?? 0) > 0
      if !hasSchema {
        try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        try db.execute(sql: "VACUUM")
      }
      _ = try String.fetchOne(db, sql: "PRAGMA journal_mode = WAL")
    }
    try makeMigrator().migrate(pool)
    return ArchiveDatabase(pool: pool)
  }

  func healthCheck() throws -> ArchiveDatabaseHealth {
    try pool.write { db in
      let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")?.lowercased() ?? ""
      let synchronousMode = try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1
      let foreignKeysEnabled = (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1
      let busyTimeoutMilliseconds = try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? 0
      let autoVacuumMode = try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") ?? 0
      let schemaTables = try String.fetchAll(db, sql: Self.schemaTablesSQL)

      return ArchiveDatabaseHealth(
        journalMode: journalMode,
        synchronousMode: synchronousMode,
        foreignKeysEnabled: foreignKeysEnabled,
        busyTimeoutMilliseconds: busyTimeoutMilliseconds,
        autoVacuumMode: autoVacuumMode,
        fts5Available: Self.checkFTS5Availability(db),
        schemaTables: schemaTables
      )
    }
  }

  @MainActor
  func importLegacyHistory(from store: LegacyHistoryStore = SwiftDataHistoryStore()) throws -> ArchiveImportReport {
    let items = try store.loadAll()
    return try importLegacyHistoryItems(items)
  }

  @MainActor
  func importLegacyHistoryItems(_ items: [HistoryItem]) throws -> ArchiveImportReport {
    var report = ArchiveImportReport(itemsSeen: items.count)
    var pinPosition = 0

    try pool.write { db in
      for (itemIndex, item) in items.enumerated() {
        report.representationsSeen += item.contents.count

        do {
          try Self.insertLegacyItem(
            item,
            itemIndex: itemIndex,
            pinPosition: &pinPosition,
            report: &report,
            db: db
          )
        } catch {
          report.errors.append(ArchiveImportError(
            itemIndex: itemIndex,
            contentIndex: nil,
            reason: error.localizedDescription
          ))
        }
      }
    }

    return report
  }

  func archiveSnapshot() throws -> ArchiveSnapshot {
    try pool.read { db in
      ArchiveSnapshot(items: try Self.fetchArchiveItems(db, sql: Self.archiveItemsSQL))
    }
  }

  func firstRecentPage(limit: Int) throws -> ArchiveRecentPage {
    try fetchRecentPage(after: nil, limit: limit)
  }

  func recentPage(after cursor: ArchiveRecentPageCursor, limit: Int) throws -> ArchiveRecentPage {
    try fetchRecentPage(after: cursor, limit: limit)
  }

  func pinnedItems() throws -> [ArchiveItemSnapshot] {
    try pool.read { db in
      try Self.fetchArchiveItems(db, sql: Self.pinnedItemsSQL)
    }
  }

  func recentPageQueryPlan(limit: Int = 1) throws -> [String] {
    try pool.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "EXPLAIN QUERY PLAN \(Self.recentItemsSQL(hasCursor: false))",
        arguments: [max(limit, 1)]
      )
      return rows.map { $0["detail"] }
    }
  }

  func softDeleteItem(id: Int64, at deletedAt: Date = Date()) throws {
    try pool.write { db in
      try db.execute(
        sql: "UPDATE clipboard_items SET deleted_at = ? WHERE id = ?",
        arguments: [Self.archiveTimestamp(deletedAt), id]
      )
    }
  }

  func softDeleteUnpinnedItems(at deletedAt: Date = Date()) throws {
    try pool.write { db in
      try db.execute(
        sql: """
          UPDATE clipboard_items
          SET deleted_at = ?
          WHERE deleted_at IS NULL
            AND NOT EXISTS (
              SELECT 1
              FROM pins
              WHERE pins.item_id = clipboard_items.id
            )
        """,
        arguments: [Self.archiveTimestamp(deletedAt)]
      )
    }
  }

  func softDeleteAllItems(at deletedAt: Date = Date()) throws {
    try pool.write { db in
      try db.execute(
        sql: """
          UPDATE clipboard_items
          SET deleted_at = ?
          WHERE deleted_at IS NULL
        """,
        arguments: [Self.archiveTimestamp(deletedAt)]
      )
    }
  }

  func setPin(itemID: Int64, pin: String?, title: String?, at updatedAt: Date = Date()) throws {
    try pool.write { db in
      guard let pin, !pin.isEmpty else {
        try db.execute(sql: "DELETE FROM pins WHERE item_id = ?", arguments: [itemID])
        return
      }

      try db.execute(
        sql: """
          INSERT INTO pins (item_id, position, title, key, updated_at)
          VALUES (?, COALESCE((SELECT MAX(position) + 1 FROM pins), 0), ?, ?, ?)
          ON CONFLICT(item_id) DO UPDATE SET
            title = excluded.title,
            key = excluded.key,
            updated_at = excluded.updated_at
        """,
        arguments: [itemID, title, pin, Self.archiveTimestamp(updatedAt)]
      )
    }
  }

  private func fetchRecentPage(after cursor: ArchiveRecentPageCursor?, limit: Int) throws -> ArchiveRecentPage {
    guard limit > 0 else {
      return ArchiveRecentPage(items: [], nextCursor: nil)
    }

    let fetchLimit = limit + 1
    let arguments: StatementArguments
    if let cursor {
      arguments = [cursor.lastCopiedAt, cursor.lastCopiedAt, cursor.id, fetchLimit]
    } else {
      arguments = [fetchLimit]
    }

    return try pool.read { db in
      var items = try Self.fetchArchiveItems(
        db,
        sql: Self.recentItemsSQL(hasCursor: cursor != nil),
        arguments: arguments
      )
      let hasMore = items.count > limit
      if hasMore {
        items.removeLast()
      }
      let nextCursor = hasMore ? items.last.map {
        ArchiveRecentPageCursor(lastCopiedAt: $0.lastSeenAt, id: $0.id)
      } : nil

      return ArchiveRecentPage(items: items, nextCursor: nextCursor)
    }
  }

  private static func fetchArchiveItems(
    _ db: Database,
    sql: String,
    arguments: StatementArguments = []
  ) throws -> [ArchiveItemSnapshot] {
    var items = try ArchiveItemSnapshot.fetchAll(db, sql: sql, arguments: arguments)
    try attachRepresentations(to: &items, db: db)
    return items
  }

  private static func attachRepresentations(to items: inout [ArchiveItemSnapshot], db: Database) throws {
    guard !items.isEmpty else { return }

    let itemIDs = items.map(\.id)
    let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
    let representations = try ArchiveRepresentationSnapshot.fetchAll(
      db,
      sql: """
        SELECT item_id, type, value, size, payload_hash
        FROM clipboard_representations
        WHERE item_id IN (\(placeholders))
        ORDER BY item_id, id
        """,
      arguments: StatementArguments(itemIDs)
    )
    let representationsByItemID = Dictionary(grouping: representations, by: \.itemID)

    for index in items.indices {
      items[index].representations = representationsByItemID[items[index].id] ?? []
    }
  }

  private static func makeConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(1)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA busy_timeout = 1000")
    }
    return configuration
  }

  private static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_archive_schema", foreignKeyChecks: .immediate) { db in
      try createInitialSchema(db)
    }
    migrator.registerMigration("v2_import_metadata", foreignKeyChecks: .immediate) { db in
      if try !clipboardRepresentationsHavePayloadHash(db) {
        try db.execute(sql: "ALTER TABLE clipboard_representations ADD COLUMN payload_hash TEXT")
      }
      if try !pinsHaveKey(db) {
        try db.execute(sql: "ALTER TABLE pins ADD COLUMN key TEXT")
      }
    }
    migrator.registerMigration("v3_recent_page_indexes", foreignKeyChecks: .immediate) { db in
      try db.execute(sql: Self.recentItemsIndexSQL)
    }
    return migrator
  }

  private static func createInitialSchema(_ db: Database) throws {
    for statement in initialSchemaStatements {
      try db.execute(sql: statement)
    }
  }

  private static func insertLegacyItem(
    _ item: HistoryItem,
    itemIndex: Int,
    pinPosition: inout Int,
    report: inout ArchiveImportReport,
    db: Database
  ) throws {
    let sourceAppID = try upsertSourceApp(item.application, db: db)
    let itemID = try insertClipboardItem(item, sourceAppID: sourceAppID, db: db)

    for (contentIndex, content) in item.contents.enumerated() {
      guard let value = content.value else {
        report.errors.append(ArchiveImportError(
          itemIndex: itemIndex,
          contentIndex: contentIndex,
          reason: "HistoryItemContent value is nil"
        ))
        continue
      }

      do {
        try insertRepresentation(content, value: value, itemID: itemID, db: db)
        report.representationsImported += 1
      } catch {
        report.errors.append(ArchiveImportError(
          itemIndex: itemIndex,
          contentIndex: contentIndex,
          reason: error.localizedDescription
        ))
      }
    }

    try insertSearchDocument(for: item, itemID: itemID, db: db)
    report.searchDocumentsImported += 1

    if let pin = item.pin, !pin.isEmpty {
      try insertPin(pin, item: item, itemID: itemID, position: pinPosition, db: db)
      pinPosition += 1
      report.pinsImported += 1
    }

    report.itemsImported += 1
  }

  private static func upsertSourceApp(_ bundleIdentifier: String?, db: Database) throws -> Int64? {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
      return nil
    }

    let sourceAppName = sourceAppName(for: bundleIdentifier)
    try db.execute(
      sql: """
        INSERT INTO source_apps (bundle_identifier, name, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(bundle_identifier) DO UPDATE SET
          name = excluded.name,
          updated_at = excluded.updated_at
      """,
      arguments: [bundleIdentifier, sourceAppName, archiveTimestamp(Date())]
    )

    return try Int64.fetchOne(
      db,
      sql: "SELECT id FROM source_apps WHERE bundle_identifier = ?",
      arguments: [bundleIdentifier]
    )
  }

  private static func insertClipboardItem(_ item: HistoryItem, sourceAppID: Int64?, db: Database) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO clipboard_items (
          source_app_id,
          item_hash,
          title,
          first_seen_at,
          last_seen_at,
          change_count
        )
        VALUES (?, ?, ?, ?, ?, ?)
      """,
      arguments: [
        sourceAppID,
        itemHash(for: item.contents),
        item.title,
        archiveTimestamp(item.firstCopiedAt),
        archiveTimestamp(item.lastCopiedAt),
        item.numberOfCopies,
      ]
    )

    return db.lastInsertedRowID
  }

  private static func insertRepresentation(
    _ content: HistoryItemContent,
    value: Data,
    itemID: Int64,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO clipboard_representations (item_id, type, value, size, payload_hash)
        VALUES (?, ?, ?, ?, ?)
      """,
      arguments: [itemID, content.type, value, value.count, payloadHash(for: value)]
    )
  }

  private static func insertSearchDocument(for item: HistoryItem, itemID: Int64, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO clipboard_search_docs (item_id, title, text)
        VALUES (?, ?, ?)
      """,
      arguments: [itemID, item.title, item.previewableText]
    )
  }

  private static func insertPin(
    _ pin: String,
    item: HistoryItem,
    itemID: Int64,
    position: Int,
    db: Database
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO pins (item_id, position, title, key)
        VALUES (?, ?, ?, ?)
      """,
      arguments: [itemID, position, item.title, pin]
    )
  }

  private static func checkFTS5Availability(_ db: Database) -> Bool {
    do {
      try db.execute(sql: "CREATE VIRTUAL TABLE temp.__maccy_fts5_smoke USING fts5(content)")
      try db.execute(sql: "DROP TABLE temp.__maccy_fts5_smoke")
      return true
    } catch {
      return false
    }
  }

  private static func clipboardRepresentationsHavePayloadHash(_ db: Database) throws -> Bool {
    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('clipboard_representations')")
      .contains("payload_hash")
  }

  private static func pinsHaveKey(_ db: Database) throws -> Bool {
    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('pins')")
      .contains("key")
  }

  private static func sourceAppName(for bundleIdentifier: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
      let bundle = Bundle(url: url)
      return bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ??
        url.deletingPathExtension().lastPathComponent
    }

    if bundleIdentifier.hasSuffix(".app") {
      return URL(fileURLWithPath: bundleIdentifier).deletingPathExtension().lastPathComponent
    }

    return bundleIdentifier
  }

  private static func itemHash(for contents: [HistoryItemContent]) -> String {
    let representationHashes = contents.map { content -> (type: String, valueHash: String, value: Data) in
      let value = content.value ?? Data()
      return (content.type, payloadHash(for: value), value)
    }.sorted { lhs, rhs in
      if lhs.type == rhs.type {
        return lhs.valueHash < rhs.valueHash
      }
      return lhs.type < rhs.type
    }

    var data = Data()
    for representationHash in representationHashes {
      appendLengthPrefixed(Data(representationHash.type.utf8), to: &data)
      appendLengthPrefixed(representationHash.value, to: &data)
    }

    return payloadHash(for: data)
  }

  private static func payloadHash(for data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
  }

  private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(value)
  }

  private static func archiveTimestamp(_ date: Date) -> String {
    archiveDateFormatter.string(from: date)
  }
}

enum ArchiveDatabaseBootstrap {
  private static var database: ArchiveDatabase?

  static func bootstrapIfEnabled() {
    guard ArchiveDatabaseFeature.isEnabled else {
      return
    }

    do {
      _ = try sharedDatabase()
    } catch {
      NSLog("Maccy archive database bootstrap failed: \(error.localizedDescription)")
    }
  }

  static func popupHistoryStoreIfEnabled() -> (any PopupHistoryStore)? {
    guard ArchiveDatabaseFeature.isEnabled else {
      return nil
    }

    do {
      return ArchivePopupHistoryStore(database: try sharedDatabase())
    } catch {
      NSLog("Maccy archive popup history store failed: \(error.localizedDescription)")
      return nil
    }
  }

  private static func sharedDatabase() throws -> ArchiveDatabase {
    if let database {
      return database
    }

    let database = try ArchiveDatabase.open()
    _ = try database.healthCheck()
    Self.database = database
    return database
  }
}

private let archiveDateFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return formatter
}()

private extension ArchiveDatabase {
  static let schemaTablesSQL = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    ORDER BY name
    """

  static let schemaTableCountSQL = """
    SELECT COUNT(*)
    FROM sqlite_master
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    """

  static let archiveItemSelectSQL = """
    SELECT
      clipboard_items.id,
      source_apps.bundle_identifier AS source_app_bundle_identifier,
      source_apps.name AS source_app_name,
      clipboard_items.item_hash,
      clipboard_items.title,
      clipboard_items.first_seen_at,
      clipboard_items.last_seen_at,
      clipboard_items.change_count,
      clipboard_items.deleted_at,
      pins.position AS pin_position,
      pins.key AS pin_key,
      pins.title AS pin_title,
      clipboard_search_docs.title AS search_title,
      clipboard_search_docs.text AS search_text
    FROM clipboard_items
    LEFT JOIN source_apps ON source_apps.id = clipboard_items.source_app_id
    LEFT JOIN pins ON pins.item_id = clipboard_items.id
    LEFT JOIN clipboard_search_docs ON clipboard_search_docs.item_id = clipboard_items.id
    """

  static let archiveItemsSQL = """
    \(archiveItemSelectSQL)
    ORDER BY clipboard_items.id
    """

  static let popupArchiveItemSelectSQL = """
    SELECT
      clipboard_items.id,
      source_apps.bundle_identifier AS source_app_bundle_identifier,
      source_apps.name AS source_app_name,
      clipboard_items.item_hash,
      clipboard_items.title,
      clipboard_items.first_seen_at,
      clipboard_items.last_seen_at,
      clipboard_items.change_count,
      clipboard_items.deleted_at,
      pins.position AS pin_position,
      pins.key AS pin_key,
      pins.title AS pin_title,
      NULL AS search_title,
      NULL AS search_text
    FROM clipboard_items
    LEFT JOIN source_apps ON source_apps.id = clipboard_items.source_app_id
    LEFT JOIN pins ON pins.item_id = clipboard_items.id
    """

  static let pinnedItemsSQL = """
    \(popupArchiveItemSelectSQL)
    WHERE clipboard_items.deleted_at IS NULL
      AND pins.item_id IS NOT NULL
    ORDER BY pins.position, clipboard_items.id DESC
    """

  static let recentItemsIndexSQL = """
    CREATE INDEX IF NOT EXISTS clipboard_items_recent_not_deleted_index
    ON clipboard_items(last_seen_at DESC, id DESC)
    WHERE deleted_at IS NULL
    """

  static func recentItemsSQL(hasCursor: Bool) -> String {
    let cursorPredicate = hasCursor ? """

      AND (
        clipboard_items.last_seen_at < ?
        OR (clipboard_items.last_seen_at = ? AND clipboard_items.id < ?)
      )
    """ : ""

    return """
      \(popupArchiveItemSelectSQL)
      WHERE clipboard_items.deleted_at IS NULL
        AND NOT EXISTS (
          SELECT 1
          FROM pins
          WHERE pins.item_id = clipboard_items.id
        )\(cursorPredicate)
      ORDER BY clipboard_items.last_seen_at DESC, clipboard_items.id DESC
      LIMIT ?
      """
  }

  static let archiveRepresentationsSQL = """
    SELECT item_id, type, value, size, payload_hash
    FROM clipboard_representations
    ORDER BY item_id, id
    """

  static let initialSchemaStatements = [
    """
    CREATE TABLE source_apps (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      bundle_identifier TEXT UNIQUE,
      name TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    )
    """,
    """
    CREATE TABLE clipboard_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL UNIQUE DEFAULT (lower(hex(randomblob(16)))),
      source_app_id INTEGER,
      item_hash TEXT,
      title TEXT,
      first_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      last_seen_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      change_count INTEGER NOT NULL DEFAULT 1,
      deleted_at TEXT,
      FOREIGN KEY (source_app_id) REFERENCES source_apps(id) ON DELETE SET NULL
    )
    """,
    "CREATE INDEX clipboard_items_source_app_id_index ON clipboard_items(source_app_id)",
    "CREATE INDEX clipboard_items_last_seen_at_index ON clipboard_items(last_seen_at)",
    recentItemsIndexSQL,
    """
    CREATE TABLE clipboard_representations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      item_id INTEGER NOT NULL REFERENCES clipboard_items(id) ON DELETE CASCADE,
      type TEXT NOT NULL,
      value BLOB NOT NULL,
      size INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      UNIQUE (item_id, type)
    )
    """,
    "CREATE INDEX clipboard_representations_item_id_index ON clipboard_representations(item_id)",
    """
    CREATE VIRTUAL TABLE clipboard_search_docs USING fts5(
      item_id UNINDEXED,
      title,
      text,
      tokenize = 'unicode61'
    )
    """,
    """
    CREATE TABLE pins (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      item_id INTEGER NOT NULL UNIQUE REFERENCES clipboard_items(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      title TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    )
    """,
    "CREATE INDEX pins_position_index ON pins(position)",
    """
    CREATE TABLE tombstones (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      entity_kind TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      reason TEXT,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      UNIQUE (entity_kind, entity_id)
    )
    """,
  ]
}
