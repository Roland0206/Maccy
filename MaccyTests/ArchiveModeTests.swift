import AppKit
import XCTest
@testable import Maccy

@MainActor
final class ArchiveModeTests: XCTestCase {
  func testInitialLoadUsesBoundedPageAndKeepsNextPageCursor() async {
    let store = FakeArchiveBrowsingStore(initialRows: [row("one"), row("two"), row("three")])
    let viewModel = ArchiveModeViewModel(store: store, pageSize: 2)

    await viewModel.loadFirstPage()

    XCTAssertEqual(store.initialPageLimits, [2])
    XCTAssertEqual(viewModel.rows.map(\.title), ["one", "two"])
    XCTAssertTrue(viewModel.hasMore)
  }

  func testSearchUsesArchiveSearchRequestsAndOffsets() async {
    let store = FakeArchiveBrowsingStore(initialRows: [])
    store.searchPages[0] = PopupHistorySearchPage(rows: [row("match one"), row("match two")], nextOffset: 2)
    store.searchPages[2] = PopupHistorySearchPage(rows: [row("match three")], nextOffset: nil)
    let viewModel = ArchiveModeViewModel(store: store, pageSize: 2)
    viewModel.query = "match"

    await viewModel.loadFirstPage()
    await viewModel.loadNextPage()

    XCTAssertEqual(store.searchRequests.map(\.query), ["match", "match"])
    XCTAssertEqual(store.searchRequests.map(\.offset), [0, 2])
    XCTAssertEqual(store.searchRequests.map(\.limit), [2, 2])
    XCTAssertEqual(viewModel.rows.map(\.title), ["match one", "match two", "match three"])
    XCTAssertFalse(viewModel.hasMore)
  }

  func testPreviewMaterializesOnlyAfterSelectionLoads() async {
    let store = FakeArchiveBrowsingStore(initialRows: [row("lazy")])
    let viewModel = ArchiveModeViewModel(store: store, pageSize: 10)

    await viewModel.loadFirstPage()

    XCTAssertEqual(store.materializedRowIDs, [])

    await viewModel.loadSelectedPreview()

    XCTAssertEqual(store.materializedRowIDs, [viewModel.rows[0].id])
    XCTAssertEqual(viewModel.selectedItem?.item.title, "lazy")
  }

  func testDeleteRemovesSelectedRowWithoutReloadingFullCorpus() async {
    let store = FakeArchiveBrowsingStore(initialRows: [row("delete me"), row("keep me")])
    let viewModel = ArchiveModeViewModel(store: store, pageSize: 10)

    await viewModel.loadFirstPage()
    await viewModel.deleteSelected()

    XCTAssertEqual(store.deletedRowIDs, ["legacy-\(ObjectIdentifier(store.itemsByTitle["delete me"]!).hashValue)"])
    XCTAssertEqual(viewModel.rows.map(\.title), ["keep me"])
  }

  func testPinToggleDelegatesToStore() async {
    let store = FakeArchiveBrowsingStore(initialRows: [row("unpinned"), row("pinned", pin: "b")])
    let viewModel = ArchiveModeViewModel(store: store, pageSize: 10)

    await viewModel.loadFirstPage()
    await viewModel.togglePinSelected()

    XCTAssertEqual(store.setPinCalls.count, 1)
    XCTAssertNotNil(store.setPinCalls.first?.pin)
    XCTAssertNotEqual(store.setPinCalls.first?.pin, "b")
  }

  private static func row(_ title: String, pin: String? = nil) -> PopupHistoryRow {
    let item = HistoryItem(contents: [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: Data(title.utf8)
      ),
    ])
    item.title = title
    item.pin = pin
    return PopupHistoryRow(legacyItem: item)
  }

  private func row(_ title: String, pin: String? = nil) -> PopupHistoryRow {
    Self.row(title, pin: pin)
  }
}

@MainActor
private final class FakeArchiveBrowsingStore: ArchiveBrowsingStore {
  var searchPages: [Int: PopupHistorySearchPage] = [:]
  var searchRequests: [ArchiveSearchRequest] = []
  var initialPageLimits: [Int] = []
  var materializedRowIDs: [String] = []
  var deletedRowIDs: [String] = []
  var setPinCalls: [(rowID: String, pin: String?)] = []
  var itemsByTitle: [String: HistoryItem] = [:]

  private let initialRows: [PopupHistoryRow]
  private var recentRows: [PopupHistoryRow]

  init(initialRows: [PopupHistoryRow], recentRows: [PopupHistoryRow] = []) {
    self.initialRows = initialRows
    self.recentRows = recentRows
    for row in initialRows + recentRows {
      if let item = row.materializeLegacyItem() {
        itemsByTitle[row.title] = item
      }
    }
  }

  func loadInitialPage(limit: Int) throws -> ArchiveModePage {
    initialPageLimits.append(limit)
    let rows = Array(initialRows.prefix(limit))
    return ArchiveModePage(
      rows: rows,
      nextRecentCursor: initialRows.count > limit
        ? .archive(ArchiveRecentPageCursor(lastCopiedAt: "cursor", id: 1))
        : nil
    )
  }

  func loadMoreRecentRows(after cursor: PopupHistoryPageCursor, limit: Int) throws -> PopupHistoryRecentPage {
    let rows = Array(recentRows.prefix(limit))
    recentRows.removeFirst(min(limit, recentRows.count))
    return PopupHistoryRecentPage(
      rows: rows,
      nextCursor: recentRows.isEmpty ? nil : .archive(ArchiveRecentPageCursor(lastCopiedAt: "cursor", id: 2))
    )
  }

  func search(_ request: ArchiveSearchRequest) async throws -> PopupHistorySearchPage {
    searchRequests.append(request)
    return searchPages[request.offset] ?? PopupHistorySearchPage(rows: [], nextOffset: nil)
  }

  func materialize(_ row: PopupHistoryRow) throws -> HistoryItem {
    materializedRowIDs.append(row.id)
    return row.materializeLegacyItem()!
  }

  func delete(_ row: PopupHistoryRow) throws {
    deletedRowIDs.append(row.id)
  }

  func setPin(_ row: PopupHistoryRow, pin: String?) throws {
    setPinCalls.append((row.id, pin))
  }
}
