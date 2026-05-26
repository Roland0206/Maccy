import AppKit
import CryptoKit
import Defaults
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
      "clipboard_search_documents",
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

enum ArchiveSearchMode: Equatable {
  case exact
  case prefix
  case fuzzy
  case regexp
  case mixed
}

struct ArchiveSearchRequest: Equatable {
  let query: String
  let mode: ArchiveSearchMode
  let limit: Int
  let offset: Int
  let candidateLimit: Int

  init(
    query: String,
    mode: ArchiveSearchMode,
    limit: Int,
    offset: Int = 0,
    candidateLimit: Int = 500
  ) {
    self.query = query
    self.mode = mode
    self.limit = limit
    self.offset = offset
    self.candidateLimit = candidateLimit
  }
}

struct ArchiveSearchPage: Equatable {
  let items: [ArchiveItemSnapshot]
  let nextOffset: Int?

  var hasMore: Bool { nextOffset != nil }
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

enum ArchivePayloadStorageKind: String, Hashable {
  case inline
  case external
}

enum ArchivePayloadStoreError: LocalizedError, Equatable {
  case missingExternalPath(type: String)
  case missingExternalFile(relativePath: String)

  var errorDescription: String? {
    switch self {
    case .missingExternalPath(let type):
      return "External payload path is missing for \(type)"
    case .missingExternalFile(let relativePath):
      return "External payload file is missing at \(relativePath)"
    }
  }
}

struct ArchiveRepresentationSnapshot: Equatable, FetchableRecord {
  let itemID: Int64
  let type: String
  let value: Data
  let size: Int
  let payloadHash: String?
  let storageKind: ArchivePayloadStorageKind
  let relativePath: String?

  var hasPayload: Bool {
    payloadHash != nil || relativePath != nil || !value.isEmpty || size == 0
  }

  init(row: Row) throws {
    itemID = row["item_id"]
    type = row["type"]
    value = row["value"]
    size = row["size"]
    payloadHash = row["payload_hash"]
    storageKind = ArchivePayloadStorageKind(rawValue: row["storage_kind"] ?? "") ?? .inline
    relativePath = row["relative_path"]
  }

  init(
    itemID: Int64,
    type: String,
    value: Data,
    size: Int,
    payloadHash: String?,
    storageKind: ArchivePayloadStorageKind,
    relativePath: String?
  ) {
    self.itemID = itemID
    self.type = type
    self.value = value
    self.size = size
    self.payloadHash = payloadHash
    self.storageKind = storageKind
    self.relativePath = relativePath
  }

  func resolvingPayload(with payloadStore: ArchivePayloadStore) throws -> ArchiveRepresentationSnapshot {
    guard storageKind == .external else { return self }
    guard let relativePath else {
      throw ArchivePayloadStoreError.missingExternalPath(type: type)
    }

    return ArchiveRepresentationSnapshot(
      itemID: itemID,
      type: type,
      value: try payloadStore.read(relativePath: relativePath),
      size: size,
      payloadHash: payloadHash,
      storageKind: storageKind,
      relativePath: relativePath
    )
  }
}

struct ArchiveExternalPayload: Equatable {
  let hash: String
  let byteCount: Int
  let relativePath: String
}

struct ArchivePayloadFile: Equatable {
  let relativePath: String
  let byteCount: Int
}

struct ArchivePayloadStore {
  static let defaultRootDirectory = URL.applicationSupportDirectory.appending(path: "Maccy/Payloads")

  let rootDirectory: URL

  init(rootDirectory: URL = Self.defaultRootDirectory) {
    self.rootDirectory = rootDirectory
  }

  func write(_ data: Data) throws -> ArchiveExternalPayload {
    let hash = Self.payloadHash(for: data)
    let relativePath = Self.relativePath(forHash: hash)
    let fileURL = fileURL(forRelativePath: relativePath)

    if !FileManager.default.fileExists(atPath: fileURL.path) {
      try writeAtomically(data, to: fileURL)
    }

    return ArchiveExternalPayload(hash: hash, byteCount: data.count, relativePath: relativePath)
  }

  func read(relativePath: String) throws -> Data {
    let fileURL = fileURL(forRelativePath: relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw ArchivePayloadStoreError.missingExternalFile(relativePath: relativePath)
    }

    return try Data(contentsOf: fileURL)
  }

