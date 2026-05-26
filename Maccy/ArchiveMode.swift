import AppKit
import Foundation
import Observation

struct ArchiveModePage: Equatable {
  let rows: [PopupHistoryRow]
  let nextRecentCursor: PopupHistoryPageCursor?
}

@MainActor
protocol ArchiveBrowsingStore {
  func loadInitialPage(limit: Int) throws -> ArchiveModePage
  func loadMoreRecentRows(after cursor: PopupHistoryPageCursor, limit: Int) throws -> PopupHistoryRecentPage
  func search(_ request: ArchiveSearchRequest) async throws -> PopupHistorySearchPage
  func materialize(_ row: PopupHistoryRow) throws -> HistoryItem
  func delete(_ row: PopupHistoryRow) throws
  func setPin(_ row: PopupHistoryRow, pin: String?) throws
}

extension ArchivePopupHistoryStore: ArchiveBrowsingStore {
  func loadInitialPage(limit: Int) throws -> ArchiveModePage {
    let page = try loadInitialRows(recentLimit: limit)
    return ArchiveModePage(
      rows: page.pinnedRows + page.recentRows,
      nextRecentCursor: page.nextRecentCursor
    )
  }
}

@MainActor
@Observable
final class ArchiveModeViewModel {
  enum State: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
  }

  var query = ""
  var rows: [PopupHistoryRow] = []
  var selectedRowID: String? {
    didSet {
      guard selectedRowID != oldValue else { return }
      selectedItem = nil
      selectedPreviewRowID = nil
    }
  }
  var selectedItem: HistoryItemDecorator?
  var state: State = .idle
  var isLoadingNextPage = false
  var isLoadingPreview = false

  var hasMore: Bool {
    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return nextRecentCursor != nil
    }
    return nextSearchOffset != nil
  }

  var selectedRow: PopupHistoryRow? {
    guard let selectedRowID else { return nil }
    return rows.first { $0.id == selectedRowID }
  }

  var canActOnSelection: Bool {
    selectedRow != nil && state != .loading
  }

  @ObservationIgnored private let store: (any ArchiveBrowsingStore)?
  @ObservationIgnored private let pageSize: Int
  @ObservationIgnored private var nextRecentCursor: PopupHistoryPageCursor?
  @ObservationIgnored private var nextSearchOffset: Int?
  @ObservationIgnored private var selectedPreviewRowID: String?

  init(
    store: (any ArchiveBrowsingStore)? = ArchiveDatabaseBootstrap.archiveBrowsingStoreIfEnabled(),
    pageSize: Int = 50
  ) {
    self.store = store
    self.pageSize = pageSize
  }

  func loadFirstPage() async {
    guard let store else {
      rows = []
      selectedRowID = nil
      selectedItem = nil
      nextRecentCursor = nil
      nextSearchOffset = nil
      state = .failed("Archive database is disabled.")
      return
    }

    state = .loading
    selectedRowID = nil
    selectedItem = nil
    selectedPreviewRowID = nil

    do {
      let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedQuery.isEmpty {
        try loadInitialRecentPage(store: store)
      } else {
        try await loadInitialSearchPage(query: trimmedQuery, store: store)
      }
      selectFirstRowIfNeeded()
      state = rows.isEmpty ? .empty : .loaded
    } catch is CancellationError {
      return
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func loadNextPage() async {
    guard let store, hasMore, !isLoadingNextPage else { return }

    isLoadingNextPage = true
    defer { isLoadingNextPage = false }

    do {
      let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedQuery.isEmpty {
        try loadNextRecentPage(store: store)
      } else {
        try await loadNextSearchPage(query: trimmedQuery, store: store)
      }
      selectFirstRowIfNeeded()
      state = rows.isEmpty ? .empty : .loaded
    } catch is CancellationError {
      return
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func loadSelectedPreview() async {
    guard let row = selectedRow, let store else {
      selectedItem = nil
      return
    }

    isLoadingPreview = true
    defer { isLoadingPreview = false }

    do {
      try Task.checkCancellation()
      let item = try store.materialize(row)
      try Task.checkCancellation()
      guard selectedRow?.id == row.id else { return }
      selectedPreviewRowID = row.id
      selectedItem = HistoryItemDecorator(item)
    } catch is CancellationError {
      return
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func copySelected(paste: Bool = false) async {
    guard let item = try? materializedSelectedItem() else { return }
    Clipboard.shared.copy(item)
    if paste {
      Clipboard.shared.paste()
    }
  }

  func deleteSelected() async {
    guard let row = selectedRow, let store else { return }

    do {
      try store.delete(row)
      remove(row: row)
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func togglePinSelected() async {
    guard let row = selectedRow, let store else { return }

    do {
      try store.setPin(row, pin: nextPin(for: row))
      await loadFirstPage()
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  private func loadInitialRecentPage(store: any ArchiveBrowsingStore) throws {
    let page = try store.loadInitialPage(limit: pageSize)
    rows = page.rows
    nextRecentCursor = page.nextRecentCursor
    nextSearchOffset = nil
  }

  private func loadInitialSearchPage(query: String, store: any ArchiveBrowsingStore) async throws {
    let page = try await store.search(searchRequest(query: query, offset: 0))
    rows = page.rows
    nextRecentCursor = nil
    nextSearchOffset = page.nextOffset
  }

  private func loadNextRecentPage(store: any ArchiveBrowsingStore) throws {
    guard let nextRecentCursor else { return }
    let page = try store.loadMoreRecentRows(after: nextRecentCursor, limit: pageSize)
    appendRows(page.rows)
    self.nextRecentCursor = page.nextCursor
  }

  private func loadNextSearchPage(query: String, store: any ArchiveBrowsingStore) async throws {
    guard let nextSearchOffset else { return }
    let page = try await store.search(searchRequest(query: query, offset: nextSearchOffset))
    appendRows(page.rows)
    self.nextSearchOffset = page.nextOffset
  }

  private func searchRequest(query: String, offset: Int) -> ArchiveSearchRequest {
    ArchiveSearchRequest(query: query, mode: .mixed, limit: pageSize, offset: offset)
  }

  private func appendRows(_ newRows: [PopupHistoryRow]) {
    let existingIDs = Set(rows.map(\.id))
    rows += newRows.filter { !existingIDs.contains($0.id) }
  }

  private func selectFirstRowIfNeeded() {
    if selectedRow == nil {
      selectedRowID = rows.first?.id
    }
  }

  private func materializedSelectedItem() throws -> HistoryItem? {
    guard let row = selectedRow, let store else { return nil }
    if let selectedItem, selectedPreviewRowID == row.id {
      return selectedItem.item
    }
    return try store.materialize(row)
  }

  private func remove(row: PopupHistoryRow) {
    rows.removeAll { $0.id == row.id }
    if selectedRowID == row.id {
      selectedRowID = rows.first?.id
      selectedItem = nil
    }
    state = rows.isEmpty ? .empty : .loaded
  }

  private func nextPin(for row: PopupHistoryRow) -> String? {
    guard row.pin == nil else { return nil }
    let assignedPins = Set(rows.filter { $0.id != row.id }.compactMap(\.pin))
    return HistoryItem.supportedPins.subtracting(assignedPins).sorted().first ?? ""
  }
}
