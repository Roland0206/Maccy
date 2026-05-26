import Foundation
import SwiftData

struct PopupHistoryRowContent: Equatable {
  let type: String
  let size: Int
  let hasPayload: Bool
}

struct PopupHistoryRow: Equatable, Identifiable {
  enum Source: Equatable {
    case legacy(ObjectIdentifier)
    case archive(id: Int64)
  }

  let id: String
  let source: Source
  let title: String
  let applicationBundleIdentifier: String?
  let firstCopiedAt: Date
  let lastCopiedAt: Date
  let numberOfCopies: Int
  let pin: String?
  let contents: [PopupHistoryRowContent]
  private let legacyItem: HistoryItem?
  private let archiveItem: ArchiveItemSnapshot?

  var isPinned: Bool { pin != nil }

  static func == (lhs: PopupHistoryRow, rhs: PopupHistoryRow) -> Bool {
    lhs.id == rhs.id &&
      lhs.source == rhs.source &&
      lhs.title == rhs.title &&
      lhs.applicationBundleIdentifier == rhs.applicationBundleIdentifier &&
      lhs.firstCopiedAt == rhs.firstCopiedAt &&
      lhs.lastCopiedAt == rhs.lastCopiedAt &&
      lhs.numberOfCopies == rhs.numberOfCopies &&
      lhs.pin == rhs.pin &&
      lhs.contents == rhs.contents
  }

  init(legacyItem item: HistoryItem) {
    let objectID = ObjectIdentifier(item)
    id = "legacy-\(objectID.hashValue)"
    source = .legacy(objectID)
    title = item.title
    applicationBundleIdentifier = item.application
    firstCopiedAt = item.firstCopiedAt
    lastCopiedAt = item.lastCopiedAt
    numberOfCopies = item.numberOfCopies
    pin = item.pin
    contents = item.contents.map { content in
      PopupHistoryRowContent(
        type: content.type,
        size: content.value?.count ?? 0,
        hasPayload: content.value != nil
      )
    }
    legacyItem = item
    archiveItem = nil
  }

  init(archiveItem item: ArchiveItemSnapshot) {
    id = "archive-\(item.id)"
    source = .archive(id: item.id)
    title = item.title ?? item.pinTitle ?? item.searchTitle ?? item.searchText ?? ""
    applicationBundleIdentifier = item.sourceAppBundleIdentifier
    firstCopiedAt = popupArchiveDateFormatter.date(from: item.firstSeenAt) ?? .distantPast
    lastCopiedAt = popupArchiveDateFormatter.date(from: item.lastSeenAt) ?? .distantPast
    numberOfCopies = item.changeCount
    pin = item.pinKey
    contents = item.representations.map { representation in
      PopupHistoryRowContent(
        type: representation.type,
        size: representation.size,
        hasPayload: true
      )
    }
    legacyItem = nil
    archiveItem = item
  }

  func materializeLegacyItem() -> HistoryItem? {
    legacyItem
  }

  func materializeArchiveItem() -> HistoryItem? {
    guard let archiveItem else { return nil }

    let item = HistoryItem(contents: archiveItem.representations.map { representation in
      HistoryItemContent(type: representation.type, value: representation.value)
    })
    item.application = archiveItem.sourceAppBundleIdentifier
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = archiveItem.changeCount
    item.pin = archiveItem.pinKey
    item.title = title
    return item
  }
}

enum PopupHistoryPageCursor: Equatable {
  case archive(ArchiveRecentPageCursor)
}

struct PopupHistoryRecentPage: Equatable {
  let rows: [PopupHistoryRow]
  let nextCursor: PopupHistoryPageCursor?
}

struct PopupHistoryPage: Equatable {
  let pinnedRows: [PopupHistoryRow]
  let recentRows: [PopupHistoryRow]
  let nextRecentCursor: PopupHistoryPageCursor?

  init(
    pinnedRows: [PopupHistoryRow],
    recentRows: [PopupHistoryRow],
    nextRecentCursor: PopupHistoryPageCursor? = nil
  ) {
    self.pinnedRows = pinnedRows
    self.recentRows = recentRows
    self.nextRecentCursor = nextRecentCursor
  }

  var rows: [PopupHistoryRow] { pinnedRows + recentRows }
}

enum PopupHistoryStoreError: Error, Equatable {
  case unsupportedRow(String)
}

@MainActor
protocol PopupHistoryStore {
  func loadInitialRows(recentLimit: Int) throws -> PopupHistoryPage
  func loadMoreRecentRows(after cursor: PopupHistoryPageCursor, limit: Int) throws -> PopupHistoryRecentPage
  func materialize(_ row: PopupHistoryRow) throws -> HistoryItem
  func delete(_ row: PopupHistoryRow) throws
  func deleteUnpinned() throws
  func deleteAll() throws
  func setPin(_ row: PopupHistoryRow, pin: String?) throws
}

@MainActor
protocol LegacyHistoryStore {
  func loadAll() throws -> [HistoryItem]
  // Returns stored items that may duplicate item. Excludes item itself even if already inserted.
  func loadDuplicateCandidates(for item: HistoryItem) throws -> [HistoryItem]
  func insert(_ item: HistoryItem) throws
  func delete(_ item: HistoryItem) throws
  func deleteUnpinned() throws
  func deleteAll() throws
  func countItems() throws -> Int
  func countContents() throws -> Int
}

