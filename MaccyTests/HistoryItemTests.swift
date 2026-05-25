import XCTest
import Defaults
@testable import Maccy

// swiftlint:disable force_try
@MainActor
class HistoryItemTests: XCTestCase {
  func testTitleForString() {
    let title = "foo"
    let item = historyItem(title)
    XCTAssertEqual(item.title, title)
  }

  func testTitleWithWhitespaces() {
    let title = "   foo bar   "
    let item = historyItem(title)
    XCTAssertEqual(item.title, "···foo bar···")
  }

  func testTitleWithNewlines() {
    let title = "\nfoo\nbar\n"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⏎foo⏎bar⏎")
  }

  func testTitleWithTabs() {
    let title = "\tfoo\tbar\t"
    let item = historyItem(title)
    XCTAssertEqual(item.title, "⇥foo⇥bar⇥")
  }

  func testTitleWithRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let item = historyItem(rtf, .rtf)
    XCTAssertEqual(item.title, "foo")
  }

  func testTitleWithHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let item = historyItem(html, .html)
    XCTAssertEqual(item.title, "foo")
  }

  func testImage() {
    let image = NSImage(named: "NSBluetoothTemplate")!
    let item = historyItem(image)
    XCTAssertEqual(item.title, "")
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let item = historyItem(url)
    XCTAssertEqual(item.title, "file:///tmp/产品培训/产品培训.txt")
  }

  func testTextFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let textContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: url.lastPathComponent.data(using: .utf8)
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, textContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "foo.bar")
  }

  func testImageFromUniversalClipboard() {
    let url = Bundle(for: type(of: self)).url(forResource: "guy", withExtension: "jpeg")!
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    XCTAssertEqual(item.image!.tiffRepresentation, NSImage(data: try! Data(contentsOf: url))!.tiffRepresentation)
  }

  func testFileFromUniversalClipboard() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let fileURLContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.fileURL.rawValue,
      value: url.dataRepresentation
    )
    let universalClipboardContent = HistoryItemContent(
      type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
      value: "".data(using: .utf8)
    )
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = [fileURLContent, universalClipboardContent]
    item.title = item.generateTitle()
    XCTAssertEqual(item.title, "file:///tmp/foo.bar")
  }

  func testItemWithoutData() {
    let item = historyItem(nil)
    XCTAssertEqual(item.title, "")
  }

  func testSeveralItemsCanHaveEmptyPin() {
    let item1 = historyItem("foo")
    item1.pin = ""
    let item2 = historyItem("bar")
    item2.pin = ""
    XCTAssertNoThrow(try Storage.shared.context.save())
    XCTAssertEqual(item1.pin, "")
    XCTAssertEqual(item2.pin, "")
  }

  private func historyItem(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: type.rawValue,
        value: data
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: NSImage) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.tiff.rawValue,
        value: value.tiffRepresentation!
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }

  private func historyItem(_ value: URL) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: value.dataRepresentation
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.lastPathComponent.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}

@MainActor
class SwiftDataHistoryStoreTests: XCTestCase {
  let store = SwiftDataHistoryStore()

  override func setUpWithError() throws {
    try store.deleteAll()
  }

  override func tearDownWithError() throws {
    try store.deleteAll()
  }

  func testLoadAllReturnsInsertedItems() throws {
    let itemCount = try store.countItems()
    let contentCount = try store.countContents()
    let item = historyItem("foo")

    try store.insert(item)

    XCTAssertTrue(try store.loadAll().contains { $0 === item })
    XCTAssertEqual(try store.countItems(), itemCount + 1)
    XCTAssertEqual(try store.countContents(), contentCount + 1)
  }

  func testLoadDuplicateCandidatesCurrentlyReturnsAllItemsForInMemoryComparison() throws {
    let first = historyItem("foo")
    let second = historyItem("bar")
    let probe = historyItem("baz")
    try store.insert(first)
    try store.insert(second)

    let candidates = try store.loadDuplicateCandidates(for: probe)

    XCTAssertEqual(candidates.count, 2)
    XCTAssertTrue(candidates.contains { $0 === first })
    XCTAssertTrue(candidates.contains { $0 === second })
  }

