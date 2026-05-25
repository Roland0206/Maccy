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
    try pool.write { db in
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

  private static func makeConfiguration() -> Configuration {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.busyMode = .timeout(1)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      try db.execute(sql: "PRAGMA synchronous = NORMAL")
      try db.execute(sql: "PRAGMA busy_timeout = 1000")
      try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
    }
    return configuration
  }

  private static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1_archive_schema", foreignKeyChecks: .immediate) { db in
      try createInitialSchema(db)
    }
    return migrator
  }

  private static func createInitialSchema(_ db: Database) throws {
    for statement in initialSchemaStatements {
      try db.execute(sql: statement)
    }
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
}

enum ArchiveDatabaseBootstrap {
  private static var database: ArchiveDatabase?

  static func bootstrapIfEnabled() {
    guard ArchiveDatabaseFeature.isEnabled else {
      return
    }

    do {
      let database = try ArchiveDatabase.open()
      _ = try database.healthCheck()
      Self.database = database
    } catch {
      NSLog("Maccy archive database bootstrap failed: \(error.localizedDescription)")
    }
  }
}

private extension ArchiveDatabase {
  static let schemaTablesSQL = """
    SELECT name
    FROM sqlite_master
    WHERE type = 'table'
      AND name NOT LIKE 'sqlite_%'
    ORDER BY name
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