struct SwiftDataPopupHistoryStore: PopupHistoryStore {
  nonisolated(unsafe) private let historyStore: any LegacyHistoryStore

  nonisolated init(historyStore: any LegacyHistoryStore = SwiftDataHistoryStore()) {
    self.historyStore = historyStore
  }

  @MainActor
  func loadInitialRows(recentLimit _: Int) throws -> PopupHistoryPage {
    let rows = try historyStore.loadAll().map { PopupHistoryRow(legacyItem: $0) }
    return PopupHistoryPage(
      pinnedRows: rows.filter(\.isPinned),
      recentRows: rows.filter { !$0.isPinned }
    )
  }

  @MainActor
  func loadMoreRecentRows(after _: PopupHistoryPageCursor, limit _: Int) throws -> PopupHistoryRecentPage {
    PopupHistoryRecentPage(rows: [], nextCursor: nil)
  }

  @MainActor
  func materialize(_ row: PopupHistoryRow) throws -> HistoryItem {
    guard case .legacy = row.source,
          let item = row.materializeLegacyItem() else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    return item
  }

  @MainActor
  func delete(_ row: PopupHistoryRow) throws {
    guard case .legacy = row.source,
          let item = row.materializeLegacyItem() else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    try historyStore.delete(item)
  }

  @MainActor
  func deleteUnpinned() throws {
    try historyStore.deleteUnpinned()
  }

  @MainActor
  func deleteAll() throws {
    try historyStore.deleteAll()
  }

  @MainActor
  func setPin(_ row: PopupHistoryRow, pin: String?) throws {
    guard case .legacy = row.source,
          let item = row.materializeLegacyItem() else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    item.pin = pin
  }
}

struct ArchivePopupHistoryStore: PopupHistoryStore {
  nonisolated(unsafe) private let database: ArchiveDatabase

  nonisolated init(database: ArchiveDatabase) {
    self.database = database
  }

  @MainActor
  func loadInitialRows(recentLimit: Int) throws -> PopupHistoryPage {
    let pinnedRows = try database.pinnedItems().map { PopupHistoryRow(archiveItem: $0) }
    let recentPage = try database.firstRecentPage(limit: recentLimit)
    let recentRows = recentPage.items.map { PopupHistoryRow(archiveItem: $0) }
    return PopupHistoryPage(
      pinnedRows: pinnedRows,
      recentRows: recentRows,
      nextRecentCursor: recentPage.nextCursor.map(PopupHistoryPageCursor.archive)
    )
  }

  @MainActor
  func loadMoreRecentRows(after cursor: PopupHistoryPageCursor, limit: Int) throws -> PopupHistoryRecentPage {
    guard case let .archive(archiveCursor) = cursor else {
      throw PopupHistoryStoreError.unsupportedRow("cursor")
    }

    let page = try database.recentPage(after: archiveCursor, limit: limit)
    return PopupHistoryRecentPage(
      rows: page.items.map { PopupHistoryRow(archiveItem: $0) },
      nextCursor: page.nextCursor.map(PopupHistoryPageCursor.archive)
    )
  }

  @MainActor
  func materialize(_ row: PopupHistoryRow) throws -> HistoryItem {
    guard case .archive = row.source,
          let item = row.materializeArchiveItem() else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    return item
  }

  @MainActor
  func delete(_ row: PopupHistoryRow) throws {
    guard case let .archive(id) = row.source else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    try database.softDeleteItem(id: id)
  }

  @MainActor
  func deleteUnpinned() throws {
    try database.softDeleteUnpinnedItems()
  }

  @MainActor
  func deleteAll() throws {
    try database.softDeleteAllItems()
  }

  @MainActor
  func setPin(_ row: PopupHistoryRow, pin: String?) throws {
    guard case let .archive(id) = row.source else {
      throw PopupHistoryStoreError.unsupportedRow(row.id)
    }

    try database.setPin(itemID: id, pin: pin, title: row.title)
  }
}

struct SwiftDataHistoryStore: LegacyHistoryStore {
  nonisolated init() {}

  @MainActor
  func loadAll() throws -> [HistoryItem] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func loadDuplicateCandidates(for item: HistoryItem) throws -> [HistoryItem] {
    // Current semantics compare against existing rows in memory. Future stores can narrow this set.
    try loadAll().filter { $0 !== item }
  }

  @MainActor
  func insert(_ item: HistoryItem) throws {
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @MainActor
  func delete(_ item: HistoryItem) throws {
    Storage.shared.context.delete(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @MainActor
  func deleteUnpinned() throws {
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.transaction {
      try? Storage.shared.context.delete(
        model: HistoryItem.self,
        where: #Predicate { $0.pin == nil }
      )
      try? Storage.shared.context.delete(
        model: HistoryItemContent.self,
        where: #Predicate { $0.item?.pin == nil }
      )
    }
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @MainActor
  func deleteAll() throws {
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.delete(model: HistoryItem.self)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @MainActor
  func countItems() throws -> Int {
    try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func countContents() throws -> Int {
    try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
  }
}

private let popupArchiveDateFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  return formatter
}()

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }
}