  func testDeleteRemovesItemAndContents() throws {
    let item = historyItem("foo")
    try store.insert(item)
    let itemCount = try store.countItems()
    let contentCount = try store.countContents()

    try store.delete(item)

    XCTAssertFalse(try store.loadAll().contains { $0 === item })
    XCTAssertEqual(try store.countItems(), itemCount - 1)
    XCTAssertEqual(try store.countContents(), contentCount - 1)
  }

  func testDeleteUnpinnedPreservesPinnedItemsThenDeleteAllRemovesEverything() throws {
    let pinned = historyItem("foo")
    pinned.pin = "f"
    let unpinned = historyItem("bar")
    try store.insert(pinned)
    try store.insert(unpinned)

    try store.deleteUnpinned()

    XCTAssertTrue(try store.loadAll().contains { $0 === pinned })
    XCTAssertFalse(try store.loadAll().contains { $0 === unpinned })

    try store.deleteAll()

    XCTAssertFalse(try store.loadAll().contains { $0 === pinned })
  }

  private func historyItem(_ value: String) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}

@MainActor
class DuplicateCandidateLookupTests: XCTestCase {
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  private let store = DuplicateCandidateHistoryStore()
  private var history: History!

  override func setUpWithError() throws {
    try SwiftDataHistoryStore().deleteAll()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    store.reset()
    history = History(historyStore: store)
  }

  override func tearDownWithError() throws {
    history = nil
    try SwiftDataHistoryStore().deleteAll()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
  }

  func testExactDuplicateCandidateMergesCopyCountAndExistingMetadata() {
    let existing = historyItem("foo")
    existing.application = "Xcode.app"
    existing.numberOfCopies = 3
    existing.title = "Existing title"
    store.duplicateCandidates = [existing]

    let incoming = historyItem("foo")
    incoming.application = "Maccy.app"
    let added = history.add(incoming)

    XCTAssertTrue(store.didLoadDuplicateCandidates)
    XCTAssertEqual(history.items, [added])
    XCTAssertEqual(added.item.numberOfCopies, 4)
    XCTAssertEqual(added.item.title, "Existing title")
    XCTAssertEqual(added.item.application, "Xcode.app")
  }

  func testSubsetDuplicateCandidateUsesExistingSupersetContents() {
    let supersetContents = [
      content(.string, "one"),
      content(.rtf, "two")
    ]
    let existing = historyItem(contents: supersetContents)
    store.duplicateCandidates = [existing]

    let incoming = historyItem(contents: [content(.string, "one")])
    let added = history.add(incoming)

    XCTAssertEqual(history.items, [added])
    XCTAssertEqual(Set(added.item.contents), Set(supersetContents))
  }

  func testModifiedPasteboardMarkerKeepsModifiedContentsInsteadOfMergingOriginalSessionItem() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let added = history.add(modifiedItem)

    XCTAssertEqual(history.items, [added])
    XCTAssertEqual(added.item.text, "bar")
  }

  private func historyItem(_ value: String) -> HistoryItem {
    historyItem(contents: [content(.string, value)])
  }

  private func historyItem(contents: [HistoryItemContent]) -> HistoryItem {
    let item = HistoryItem()
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()
    return item
  }

  private func content(_ type: NSPasteboard.PasteboardType, _ value: String) -> HistoryItemContent {
    HistoryItemContent(
      type: type.rawValue,
      value: value.data(using: .utf8)
    )
  }
}

@MainActor
private final class DuplicateCandidateHistoryStore: LegacyHistoryStore {
  var didLoadDuplicateCandidates = false
  var duplicateCandidates: [HistoryItem] = []
  private var items: [HistoryItem] = []

  func reset() {
    didLoadDuplicateCandidates = false
    duplicateCandidates = []
    items = []
  }

  func loadAll() throws -> [HistoryItem] {
    items
  }

  func loadDuplicateCandidates(for item: HistoryItem) throws -> [HistoryItem] {
    didLoadDuplicateCandidates = true
    return duplicateCandidates + [item]
  }

  func insert(_ item: HistoryItem) throws {
    items.append(item)
  }

  func delete(_ item: HistoryItem) throws {
    items.removeAll { $0 === item }
  }

  func deleteUnpinned() throws {
    items.removeAll { $0.pin == nil }
  }

  func deleteAll() throws {
    items.removeAll()
  }

  func countItems() throws -> Int {
    items.count
  }

  func countContents() throws -> Int {
    items.flatMap(\.contents).count
  }
}
// swiftlint:enable force_try
