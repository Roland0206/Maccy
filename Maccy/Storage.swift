import Foundation
import SwiftData

@MainActor
protocol LegacyHistoryStore {
  func loadAll() throws -> [HistoryItem]
  func insert(_ item: HistoryItem) throws
  func delete(_ item: HistoryItem) throws
  func deleteUnpinned() throws
  func deleteAll() throws
  func countItems() throws -> Int
  func countContents() throws -> Int
}

struct SwiftDataHistoryStore: LegacyHistoryStore {
  nonisolated init() {}

  @MainActor
  func loadAll() throws -> [HistoryItem] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
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