  func files() throws -> [ArchivePayloadFile] {
    guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return [] }
    guard let enumerator = FileManager.default.enumerator(
      at: rootDirectory,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
    ) else { return [] }

    var files: [ArchivePayloadFile] = []
    for case let fileURL as URL in enumerator {
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
      guard values.isDirectory == false, let relativePath = relativePath(for: fileURL) else { continue }
      files.append(ArchivePayloadFile(relativePath: relativePath, byteCount: values.fileSize ?? 0))
    }

    return files.sorted { $0.relativePath < $1.relativePath }
  }

  func delete(relativePath: String) throws {
    let fileURL = fileURL(forRelativePath: relativePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }

  func removeEmptyDirectories() throws {
    guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
    guard let enumerator = FileManager.default.enumerator(
      at: rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return }

    let directories = try enumerator.compactMap { item -> URL? in
      guard let directoryURL = item as? URL else { return nil }
      let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
      return values.isDirectory == true ? directoryURL : nil
    }

    for directoryURL in directories.sorted(by: { $0.path.count > $1.path.count }) {
      if try FileManager.default.contentsOfDirectory(atPath: directoryURL.path).isEmpty {
        try FileManager.default.removeItem(at: directoryURL)
      }
    }
  }

  func fileURL(forRelativePath relativePath: String) -> URL {
    rootDirectory.appending(path: relativePath)
  }

  static func relativePath(forHash hash: String) -> String {
    "\(hash.prefix(2))/\(hash)"
  }

  static func payloadHash(for data: Data) -> String {
    Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
  }

  private func writeAtomically(_ data: Data, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporaryURL = fileURL.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
    try data.write(to: temporaryURL, options: .atomic)
    do {
      try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      try? FileManager.default.removeItem(at: temporaryURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private func relativePath(for fileURL: URL) -> String? {
    let rootPath = rootDirectory.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix("\(rootPath)/") else { return nil }
    return String(filePath.dropFirst(rootPath.count + 1))
  }
}

private struct SearchDocumentRow: FetchableRecord {
  let itemID: Int64
  let title: String?
  let text: String?

  init(row: Row) throws {
    itemID = row["item_id"]
    title = row["title"]
    text = row["text"]
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
  private let payloadStore: ArchivePayloadStore
  private let inlinePayloadThresholdBytes: Int

  private init(
    pool: DatabasePool,
    payloadStore: ArchivePayloadStore,
    inlinePayloadThresholdBytes: Int
  ) {
    self.pool = pool
    self.payloadStore = payloadStore
    self.inlinePayloadThresholdBytes = inlinePayloadThresholdBytes
  }

  static func open(
    at url: URL = defaultURL,
    payloadStore: ArchivePayloadStore = ArchivePayloadStore(),
    inlinePayloadThresholdBytes: Int = Defaults[.archiveInlinePayloadThresholdBytes]
  ) throws -> ArchiveDatabase {
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
    return ArchiveDatabase(
      pool: pool,
      payloadStore: payloadStore,
      inlinePayloadThresholdBytes: inlinePayloadThresholdBytes
    )
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
            payloadStore: payloadStore,
            inlinePayloadThresholdBytes: inlinePayloadThresholdBytes,
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
      ArchiveSnapshot(items: try Self.fetchArchiveItems(
        db,
        sql: Self.archiveItemsSQL,
        payloadStore: payloadStore
      ))
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
      try Self.fetchArchiveItems(
        db,
        sql: Self.pinnedItemsSQL,
        includePayloads: false
      )
    }
  }

  func item(id: Int64) throws -> ArchiveItemSnapshot? {
    try pool.read { db in
      try Self.fetchArchiveItems(
        db,
        sql: Self.archiveItemByIDSQL,
        arguments: [id],
        payloadStore: payloadStore
      ).first
    }
  }

  func search(_ request: ArchiveSearchRequest) throws -> ArchiveSearchPage {
    let normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = max(request.limit, 0)
    let offset = max(request.offset, 0)
    guard !normalizedQuery.isEmpty, limit > 0 else {
      return ArchiveSearchPage(items: [], nextOffset: nil)
    }

    switch request.mode {
    case .exact:
      return try searchFTS(query: normalizedQuery, prefix: false, limit: limit, offset: offset)
    case .prefix:
      return try searchFTS(query: normalizedQuery, prefix: true, limit: limit, offset: offset)
    case .fuzzy:
      return try searchBoundedCandidates(request, limit: limit, offset: offset) {
        Self.fuzzySearchMatcher(query: $0, item: $1)
      }
    case .regexp:
      return try searchBoundedCandidates(request, limit: limit, offset: offset) {
        Self.regularExpressionMatcher(query: $0, item: $1)
      }
    case .mixed:
      let exactPage = try searchFTS(query: normalizedQuery, prefix: false, limit: limit, offset: offset)
      if !exactPage.items.isEmpty { return exactPage }

      let regexpPage = try searchBoundedCandidates(
        request,
        limit: limit,
        offset: offset
      ) {
        Self.regularExpressionMatcher(query: $0, item: $1)
      }
      if !regexpPage.items.isEmpty { return regexpPage }

      return try searchBoundedCandidates(request, limit: limit, offset: offset) {
        Self.fuzzySearchMatcher(query: $0, item: $1)
      }
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

  func rebuildSearchIndex() throws {
    try pool.write { db in
      try Self.rebuildSearchIndex(db)
    }
  }

  func searchIndexItemIDs(matching query: String, limit: Int = 50) throws -> [Int64] {
    guard !query.isEmpty, limit > 0 else { return [] }

    return try pool.read { db in
      try Int64.fetchAll(
        db,
        sql: Self.searchIndexItemIDsSQL,
        arguments: [query, limit]
      )
    }
  }

  func searchIndexDefinition() throws -> String? {
    try pool.read { db in
      try Self.searchIndexSQLDefinition(db)
    }
  }

  func representationColumnNames() throws -> [String] {
    try pool.read { db in
      try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('clipboard_representations')")
    }
  }

  func orphanedExternalPayloadFiles() throws -> [ArchivePayloadFile] {
    let referencedPaths = try referencedExternalPayloadRelativePaths()
    return try payloadStore.files().filter { !referencedPaths.contains($0.relativePath) }
  }

  @discardableResult
  func cleanupOrphanedExternalPayloadFiles() throws -> [ArchivePayloadFile] {
    let orphans = try orphanedExternalPayloadFiles()
    for orphan in orphans {
      try payloadStore.delete(relativePath: orphan.relativePath)
    }
    try payloadStore.removeEmptyDirectories()
    return orphans
  }

  @discardableResult
  func deleteItemPermanently(id: Int64) throws -> [ArchivePayloadFile] {
    try pool.write { db in
      try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id])
    }
    return try cleanupOrphanedExternalPayloadFiles()
  }

  private func referencedExternalPayloadRelativePaths() throws -> Set<String> {
    try pool.read { db in
      Set(try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT relative_path
          FROM clipboard_representations
          WHERE storage_kind = ?
            AND relative_path IS NOT NULL
        """,
        arguments: [ArchivePayloadStorageKind.external.rawValue]
      ))
    }
  }

  private func searchFTS(query: String, prefix: Bool, limit: Int, offset: Int) throws -> ArchiveSearchPage {
    guard let matchQuery = Self.ftsQuery(for: query, prefix: prefix) else {
      return ArchiveSearchPage(items: [], nextOffset: nil)
    }

    let fetchLimit = limit + 1
    return try pool.read { db in
      var items = try Self.fetchArchiveItemSummaries(
        db,
        sql: Self.searchItemsSQL,
        arguments: [matchQuery, fetchLimit, offset]
      )
      let hasMore = items.count > limit
      if hasMore {
        items.removeLast()
      }

      return ArchiveSearchPage(
        items: items,
        nextOffset: hasMore ? offset + limit : nil
      )
    }
  }

  private func searchBoundedCandidates(
    _ request: ArchiveSearchRequest,
    limit: Int,
    offset: Int,
    matcher: (String, ArchiveItemSnapshot) -> Bool
  ) throws -> ArchiveSearchPage {
    let candidateLimit = max(request.candidateLimit, 0)
    guard candidateLimit > 0 else {
      return ArchiveSearchPage(items: [], nextOffset: nil)
    }

    let candidates = try pool.read { db in
      try Self.fetchArchiveItemSummaries(
        db,
        sql: Self.searchCandidateItemsSQL,
        arguments: [candidateLimit]
      )
    }
    let matches = candidates.filter { matcher(request.query, $0) }
    let pageItems = Array(matches.dropFirst(offset).prefix(limit))
    let hasMore = matches.count > offset + pageItems.count

    return ArchiveSearchPage(
      items: pageItems,
      nextOffset: hasMore ? offset + pageItems.count : nil
    )
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

  func replaceSearchDocument(itemID: Int64, title: String?, text: String?) throws {
    try pool.write { db in
      try Self.replaceSearchDocument(itemID: itemID, title: title, text: text, db: db)
    }
  }

  func deleteSearchDocument(itemID: Int64) throws {
    try pool.write { db in
      try db.execute(sql: "DELETE FROM clipboard_search_documents WHERE item_id = ?", arguments: [itemID])
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
        arguments: arguments,
        includePayloads: false
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
    arguments: StatementArguments = [],
    includePayloads: Bool = true,
    payloadStore: ArchivePayloadStore? = nil
  ) throws -> [ArchiveItemSnapshot] {
    var items = try fetchArchiveItemSummaries(db, sql: sql, arguments: arguments)
    try attachRepresentations(
      to: &items,
      includePayloads: includePayloads,
      payloadStore: payloadStore,
      db: db
    )
    return items
  }

  private static func fetchArchiveItemSummaries(
    _ db: Database,
    sql: String,
    arguments: StatementArguments = []
  ) throws -> [ArchiveItemSnapshot] {
    try ArchiveItemSnapshot.fetchAll(db, sql: sql, arguments: arguments)
  }

  private static func attachRepresentations(
    to items: inout [ArchiveItemSnapshot],
    includePayloads: Bool,
    payloadStore: ArchivePayloadStore?,
    db: Database
  ) throws {
    guard !items.isEmpty else { return }

    let itemIDs = items.map(\.id)
    let placeholders = Array(repeating: "?", count: itemIDs.count).joined(separator: ", ")
    let valueSQL = includePayloads ? "value" : "CAST('' AS BLOB) AS value"
    var representations = try ArchiveRepresentationSnapshot.fetchAll(
      db,
      sql: """
        SELECT item_id, type, \(valueSQL), size, payload_hash, storage_kind, relative_path
        FROM clipboard_representations
        WHERE item_id IN (\(placeholders))
        ORDER BY item_id, id
        """,
      arguments: StatementArguments(itemIDs)
    )

    if includePayloads, let payloadStore {
      representations = try representations.map { try $0.resolvingPayload(with: payloadStore) }
    }

    let representationsByItemID = Dictionary(grouping: representations, by: \.itemID)

    for index in items.indices {
      items[index].representations = representationsByItemID[items[index].id] ?? []
    }
  }

  private static func ftsQuery(for query: String, prefix: Bool) -> String? {
    let tokens = searchTokens(in: query)
    guard !tokens.isEmpty else { return nil }

    if prefix {
      return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    return tokens.map(quotedFTSToken).joined(separator: " ")
  }

  private static func searchTokens(in query: String) -> [String] {
    var tokens: [String] = []
    var current = ""

    for scalar in query.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        current.append(String(scalar))
      } else if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }

    if !current.isEmpty {
      tokens.append(current)
    }

    return tokens
  }

  private static func quotedFTSToken(_ token: String) -> String {
    "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private static func regularExpressionMatcher(query: String, item: ArchiveItemSnapshot) -> Bool {
    let searchText = searchableText(for: item)
    guard let expression = try? NSRegularExpression(pattern: query) else {
      return false
    }

    return expression.firstMatch(
      in: searchText,
      options: [],
      range: NSRange(searchText.startIndex..<searchText.endIndex, in: searchText)
    ) != nil
  }

  private static func fuzzySearchMatcher(query: String, item: ArchiveItemSnapshot) -> Bool {
    let queryTokens = searchTokens(in: query).map { $0.lowercased() }
    guard !queryTokens.isEmpty else { return false }

    var searchText = searchableText(for: item)
    if searchText.count > fuzzySearchLimit {
      let stopIndex = searchText.index(searchText.startIndex, offsetBy: fuzzySearchLimit)
      searchText = "\(searchText[...stopIndex])"
    }
    let itemTokens = searchTokens(in: searchText).map { $0.lowercased() }

    return queryTokens.allSatisfy { queryToken in
      let maximumDistance = max(1, queryToken.count / 4)
      return itemTokens.contains { itemToken in
        levenshteinDistance(queryToken, itemToken) <= maximumDistance
      }
    }
  }

  private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
    let lhsCharacters = Array(lhs)
    let rhsCharacters = Array(rhs)
    guard !lhsCharacters.isEmpty else { return rhsCharacters.count }
    guard !rhsCharacters.isEmpty else { return lhsCharacters.count }

    var previous = Array(0...rhsCharacters.count)
    var current = Array(repeating: 0, count: rhsCharacters.count + 1)

    for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
      current[0] = lhsIndex + 1
      for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
        current[rhsIndex + 1] = min(
          previous[rhsIndex + 1] + 1,
          current[rhsIndex] + 1,
          previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
        )
      }
      swap(&previous, &current)
    }

    return previous[rhsCharacters.count]
  }

  private static func searchableText(for item: ArchiveItemSnapshot) -> String {
    [item.title, item.searchTitle, item.searchText]
      .compactMap { $0 }
      .joined(separator: " ")
  }

  private static let fuzzySearchLimit = 5_000

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
    migrator.registerMigration("v4_external_content_search_index", foreignKeyChecks: .immediate) { db in
      try migrateSearchDocumentsToExternalContent(db)
    }
    migrator.registerMigration("v5_hybrid_payload_metadata", foreignKeyChecks: .immediate) { db in
      if try !clipboardRepresentationsHaveStorageKind(db) {
        try db.execute(sql: "ALTER TABLE clipboard_representations ADD COLUMN storage_kind TEXT NOT NULL DEFAULT 'inline'")
      }
      if try !clipboardRepresentationsHaveRelativePath(db) {
        try db.execute(sql: "ALTER TABLE clipboard_representations ADD COLUMN relative_path TEXT")
      }
    }
    return migrator
  }

  private static func createInitialSchema(_ db: Database) throws {
    for statement in initialSchemaStatements {
      try db.execute(sql: statement)
    }
  }

  private static func migrateSearchDocumentsToExternalContent(_ db: Database) throws {
    let usesExternalContent = try searchIndexUsesExternalContent(db)
    let legacyRows = usesExternalContent ? [] : try legacySearchDocumentRows(db)

    try db.execute(sql: searchDocumentsTableSQL)
    for row in legacyRows {
      try replaceSearchDocument(
        itemID: row.itemID,
        title: row.title,
        text: row.text,
        db: db
      )
    }

    try dropSearchDocumentTriggers(db)
    if !usesExternalContent, try searchIndexExists(db) {
      try db.execute(sql: "DROP TABLE clipboard_search_docs")
    }
    try db.execute(sql: searchIndexSQL)
    try createSearchDocumentTriggers(db)
    try rebuildSearchIndex(db)
  }

  private static func insertLegacyItem(
    _ item: HistoryItem,
    itemIndex: Int,
    pinPosition: inout Int,
    report: inout ArchiveImportReport,
    payloadStore: ArchivePayloadStore,
    inlinePayloadThresholdBytes: Int,
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
        try insertRepresentation(
          content,
          value: value,
          itemID: itemID,
          payloadStore: payloadStore,
          inlinePayloadThresholdBytes: inlinePayloadThresholdBytes,
          db: db
        )
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
    payloadStore: ArchivePayloadStore,
    inlinePayloadThresholdBytes: Int,
    db: Database
  ) throws {
    let threshold = max(inlinePayloadThresholdBytes, 0)
    let payloadHash: String
    let storedValue: Data
    let storageKind: ArchivePayloadStorageKind
    let relativePath: String?

    if value.count <= threshold {
      payloadHash = Self.payloadHash(for: value)
      storedValue = value
      storageKind = .inline
      relativePath = nil
    } else {
      let externalPayload = try payloadStore.write(value)
      payloadHash = externalPayload.hash
      storedValue = Data()
      storageKind = .external
      relativePath = externalPayload.relativePath
    }

    try db.execute(
      sql: """
        INSERT INTO clipboard_representations (
          item_id,
          type,
          value,
          size,
          payload_hash,
          storage_kind,
          relative_path
        )
        VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      arguments: [
        itemID,
        content.type,
        storedValue,
        value.count,
        payloadHash,
        storageKind.rawValue,
        relativePath,
      ]
    )
  }

  private static func insertSearchDocument(for item: HistoryItem, itemID: Int64, db: Database) throws {
    try replaceSearchDocument(itemID: itemID, title: item.title, text: item.previewableText, db: db)
  }

  private static func replaceSearchDocument(itemID: Int64, title: String?, text: String?, db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO clipboard_search_documents (item_id, title, text)
        VALUES (?, ?, ?)
        ON CONFLICT(item_id) DO UPDATE SET
          title = excluded.title,
          text = excluded.text
      """,
      arguments: [itemID, title, text]
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

  private static func searchIndexExists(_ db: Database) throws -> Bool {
    try (Int.fetchOne(
      db,
      sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'clipboard_search_docs'"
    ) ?? 0) > 0
  }

  private static func searchIndexUsesExternalContent(_ db: Database) throws -> Bool {
    guard let definition = try searchIndexSQLDefinition(db)?.lowercased() else {
      return false
    }

    return definition.contains("content='clipboard_search_documents'") ||
      definition.contains("content=\"clipboard_search_documents\"") ||
      definition.contains("content=clipboard_search_documents")
  }

  private static func searchIndexSQLDefinition(_ db: Database) throws -> String? {
    try String.fetchOne(
      db,
      sql: "SELECT sql FROM sqlite_master WHERE name = 'clipboard_search_docs'"
    )
  }

  private static func legacySearchDocumentRows(_ db: Database) throws -> [SearchDocumentRow] {
    guard try searchIndexExists(db) else { return [] }

    return try SearchDocumentRow.fetchAll(
      db,
      sql: "SELECT item_id, title, text FROM clipboard_search_docs WHERE item_id IS NOT NULL"
    )
  }

  private static func dropSearchDocumentTriggers(_ db: Database) throws {
    for trigger in searchDocumentTriggerNames {
      try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
  }

  private static func createSearchDocumentTriggers(_ db: Database) throws {
    for statement in searchDocumentTriggerStatements {
      try db.execute(sql: statement)
    }
  }

  private static func rebuildSearchIndex(_ db: Database) throws {
    try db.execute(sql: "INSERT INTO clipboard_search_docs(clipboard_search_docs) VALUES('rebuild')")
  }

  private static func clipboardRepresentationsHavePayloadHash(_ db: Database) throws -> Bool {
    try clipboardRepresentationsHaveColumn("payload_hash", db)
  }

  private static func clipboardRepresentationsHaveStorageKind(_ db: Database) throws -> Bool {
    try clipboardRepresentationsHaveColumn("storage_kind", db)
  }

  private static func clipboardRepresentationsHaveRelativePath(_ db: Database) throws -> Bool {
    try clipboardRepresentationsHaveColumn("relative_path", db)
  }

  private static func clipboardRepresentationsHaveColumn(_ name: String, _ db: Database) throws -> Bool {
    try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('clipboard_representations')")
      .contains(name)
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

  static func archiveBrowsingStoreIfEnabled() -> (any ArchiveBrowsingStore)? {
    guard ArchiveDatabaseFeature.isEnabled else {
      return nil
    }

    do {
      return ArchivePopupHistoryStore(database: try sharedDatabase())
    } catch {
      NSLog("Maccy archive mode store failed: \(error.localizedDescription)")
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
      clipboard_search_documents.title AS search_title,
      clipboard_search_documents.text AS search_text
    FROM clipboard_items
    LEFT JOIN source_apps ON source_apps.id = clipboard_items.source_app_id
    LEFT JOIN pins ON pins.item_id = clipboard_items.id
    LEFT JOIN clipboard_search_documents ON clipboard_search_documents.item_id = clipboard_items.id
    """

  static let archiveItemsSQL = """
    \(archiveItemSelectSQL)
    ORDER BY clipboard_items.id
    """

  static let archiveItemByIDSQL = """
    \(archiveItemSelectSQL)
    WHERE clipboard_items.id = ?
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
    SELECT item_id, type, value, size, payload_hash, storage_kind, relative_path
    FROM clipboard_representations
    ORDER BY item_id, id
    """

  static let searchIndexItemIDsSQL = """
    SELECT clipboard_search_docs.rowid
    FROM clipboard_search_docs
    JOIN clipboard_items ON clipboard_items.id = clipboard_search_docs.rowid
    WHERE clipboard_search_docs MATCH ?
      AND clipboard_items.deleted_at IS NULL
    ORDER BY clipboard_search_docs.rowid
    LIMIT ?
    """

  static let searchItemsSQL = """
    \(archiveItemSelectSQL)
    JOIN clipboard_search_docs ON clipboard_search_docs.rowid = clipboard_items.id
    WHERE clipboard_search_docs MATCH ?
      AND clipboard_items.deleted_at IS NULL
    ORDER BY bm25(clipboard_search_docs), clipboard_items.last_seen_at DESC, clipboard_items.id DESC
    LIMIT ? OFFSET ?
    """

  static let searchCandidateItemsSQL = """
    \(archiveItemSelectSQL)
    WHERE clipboard_items.deleted_at IS NULL
    ORDER BY clipboard_items.last_seen_at DESC, clipboard_items.id DESC
    LIMIT ?
    """

  static let searchDocumentsTableSQL = """
    CREATE TABLE IF NOT EXISTS clipboard_search_documents (
      item_id INTEGER PRIMARY KEY REFERENCES clipboard_items(id) ON DELETE CASCADE,
      title TEXT,
      text TEXT
    )
    """

  static let searchIndexSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_search_docs USING fts5(
      title,
      text,
      content='clipboard_search_documents',
      content_rowid='item_id',
      tokenize='unicode61 remove_diacritics 1',
      prefix='2 3 4'
    )
    """

  static let searchDocumentAfterInsertTriggerName = "clipboard_search_documents_ai"
  static let searchDocumentAfterDeleteTriggerName = "clipboard_search_documents_ad"
  static let searchDocumentAfterUpdateTriggerName = "clipboard_search_documents_au"

  static let searchDocumentTriggerNames = [
    searchDocumentAfterInsertTriggerName,
    searchDocumentAfterDeleteTriggerName,
    searchDocumentAfterUpdateTriggerName,
  ]

  static let searchDocumentAfterInsertTriggerSQL = """
    CREATE TRIGGER IF NOT EXISTS clipboard_search_documents_ai
    AFTER INSERT ON clipboard_search_documents BEGIN
      INSERT INTO clipboard_search_docs(rowid, title, text)
      VALUES (new.item_id, new.title, new.text);
    END
    """

  static let searchDocumentAfterDeleteTriggerSQL = """
    CREATE TRIGGER IF NOT EXISTS clipboard_search_documents_ad
    AFTER DELETE ON clipboard_search_documents BEGIN
      INSERT INTO clipboard_search_docs(clipboard_search_docs, rowid, title, text)
      VALUES ('delete', old.item_id, old.title, old.text);
    END
    """

  static let searchDocumentAfterUpdateTriggerSQL = """
    CREATE TRIGGER IF NOT EXISTS clipboard_search_documents_au
    AFTER UPDATE ON clipboard_search_documents BEGIN
      INSERT INTO clipboard_search_docs(clipboard_search_docs, rowid, title, text)
      VALUES ('delete', old.item_id, old.title, old.text);
      INSERT INTO clipboard_search_docs(rowid, title, text)
      VALUES (new.item_id, new.title, new.text);
    END
    """

  static let searchDocumentTriggerStatements = [
    searchDocumentAfterInsertTriggerSQL,
    searchDocumentAfterDeleteTriggerSQL,
    searchDocumentAfterUpdateTriggerSQL,
  ]

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
    searchDocumentsTableSQL,
    searchIndexSQL,
    searchDocumentAfterInsertTriggerSQL,
    searchDocumentAfterDeleteTriggerSQL,
    searchDocumentAfterUpdateTriggerSQL,
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
